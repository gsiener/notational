//
//  NVLegacyImporterTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "NVLegacyImporter.h"
#import "NVNoteRecord.h"
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NoteObject.h"
#import "WALController.h"

@interface NVLegacyImporterTests : NVTestCase {
	NSString *databasePath, *journalDirectory;
}
@end

@implementation NVLegacyImporterTests

- (void)setUp {
	[super setUp];
	databasePath = [self.temporaryDirectory stringByAppendingPathComponent:@"Notes & Settings"];
	journalDirectory = [self.temporaryDirectory stringByAppendingPathComponent:@"Caches"];
	[[NSFileManager defaultManager] createDirectoryAtPath:journalDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)markSynced:(NoteObject *)note dirty:(BOOL)dirty {
	NSMutableDictionary *md = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"abc123", @"key", [NSNumber numberWithInt:4], @"version",
							   [NSNumber numberWithDouble:1000], @"modify", nil];
	if (dirty) [md setObject:[NSNumber numberWithBool:YES] forKey:@"dirty"];
	[note setSyncObjectAndKeyMD:md forService:@"SN"];
}

- (void)writeDatabase:(NSArray *)notes prefs:(NotationPrefs *)prefs {
	NSData *bytes = [FrozenNotation frozenDataWithExistingNotes:[notes mutableCopy] deletedNotes:[NSMutableSet set] prefs:prefs];
	XCTAssertTrue([bytes writeToFile:databasePath atomically:YES]);
}

- (NVLegacyImporter *)importer {
	return [[NVLegacyImporter alloc] initWithDatabasePath:databasePath journalDirectory:journalDirectory];
}

- (void)testNoDatabase {
	XCTAssertEqual([[self importer] read], NVLegacyImportNothingFound);
}

- (void)testSyncedNotesAreNotImported {
	NoteObject *a = NVTestNote(@"Synced", @"fine", @"");
	[self markSynced:a dirty:NO];
	[self writeDatabase:[NSArray arrayWithObject:a] prefs:[[NotationPrefs alloc] init]];

	NVLegacyImporter *importer = [self importer];
	XCTAssertEqual([importer read], NVLegacyImportRead);
	XCTAssertEqual([importer totalNotes], (NSUInteger)1);
	XCTAssertEqual([importer syncedNotes], (NSUInteger)1);
	XCTAssertEqual([[importer recoveredNotes] count], (NSUInteger)0);
}

- (void)testNeverSyncedAndDirtyNotesAreRecoveredAsNewTaggedNotes {
	NoteObject *never = NVTestNote(@"Offline idea", @"written on a plane", @"ideas travel");
	NoteObject *dirty = NVTestNote(@"Edited", @"edited but not pushed", @"");
	[self markSynced:dirty dirty:YES];
	NoteObject *clean = NVTestNote(@"Clean", @"in sync", @"");
	[self markSynced:clean dirty:NO];
	[self writeDatabase:[NSArray arrayWithObjects:never, dirty, clean, nil] prefs:[[NotationPrefs alloc] init]];

	NVLegacyImporter *importer = [self importer];
	XCTAssertEqual([importer read], NVLegacyImportRead);
	NSArray *recovered = [importer recoveredNotes];
	XCTAssertEqual([recovered count], (NSUInteger)2);

	NVNoteRecord *idea = nil;
	for (NVNoteRecord *record in recovered) if ([[record content] hasPrefix:@"Offline idea"]) idea = record;
	XCTAssertEqualObjects([idea content], @"Offline idea\n\nwritten on a plane");
	XCTAssertEqualObjects([idea tags], ([NSArray arrayWithObjects:@"ideas", @"travel", NVRecoveredNoteTag, nil]));
	XCTAssertEqual([[idea noteID] length], (NSUInteger)32);
	XCTAssertFalse([[idea noteID] isEqualToString:@"abc123"]);
	XCTAssertGreaterThan([idea creationDate], 1500000000.0); //converted to 1970-based seconds
	for (NVNoteRecord *record in recovered) XCTAssertTrue([[record tags] containsObject:NVRecoveredNoteTag]);
}

