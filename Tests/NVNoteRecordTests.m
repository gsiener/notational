//
//  NVNoteRecordTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVNoteRecord.h"

@interface NVNoteRecordTests : XCTestCase
@end

@implementation NVNoteRecordTests

- (NSDictionary *)serverNote {
	return [NSDictionary dictionaryWithObjectsAndKeys:
			@"Title\nbody", @"content",
			[NSArray arrayWithObjects:@"work", @"todo", nil], @"tags",
			[NSNumber numberWithBool:NO], @"deleted",
			[NSArray arrayWithObjects:@"pinned", @"markdown", nil], @"systemTags",
			[NSNumber numberWithDouble:1700000000.5], @"creationDate",
			[NSNumber numberWithDouble:1700000100.25], @"modificationDate",
			@"https://simplenote.com/s/abc", @"shareURL",
			@"", @"publishURL",
			@"kept verbatim", @"someFutureField", nil];
}

- (void)testRecordFromServerData {
	NVNoteRecord *record = [NVNoteRecord recordWithNoteID:@"abc" serverData:[self serverNote] version:7];
	XCTAssertEqualObjects([record content], @"Title\nbody");
	XCTAssertEqualObjects([record tags], ([NSArray arrayWithObjects:@"work", @"todo", nil]));
	XCTAssertFalse([record deleted]);
	XCTAssertEqual([record creationDate], 1700000000.5);
	XCTAssertEqual([record confirmedVersion], (NSInteger)7);
	XCTAssertFalse([record pending]);
}

- (void)testPushPreservesFieldsNvALTDoesNotOwn {
	NVNoteRecord *record = [NVNoteRecord recordWithNoteID:@"abc" serverData:[self serverNote] version:7];
	[record setContent:@"Title\nedited body"];
	[record setTags:[NSArray arrayWithObject:@"work"]];
	NSDictionary *push = [record dataForPush];
	XCTAssertEqualObjects([push objectForKey:@"content"], @"Title\nedited body");
	XCTAssertEqualObjects([push objectForKey:@"tags"], [NSArray arrayWithObject:@"work"]);
	XCTAssertEqualObjects([push objectForKey:@"systemTags"], ([NSArray arrayWithObjects:@"pinned", @"markdown", nil]));
	XCTAssertEqualObjects([push objectForKey:@"shareURL"], @"https://simplenote.com/s/abc");
	XCTAssertEqualObjects([push objectForKey:@"someFutureField"], @"kept verbatim");
}

- (void)testUntouchedRecordPushesExactlyWhatTheServerSent {
	NVNoteRecord *record = [NVNoteRecord recordWithNoteID:@"abc" serverData:[self serverNote] version:7];
	XCTAssertEqualObjects([record dataForPush], [self serverNote]);
}

- (void)testNewNoteHasRequiredFields {
	NVNoteRecord *record = [[[NVNoteRecord alloc] init] autorelease];
	[record setNoteID:[NVNoteRecord newNoteID]];
	[record setContent:@"new"];
	NSDictionary *push = [record dataForPush];
	for (NSString *key in [NSArray arrayWithObjects:@"content", @"tags", @"deleted", @"systemTags", @"creationDate",
						   @"modificationDate", @"shareURL", @"publishURL", nil])
		XCTAssertNotNil([push objectForKey:key], @"%@", key);
	XCTAssertEqual([[record noteID] length], (NSUInteger)32);
}

- (void)testMalformedServerDataIsTolerated {
	NSDictionary *odd = [NSDictionary dictionaryWithObjectsAndKeys:[NSNull null], @"content",
						 [NSArray arrayWithObjects:@"ok", [NSNumber numberWithInt:3], nil], @"tags", nil];
	NVNoteRecord *record = [NVNoteRecord recordWithNoteID:@"x" serverData:odd version:1];
	XCTAssertEqualObjects([record content], @"");
	XCTAssertEqualObjects([record tags], [NSArray arrayWithObject:@"ok"]);
}

@end
