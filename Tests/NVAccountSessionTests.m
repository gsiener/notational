#import "NVTestSupport.h"
#import "NVAccountSession.h"
#import "NotationController.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVFakeSimplenoteService.h"

@interface MemoryAccountCredentials : NSObject <NVAccountCredentials>
@property NSMutableDictionary *tokens;
@property dispatch_semaphore_t readStarted;
@property dispatch_semaphore_t allowRead;
@property BOOL failSave;
@end
@implementation MemoryAccountCredentials
- (instancetype)init { if ((self = [super init])) _tokens = [NSMutableDictionary dictionary]; return self; }
- (NSString *)tokenForAccount:(NSString *)email {
    NSString *token = _tokens[email];
    if (_readStarted) dispatch_semaphore_signal(_readStarted);
    if (_allowRead) dispatch_semaphore_wait(_allowRead, DISPATCH_TIME_FOREVER);
    return token;
}
- (BOOL)setToken:(NSString *)token forAccount:(NSString *)email { if (_failSave) return NO; _tokens[email] = token; return YES; }
- (void)removeTokenForAccount:(NSString *)email { if (email) [_tokens removeObjectForKey:email]; }
@end

// Periodic scheduling is irrelevant here; explicit cycles still exercise the real engine.
@interface ManualAccountEngine : NVSyncEngine
@end
@implementation ManualAccountEngine
- (void)start {}
@end

