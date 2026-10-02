//
//  NVSyncEngineTests.m
//  NotationTests
//
//  Sync scenarios against the in-memory Simplenote fake: each "machine" is a Notes
//  store plus a Sync engine sharing one fake account.
//

#import <XCTest/XCTest.h>
#import "NVSyncEngine.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NVFakeSimplenoteService.h"

//one nvALT installation
@interface NVTestMachine : NSObject <NVSyncEngineDelegate> {
@public
	NVNotesStore *store;
	NVSyncEngine *engine;
	dispatch_queue_t callbacks;
	NSMutableArray *updates;     //arrays of updated records, one per delivery
	NSMutableArray *removals;
	NSMutableArray *statuses;
}
- (id)initAtPath:(NSString *)path server:(NVFakeSimplenoteService *)server;
- (BOOL)sync;
- (void)drainCallbacks;
- (NVNoteRecord *)note:(NSString *)noteID;
- (NVNoteRecord *)editNote:(NSString *)noteID content:(NSString *)content;
- (NVNoteRecord *)createNoteWithContent:(NSString *)content;
@end

@implementation NVTestMachine

- (id)initAtPath:(NSString *)path server:(NVFakeSimplenoteService *)server {
	if ((self = [super init])) {
		store = [NVNotesStore storeAtPath:path error:NULL];
		engine = [[NVSyncEngine alloc] initWithStore:store service:server];
		callbacks = dispatch_queue_create("test.callbacks", DISPATCH_QUEUE_SERIAL);
		[engine setDelegate:self];
		[engine setDelegateQueue:callbacks];
		[engine setIndexPageSize:3];
		updates = [[NSMutableArray alloc] init];
		removals = [[NSMutableArray alloc] init];
		statuses = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc {
	[engine stop];
	[engine setDelegate:nil];
	[store close];
}

- (BOOL)sync {
	BOOL ok = [engine syncOnceReturningError:NULL];
	[self drainCallbacks];
	return ok;
}

- (void)drainCallbacks {
	dispatch_sync(callbacks, ^{});
}

- (void)syncEngine:(NVSyncEngine *)e didUpdateNotes:(NSArray *)records removedNoteIDs:(NSArray *)noteIDs {
	[updates addObject:records];
	[removals addObjectsFromArray:noteIDs];
}

- (void)syncEngine:(NVSyncEngine *)e didChangeStatus:(NVSyncStatus)status {
	[statuses addObject:[NSNumber numberWithInt:status]];
}

- (NVNoteRecord *)note:(NSString *)noteID {
	return [store noteWithID:noteID];
}

- (NVNoteRecord *)editNote:(NSString *)noteID content:(NSString *)content {
	NVNoteRecord *record = [store noteWithID:noteID];
	[record setContent:content];
	[record setModificationDate:[[NSDate date] timeIntervalSince1970]];
	[store saveLocalEdit:record];
	return [store noteWithID:noteID];
}

- (NVNoteRecord *)createNoteWithContent:(NSString *)content {
	NVNoteRecord *record = [[NVNoteRecord alloc] init];
	[record setNoteID:[NVNoteRecord newNoteID]];
	[record setContent:content];
	[record setCreationDate:[[NSDate date] timeIntervalSince1970]];
	[record setModificationDate:[record creationDate]];
	[store saveLocalEdit:record];
	return [store noteWithID:[record noteID]];
}

@end

//Passes requests through to the fake after a delay, outside its lock, so several can be in flight
//at once; counts how many were, and whether the Notes store was held during any of them.
@interface NVSlowSimplenoteService : NSObject <NVSimplenoteService> {
@public
	NVFakeSimplenoteService *server;
	NVNotesStore *store;
	BOOL indexWithoutData;
	NSUInteger inFlight, maxInFlight, requestsWhileStoreHeld;
}
@end

@implementation NVSlowSimplenoteService

- (void)beginRequest {
	@synchronized(self) {
		inFlight++;
		maxInFlight = MAX(maxInFlight, inFlight);
	}
	//can the store be used right now? a request made inside a transaction holds it
	NVNotesStore *probed = store;
	dispatch_semaphore_t answered = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[probed noteCount];
		dispatch_semaphore_signal(answered);
	});
	if (probed && dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)))) {
		@synchronized(self) { requestsWhileStoreHeld++; }
	}
	[NSThread sleepForTimeInterval:0.02];
}