- (void)testRecoveredTagsAreSplitAsTheTagUISplitsThem {
	NoteObject *note = NVTestNote(@"Tagged", @"with semicolons", @"ideas;travel\tlater");
	[self writeDatabase:[NSArray arrayWithObject:note] prefs:[[NotationPrefs alloc] init]];

	NVLegacyImporter *importer = [self importer];
	XCTAssertEqual([importer read], NVLegacyImportRead);
	NVNoteRecord *recovered = [[importer recoveredNotes] lastObject];
	XCTAssertEqualObjects([recovered tags], (@[@"ideas", @"travel", @"later", NVRecoveredNoteTag]));
	XCTAssertEqualWithAccuracy([recovered modificationDate], modifiedDateOfNote(note) + kCFAbsoluteTimeIntervalSince1970, 0.001);
}

- (void)testJournalChangesNewerThanTheDatabaseCount {
	NoteObject *note = NVTestNote(@"Journal", @"v1", @"");
	[self markSynced:note dirty:NO];
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	[self writeDatabase:[NSArray arrayWithObject:note] prefs:prefs];

	//after the last database save, the note was edited and the edit only reached the journal
	[note setContentString:[[NSAttributedString alloc] initWithString:@"v2 only in the journal"]];
	[note incrementLSN];
	[self markSynced:note dirty:YES];
	WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:[journalDirectory fileSystemRepresentation]
																	  encryptionKey:[prefs WALSessionKey]];
	XCTAssertTrue([writer writeNoteObject:note]);
	XCTAssertTrue([writer synchronize]);
	writer = nil; //release the journal writer

	NVLegacyImporter *importer = [self importer];
	XCTAssertEqual([importer read], NVLegacyImportRead);
	XCTAssertEqual([importer journalRecords], (NSUInteger)1);
	XCTAssertEqual([[importer recoveredNotes] count], (NSUInteger)1);
	XCTAssertTrue([[[[importer recoveredNotes] lastObject] content] hasSuffix:@"v2 only in the journal"]);
	//the importer never deletes the journal
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[journalDirectory stringByAppendingPathComponent:@"Interim Note-Changes"]]);
}

- (void)testEncryptedDatabaseIsReportedNotRead {
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	[prefs setDoesEncryption:YES];
	[prefs setPassphraseData:[@"secret" dataUsingEncoding:NSUTF8StringEncoding] withIterations:1000];
	[self writeDatabase:[NSArray arrayWithObject:NVTestNote(@"Locked", @"x", @"")] prefs:prefs];
	XCTAssertEqual([[self importer] read], NVLegacyImportEncrypted);
}

- (void)testGarbageFileIsUnreadableAndUntouched {
	NSData *garbage = [@"not an archive" dataUsingEncoding:NSUTF8StringEncoding];
	[garbage writeToFile:databasePath atomically:YES];
	XCTAssertEqual([[self importer] read], NVLegacyImportUnreadable);
	XCTAssertEqualObjects([NSData dataWithContentsOfFile:databasePath], garbage);
}

- (void)testSettingsAreExtracted {
	NotationPrefs *prefs = [[NotationPrefs alloc] init];
	[prefs setConfirmsFileDeletion:NO];
	[prefs setBaseBodyFont:[NSFont fontWithName:@"Menlo" size:15]];
	[self writeDatabase:[NSArray array] prefs:prefs];
	NVLegacyImporter *importer = [self importer];
	XCTAssertEqual([importer read], NVLegacyImportRead);
	XCTAssertFalse([importer confirmsDeletion]);
	XCTAssertEqualObjects([[importer bodyFont] fontName], @"Menlo-Regular");
	XCTAssertEqual([[importer bodyFont] pointSize], (CGFloat)15);
}

@end
