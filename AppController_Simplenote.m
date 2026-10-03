//
//  AppController_Simplenote.m
//  Notation
//

#import "AppController_Simplenote.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "NVArchiving.h"
#import "NSFileManager+DirectoryLocations.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NVSyncEngine.h"
#import "NVSimplenoteHTTPService.h"
#import "NVLegacyImporter.h"
#import "NVSimplenoteAccountWindowController.h"
#import "TitlebarButton.h"
#import "NVAccountSession.h"

static NSString *const AccountKey = @"simplenoteAccount";
static NSString *const ClientIDKey = @"clientID";
static NSString *const LegacyImportKey = @"legacyImportVersion";
static NSString *const NotationSettingsKey = @"notationSettings";

static NVSimplenoteAccountWindowController *accountWindow = nil;


@implementation AppController (Simplenote)

#pragma mark Opening the store

+ (NSString *)notesStorePath {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *directory = [fm findOrCreateDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appendPathComponent:@"Notational" error:NULL];
	if (!directory) return nil;
	NSString *support = [directory stringByDeletingLastPathComponent];
	NSString *path = [directory stringByAppendingPathComponent:@"Notes.sqlite"];
	
	//builds from before the rename kept the store in .../nvALT; move it (with its WAL files) once
	NSString *earlier = [[support stringByAppendingPathComponent:@"nvALT"] stringByAppendingPathComponent:@"Notes.sqlite"];
	if (![fm fileExistsAtPath:path] && [fm fileExistsAtPath:earlier]) {
		for (NSString *suffix in [NSArray arrayWithObjects:@"", @"-wal", @"-shm", nil]) {
			NSString *from = [earlier stringByAppendingString:suffix];
			if ([fm fileExistsAtPath:from]) [fm moveItemAtPath:from toPath:[path stringByAppendingString:suffix] error:NULL];
		}
		NSLog(@"Moved notes store from %@ to %@", earlier, path);
	}
	return path;
}

- (void)migrateLegacyDatabaseIntoStore:(NVNotesStore *)store {
	if ([store metadataValueForKey:LegacyImportKey]) return;

	NVLegacyImporter *importer = [[NVLegacyImporter alloc] initWithDatabasePath:[NVLegacyImporter defaultDatabasePath]
																journalDirectory:[NVLegacyImporter defaultJournalDirectory]];
	NVLegacyImportResult result = [importer read];
	switch (result) {
		case NVLegacyImportRead: {
			[store saveLocalEdits:[importer recoveredNotes]];
			//carry over the settings that still apply
			if (![store metadataValueForKey:NotationSettingsKey]) {
				NotationPrefs *prefs = [[NotationPrefs alloc] init];
				if ([importer bodyFont]) [prefs setBaseBodyFont:[importer bodyFont]];
				if ([importer textColor]) [prefs setForegroundTextColor:[importer textColor]];
				[prefs setConfirmsFileDeletion:[importer confirmsDeletion]];
				[store setMetadataValue:[NVKeyedArchivedData(prefs) base64EncodedStringWithOptions:0]
								 forKey:NotationSettingsKey];
			}
			NSLog(@"Migrated from old nvALT database: %lu notes, %lu already in Simplenote, %lu recovered",
				  (unsigned long)[importer totalNotes], (unsigned long)[importer syncedNotes], (unsigned long)[[importer recoveredNotes] count]);
			if ([[importer recoveredNotes] count]) {
				NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"Recovered %lu notes that never reached Simplenote", nil),
									   (unsigned long)[[importer recoveredNotes] count]],
						   [NSString stringWithFormat:NSLocalizedString(@"They're tagged “%@” so you can review them. Your old nvALT files were left untouched.", nil), NVRecoveredNoteTag],
						   nil, nil, nil);
			}
			break;
		}
		case NVLegacyImportEncrypted: {
			NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"Your old nvALT notes database is encrypted", nil),
					   NSLocalizedString(@"This version keeps notes in Simplenote and can't open encrypted databases. If some notes never synced, open them in the previous nvALT and export them. Your old files were left untouched.", nil),
					   nil, nil, nil);
			break;
		}
		case NVLegacyImportUnreadable:
			NSLog(@"Old nvALT database exists but couldn't be read; leaving it untouched");
			break;
		case NVLegacyImportNothingFound:
			break;
	}
	[store setMetadataValue:@"1" forKey:LegacyImportKey];
}

- (NSString *)clientIDForStore:(NVNotesStore *)store {
	NSString *clientID = [store metadataValueForKey:ClientIDKey];
	if (!clientID) {
		clientID = [@"nvalt-" stringByAppendingString:[[NVNoteRecord newNoteID] substringToIndex:12]];
		[store setMetadataValue:clientID forKey:ClientIDKey];
	}
	return clientID;
}

- (NVSyncEngine *)syncEngineForStore:(NVNotesStore *)store token:(NSString *)token {
	if (![store metadataValueForKey:AccountKey] || !token) return nil;
	NVSimplenoteHTTPService *service = [[NVSimplenoteHTTPService alloc] initWithToken:token clientID:[self clientIDForStore:store]];
	NVSyncEngine *engine = [[NVSyncEngine alloc] initWithStore:store service:service];
	//a menu-bar app spends most of its time in the background: poll less often there (#36)
	[engine setInBackground:![NSApp isActive]];
	return engine;
}