- (void)endRequest {
	@synchronized(self) { inFlight--; }
}

- (NVIndexPage *)indexPageAfterMark:(NSString *)mark limit:(NSUInteger)limit includeData:(BOOL)includeData error:(NSError **)error {
	return [server indexPageAfterMark:mark limit:limit includeData:includeData && !indexWithoutData error:error];
}

- (NSArray *)changesSince:(NSString *)changeVersion error:(NSError **)error {
	return [server changesSince:changeVersion error:error];
}

- (NSDictionary *)noteWithID:(NSString *)noteID version:(NSInteger *)version error:(NSError **)error {
	[self beginRequest];
	NSDictionary *data = [server noteWithID:noteID version:version error:error];
	[self endRequest];
	return data;
}

- (NSDictionary *)postNoteWithID:(NSString *)noteID data:(NSDictionary *)data baseVersion:(NSInteger)baseVersion
						 version:(NSInteger *)newVersion error:(NSError **)error {
	[self beginRequest];
	NSDictionary *result = [server postNoteWithID:noteID data:data baseVersion:baseVersion version:newVersion error:error];
	[self endRequest];
	return result;
}

@end

//the fake, failing every fetch with a code, or every post of one note as too large
@interface NVFailingSimplenoteService : NVFakeSimplenoteService
@property (atomic, assign) NSInteger getFailureCode;
@property (atomic, copy) NSString *tooLargeNoteID;
@end

@implementation NVFailingSimplenoteService
@synthesize getFailureCode, tooLargeNoteID;

- (NSDictionary *)noteWithID:(NSString *)noteID version:(NSInteger *)version error:(NSError **)error {
	if ([self getFailureCode]) {
		if (error) *error = [NSError errorWithDomain:NVSimplenoteErrorDomain code:[self getFailureCode] userInfo:nil];
		return nil;
	}
	return [super noteWithID:noteID version:version error:error];
}

- (NSDictionary *)postNoteWithID:(NSString *)noteID data:(NSDictionary *)data baseVersion:(NSInteger)baseVersion
						 version:(NSInteger *)newVersion error:(NSError **)error {
	if ([noteID isEqualToString:[self tooLargeNoteID]]) {
		if (error) *error = [NSError errorWithDomain:NVSimplenoteErrorDomain code:NVSimplenoteErrorTooLarge userInfo:nil];
		return nil;
	}
	return [super postNoteWithID:noteID data:data baseVersion:baseVersion version:newVersion error:error];
}
@end

@interface NVSyncEngineTests : XCTestCase {
	NSString *directory;
	NVFakeSimplenoteService *server;
}
@end

@implementation NVSyncEngineTests

- (void)setUp {
	[super setUp];
	directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	server = [[NVFakeSimplenoteService alloc] init];
}

- (void)tearDown {
	[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
	[super tearDown];
}

- (NVTestMachine *)machine:(NSString *)name {
	return [[NVTestMachine alloc] initAtPath:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".sqlite"]]
									   server:server];
}

- (NSString *)serverContentOf:(NSString *)noteID {
	return [[server currentDataOfNote:noteID] objectForKey:@"content"];
}

#pragma mark First sync and catch-up

