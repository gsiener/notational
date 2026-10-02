//
//  NVNotesStoreTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVNotesStore.h"
#import "NVNoteRecord.h"

@interface NVNotesStoreTests : XCTestCase {
	NSString *directory;
	NSString *path;
}
@end

@implementation NVNotesStoreTests

- (void)setUp {
	[super setUp];
	directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	path = [directory stringByAppendingPathComponent:@"Notes.sqlite"];
}

- (void)tearDown {
	[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
	[super tearDown];
}

- (NVNotesStore *)openStore {
	NSError *error = nil;
	NVNotesStore *store = [NVNotesStore storeAtPath:path error:&error];
	XCTAssertNotNil(store, @"%@", error);
	return store;
}

- (NVNoteRecord *)serverRecord:(NSString *)noteID content:(NSString *)content version:(NSInteger)version {
	NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:content, @"content", [NSArray arrayWithObject:@"tag"], @"tags",
						  [NSNumber numberWithBool:NO], @"deleted", [NSNumber numberWithDouble:1700000000], @"creationDate",
						  [NSNumber numberWithDouble:1700000500], @"modificationDate",
						  [NSArray arrayWithObject:@"pinned"], @"systemTags", @"x", @"futureField", nil];
	return [NVNoteRecord recordWithNoteID:noteID serverData:data version:version];
}

//writes server-confirmed records the way the Sync engine does, in one transaction
- (void)put:(NSArray *)records into:(NVNotesStore *)store {
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		for (NVNoteRecord *record in records) [t putNote:record];
	}];
}

- (void)testServerNoteRoundTripsAcrossReopen {
	NVNotesStore *store = [self openStore];
	[self put:@[[self serverRecord:@"a" content:@"Title\nbody" version:4]] into:store];
	[store setSyncPoint:@"cv123"];
	[store close];

	store = [self openStore];
	NVNoteRecord *record = [store noteWithID:@"a"];
	XCTAssertEqualObjects([record content], @"Title\nbody");
	XCTAssertEqualObjects([record tags], [NSArray arrayWithObject:@"tag"]);
	XCTAssertEqual([record confirmedVersion], (NSInteger)4);
	XCTAssertFalse([record pending]);
	XCTAssertEqual([record creationDate], 1700000000.0);
	XCTAssertEqualObjects([[record serverData] objectForKey:@"futureField"], @"x");
	XCTAssertEqualObjects([[record serverData] objectForKey:@"systemTags"], [NSArray arrayWithObject:@"pinned"]);
	XCTAssertEqualObjects([store syncPoint], @"cv123");
}

- (void)testContentIsStoredByteForByte {
	NVNotesStore *store = [self openStore];
	NSArray *samples = [NSArray arrayWithObjects:@"", @"no newline", @"trailing\n", @"crlf\r\nline\r\n", @"tabs\tand  spaces  ",
						@"🗒️ emoji 👍🏽 and àéîõü", [NSString stringWithFormat:@"nul%Cinside", (unichar)0], @"\n\n\nleading", nil];
	NSUInteger i;
	NSMutableArray *records = [NSMutableArray array];
	for (i = 0; i < [samples count]; i++)
		[records addObject:[self serverRecord:[NSString stringWithFormat:@"n%lu", (unsigned long)i] content:[samples objectAtIndex:i] version:1]];
	[self put:records into:store];
	[store close];
	store = [self openStore];
	for (i = 0; i < [samples count]; i++) {
		NSString *stored = [[store noteWithID:[NSString stringWithFormat:@"n%lu", (unsigned long)i]] content];
		XCTAssertEqualObjects(stored, [samples objectAtIndex:i]);
		XCTAssertEqual([stored length], [[samples objectAtIndex:i] length]);
	}
}

- (void)testLocalEditsArePendingAndBumpRevision {
	NVNotesStore *store = [self openStore];
	[self put:@[[self serverRecord:@"a" content:@"v1" version:1]] into:store];

	NVNoteRecord *edit = [store noteWithID:@"a"];
	[edit setContent:@"edited"];
	[store saveLocalEdit:edit];
	[store saveLocalEdit:edit];

	NVNoteRecord *stored = [store noteWithID:@"a"];
	XCTAssertTrue([stored pending]);
	XCTAssertEqual([stored localRevision], (NSInteger)2);
	XCTAssertEqualObjects([stored content], @"edited");
	//the confirmed base is untouched by local edits
	XCTAssertEqual([stored confirmedVersion], (NSInteger)1);
	XCTAssertEqualObjects([[stored serverData] objectForKey:@"content"], @"v1");
	XCTAssertEqual([[store pendingNotes] count], (NSUInteger)1);
}