- (NotationController *)openSimplenoteBackedNotationReturningError:(NSError **)error {
	NSString *storePath = [AppController notesStorePath];
	if (!storePath) {
		if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
											userInfo:[NSDictionary dictionaryWithObject:NSLocalizedString(@"The folder for the notes couldn't be created.", nil) forKey:NSLocalizedDescriptionKey]];
		return nil;
	}
	NVNotesStore *store = [NVNotesStore storeAtPath:storePath error:error];
	if (!store) return nil;
	if ([store movedAsideCorruptFile])
		NSLog(@"Notes store was unreadable and was moved aside to %@; re-syncing from Simplenote", [store movedAsideCorruptFile]);

	[self migrateLegacyDatabaseIntoStore:store];

	NotationController *notation = [[NotationController alloc] initWithNotesStore:store];
    __weak AppController *weakSelf = self;
    accountSession = [[NVAccountSession alloc] initWithNotation:notation
        credentials:[NVSimplenoteCredentials defaultCredentials]
        engineFactory:^NVSyncEngine *(NVNotesStore *aStore, NSString *token) {
            return [weakSelf syncEngineForStore:aStore token:token];
        }];
    [accountSession restoreSignIn];
	return notation;
}

#pragma mark Account

- (void)installSimplenoteMenuItem {
	NSMenu *appMenu = [[[NSApp mainMenu] itemAtIndex:0] submenu];
	if ([appMenu indexOfItemWithTarget:self andAction:@selector(showSimplenoteAccount:)] >= 0) return;
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Simplenote Account…", nil)
												   action:@selector(showSimplenoteAccount:) keyEquivalent:@""];
	[item setTarget:self];
	//right after Preferences… (⌘,)
	NSInteger prefsIndex = -1, i;
	for (i = 0; i < [appMenu numberOfItems]; i++) {
		if ([[[appMenu itemAtIndex:i] keyEquivalent] isEqualToString:@","]) {
			prefsIndex = i;
			break;
		}
	}
	[appMenu insertItem:item atIndex:prefsIndex >= 0 ? prefsIndex + 1 : MIN((NSInteger)2, [appMenu numberOfItems])];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(simplenoteSyncStatusChanged:)
												 name:NVSyncStatusDidChangeNotification object:nil];
	
	//never signed in: notes come from Simplenote, so say so instead of showing an empty list
	//(UI tests launch with -SuppressSignInPrompt YES; the menu item still opens the window)
	if (![[notationController notesStore] metadataValueForKey:AccountKey] &&
		![[NSUserDefaults standardUserDefaults] boolForKey:@"SuppressSignInPrompt"])
		[self performSelector:@selector(showSimplenoteAccount:) withObject:nil afterDelay:0.3];
}

- (IBAction)showSimplenoteAccount:(id)sender {
	if (!accountWindow) accountWindow = [[NVSimplenoteAccountWindowController alloc] init];
	[accountWindow setAccountDelegate:(id<NVSimplenoteAccountDelegate>)self];
	[accountWindow refresh];
	[accountWindow showWindow:sender];
	[[accountWindow window] makeKeyAndOrderFront:sender];
}

- (void)simplenoteSyncStatusChanged:(NSNotification *)notification {
	NVSyncStatus status = (NVSyncStatus)[[[notification userInfo] objectForKey:NVSyncStatusKey] intValue];
	[accountWindow refresh];
	switch (status) {
		case NVSyncStatusSyncing: [titleBarButton setStatusIconType:SynchronizingIcon]; break;
		case NVSyncStatusOffline:
		case NVSyncStatusSignedOut: [titleBarButton setStatusIconType:AlertIcon]; break;
		default: [titleBarButton setStatusIconType:NoIcon]; break;
	}
	if (status == NVSyncStatusSignedOut) {
		//the token stopped working: ask to sign in again
		[self showSimplenoteAccount:nil];
	}
}

//NVSimplenoteAccountDelegate

- (NSString *)simplenoteAccountEmail {
	return [[notationController notesStore] metadataValueForKey:AccountKey];
}

- (NVSyncStatus)simplenoteSyncStatus {
	NVSyncEngine *engine = [notationController syncEngine];
	if (!engine && [accountSession loadingCredentials]) return NVSyncStatusSyncing;
	return engine ? [engine status] : NVSyncStatusSignedOut;
}

- (NSError *)simplenoteLastError {
	return [[notationController syncEngine] lastError];
}

- (void)simplenoteAccountDidSignInAs:(NSString *)email token:(NSString *)token completion:(void (^)(BOOL, NSError *))completion {
    [accountSession signInAs:email token:token choose:^NVAccountSwitchChoice {
        NSInteger result = NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"Switch accounts with unsynced changes?", nil),
            NSLocalizedString(@"Sync changes to the old account before switching, or discard them. Discarded changes cannot be recovered from this Mac.", nil),
            NSLocalizedString(@"Sync and Switch", nil), NSLocalizedString(@"Cancel", nil), NSLocalizedString(@"Discard and Switch", nil));
        if (result == NSAlertFirstButtonReturn) return NVAccountSwitchSync;
        return result == NSAlertThirdButtonReturn ? NVAccountSwitchDiscard : NVAccountSwitchCancel;
    } completion:^(BOOL switched, NSError *error) {
        if (switched && notationController != [accountSession notation])
            [self setNotationController:[accountSession notation]];
        completion(switched, error);
    }];
}

- (void)simplenoteAccountSignOut {
    [accountSession signOut];
}

- (void)simplenoteSyncNow {
	[[notationController syncEngine] syncNow];
}

@end