- (void)testFirstSyncDownloadsEveryNoteIncludingTrash {
	NSMutableArray *ids = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < 10; i++) [ids addObject:[server remoteCreateNoteWithContent:[NSString stringWithFormat:@"note %lu", (unsigned long)i] tags:nil]];
	[server remoteTrashNote:[ids objectAtIndex:3]];

	NVTestMachine *mac = [self machine:@"mac"];
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([mac->store noteCount], (NSUInteger)10);
	XCTAssertTrue([[mac note:[ids objectAtIndex:3]] deleted]);
	XCTAssertEqualObjects([[mac note:[ids objectAtIndex:7]] content], @"note 7");
	XCTAssertEqual([[mac note:[ids objectAtIndex:3]] confirmedVersion], (NSInteger)2);
	XCTAssertEqualObjects([mac->store syncPoint], [server currentChangeVersion]);
	XCTAssertEqual([[mac->updates valueForKeyPath:@"@sum.@count"] integerValue], (NSInteger)10);
	//pages of 3: 4 index requests, no per-note fetches
	XCTAssertEqual([[server requestCounts] countForObject:@"index"], (NSUInteger)4);
	XCTAssertEqual([[server requestCounts] countForObject:@"get"], (NSUInteger)0);
}

- (void)testCatchUpAppliesRemoteCreatesEditsTrashAndPurges {
	NSString *edited = [server remoteCreateNoteWithContent:@"original" tags:nil];
	NSString *trashed = [server remoteCreateNoteWithContent:@"to trash" tags:nil];
	NSString *purged = [server remoteCreateNoteWithContent:@"to purge" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	XCTAssertTrue([mac sync]);
	[mac->updates removeAllObjects];

	[server remoteSetContent:@"edited elsewhere" ofNote:edited];
	[server remoteTrashNote:trashed];
	[server remotePurgeNote:purged];
	NSString *created = [server remoteCreateNoteWithContent:@"created elsewhere" tags:[NSArray arrayWithObject:@"inbox"]];
	XCTAssertTrue([mac sync]);

	XCTAssertEqualObjects([[mac note:edited] content], @"edited elsewhere");
	XCTAssertTrue([[mac note:trashed] deleted]);
	XCTAssertNil([mac note:purged]);
	XCTAssertEqualObjects([[mac note:created] tags], [NSArray arrayWithObject:@"inbox"]);
	XCTAssertEqualObjects(mac->removals, [NSArray arrayWithObject:purged]);
	XCTAssertEqual([[[mac->updates lastObject] valueForKey:@"noteID"] count], (NSUInteger)3);
	XCTAssertEqualObjects([mac->store syncPoint], [server currentChangeVersion]);
	XCTAssertEqual([[server requestCounts] countForObject:@"index"], (NSUInteger)1);
}

- (void)testCatchUpFetchesNotesWhenTheFeedCarriesNoData {
	[server setChangesOmitData:YES];
	NSString *noteID = [server remoteCreateNoteWithContent:@"v1" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[server remoteSetContent:@"v2" ofNote:noteID];
	[server remoteSetContent:@"v3" ofNote:noteID];
	NSString *purged = [server remoteCreateNoteWithContent:@"gone" tags:nil];
	[server remotePurgeNote:purged];
	
	NSUInteger getsBefore = [[server requestCounts] countForObject:@"get"];
	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([[mac note:noteID] content], @"v3");
	XCTAssertEqual([[mac note:noteID] confirmedVersion], (NSInteger)3);
	XCTAssertNil([mac note:purged]);
	//one fetch for the twice-edited note, none for the purged one
	XCTAssertEqual([[server requestCounts] countForObject:@"get"] - getsBefore, (NSUInteger)1);
	
	//our own pushes come back in the feed without data; they must not be fetched again
	[mac editNote:noteID content:@"v4 from nvALT"];
	XCTAssertTrue([mac sync]);
	getsBefore = [[server requestCounts] countForObject:@"get"];
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([[server requestCounts] countForObject:@"get"] - getsBefore, (NSUInteger)0);
}

- (void)testQuietCycleDeliversNothing {
	[server remoteCreateNoteWithContent:@"a" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	XCTAssertTrue([mac sync]);
	[mac->updates removeAllObjects];
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([mac->updates count], (NSUInteger)0);
	XCTAssertEqual([[server requestCounts] countForObject:@"post"], (NSUInteger)0);
}

#pragma mark Pushing local edits

- (void)testLocalEditIsPushedAndConfirmed {
	NSString *noteID = [server remoteCreateNoteWithContent:@"Title\nbody" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"Title\nbody edited"];
	XCTAssertTrue([[mac note:noteID] pending]);

	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([self serverContentOf:noteID], @"Title\nbody edited");
	NVNoteRecord *record = [mac note:noteID];
	XCTAssertFalse([record pending]);
	XCTAssertEqual([record confirmedVersion], [server currentVersionOfNote:noteID]);
	//our own echo in the change feed must not count as a remote update
	[mac->updates removeAllObjects];
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([mac->updates count], (NSUInteger)0);
}

- (void)testNewLocalNoteIsCreatedOnServer {
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	NVNoteRecord *created = [mac createNoteWithContent:@"Written offline\nin nvALT"];
	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([self serverContentOf:[created noteID]], @"Written offline\nin nvALT");
	XCTAssertEqual([[mac note:[created noteID]] confirmedVersion], (NSInteger)1);
	for (NSString *key in [NSArray arrayWithObjects:@"systemTags", @"shareURL", @"publishURL", @"tags", nil])
		XCTAssertNotNil([[server currentDataOfNote:[created noteID]] objectForKey:key], @"%@", key);
}

- (void)testLocalTrashIsPushedAsDeletedFlag {
	NSString *noteID = [server remoteCreateNoteWithContent:@"bye" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	NVNoteRecord *record = [mac note:noteID];
	[record setDeleted:YES];
	[mac->store saveLocalEdit:record];
	XCTAssertTrue([mac sync]);
	XCTAssertTrue([[[server currentDataOfNote:noteID] objectForKey:@"deleted"] boolValue]);
	XCTAssertEqual([server noteCount], (NSUInteger)1); //trashed, never purged
}

- (void)testPushKeepsPinnedAndPublishedState {
	NSString *noteID = [server remoteCreateNoteWithContent:@"pinned note" tags:nil];
	NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:[server currentDataOfNote:noteID]];
	[data setObject:[NSArray arrayWithObjects:@"pinned", @"published", nil] forKey:@"systemTags"];
	[data setObject:@"https://simplenote.com/p/xyz" forKey:@"publishURL"];
	[server remoteSetData:data ofNote:noteID];

	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"pinned note, edited in nvALT"];
	[mac sync];
	NSDictionary *after = [server currentDataOfNote:noteID];
	XCTAssertEqualObjects([after objectForKey:@"systemTags"], ([NSArray arrayWithObjects:@"pinned", @"published", nil]));
	XCTAssertEqualObjects([after objectForKey:@"publishURL"], @"https://simplenote.com/p/xyz");
}

#pragma mark Concurrent edits

- (void)testRemoteChangeDoesNotClobberPendingLocalEdit {
	NSString *noteID = [server remoteCreateNoteWithContent:@"title\nline one\nline two\n" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"title\nline one (mine)\nline two\n"];
	[server remoteSetContent:@"title\nline one\nline two\nadded on phone\n" ofNote:noteID];

	XCTAssertTrue([mac sync]);
	NSString *expected = @"title\nline one (mine)\nline two\nadded on phone\n";
	XCTAssertEqualObjects([self serverContentOf:noteID], expected);
	XCTAssertEqualObjects([[mac note:noteID] content], expected);
	XCTAssertFalse([[mac note:noteID] pending]);
	//the merged result is reported so the UI can show the phone's line
	NSArray *reported = [[mac->updates lastObject] valueForKey:@"content"];
	XCTAssertTrue([reported containsObject:expected]);
}

- (void)testTwoMachinesEditingOfflineConverge {
	NSString *noteID = [server remoteCreateNoteWithContent:@"shopping\neggs\nmilk\n" tags:nil];
	NVTestMachine *home = [self machine:@"home"], *work = [self machine:@"work"];
	[home sync];
	[work sync];

	[home editNote:noteID content:@"shopping\neggs\nmilk\ncoffee\n"];
	[work editNote:noteID content:@"shopping\nfree-range eggs\nmilk\n"];
	XCTAssertTrue([home sync]);
	XCTAssertTrue([work sync]);
	XCTAssertTrue([home sync]);

	NSString *expected = @"shopping\nfree-range eggs\nmilk\ncoffee\n";
	XCTAssertEqualObjects([self serverContentOf:noteID], expected);
	XCTAssertEqualObjects([[home note:noteID] content], expected);
	XCTAssertEqualObjects([[work note:noteID] content], expected);
}

- (void)testTypingDuringAnInFlightPushIsKept {
	NSString *noteID = [server remoteCreateNoteWithContent:@"draft\nfirst\n" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"draft\nfirst\nsecond\n"];

	__block BOOL typed = NO;
	[server setAfterPostApplied:^(NSString *postedID) {
		if (typed) return;
		typed = YES;
		//the user keeps typing while the request is out
		NVNoteRecord *record = [mac->store noteWithID:postedID];
		[record setContent:@"draft\nfirst\nsecond\nthird\n"];
		[mac->store saveLocalEdit:record];
	}];
	XCTAssertTrue([mac sync]);
	[server setAfterPostApplied:nil];

	XCTAssertEqualObjects([[mac note:noteID] content], @"draft\nfirst\nsecond\nthird\n");
	//the cycle pushes again from the new base, so nothing is left behind
	XCTAssertEqualObjects([self serverContentOf:noteID], @"draft\nfirst\nsecond\nthird\n");
	XCTAssertFalse([[mac note:noteID] pending]);
}

- (void)testTypingDuringPushThatMergedARemoteEdit {
	NSString *noteID = [server remoteCreateNoteWithContent:@"top\nmiddle\nbottom\n" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[server remoteSetContent:@"top (phone)\nmiddle\nbottom\n" ofNote:noteID];
	[mac editNote:noteID content:@"top\nmiddle\nbottom\nmine 1\n"];

	__block BOOL typed = NO;
	[server setAfterPostApplied:^(NSString *postedID) {
		if (typed) return;
		typed = YES;
		NVNoteRecord *record = [mac->store noteWithID:postedID];
		[record setContent:@"top\nmiddle\nbottom\nmine 1\nmine 2\n"];
		[mac->store saveLocalEdit:record];
	}];
	//skip the pull so the remote edit is only discovered through the push's merge
	[mac->store setSyncPoint:[server currentChangeVersion]];
	XCTAssertTrue([mac sync]);
	[server setAfterPostApplied:nil];

	NSString *expected = @"top (phone)\nmiddle\nbottom\nmine 1\nmine 2\n";
	XCTAssertEqualObjects([[mac note:noteID] content], expected);
	XCTAssertEqualObjects([self serverContentOf:noteID], expected);
}

- (void)testPrunedBaseVersionIsMergedLocally {
	NSString *noteID = [server remoteCreateNoteWithContent:@"a\nb\nc\n" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"a\nb (mine)\nc\n"];
	[server remoteSetContent:@"a\nb\nc\nd (phone)\n" ofNote:noteID];
	[server pruneHistoryOfNote:noteID];
	[mac->store setSyncPoint:[server currentChangeVersion]];

	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([self serverContentOf:noteID], @"a\nb (mine)\nc\nd (phone)\n");
	XCTAssertFalse([[mac note:noteID] pending]);
}

- (void)testNotePurgedElsewhereWhileEditedHereIsRecreated {
	NSString *noteID = [server remoteCreateNoteWithContent:@"keep me" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"keep me, I was editing this"];
	[server remotePurgeNote:noteID];

	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([self serverContentOf:noteID], @"keep me, I was editing this");
	XCTAssertFalse([[mac note:noteID] pending]);
}

#pragma mark Several notes at once

- (NVTestMachine *)machine:(NSString *)name throughSlowService:(NVSlowSimplenoteService **)outSlow {
	NVTestMachine *mac = [self machine:name];
	NVSlowSimplenoteService *slow = [[NVSlowSimplenoteService alloc] init];
	slow->server = server;
	slow->store = mac->store;
	[mac->engine setDelegate:nil];
	mac->engine = [[NVSyncEngine alloc] initWithStore:mac->store service:slow];
	[mac->engine setDelegate:mac];
	[mac->engine setDelegateQueue:mac->callbacks];
	[mac->engine setIndexPageSize:3];
	*outSlow = slow;
	return mac;
}

- (void)testChangedNotesAreFetchedAFewAtATimeWithTheStoreFree {
	[server setChangesOmitData:YES];
	NSMutableArray *ids = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < 12; i++) [ids addObject:[server remoteCreateNoteWithContent:[NSString stringWithFormat:@"note %lu", (unsigned long)i] tags:nil]];
	NVSlowSimplenoteService *slow = nil;
	NVTestMachine *mac = [self machine:@"mac" throughSlowService:&slow];
	XCTAssertTrue([mac sync]);
	[mac->updates removeAllObjects];
	for (i = 0; i < 12; i++) [server remoteSetContent:[NSString stringWithFormat:@"note %lu, edited", (unsigned long)i] ofNote:[ids objectAtIndex:i]];
	//edited here too: the pull leaves it for the push, which the server merges
	[mac editNote:[ids objectAtIndex:5] content:@"note 5\nmine"];

	XCTAssertTrue([mac sync]);
	for (i = 0; i < 12; i++) {
		NSString *expected = [NSString stringWithFormat:i == 5 ? @"note %lu, edited\nmine" : @"note %lu, edited", (unsigned long)i];
		XCTAssertEqualObjects([[mac note:[ids objectAtIndex:i]] content], expected);
		XCTAssertEqualObjects([self serverContentOf:[ids objectAtIndex:i]], expected);
	}
	//one fetch per changed note but ours
	XCTAssertEqual([[server requestCounts] countForObject:@"get"], (NSUInteger)11);
	XCTAssertGreaterThan(slow->maxInFlight, (NSUInteger)1);
	XCTAssertLessThanOrEqual(slow->maxInFlight, (NSUInteger)4);
	XCTAssertEqual(slow->requestsWhileStoreHeld, (NSUInteger)0);
}

- (void)testAFailedFetchStopsThePullAndLeavesTheSyncPoint {
	server = [[NVFailingSimplenoteService alloc] init];
	[server setChangesOmitData:YES];
	NSString *a = [server remoteCreateNoteWithContent:@"a" tags:nil];
	NSString *b = [server remoteCreateNoteWithContent:@"b" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	XCTAssertTrue([mac sync]);
	NSString *syncPoint = [mac->store syncPoint];
	[server remoteSetContent:@"a2" ofNote:a];
	[server remoteSetContent:@"b2" ofNote:b];
	[(NVFailingSimplenoteService *)server setGetFailureCode:NVSimplenoteErrorServer];
	NSError *error = nil;
	XCTAssertFalse([mac->engine syncOnceReturningError:&error]);
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorServer);
	XCTAssertEqualObjects([mac->store syncPoint], syncPoint);
	XCTAssertEqualObjects([[mac note:a] content], @"a");
	[(NVFailingSimplenoteService *)server setGetFailureCode:0];
	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([[mac note:a] content], @"a2");
	XCTAssertEqualObjects([[mac note:b] content], @"b2");
}

- (void)testAFullSyncFetchesNotesTheIndexListsWithoutData {
	NSMutableArray *ids = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < 7; i++) [ids addObject:[server remoteCreateNoteWithContent:[NSString stringWithFormat:@"note %lu", (unsigned long)i] tags:nil]];
	NVSlowSimplenoteService *slow = nil;
	NVTestMachine *mac = [self machine:@"mac" throughSlowService:&slow];
	slow->indexWithoutData = YES;
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([mac->store noteCount], (NSUInteger)7);
	for (i = 0; i < 7; i++)
		XCTAssertEqualObjects([[mac note:[ids objectAtIndex:i]] content], ([NSString stringWithFormat:@"note %lu", (unsigned long)i]));
	XCTAssertEqual([[server requestCounts] countForObject:@"get"], (NSUInteger)7);
	XCTAssertGreaterThan(slow->maxInFlight, (NSUInteger)1);
	XCTAssertEqual(slow->requestsWhileStoreHeld, (NSUInteger)0);
}

- (void)testPendingNotesArePushedAFewAtATime {
	NVSlowSimplenoteService *slow = nil;
	NVTestMachine *mac = [self machine:@"mac" throughSlowService:&slow];
	XCTAssertTrue([mac sync]);
	NSMutableArray *created = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < 10; i++) [created addObject:[mac createNoteWithContent:[NSString stringWithFormat:@"local %lu", (unsigned long)i]]];
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([[mac->store pendingNotes] count], (NSUInteger)0);
	for (NVNoteRecord *record in created) {
		XCTAssertEqualObjects([self serverContentOf:[record noteID]], [record content]);
		XCTAssertEqual([[mac note:[record noteID]] confirmedVersion], (NSInteger)1);
	}
	XCTAssertGreaterThan(slow->maxInFlight, (NSUInteger)1);
	XCTAssertLessThanOrEqual(slow->maxInFlight, (NSUInteger)4);
	XCTAssertEqual(slow->requestsWhileStoreHeld, (NSUInteger)0);
}

