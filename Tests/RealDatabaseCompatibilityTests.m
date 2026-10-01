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
//  Logs counts and settings only, never note contents. Skipped when unset.
//

#import <XCTest/XCTest.h>
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "WALController.h"

@interface RealDatabaseCompatibilityTests : XCTestCase
@end

@implementation RealDatabaseCompatibilityTests

- (FrozenNotation *)frozenNotationAtPath:(NSString *)path {
	NSData *bytes = [NSData dataWithContentsOfFile:path];
	XCTAssertNotNil(bytes, @"could not read %@", path);
	FrozenNotation *frozen = nil;
	@try {
		frozen = [NSKeyedUnarchiver unarchiveObjectWithData:bytes];
	} @catch (NSException *e) {
		XCTFail(@"unarchiving failed: %@", [e reason]);
	}
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

	NSString *journalDirectory = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_JOURNAL_DIR"];
	if ([journalDirectory length]) {
		WALRecoveryController *recovery = [[[WALRecoveryController alloc] initWithParentFSRep:[journalDirectory fileSystemRepresentation]
																		 encryptionKey:[prefs WALSessionKey]] autorelease];
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
}

@end
