//
//  NotesDatabaseTests.m
//  NotationTests
//
//  Characterization tests for the notes database ("Notes & Settings") and the
//  write-ahead journal, exercised through the classes that exist today.
//  They pin current on-disk behaviour ahead of the Notes store refactor (#1).
//
//  NotationPrefs keychain lookups use a per-instance random UUID as the account
//  name, so these tests cannot read or delete the user's real keychain entries.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NVArchiving.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "WALController.h"
#import "NSData_transformations.h"

@interface NotesDatabaseTests : NVTestCase
@end

@implementation NotesDatabaseTests

#pragma mark Helpers

- (NSMutableArray *)sampleNotes {
	return [NSMutableArray arrayWithObjects:
			NVTestNote(@"Groceries", @"eggs\nmilk\ncoffee", @""),
			NVTestNote(@"Ünïcødé ✓", @"emoji 🗒️ and accents àéîõü", @""),
			NVTestNote(@"Empty body", @"", @""),
			nil];
}

- (NotationPrefs *)encryptedPrefsWithPassphrase:(NSString *)passphrase {
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	[prefs setDoesEncryption:YES];
	//low iteration count keeps the test fast; the derivation path is the same
	[prefs setPassphraseData:[passphrase dataUsingEncoding:NSUTF8StringEncoding] withIterations:1000];
	return prefs;
}

//archive → bytes → unarchive, as written to and read from "Notes & Settings"
- (FrozenNotation *)reloadedFrozenNotationFromNotes:(NSMutableArray *)notes prefs:(NotationPrefs *)prefs {
	NSData *databaseBytes = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[NSMutableSet set] prefs:prefs];
	XCTAssertNotNil(databaseBytes);
	XCTAssertGreaterThan([databaseBytes length], (NSUInteger)0);
	return NVUnarchiveKeyedObject(databaseBytes);
}

- (void)assertNotes:(NSArray *)actual matchNotes:(NSArray *)expected {
	XCTAssertEqual([actual count], [expected count]);
	NSUInteger i;
	for (i = 0; i < MIN([actual count], [expected count]); i++) {
		NoteObject *a = [actual objectAtIndex:i], *e = [expected objectAtIndex:i];
		XCTAssertEqualObjects(titleOfNote(a), titleOfNote(e));
		XCTAssertEqualObjects([[a contentString] string], [[e contentString] string]);
		XCTAssertEqual(memcmp([a uniqueNoteIDBytes], [e uniqueNoteIDBytes], sizeof(CFUUIDBytes)), 0);
	}
}

#pragma mark Notes database

- (void)testUnencryptedDatabaseRoundTrip {
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	NSMutableArray *notes = [self sampleNotes];

	FrozenNotation *frozen = [self reloadedFrozenNotationFromNotes:notes prefs:prefs];
	XCTAssertFalse([[frozen notationPrefs] doesEncryption]);

	OSStatus err = noErr;
	NSArray *reloaded = [frozen unpackedNotesWithPrefs:[frozen notationPrefs] returningError:&err];
	XCTAssertEqual(err, (OSStatus)noErr);
	[self assertNotes:reloaded matchNotes:notes];
}

- (void)testEncryptedDatabaseRoundTripWithCorrectPassphrase {
	NotationPrefs *prefs = [self encryptedPrefsWithPassphrase:@"correct horse battery staple"];
	NSMutableArray *notes = [self sampleNotes];

	FrozenNotation *frozen = [self reloadedFrozenNotationFromNotes:notes prefs:prefs];
	NotationPrefs *reloadedPrefs = [frozen notationPrefs];
	XCTAssertTrue([reloadedPrefs doesEncryption]);
	XCTAssertTrue([reloadedPrefs canLoadPassphrase:@"correct horse battery staple"]);

	OSStatus err = noErr;
	NSArray *reloaded = [frozen unpackedNotesWithPrefs:reloadedPrefs returningError:&err];
	XCTAssertEqual(err, (OSStatus)noErr);
	[self assertNotes:reloaded matchNotes:notes];
}

- (void)testEncryptedDatabaseRejectsWrongPassphrase {
	NotationPrefs *prefs = [self encryptedPrefsWithPassphrase:@"right"];
	FrozenNotation *frozen = [self reloadedFrozenNotationFromNotes:[self sampleNotes] prefs:prefs];
	XCTAssertFalse([[frozen notationPrefs] canLoadPassphrase:@"wrong"]);
}