@interface NVAccountSessionTests : NVTestCase {
    NVNotesStore *store;
    NVFakeSimplenoteService *oldServer, *newServer;
    MemoryAccountCredentials *credentials;
    NVAccountSession *session;
    NotationController *original;
    NSString *noteID;
}
@end
@implementation NVAccountSessionTests
- (void)setUp {
    [super setUp];
    store = [NVNotesStore storeAtPath:[self.temporaryDirectory stringByAppendingPathComponent:@"Notes.sqlite"] error:NULL];
    oldServer = [[NVFakeSimplenoteService alloc] init];
    newServer = [[NVFakeSimplenoteService alloc] init];
    credentials = [[MemoryAccountCredentials alloc] init];
    [credentials setToken:@"old-token" forAccount:@"old@example.com"];
    [store setMetadataValue:@"old@example.com" forKey:@"simplenoteAccount"];
    noteID = [oldServer remoteCreateNoteWithContent:@"Old note\noriginal" tags:nil];
    NVSyncEngine *engine = [[ManualAccountEngine alloc] initWithStore:store service:oldServer];
    XCTAssertTrue([engine syncOnceReturningError:NULL]);
    original = [[NotationController alloc] initWithNotesStore:store];
    [original setSyncEngine:engine];
    NVFakeSimplenoteService *old = oldServer, *next = newServer;
    session = [[NVAccountSession alloc] initWithNotation:original credentials:credentials
        engineFactory:^NVSyncEngine *(NVNotesStore *aStore, NSString *token) {
            return [[ManualAccountEngine alloc] initWithStore:aStore service:[token isEqual:@"old-token"] ? old : next];
        }];
}
- (void)tearDown {
    [[session notation] closeAllResources];
    [original closeAllResources];
    [store close];
    [super tearDown];
}
- (void)edit {
    [[original noteForRecordID:noteID] setContentString:[[NSAttributedString alloc] initWithString:@"unsaved"]];
}
- (BOOL)switchChoosing:(NVAccountSwitchChoice)choice error:(NSError **)error {
    XCTestExpectation *done = [self expectationWithDescription:@"transition"];
    __block BOOL result = NO;
    __block NSError *failure;
    [session signInAs:@"new@example.com" token:@"new-token" choose:^{ return choice; }
        completion:^(BOOL switched, NSError *e) { result = switched; failure = e; [done fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    if (error) *error = failure;
    return result;
}
- (void)assertOldNoteCannotReachNewAccount {
    // AppController retires the old controller again while rebinding the UI.
    [original closeAllResources];
    XCTAssertNil([store noteWithID:noteID]);
    XCTAssertTrue([[[session notation] syncEngine] syncOnceReturningError:NULL]);
    XCTAssertNil([newServer currentDataOfNote:noteID]);
}
- (void)testDiscardRetiresDirtyControllerBeforeClearingStore {
    [self edit];
    XCTAssertTrue([self switchChoosing:NVAccountSwitchDiscard error:NULL]);
    [self assertOldNoteCannotReachNewAccount];
    XCTAssertEqualObjects([oldServer currentDataOfNote:noteID][@"content"], @"Old note\noriginal");
}
- (void)testSyncAndSwitchSendsDirtyEditsOnlyToOldAccount {
    [self edit];
    XCTAssertTrue([self switchChoosing:NVAccountSwitchSync error:NULL]);
    XCTAssertEqualObjects([oldServer currentDataOfNote:noteID][@"content"], @"Old note\nunsaved");
    [self assertOldNoteCannotReachNewAccount];
}
- (void)testCancelKeepsOldAccountAndEdits {
    [self edit];
    XCTAssertFalse([self switchChoosing:NVAccountSwitchCancel error:NULL]);
    XCTAssertEqual([session notation], original);
    XCTAssertEqualObjects([store metadataValueForKey:@"simplenoteAccount"], @"old@example.com");
    XCTAssertTrue([[store noteWithID:noteID] pending]);
    XCTAssertNil(credentials.tokens[@"new@example.com"]);
}
- (void)testFailedSyncNeverDiscardsAndCanBeRetried {
    [self edit];
    [oldServer failNextRequestsWithCodes:@[@(NVSimplenoteErrorNetwork)]];
    NSError *error;
    XCTAssertFalse([self switchChoosing:NVAccountSwitchSync error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual([session notation], original);
    XCTAssertTrue([[store noteWithID:noteID] pending]);
    XCTAssertTrue([self switchChoosing:NVAccountSwitchSync error:NULL]);
    [self assertOldNoteCannotReachNewAccount];
}
- (void)testNewEditsDuringSyncKeepTheOldAccountActive {
    [self edit];
    NotationController *controller = original;
    NSString *identifier = noteID;
    oldServer.afterPostApplied = ^(NSString *postedID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[controller noteForRecordID:identifier] setContentString:[[NSAttributedString alloc] initWithString:@"typed during sync"]];
        });
    };
    NSError *error;
    XCTAssertFalse([self switchChoosing:NVAccountSwitchSync error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual([session notation], original);
    XCTAssertEqualObjects([[store noteWithID:noteID] content], @"Old note\ntyped during sync");
    XCTAssertTrue([[store noteWithID:noteID] pending]);
    XCTAssertEqual([newServer noteCount], (NSUInteger)0);
    oldServer.afterPostApplied = nil;
}
- (void)testSignOutDuringSyncCancelsTheSwitch {
    [self edit];
    NVAccountSession *account = session;
    oldServer.afterPostApplied = ^(NSString *postedID) {
        dispatch_async(dispatch_get_main_queue(), ^{ [account signOut]; });
    };
    XCTAssertFalse([self switchChoosing:NVAccountSwitchSync error:NULL]);
    XCTAssertEqual([session notation], original);
    XCTAssertNil([original syncEngine]);
    XCTAssertEqualObjects([store metadataValueForKey:@"simplenoteAccount"], @"old@example.com");
    XCTAssertNil(credentials.tokens[@"new@example.com"]);
    oldServer.afterPostApplied = nil;
}
- (void)testSameAccountSignInPreservesNotesWithoutDiscardPrompt {
    [self edit];
    __block BOOL finished = NO;
    [session signInAs:@"OLD@example.com" token:@"old-token" choose:^{
        XCTFail(@"The same account must not offer to discard its notes");
        return NVAccountSwitchCancel;
    } completion:^(BOOL switched, NSError *error) { finished = switched; XCTAssertNil(error); }];
    XCTAssertTrue(finished);
    XCTAssertEqual([session notation], original);
    XCTAssertNotNil([store noteWithID:noteID]);
}
- (void)testSignedOutPendingNotesRequireDiscardOrOldAccountSignIn {
    [self edit];
    [session signOut];
    XCTAssertNil([original syncEngine]);
    XCTAssertNotNil([store noteWithID:noteID]);
    NSError *error;
    XCTAssertFalse([self switchChoosing:NVAccountSwitchSync error:&error]);
    XCTAssertNotNil(error);
    XCTAssertTrue([self switchChoosing:NVAccountSwitchDiscard error:NULL]);
    [self assertOldNoteCannotReachNewAccount];
}
- (void)testFirstSignInKeepsLocalOnlyNotes {
    [original setSyncEngine:nil];
    [store removeAllNotes];
    [store setSyncPoint:nil];
    [store setMetadataValue:nil forKey:@"simplenoteAccount"];
    NoteObject *local = [[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@"unsaved"]
        title:@"Local note" delegate:original labels:nil];
    [original addNotes:@[local]];
    noteID = [local noteRecordID];
    XCTAssertTrue([self switchChoosing:NVAccountSwitchCancel error:NULL]);
    XCTAssertEqual([session notation], original);
    XCTAssertTrue([[[session notation] syncEngine] syncOnceReturningError:NULL]);
    XCTAssertEqualObjects([newServer currentDataOfNote:noteID][@"content"], @"Local note\nunsaved");
}
- (void)testCredentialFailureLeavesOldAccountIntact {
    [self edit];
    credentials.failSave = YES;
    NSError *error;
    XCTAssertFalse([self switchChoosing:NVAccountSwitchDiscard error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects([store metadataValueForKey:@"simplenoteAccount"], @"old@example.com");
    XCTAssertNotNil([store noteWithID:noteID]);
}
- (void)testCancellingSwitchDoesNotCancelCredentialRestoration {
    [self edit];
    [original setSyncEngine:nil];
    credentials.readStarted = dispatch_semaphore_create(0);
    credentials.allowRead = dispatch_semaphore_create(0);
    [session restoreSignIn];
    XCTAssertEqual(dispatch_semaphore_wait(credentials.readStarted, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)), 0L);
    XCTAssertFalse([self switchChoosing:NVAccountSwitchCancel error:NULL]);
    XCTAssertTrue([session loadingCredentials]);
    dispatch_semaphore_signal(credentials.allowRead);
    NSPredicate *restored = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return ![(NVAccountSession *)object loadingCredentials];
    }];
    [self expectationForPredicate:restored evaluatedWithObject:session handler:nil];
    [self waitForExpectationsWithTimeout:3 handler:nil];
    XCTAssertNotNil([original syncEngine]);
    XCTAssertEqualObjects([store metadataValueForKey:@"simplenoteAccount"], @"old@example.com");
}
- (void)testDelayedCredentialReadCannotUndoSignOut {
    [original setSyncEngine:nil];
    credentials.readStarted = dispatch_semaphore_create(0);
    credentials.allowRead = dispatch_semaphore_create(0);
    [session restoreSignIn];
    XCTAssertEqual(dispatch_semaphore_wait(credentials.readStarted, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)), 0L);
    [session signOut];
    dispatch_semaphore_signal(credentials.allowRead);
    // Drain main-queue delivery after the credential worker is released.
    XCTestExpectation *drained = [self expectationWithDescription:@"credential completion"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/10), dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectationsWithTimeout:3 handler:nil];
    XCTAssertNil([original syncEngine]);
    XCTAssertFalse([session loadingCredentials]);
    XCTAssertNotNil([store noteWithID:noteID]);
}

- (void)testStatusOwnerPublishesExpiryOnceAndIgnoresDuplicateOrRetiredEngine {
    NSMutableArray *events = [NSMutableArray array];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NVSyncStatusDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *event) { [events addObject:event]; }];
    NVSyncEngine *active = [original syncEngine];
    [session syncEngine:active didChangeStatus:NVSyncStatusSyncing];
    [session syncEngine:active didChangeStatus:NVSyncStatusIdle];
    [session syncEngine:active didChangeStatus:NVSyncStatusSignedOut];
    [session syncEngine:active didChangeStatus:NVSyncStatusSignedOut];
    XCTAssertEqual([events count], (NSUInteger)3);
    XCTAssertEqualObjects([events.lastObject userInfo][NVAccountCredentialExpiredKey], @(YES));
    [session signOut];
    [session syncEngine:active didChangeStatus:NVSyncStatusSyncing];
    XCTAssertEqual([events count], (NSUInteger)3);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

