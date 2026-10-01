//
//  AppController_Simplenote.m
//  Notation
//

#import "AppController_Simplenote.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NVSyncEngine.h"
#import "NVSimplenoteHTTPService.h"
#import "NVLegacyImporter.h"
#import "NVSimplenoteAccountWindowController.h"

NSString *const NVSyncStatusDidChangeNotification = @"NVSyncStatusDidChangeNotification";

static NSString *const AccountKey = @"simplenoteAccount";
static NSString *const ClientIDKey = @"clientID";
static NSString *const LegacyImportKey = @"legacyImportVersion";
static NSString *const NotationSettingsKey = @"notationSettings";

static NVSimplenoteAccountWindowController *accountWindow = nil;

@implementation AppController (Simplenote)

#pragma mark Opening the store

+ (NSString *)notesStorePath {
	NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	return [[support stringByAppendingPathComponent:@"nvALT"] stringByAppendingPathComponent:@"Notes.sqlite"];
}

- (void)migrateLegacyDatabaseIntoStore:(NVNotesStore *)store {
	if ([store metadataValueForKey:LegacyImportKey]) return;

	NVLegacyImporter *importer = [[[NVLegacyImporter alloc] initWithDatabasePath:[NVLegacyImporter defaultDatabasePath]
																journalDirectory:[NVLegacyImporter defaultJournalDirectory]] autorelease];
	NVLegacyImportResult result = [importer read];
	switch (result) {
		case NVLegacyImportRead: {
			for (NVNoteRecord *record in [importer recoveredNotes]) [store saveLocalEdit:record];
			//carry over the settings that still apply
			if (![store metadataValueForKey:NotationSettingsKey]) {
				NotationPrefs *prefs = [[[NotationPrefs alloc] init] autorelease];
				if ([importer bodyFont]) [prefs setBaseBodyFont:[importer bodyFont]];
				if ([importer textColor]) [prefs setForegroundTextColor:[importer textColor]];
				[prefs setConfirmsFileDeletion:[importer confirmsDeletion]];
				[store setMetadataValue:[[NSKeyedArchiver archivedDataWithRootObject:prefs] base64EncodedStringWithOptions:0]
								 forKey:NotationSettingsKey];
			}
			NSLog(@"Migrated from old nvALT database: %lu notes, %lu already in Simplenote, %lu recovered",
				  (unsigned long)[importer totalNotes], (unsigned long)[importer syncedNotes], (unsigned long)[[importer recoveredNotes] count]);
			if ([[importer recoveredNotes] count]) {
				NSAlert *alert = [[[NSAlert alloc] init] autorelease];
				[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Recovered %lu notes that never reached Simplenote", nil),
									   (unsigned long)[[importer recoveredNotes] count]]];
				[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"They're tagged “%@” so you can review them. Your old nvALT files were left untouched.", nil), NVRecoveredNoteTag]];
				[alert runModal];
			}
			break;
		}
		case NVLegacyImportEncrypted: {
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setMessageText:NSLocalizedString(@"Your old nvALT notes database is encrypted", nil)];
			[alert setInformativeText:NSLocalizedString(@"This version keeps notes in Simplenote and can't open encrypted databases. If some notes never synced, open them in the previous nvALT and export them. Your old files were left untouched.", nil)];
			[alert runModal];
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

- (NVSyncEngine *)syncEngineForStore:(NVNotesStore *)store {
	NSString *account = [store metadataValueForKey:AccountKey];
	NSString *token = [[NVSimplenoteCredentials defaultCredentials] tokenForAccount:account];
	if (!account || !token) return nil;
	NVSimplenoteHTTPService *service = [[[NVSimplenoteHTTPService alloc] initWithToken:token clientID:[self clientIDForStore:store]] autorelease];
	return [[[NVSyncEngine alloc] initWithStore:store service:service] autorelease];
}

- (NotationController *)openSimplenoteBackedNotationReturningError:(NSError **)error {
	NVNotesStore *store = [NVNotesStore storeAtPath:[AppController notesStorePath] error:error];
	if (!store) return nil;
	if ([store movedAsideCorruptFile])
		NSLog(@"Notes store was unreadable and was moved aside to %@; re-syncing from Simplenote", [store movedAsideCorruptFile]);

	[self migrateLegacyDatabaseIntoStore:store];

	NotationController *notation = [[[NotationController alloc] initWithNotesStore:store] autorelease];
	NVSyncEngine *engine = [self syncEngineForStore:store];
	if (engine) {
		[notation setSyncEngine:engine];
		[engine start];
	}
	return notation;
}

#pragma mark Account

- (void)installSimplenoteMenuItem {
	NSMenu *appMenu = [[[NSApp mainMenu] itemAtIndex:0] submenu];
	if ([appMenu indexOfItemWithTarget:self andAction:@selector(showSimplenoteAccount:)] >= 0) return;
	NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Simplenote Account…", nil)
												   action:@selector(showSimplenoteAccount:) keyEquivalent:@""] autorelease];
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
	if (![[notationController notesStore] metadataValueForKey:AccountKey])
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
	NVSyncStatus status = (NVSyncStatus)[[[notification userInfo] objectForKey:@"status"] intValue];
	[accountWindow refresh];
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
	return engine ? [engine status] : NVSyncStatusSignedOut;
}

- (NSError *)simplenoteLastError {
	return [[notationController syncEngine] lastError];
}

- (BOOL)simplenoteAccountWillSignInAs:(NSString *)email {
	NVNotesStore *store = [notationController notesStore];
	NSString *previous = [store metadataValueForKey:AccountKey];
	if (!previous || [previous caseInsensitiveCompare:email] == NSOrderedSame || ![store noteCount]) return YES;

	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Switch from %@ to %@?", nil), previous, email]];
	[alert setInformativeText:NSLocalizedString(@"Notes from the other account will be removed from this Mac. They stay in Simplenote. Notes not yet synced will be lost.", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Switch Accounts", nil)];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
	return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)simplenoteAccountDidSignInAs:(NSString *)email token:(NSString *)token {
	NVNotesStore *store = [notationController notesStore];
	NSString *previous = [store metadataValueForKey:AccountKey];
	[[NVSimplenoteCredentials defaultCredentials] setToken:token forAccount:email];

	if (previous && [previous caseInsensitiveCompare:email] != NSOrderedSame) {
		[[notationController syncEngine] stop];
		[notationController setSyncEngine:nil];
		[[NVSimplenoteCredentials defaultCredentials] removeTokenForAccount:previous];
		[store removeAllNotes];
		[store setSyncPoint:nil];
		[store setMetadataValue:email forKey:AccountKey];
		[self setNotationController:[[[NotationController alloc] initWithNotesStore:store] autorelease]];
	} else {
		[store setMetadataValue:email forKey:AccountKey];
	}

	NVSyncEngine *engine = [self syncEngineForStore:store];
	[notationController setSyncEngine:engine];
	[engine start];
}

- (void)simplenoteAccountSignOut {
	NVNotesStore *store = [notationController notesStore];
	NSString *account = [store metadataValueForKey:AccountKey];
	[[notationController syncEngine] stop];
	[notationController setSyncEngine:nil];
	[[NVSimplenoteCredentials defaultCredentials] removeTokenForAccount:account];
	//the account name stays so signing back in to the same account keeps the local copy
}

- (void)simplenoteSyncNow {
	[[notationController syncEngine] syncNow];
}

@end
