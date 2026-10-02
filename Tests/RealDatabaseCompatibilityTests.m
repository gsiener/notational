//
//  RealDatabaseCompatibilityTests.m
//  NotationTests
//
//  Opt-in check that an existing "Notes & Settings" database (and, optionally, a
//  leftover journal) written by an older nvALT build still opens with this code.
//  Point it at a COPY, never the live file:
//
//    TEST_RUNNER_NV_DATABASE="/path/to/copy/Notes & Settings" \
//    TEST_RUNNER_NV_JOURNAL_DIR="/path/to/copy/journal-folder" \
//    xcodebuild test -project Notation.xcodeproj -scheme NotationTests \
//      -only-testing:NotationTests/RealDatabaseCompatibilityTests
//
//  Logs counts, settings and timings only, never note contents. Skipped when unset.
//

#import <XCTest/XCTest.h>
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NVArchiving.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "WALController.h"
#import "NVLegacyImporter.h"
#import "NVNoteContent.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NotationController.h"

@interface RealDatabaseCompatibilityTests : XCTestCase
@end

@implementation RealDatabaseCompatibilityTests

- (FrozenNotation *)frozenNotationAtPath:(NSString *)path {
	NSData *bytes = [NSData dataWithContentsOfFile:path];
	XCTAssertNotNil(bytes, @"could not read %@", path);
	FrozenNotation *frozen = NVUnarchiveKeyedObject(bytes);
	XCTAssertNotNil(frozen, @"unarchiving failed");
	return frozen;
}

- (void)testExistingDatabaseOpens {
	NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_DATABASE"];
	if (![path length]) {
		XCTSkip(@"set TEST_RUNNER_NV_DATABASE to a copy of a Notes & Settings file");
	}

	FrozenNotation *frozen = [self frozenNotationAtPath:path];
	XCTAssertNotNil(frozen);
	NotationPrefs *prefs = [frozen notationPrefs];
	XCTAssertNotNil(prefs);
	NSLog(@"[compat] encrypted=%d storageFormat=%ld epoch=%u syncServices=%@ deletedNotes=%lu",
		  [prefs doesEncryption], (long)[prefs notesStorageFormat], [prefs epochIteration],
		  [[prefs syncServiceAccounts] allKeys], (unsigned long)[[frozen deletedNotes] count]);

	if ([prefs doesEncryption]) {
		NSString *passphrase = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_PASSPHRASE"];
		if (![passphrase length]) {
			XCTSkip(@"database is encrypted; set TEST_RUNNER_NV_PASSPHRASE to unlock it");
		}
		XCTAssertTrue([prefs canLoadPassphrase:passphrase], @"passphrase rejected");
	}

	OSStatus err = noErr;
	NSArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&err];
	XCTAssertEqual(err, (OSStatus)noErr);
	XCTAssertNotNil(notes);

	NSUInteger withBodies = 0;
	for (NoteObject *note in notes) {
		XCTAssertTrue([note isKindOfClass:[NoteObject class]]);
		XCTAssertNotNil(titleOfNote(note));
		if ([[[note contentString] string] length]) withBodies++;
	}
	NSLog(@"[compat] notes=%lu nonEmptyBodies=%lu", (unsigned long)[notes count], (unsigned long)withBodies);

	//Simplenote state carried by each note: what a migration would have to push
	NSUInteger synced = 0, neverSynced = 0, dirty = 0;
	NSDate *newestSync = nil, *oldestDirty = nil;
	for (NoteObject *note in notes) {
		NSDictionary *sn = [[note syncServicesMD] objectForKey:@"SN"];
		if (![sn objectForKey:@"key"]) { neverSynced++; continue; }
		synced++;
		NSNumber *modify = [sn objectForKey:@"modify"];
		NSDate *modified = modify ? [NSDate dateWithTimeIntervalSinceReferenceDate:[modify doubleValue]] : nil;
		if (modified && (!newestSync || [modified compare:newestSync] == NSOrderedDescending)) newestSync = modified;
		if ([[sn objectForKey:@"dirty"] boolValue]) {
			dirty++;
			if (modified && (!oldestDirty || [modified compare:oldestDirty] == NSOrderedAscending)) oldestDirty = modified;
		}
	}
	NSLog(@"[compat] simplenote: synced=%lu neverSynced=%lu dirty=%lu newestSyncedModify=%@ oldestDirtyModify=%@",
		  (unsigned long)synced, (unsigned long)neverSynced, (unsigned long)dirty, newestSync, oldestDirty);
	XCTAssertGreaterThan([notes count], (NSUInteger)0);
	
	//every note's Simplenote content must survive split + recombine byte for byte
	NSUInteger exact = 0;
	for (NoteObject *note in notes) {
		NSString *content = [note combinedContentWithContextSeparator:[[[note syncServicesMD] objectForKey:@"SN"] objectForKey:@"SepStr"]];
		NVNoteContent *split = [NVNoteContent contentWithString:content];
		if ([[split stringWithTitle:[split title] body:[split body]] isEqualToString:content]) exact++;
	}
	NSLog(@"[compat] content round trip: %lu/%lu exact", (unsigned long)exact, (unsigned long)[notes count]);
	XCTAssertEqual(exact, [notes count]);

	NSString *journalDirectory = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_JOURNAL_DIR"];
	if ([journalDirectory length]) {
		WALRecoveryController *recovery = [[WALRecoveryController alloc] initWithParentFSRep:[journalDirectory fileSystemRepresentation]
																		 encryptionKey:[prefs WALSessionKey]];
		XCTAssertNotNil(recovery, @"journal could not be opened");
		NSDictionary *recovered = [recovery recoveredNotes];

		NSMutableSet *existingIDs = [NSMutableSet set];
		for (NoteObject *note in notes)
			[existingIDs addObject:[NSData dataWithBytes:[note uniqueNoteIDBytes] length:sizeof(CFUUIDBytes)]];
		NSUInteger updated = 0, added = 0, removed = 0, journalSynced = 0, journalDirty = 0;
		for (id obj in [recovered allValues]) {
			BOOL known = [existingIDs containsObject:[NSData dataWithBytes:[obj uniqueNoteIDBytes] length:sizeof(CFUUIDBytes)]];
			if ([obj isKindOfClass:[DeletedNoteObject class]]) removed++;
			else if (known) updated++;
			else added++;
			NSDictionary *sn = [[obj syncServicesMD] objectForKey:@"SN"];
			if ([sn objectForKey:@"key"]) journalSynced++;
			if (![sn objectForKey:@"key"] || [[sn objectForKey:@"dirty"] boolValue]) journalDirty++;
		}
		NSLog(@"[compat] journal simplenote: withKey=%lu needsPush=%lu", (unsigned long)journalSynced, (unsigned long)journalDirty);
		NSLog(@"[compat] journal records=%lu (updates to existing=%lu, new notes=%lu, deletions=%lu)",
			  (unsigned long)[recovered count], (unsigned long)updated, (unsigned long)added, (unsigned long)removed);
		//leave the copied journal in place so the check can be re-run
	}
	
	//what migration to the Simplenote-backed store would import as nvalt-recovered notes
	NVLegacyImporter *importer = [[NVLegacyImporter alloc] initWithDatabasePath:path journalDirectory:journalDirectory];
	XCTAssertEqual([importer read], NVLegacyImportRead);
	NSLog(@"[compat] migration: total=%lu synced=%lu wouldRecover=%lu journalRecords=%lu",
		  (unsigned long)[importer totalNotes], (unsigned long)[importer syncedNotes],
		  (unsigned long)[[importer recoveredNotes] count], (unsigned long)[importer journalRecords]);
}