- (void)testATooLargeNoteDoesNotStopTheOthers {
	server = [[NVFailingSimplenoteService alloc] init];
	NVTestMachine *mac = [self machine:@"mac"];
	XCTAssertTrue([mac sync]);
	NVNoteRecord *a = [mac createNoteWithContent:@"a"];
	NVNoteRecord *big = [mac createNoteWithContent:@"too big"];
	NVNoteRecord *c = [mac createNoteWithContent:@"c"];
	[(NVFailingSimplenoteService *)server setTooLargeNoteID:[big noteID]];
	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([[mac->store pendingNotes] valueForKey:@"noteID"], [NSArray arrayWithObject:[big noteID]]);
	XCTAssertEqualObjects([self serverContentOf:[a noteID]], @"a");
	XCTAssertEqualObjects([self serverContentOf:[c noteID]], @"c");
	XCTAssertNil([server currentDataOfNote:[big noteID]]);
}

#pragma mark Re-index and failures

- (void)testForgottenSyncPointTriggersReindexWithoutLosingLocalEdits {
	NSString *kept = [server remoteCreateNoteWithContent:@"kept" tags:nil];
	NSString *purged = [server remoteCreateNoteWithContent:@"purged" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:kept content:@"kept, edited offline"];
	[server remotePurgeNote:purged];
	NSString *added = [server remoteCreateNoteWithContent:@"added" tags:nil];
	[server forgetChangeHistory];

	XCTAssertTrue([mac sync]);
	XCTAssertNil([mac note:purged]);
	XCTAssertNotNil([mac note:added]);
	XCTAssertEqualObjects([self serverContentOf:kept], @"kept, edited offline");
	//the next cycle catches up past our own push without reporting it as a remote change
	[mac->updates removeAllObjects];
	XCTAssertTrue([mac sync]);
	XCTAssertEqualObjects([mac->store syncPoint], [server currentChangeVersion]);
	XCTAssertEqual([mac->updates count], (NSUInteger)0);
	XCTAssertEqual([[server requestCounts] countForObject:@"index"], (NSUInteger)2);
}

