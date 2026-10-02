//
//  RealSimplenoteSyncTests.m
//  NotationTests
//
//  Opt-in end-to-end check of the HTTP adapter + Sync engine against a real Simplenote
//  account. Reads the whole account into a temporary store, and writes ONLY to one
//  throwaway note you name (create one first, e.g. with the write spike):
//
//    TEST_RUNNER_NV_SIMPLENOTE_TOKEN=<sync token> \
//    TEST_RUNNER_NV_SIMPLENOTE_TEST_NOTE=<throwaway note id> \
//    xcodebuild test -project Notation.xcodeproj -scheme NotationTests \
//      -only-testing:NotationTests/RealSimplenoteSyncTests
//
//  Logs counts and the throwaway note's own text only. Skipped when unset.
//

#import <XCTest/XCTest.h>
#import "NVSimplenoteHTTPService.h"
#import "NVSyncEngine.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"

@interface RealSimplenoteSyncTests : XCTestCase {
	NSString *directory;
}
@end

@implementation RealSimplenoteSyncTests

- (void)tearDown {
	if (directory) [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
	[super tearDown];
}

- (void)testFullSyncPushAndServerMergeAgainstRealAccount {
	NSDictionary *env = [[NSProcessInfo processInfo] environment];
	NSString *token = [env objectForKey:@"NV_SIMPLENOTE_TOKEN"], *noteID = [env objectForKey:@"NV_SIMPLENOTE_TEST_NOTE"];
	if (![token length] || ![noteID length]) {
		XCTSkip(@"set TEST_RUNNER_NV_SIMPLENOTE_TOKEN and TEST_RUNNER_NV_SIMPLENOTE_TEST_NOTE");
	}

	directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	NVNotesStore *store = [NVNotesStore storeAtPath:[directory stringByAppendingPathComponent:@"Notes.sqlite"] error:NULL];
	NVSimplenoteHTTPService *service = [[NVSimplenoteHTTPService alloc] initWithToken:token clientID:@"nvalt-e2e-test"];
	NVSyncEngine *engine = [[NVSyncEngine alloc] initWithStore:store service:service];
	[engine setDelegateQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];

	//1. first sync: the whole account, read-only
	NSDate *start = [NSDate date];
	NSError *error = nil;
	XCTAssertTrue([engine syncOnceReturningError:&error], @"%@", error);
	NSUInteger serverCount = 0;
	NSString *mark = nil;
	do {
		NVIndexPage *page = [service indexPageAfterMark:mark limit:500 includeData:NO error:&error];
		XCTAssertNotNil(page, @"%@", error);
		serverCount += [[page notes] count];
		mark = [page nextMark];
	} while (mark);
	NSLog(@"[e2e] first sync: %lu notes in %.1fs (server index: %lu); sync point set: %d",
		  (unsigned long)[store noteCount], -[start timeIntervalSinceNow], (unsigned long)serverCount, [store syncPoint] != nil);
	XCTAssertEqual([store noteCount], serverCount);
	XCTAssertEqual([[store pendingNotes] count], (NSUInteger)0);
	NVNoteRecord *throwaway = [store noteWithID:noteID];
	XCTAssertNotNil(throwaway, @"throwaway note not found");

	//2. a local edit to the throwaway note is pushed and confirmed
	NSString *marker = [NSString stringWithFormat:@"edited by nvALT e2e test %@", [[NSUUID UUID] UUIDString]];
	[throwaway setContent:[[throwaway content] stringByAppendingFormat:@"\n%@", marker]];
	[store saveLocalEdit:throwaway];
	XCTAssertTrue([engine syncOnceReturningError:&error], @"%@", error);
	NSInteger serverVersion = 0;
	NSDictionary *onServer = [service noteWithID:noteID version:&serverVersion error:&error];
	XCTAssertTrue([[onServer objectForKey:@"content"] hasSuffix:marker]);
	XCTAssertFalse([[store noteWithID:noteID] pending]);
	XCTAssertEqual([[store noteWithID:noteID] confirmedVersion], serverVersion);

	//3. "the phone" edits the same note while this machine has an unpushed edit: the server merges both
	NSMutableDictionary *phone = [NSMutableDictionary dictionaryWithDictionary:onServer];
	[phone setObject:[[onServer objectForKey:@"content"] stringByAppendingString:@"\nline from the phone"] forKey:@"content"];
	XCTAssertNotNil([service postNoteWithID:noteID data:phone baseVersion:serverVersion version:NULL error:&error], @"%@", error);
	NVNoteRecord *local = [store noteWithID:noteID];
	[local setContent:[NSString stringWithFormat:@"%@\nline from this Mac", [local content]]];
	[store saveLocalEdit:local];
	XCTAssertTrue([engine syncOnceReturningError:&error], @"%@", error);

	NSString *merged = [[service noteWithID:noteID version:NULL error:&error] objectForKey:@"content"];
	NSLog(@"[e2e] merged throwaway note: %@", merged);
	XCTAssertTrue([merged rangeOfString:@"line from the phone"].location != NSNotFound);
	XCTAssertTrue([merged rangeOfString:@"line from this Mac"].location != NSNotFound);
	XCTAssertEqualObjects([[store noteWithID:noteID] content], merged);
	XCTAssertFalse([[store noteWithID:noteID] pending]);

	//4. a quiet cycle afterwards changes nothing
	XCTAssertTrue([engine syncOnceReturningError:&error], @"%@", error);
	XCTAssertEqual([[store pendingNotes] count], (NSUInteger)0);
	[store close];
}

@end