//Launch cost of the Simplenote-backed path: the database's notes, as a synced Notes store
//(each row carrying its server copy), loaded into a NotationController as the app does at launch
- (void)testLoadingTheNotesThroughTheStore {
	NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_DATABASE"];
	if (![path length]) {
		XCTSkip(@"set TEST_RUNNER_NV_DATABASE to a copy of a Notes & Settings file");
	}
	FrozenNotation *frozen = [self frozenNotationAtPath:path];
	NotationPrefs *prefs = [frozen notationPrefs];
	if ([prefs doesEncryption]) XCTSkip(@"database is encrypted");
	OSStatus err = noErr;
	NSArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&err];
	XCTAssertGreaterThan([notes count], (NSUInteger)0);

	NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	NSString *storePath = [directory stringByAppendingPathComponent:@"Notes.sqlite"];
	NVNotesStore *store = [NVNotesStore storeAtPath:storePath error:NULL];
	XCTAssertNotNil(store);
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		for (NoteObject *note in notes) {
			NVNoteRecord *record = [[NVNoteRecord alloc] init];
			[record setNoteID:[NVNoteRecord newNoteID]];
			[record setContent:[note combinedContentWithContextSeparator:[[[note syncServicesMD] objectForKey:@"SN"] objectForKey:@"SepStr"]]];
			[record setTags:[note orderedLabelTitles] ? [note orderedLabelTitles] : [NSArray array]];
			[record setCreationDate:createdDateOfNote(note) + kCFAbsoluteTimeIntervalSince1970];
			[record setModificationDate:modifiedDateOfNote(note) + kCFAbsoluteTimeIntervalSince1970];
			[record setServerData:[record dataForPush]];
			[record setConfirmedVersion:1];
			[t putNote:record];
		}
	}];
	[store close];

	NSMutableArray *storeTimes = [NSMutableArray array], *listTimes = [NSMutableArray array], *controllerTimes = [NSMutableArray array];
	NSUInteger loaded = 0, run;
	for (run = 0; run < 5; run++) {
		@autoreleasepool {
			store = [NVNotesStore storeAtPath:storePath error:NULL];
			CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
			loaded = [[store allNotes] count];
			[storeTimes addObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent() - start]];
			start = CFAbsoluteTimeGetCurrent();
			[store allNotesWithoutServerData];
			[listTimes addObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent() - start]];
			start = CFAbsoluteTimeGetCurrent();
			NotationController *controller = [[NotationController alloc] initWithNotesStore:store];
			[controllerTimes addObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent() - start]];
			[controller closeAllResources];
			[NSObject cancelPreviousPerformRequestsWithTarget:controller];
			[store close];
		}
	}
	NSArray *sortedStore = [storeTimes sortedArrayUsingSelector:@selector(compare:)];
	NSArray *sortedList = [listTimes sortedArrayUsingSelector:@selector(compare:)];
	NSArray *sortedController = [controllerTimes sortedArrayUsingSelector:@selector(compare:)];
	NSLog(@"[compat] launch load of %lu notes: store allNotes median %.0f ms, allNotesWithoutServerData median %.0f ms; NotationController initWithNotesStore median %.0f ms (min %.0f, max %.0f)",
		  (unsigned long)loaded, [[sortedStore objectAtIndex:2] doubleValue] * 1000.0, [[sortedList objectAtIndex:2] doubleValue] * 1000.0,
		  [[sortedController objectAtIndex:2] doubleValue] * 1000.0, [[sortedController firstObject] doubleValue] * 1000.0,
		  [[sortedController lastObject] doubleValue] * 1000.0);
	XCTAssertEqual(loaded, [notes count]);
	[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

@end