- (void)testOrdinarySignOutIsSignedOutWithoutExpiryPrompt {
    NSMutableArray *events = [NSMutableArray array];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NVSyncStatusDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *event) { [events addObject:event]; }];
    [session syncEngine:[original syncEngine] didChangeStatus:NVSyncStatusIdle];
    [session signOut];
    XCTAssertEqual([session status], NVSyncStatusSignedOut);
    XCTAssertEqual([events count], (NSUInteger)2);
    XCTAssertEqualObjects([events.lastObject userInfo][NVAccountCredentialExpiredKey], @(NO));
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

- (void)testMissingRestoredCredentialReturnsToSignedOutWithoutExpiryPrompt {
    [original setSyncEngine:nil];
    [credentials removeTokenForAccount:@"old@example.com"];
    NSMutableArray *events = [NSMutableArray array];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NVSyncStatusDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *event) { [events addObject:event]; }];
    [session restoreSignIn];
    NSPredicate *restored = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return ![(NVAccountSession *)object loadingCredentials];
    }];
    [self expectationForPredicate:restored evaluatedWithObject:session handler:nil];
    [self waitForExpectationsWithTimeout:3 handler:nil];
    XCTAssertNil([original syncEngine]);
    XCTAssertEqual([session status], NVSyncStatusSignedOut);
    XCTAssertEqual([events count], (NSUInteger)2);
    XCTAssertEqualObjects([events.lastObject userInfo][NVAccountCredentialExpiredKey], @(NO));
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

- (void)testRejectedCredentialFromActiveEnginePublishesOneExpiry {
    NVSyncEngine *active = [original syncEngine];
    NSMutableArray *events = [NSMutableArray array];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NVSyncStatusDidChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *event) { [events addObject:event]; }];
    [session syncEngine:active didChangeStatus:NVSyncStatusIdle];
    [oldServer failNextRequestsWithCodes:@[@(NVSimplenoteErrorUnauthorized)]];
    XCTAssertFalse([active syncOnceReturningError:NULL]);
    NSPredicate *signedOut = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [(NVAccountSession *)object status] == NVSyncStatusSignedOut;
    }];
    [self expectationForPredicate:signedOut evaluatedWithObject:session handler:nil];
    [self waitForExpectationsWithTimeout:3 handler:nil];
    NSUInteger expiries = 0;
    for (NSNotification *event in events)
        if ([event.userInfo[NVAccountCredentialExpiredKey] boolValue]) expiries++;
    XCTAssertEqual(expiries, (NSUInteger)1);
    [session syncEngine:active didChangeStatus:NVSyncStatusSignedOut];
    XCTAssertEqual([events count], (NSUInteger)3);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}
@end