- (void)testNewLocalNote {
	NVNotesStore *store = [self openStore];
	NVNoteRecord *note = [[NVNoteRecord alloc] init];
	[note setNoteID:[NVNoteRecord newNoteID]];
	[note setContent:@"brand new"];
	[store saveLocalEdit:note];
	NVNoteRecord *stored = [store noteWithID:[note noteID]];
	XCTAssertTrue([stored pending]);
	XCTAssertEqual([stored confirmedVersion], (NSInteger)0);
	XCTAssertEqual([stored localRevision], (NSInteger)1);
}

- (void)testTransactionIsAtomicReadModifyWrite {
	NVNotesStore *store = [self openStore];
	[self put:@[[self serverRecord:@"a" content:@"v1" version:1]] into:store];

	//hammer the same note from many threads; every increment must land
	dispatch_apply(200, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t i) {
		[store performTransaction:^(id<NVNotesStoreTransaction> t) {
			NVNoteRecord *record = [t noteWithID:@"a"];
			[record setConfirmedVersion:[record confirmedVersion] + 1];
			[t putNote:record];
		}];
	});
	XCTAssertEqual([[store noteWithID:@"a"] confirmedVersion], (NSInteger)201);
}

- (void)testTransactionCreatesUpdatesAndRemovesTogether {
	NVNotesStore *store = [self openStore];
	[self put:@[[self serverRecord:@"old" content:@"x" version:1]] into:store];
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		XCTAssertNil([t noteWithID:@"new"]);
		NSUInteger i;
		for (i = 0; i < 300; i++)
			[t putNote:[self serverRecord:[NSString stringWithFormat:@"n%lu", (unsigned long)i] content:@"y" version:1]];
		NVNoteRecord *old = [t noteWithID:@"old"];
		[old setContent:@"changed"];
		[t putNote:old];
		[t removeNoteWithID:@"n0"];
		XCTAssertEqual([[t allNotes] count], (NSUInteger)300);
	}];
	XCTAssertEqual([store noteCount], (NSUInteger)300);
	XCTAssertEqualObjects([[store noteWithID:@"old"] content], @"changed");
}

- (void)testReadsSeeQueuedWrites {
	NVNotesStore *store = [self openStore];
	NSUInteger i;
	//local edits are queued and return at once
	for (i = 0; i < 500; i++) {
		NVNoteRecord *note = [[NVNoteRecord alloc] init];
		[note setNoteID:[NSString stringWithFormat:@"n%lu", (unsigned long)i]];
		[note setContent:@"x"];
		[store saveLocalEdit:note];
	}
	XCTAssertEqual([store noteCount], (NSUInteger)500);
	XCTAssertEqual([[store allNotes] count], (NSUInteger)500);
	[store removeAllNotes];
	XCTAssertEqual([store noteCount], (NSUInteger)0);
}

- (void)testMetadata {
	NVNotesStore *store = [self openStore];
	XCTAssertNil([store syncPoint]);
	[store setMetadataValue:@"me@example.com" forKey:@"account"];
	XCTAssertEqualObjects([store metadataValueForKey:@"account"], @"me@example.com");
	[store setMetadataValue:nil forKey:@"account"];
	XCTAssertNil([store metadataValueForKey:@"account"]);
}

- (void)testUnreadableFileIsMovedAsideNotDeleted {
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
	NSData *garbage = [@"this is not a sqlite database, it's a lovely note someone might want back" dataUsingEncoding:NSUTF8StringEncoding];
	[garbage writeToFile:path atomically:YES];

	NVNotesStore *store = [self openStore];
	XCTAssertNotNil([store movedAsideCorruptFile]);
	XCTAssertEqualObjects([NSData dataWithContentsOfFile:[store movedAsideCorruptFile]], garbage);
	XCTAssertEqual([store noteCount], (NSUInteger)0);
	[self put:@[[self serverRecord:@"a" content:@"works" version:1]] into:store];
	XCTAssertEqualObjects([[store noteWithID:@"a"] content], @"works");
}

- (void)testLoadsThousandsOfNotesQuickly {
	NVNotesStore *store = [self openStore];
	NSUInteger i;
	NSString *body = [@"" stringByPaddingToLength:2000 withString:@"lorem ipsum " startingAtIndex:0];
	NSMutableArray *records = [NSMutableArray array];
	for (i = 0; i < 2500; i++)
		[records addObject:[self serverRecord:[NSString stringWithFormat:@"n%lu", (unsigned long)i] content:body version:1]];
	[self put:records into:store];
	[store close];

	NSDate *start = [NSDate date];
	store = [self openStore];
	NSArray *all = [store allNotes];
	XCTAssertEqual([all count], (NSUInteger)2500);
	XCTAssertLessThan(-[start timeIntervalSinceNow], 2.0);
}

@end