- (void)testEncryptedDatabaseBytesDoNotContainPlaintext {
	NotationPrefs *prefs = [self encryptedPrefsWithPassphrase:@"secret"];
	NSMutableArray *notes = [NSMutableArray arrayWithObject:NVTestNote(@"Diary", @"PLAINTEXT-CANARY-PLAINTEXT-CANARY", @"")];
	NSData *databaseBytes = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[NSMutableSet set] prefs:prefs];
	NSData *canary = [@"PLAINTEXT-CANARY" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertEqual([databaseBytes rangeOfData:canary options:0 range:NSMakeRange(0, [databaseBytes length])].location, (NSUInteger)NSNotFound);
	XCTAssertEqual([databaseBytes rangeOfData:[@"Diary" dataUsingEncoding:NSUTF8StringEncoding] options:0
										range:NSMakeRange(0, [databaseBytes length])].location, (NSUInteger)NSNotFound);
}

- (void)testEachSaveUsesFreshSessionSalt {
	NotationPrefs *prefs = [self encryptedPrefsWithPassphrase:@"secret"];
	NSMutableArray *notes = [self sampleNotes];
	NSData *first = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[NSMutableSet set] prefs:prefs];
	NSData *second = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[NSMutableSet set] prefs:prefs];
	XCTAssertNotEqualObjects(first, second);
}

#pragma mark Write-ahead journal

- (NSData *)journalKey {
	return [[self encryptedPrefsWithPassphrase:@"journal"] WALSessionKey];
}

- (void)testJournalRecoversNotesAfterCrash {
	NSData *key = [self journalKey];
	NSMutableArray *notes = [self sampleNotes];

	WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	XCTAssertNotNil(writer);
	for (NoteObject *note in notes)
		XCTAssertTrue([writer writeNoteObject:note]);
	XCTAssertTrue([writer synchronize]);
	//simulate a crash: release without destroying the journal
	writer = nil;

	//a leftover journal blocks a new writer, which is how launch detects a crash
	WALStorageController *blocked = [[WALStorageController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	XCTAssertNil(blocked);

	WALRecoveryController *recovery = [[WALRecoveryController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	XCTAssertNotNil(recovery);
	NSDictionary *recovered = [recovery recoveredNotes];
	XCTAssertEqual([recovered count], [notes count]);

	NSMutableSet *recoveredTitles = [NSMutableSet set];
	for (id note in [recovered allValues]) [recoveredTitles addObject:titleOfNote(note)];
	XCTAssertEqualObjects(recoveredTitles, [NSSet setWithArray:[notes valueForKey:@"titleString"]]);
	XCTAssertTrue([recovery destroyLogFile]);
}

- (void)testJournalKeepsNewestRevisionOfANote {
	NSData *key = [self journalKey];
	NoteObject *note = NVTestNote(@"Draft", @"version 1", @"");

	WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	XCTAssertTrue([writer writeNoteObject:note]);
	[note setContentString:[[NSAttributedString alloc] initWithString:@"version 2"]];
	[note incrementLSN];
	XCTAssertTrue([writer writeNoteObject:note]);
	XCTAssertTrue([writer synchronize]);
	writer = nil; //release the journal writer

	WALRecoveryController *recovery = [[WALRecoveryController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	NSArray *recovered = [[recovery recoveredNotes] allValues];
	XCTAssertEqual([recovered count], (NSUInteger)1);
	XCTAssertEqualObjects([[[recovered lastObject] contentString] string], @"version 2");
	[recovery destroyLogFile];
}

- (void)testJournalRecordsRemovals {
	NSData *key = [self journalKey];
	NoteObject *note = NVTestNote(@"Doomed", @"bye", @"");

	WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	XCTAssertTrue([writer writeNoteObject:note]);
	[note incrementLSN];
	XCTAssertTrue([writer writeRemovalForNote:note]);
	XCTAssertTrue([writer synchronize]);
	writer = nil; //release the journal writer

	WALRecoveryController *recovery = [[WALRecoveryController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:key];
	NSArray *recovered = [[recovery recoveredNotes] allValues];
	XCTAssertEqual([recovered count], (NSUInteger)1);
	XCTAssertTrue([[recovered lastObject] isKindOfClass:[DeletedNoteObject class]]);
	[recovery destroyLogFile];
}

- (void)testJournalWithWrongKeyRecoversNothing {
	NoteObject *note = NVTestNote(@"Private", @"text", @"");
	WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:[self journalKey]];
	XCTAssertTrue([writer writeNoteObject:note]);
	XCTAssertTrue([writer synchronize]);
	writer = nil; //release the journal writer

	NSData *otherKey = [[self encryptedPrefsWithPassphrase:@"someone else"] WALSessionKey];
	WALRecoveryController *recovery = [[WALRecoveryController alloc] initWithParentFSRep:[self.temporaryDirectory fileSystemRepresentation] encryptionKey:otherKey];
	XCTAssertEqual([[recovery recoveredNotes] count], (NSUInteger)0);
	[recovery destroyLogFile];
}

@end