- (void)testUnauthorizedSignsOutAndKeepsEdits {
	NSString *noteID = [server remoteCreateNoteWithContent:@"x" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"x edited"];
	[server failNextRequestsWithCodes:[NSArray arrayWithObject:[NSNumber numberWithInteger:NVSimplenoteErrorUnauthorized]]];

	NSError *error = nil;
	XCTAssertFalse([mac->engine syncOnceReturningError:&error]);
	[mac drainCallbacks];
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorUnauthorized);
	XCTAssertEqual([mac->engine status], NVSyncStatusSignedOut);
	XCTAssertEqualObjects([mac->statuses lastObject], [NSNumber numberWithInt:NVSyncStatusSignedOut]);
	XCTAssertTrue([[mac note:noteID] pending]);
}

- (void)testNetworkFailureGoesOfflineThenRecovers {
	NSString *noteID = [server remoteCreateNoteWithContent:@"x" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	[mac editNote:noteID content:@"x edited"];
	[server failNextRequestsWithCodes:[NSArray arrayWithObject:[NSNumber numberWithInteger:NVSimplenoteErrorNetwork]]];
	XCTAssertFalse([mac sync]);
	XCTAssertEqual([mac->engine status], NVSyncStatusOffline);
	XCTAssertTrue([[mac note:noteID] pending]);

	XCTAssertTrue([mac sync]);
	XCTAssertEqual([mac->engine status], NVSyncStatusIdle);
	XCTAssertEqualObjects([self serverContentOf:noteID], @"x edited");
}

- (void)testFailureMidPushKeepsRemainingNotesPending {
	NVTestMachine *mac = [self machine:@"mac"];
	[mac sync];
	NVNoteRecord *a = [mac createNoteWithContent:@"a"];
	NVNoteRecord *b = [mac createNoteWithContent:@"b"];
	//changes request succeeds, first post succeeds, second fails
	[server failNextRequestsWithCodes:[NSArray array]];
	__block NSUInteger posts = 0;
	__weak NVFakeSimplenoteService *weakServer = server;
	[server setAfterPostApplied:^(NSString *postedID) {
		if (++posts == 1) [weakServer failNextRequestsWithCodes:[NSArray arrayWithObject:[NSNumber numberWithInteger:NVSimplenoteErrorServer]]];
	}];
	XCTAssertFalse([mac sync]);
	[server setAfterPostApplied:nil];
	XCTAssertEqual([[mac->store pendingNotes] count], (NSUInteger)1);
	XCTAssertTrue([mac sync]);
	XCTAssertEqual([[mac->store pendingNotes] count], (NSUInteger)0);
	XCTAssertEqualObjects([self serverContentOf:[a noteID]], @"a");
	XCTAssertEqualObjects([self serverContentOf:[b noteID]], @"b");
}

- (void)testStartRunsCyclesInTheBackground {
	[server remoteCreateNoteWithContent:@"from the server" tags:nil];
	NVTestMachine *mac = [self machine:@"mac"];
	[mac->engine setPollInterval:0.2];
	[mac->engine start];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
	while ([mac->store noteCount] == 0 && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:0.05];
	XCTAssertEqual([mac->store noteCount], (NSUInteger)1);

	NVNoteRecord *local = [mac createNoteWithContent:@"pushed by syncNow"];
	[mac->engine syncNow];
	deadline = [NSDate dateWithTimeIntervalSinceNow:5];
	while (![server currentDataOfNote:[local noteID]] && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:0.05];
	XCTAssertEqualObjects([self serverContentOf:[local noteID]], @"pushed by syncNow");
	[mac->engine stop];
}

@end
