#import "NVAccountSession.h"
#import "NotationController.h"
#import "NVNotesStore.h"

static NSString *const AccountKey = @"simplenoteAccount";
NSString *const NVAccountCredentialExpiredKey = @"credentialExpired";
static NSError *TransitionError(NSString *message) {
    return [NSError errorWithDomain:@"NVAccountSession" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation NVAccountSession {
    id<NVAccountCredentials> credentials;
    NVSyncEngine *(^engineFactory)(NVNotesStore *, NSString *);
    NSUInteger generation;
    NVSyncStatus currentStatus;
}
@synthesize notation = _notation, loadingCredentials = _loadingCredentials;
- (NVSyncStatus)status { return currentStatus; }

- (void)publishStatus:(NVSyncStatus)status expired:(BOOL)expired {
    if (currentStatus == status) return;
    currentStatus = status;
    [[NSNotificationCenter defaultCenter] postNotificationName:NVSyncStatusDidChangeNotification
        object:_notation userInfo:@{NVSyncStatusKey: @(status), NVAccountCredentialExpiredKey: @(expired)}];
}

- (void)syncEngine:(NVSyncEngine *)engine didChangeStatus:(NVSyncStatus)status {
    if (engine != [_notation syncEngine]) return;
    [self publishStatus:status expired:status == NVSyncStatusSignedOut];
}

- (instancetype)initWithNotation:(NotationController *)notation
                    credentials:(id<NVAccountCredentials>)aCredentials
                  engineFactory:(NVSyncEngine *(^)(NVNotesStore *, NSString *))factory {
    if ((self = [super init])) {
        _notation = notation;
        credentials = aCredentials;
        engineFactory = [factory copy];
        notation.accountSession = self;
        currentStatus = NVSyncStatusSignedOut;
    }
    return self;
}

- (void)restoreSignIn {
    NSString *account = [[_notation notesStore] metadataValueForKey:AccountKey];
    if (!account) return;
    NSUInteger request = ++generation;
    _loadingCredentials = YES;
    [self publishStatus:NVSyncStatusSyncing expired:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *token = [self->credentials tokenForAccount:account];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (request != self->generation) return;
            self->_loadingCredentials = NO;
            if (token) {
                NVSyncEngine *engine = self->engineFactory([self->_notation notesStore], token);
                [self->_notation setSyncEngine:engine];
                [engine start];
            }
            [self publishStatus:[self->_notation syncEngine] ? NVSyncStatusSyncing : NVSyncStatusSignedOut expired:NO];
        });
    });
}

- (void)signOut {
    ++generation;
    _loadingCredentials = NO;
    [_notation setSyncEngine:nil];
    [_notation flushAllNoteChanges];
    [credentials removeTokenForAccount:[[_notation notesStore] metadataValueForKey:AccountKey]];
    [self publishStatus:NVSyncStatusSignedOut expired:NO];
}

- (void)signInAs:(NSString *)email token:(NSString *)token
         choose:(NVAccountSwitchChoice (^)(void))choose
     completion:(void (^)(BOOL, NSError *))completion {
    NVNotesStore *store = [_notation notesStore];
    NSString *previous = [store metadataValueForKey:AccountKey];
    BOOL switching = previous && [previous caseInsensitiveCompare:email] != NSOrderedSame;
    [_notation flushAllNoteChanges];
    NVAccountSwitchChoice choice = switching && [[store pendingNotes] count] ? choose() : NVAccountSwitchDiscard;
    if (choice == NVAccountSwitchCancel) { completion(NO, nil); return; }
    NSUInteger request = ++generation;
    _loadingCredentials = NO;

    void (^finish)(NSError *) = ^(NSError *error) {
        if (request != self->generation) { completion(NO, nil); return; }
        if (error) { completion(NO, error); return; }
        // Recheck edits made while the network request was in flight.
        [self->_notation flushAllNoteChanges];
        if (choice == NVAccountSwitchSync && [[store pendingNotes] count]) {
            completion(NO, TransitionError(NSLocalizedString(@"Some changes are still unsynced. Retry or explicitly discard them to switch accounts.", nil)));
            return;
        }
        if (![self->credentials setToken:token forAccount:email]) {
            completion(NO, TransitionError(NSLocalizedString(@"The sign-in token could not be saved. The account was not changed.", nil)));
            return;
        }
        if (switching) {
            // Retire and flush the old controller BEFORE clearing its shared store.
            [self->_notation setSyncEngine:nil];
            [self->_notation closeAllResources];
            [store removeAllNotes];
            [store setSyncPoint:nil];
            [store setMetadataValue:email forKey:AccountKey];
            self->_notation = [[NotationController alloc] initWithNotesStore:store];
            self->_notation.accountSession = self;
            [self->credentials removeTokenForAccount:previous];
        } else {
            [store setMetadataValue:email forKey:AccountKey];
        }
        NVSyncEngine *engine = self->engineFactory(store, token);
        [self->_notation setSyncEngine:engine];
        [engine start];
        [self publishStatus:NVSyncStatusSyncing expired:NO];
        completion(YES, nil);
    };
    if (choice != NVAccountSwitchSync) { finish(nil); return; }
    NVSyncEngine *engine = [_notation syncEngine];
    if (!engine) {
        finish(TransitionError(NSLocalizedString(@"Sign in to the old account to sync its changes, or explicitly discard them to switch accounts.", nil)));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [engine syncOnceReturningError:&error];
        if (!ok && !error) error = TransitionError(NSLocalizedString(@"Sync failed. The account was not changed.", nil));
        dispatch_async(dispatch_get_main_queue(), ^{ finish(error); });
    });
}
@end
