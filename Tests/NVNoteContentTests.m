//
//  NVNoteContentTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVNoteContent.h"

@interface NVNoteContentTests : XCTestCase
@end

@implementation NVNoteContentTests

- (NSArray *)samples {
	NSMutableString *longLine = [NSMutableString string];
	while ([longLine length] < 200) [longLine appendString:@"a fairly long first line that keeps going "];
	return [NSArray arrayWithObjects:
			@"", @"Title", @"Title\nbody", @"Title\n\nbody\nmore\n", @"Title\r\n\r\nwindows body\r\n",
			@"  \n\nTitle after blank lines\nbody", @"\nbody only after empty first line", @"\n\n\n",
			@"Title   \n  indented body", @"Title\t\ttabbed", @"🗒️ Emoji title\n👍🏽 body",
			[longLine stringByAppendingString:@"\nsecond line"], @"Title line separator body",
			@"Title\n", @"   ", nil];
}

- (void)testUnchangedContentRoundTripsExactly {
	for (NSString *sample in [self samples]) {
		NVNoteContent *content = [NVNoteContent contentWithString:sample];
		XCTAssertEqualObjects([content stringWithTitle:[content title] body:[content body]], sample, @"%@", sample);
	}
}

- (void)testTitleAndBody {
	NVNoteContent *content = [NVNoteContent contentWithString:@"Groceries\n\neggs\nmilk"];
	XCTAssertEqualObjects([content title], @"Groceries");
	XCTAssertEqualObjects([content body], @"eggs\nmilk");

	content = [NVNoteContent contentWithString:@"\n\nbody only"];
	XCTAssertEqualObjects([content title], @"body only");

	content = [NVNoteContent contentWithString:@""];
	XCTAssertEqualObjects([content title], @"Untitled Note");
	XCTAssertEqualObjects([content body], @"");
}

- (void)testLongFirstLineWrapsAtAWord {
	NVNoteContent *content = [NVNoteContent contentWithString:
							  @"This first line is much longer than sixty characters and keeps on going for a while\nnext"];
	XCTAssertLessThanOrEqual([[content title] length], (NSUInteger)60);
	XCTAssertFalse([[content title] hasSuffix:@" "]);
	XCTAssertTrue([[content body] hasSuffix:@"\nnext"]);
}

- (void)testEditsKeepTheOriginalSeparator {
	NVNoteContent *content = [NVNoteContent contentWithString:@"Title\n\n\nbody"];
	XCTAssertEqualObjects([content stringWithTitle:@"Title" body:@"new body"], @"Title\n\n\nnew body");
	XCTAssertEqualObjects([content stringWithTitle:@"Renamed" body:@"body"], @"Renamed\n\n\nbody");

	content = [NVNoteContent contentWithString:@"Title\r\nbody"];
	XCTAssertEqualObjects([content stringWithTitle:@"Title" body:@"edited"], @"Title\r\nedited");
}

- (void)testAddingABodyToATitleOnlyNoteInsertsALineBreak {
	NVNoteContent *content = [NVNoteContent contentWithString:@"Just a title"];
	XCTAssertEqualObjects([content stringWithTitle:@"Just a title" body:@"now a body"], @"Just a title\nnow a body");
}

- (void)testPlaceholderTitleIsNeverWrittenBack {
	NVNoteContent *content = [NVNoteContent contentWithString:@""];
	XCTAssertEqualObjects([content stringWithTitle:[content title] body:@"typed into an empty note"], @"typed into an empty note");
}

@end
