//
//  NVFakeSimplenoteServiceTests.m
//  NotationTests
//
//  The fake server is the Sync engine's test double; these pin the behaviour the engine
//  relies on, matching what the real Simperium HTTP API does (see docs/research).
//

#import <XCTest/XCTest.h>
#import "NVFakeSimplenoteService.h"
#import "NVNoteRecord.h"

@interface NVFakeSimplenoteServiceTests : XCTestCase {
	NVFakeSimplenoteService *server;
}
@end

@implementation NVFakeSimplenoteServiceTests

- (void)setUp {
	[super setUp];
	server = [[NVFakeSimplenoteService alloc] init];
}

- (void)tearDown {
	[super tearDown];
}

- (NSDictionary *)dataWithContent:(NSString *)content {
	NVNoteRecord *record = [[NVNoteRecord alloc] init];
	[record setContent:content];
	return [record dataForPush];
}

- (void)testCreateThenUpdateAdvancesVersions {
	NSInteger version = 0;
	NSError *error = nil;
	XCTAssertNotNil([server postNoteWithID:@"n1" data:[self dataWithContent:@"one"] baseVersion:0 version:&version error:&error]);
	XCTAssertEqual(version, (NSInteger)1);
	[server postNoteWithID:@"n1" data:[self dataWithContent:@"two"] baseVersion:1 version:&version error:&error];
	XCTAssertEqual(version, (NSInteger)2);
	XCTAssertEqualObjects([[server currentDataOfNote:@"n1"] objectForKey:@"content"], @"two");
}

- (void)testIdenticalPostDoesNotCreateAVersion {
	NSInteger version = 0;
	NSDictionary *data = [self dataWithContent:@"same"];
	[server postNoteWithID:@"n1" data:data baseVersion:0 version:&version error:NULL];
	[server postNoteWithID:@"n1" data:data baseVersion:1 version:&version error:NULL];
	XCTAssertEqual(version, (NSInteger)1);
}

- (void)testStalePostIsMergedServerSide {
	NSInteger version = 0;
	[server postNoteWithID:@"n1" data:[self dataWithContent:@"title\none\ntwo\n"] baseVersion:0 version:&version error:NULL];
	[server remoteSetContent:@"title\none\ntwo\nfrom another machine\n" ofNote:@"n1"];
	NSDictionary *merged = [server postNoteWithID:@"n1" data:[self dataWithContent:@"title\nONE\ntwo\n"] baseVersion:1 version:&version error:NULL];
	XCTAssertEqual(version, (NSInteger)3);
	XCTAssertEqualObjects([merged objectForKey:@"content"], @"title\nONE\ntwo\nfrom another machine\n");
}

- (void)testStalePostKeepsFieldsThePosterDidNotChange {
	NSInteger version = 0;
	[server postNoteWithID:@"n1" data:[self dataWithContent:@"text"] baseVersion:0 version:&version error:NULL];
	NSMutableDictionary *pinned = [NSMutableDictionary dictionaryWithDictionary:[server currentDataOfNote:@"n1"]];
	[pinned setObject:[NSArray arrayWithObject:@"pinned"] forKey:@"systemTags"];
	[server remoteSetData:pinned ofNote:@"n1"];
	NSDictionary *merged = [server postNoteWithID:@"n1" data:[self dataWithContent:@"text edited"] baseVersion:1 version:&version error:NULL];
	XCTAssertEqualObjects([merged objectForKey:@"systemTags"], [NSArray arrayWithObject:@"pinned"]);
	XCTAssertEqualObjects([merged objectForKey:@"content"], @"text edited");
}

- (void)testIndexPagesAndChangeVersion {
	NSUInteger i;
	for (i = 0; i < 5; i++) [server remoteCreateNoteWithContent:[NSString stringWithFormat:@"note %lu", (unsigned long)i] tags:nil];
	NSError *error = nil;
	NVIndexPage *page = [server indexPageAfterMark:nil limit:2 includeData:YES error:&error];
	XCTAssertEqual([[page notes] count], (NSUInteger)2);
	XCTAssertNotNil([page nextMark]);
	XCTAssertEqualObjects([page changeVersion], [server currentChangeVersion]);
	NSUInteger seen = [[page notes] count];
	while ([page nextMark]) {
		page = [server indexPageAfterMark:[page nextMark] limit:2 includeData:NO error:&error];
		seen += [[page notes] count];
		XCTAssertNil([(NVRemoteNote *)[[page notes] lastObject] data]);
	}
	XCTAssertEqual(seen, (NSUInteger)5);
}

- (void)testChangesFeed {
	NSString *start = [server currentChangeVersion];
	NSString *a = [server remoteCreateNoteWithContent:@"a" tags:nil];
	[server remoteSetContent:@"a2" ofNote:a];
	[server remotePurgeNote:a];
	NSError *error = nil;
	NSArray *changes = [server changesSince:start error:&error];
	XCTAssertEqual([changes count], (NSUInteger)3);
	XCTAssertEqual([(NVRemoteChange *)[changes objectAtIndex:1] version], (NSInteger)2);
	XCTAssertTrue([[changes lastObject] removed]);
	XCTAssertEqual([[server changesSince:[server currentChangeVersion] error:&error] count], (NSUInteger)0);
}

- (void)testForgottenHistoryRequiresReindex {
	NSString *start = [server currentChangeVersion];
	[server remoteCreateNoteWithContent:@"a" tags:nil];
	[server forgetChangeHistory];
	NSError *error = nil;
	XCTAssertNil([server changesSince:start error:&error]);
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorUnknownChangeVersion);
}

- (void)testInjectedFailures {
	[server failNextRequestsWithCodes:[NSArray arrayWithObjects:[NSNumber numberWithInteger:NVSimplenoteErrorUnauthorized], nil]];
	NSError *error = nil;
	XCTAssertNil([server indexPageAfterMark:nil limit:10 includeData:NO error:&error]);
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorUnauthorized);
	XCTAssertNotNil([server indexPageAfterMark:nil limit:10 includeData:NO error:&error]);
	XCTAssertEqual([[server requestCounts] countForObject:@"index"], (NSUInteger)2);
}

@end
