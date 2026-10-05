//
//  NotesListPreviewTests.m
//  NotationTests
//
//  The notes list's preview strings and the @done strikethrough, both made for every note when the
//  list is built (#64): they must stay small and skip notes with nothing to do.
//

#import <XCTest/XCTest.h>
#import "NSString_CustomTruncation.h"
#import "AttributedPlainText.h"
#import "GlobalPrefs.h"

@interface NotesListPreviewTests : XCTestCase
@end

@implementation NotesListPreviewTests

- (NSAttributedString *)bodyOfLength:(NSUInteger)length {
	return [[NSAttributedString alloc] initWithString:[@"" stringByPaddingToLength:length withString:@"body text " startingAtIndex:0]];
}

//a title wider than the column used to wrap the body count around and put the whole body in the preview
- (void)testPreviewOfALongTitleHoldsNoBody {
	NSString *title = [@"" stringByPaddingToLength:200 withString:@"Long title " startingAtIndex:0];
	NSAttributedString *preview = [title attributedSingleLinePreviewFromBodyText:[self bodyOfLength:100000] upToWidth:300];
	XCTAssertLessThan([preview length], [title length] + 20);
	NSAttributedString *multiLine = [title attributedMultiLinePreviewFromBodyText:[self bodyOfLength:100000] upToWidth:300 intrusionWidth:2000];
	XCTAssertLessThan([multiLine length], [title length] + 20);
}

//before the window gives the list its width, previews are built with width 0
- (void)testPreviewWithNoWidthHoldsNoBody {
	NSAttributedString *preview = [@"Title" attributedSingleLinePreviewFromBodyText:[self bodyOfLength:100000] upToWidth:0];
	XCTAssertLessThan([preview length], (NSUInteger)30, @"title and delimiter only");
}

- (void)testPreviewStillShowsTheStartOfTheBody {
	NSAttributedString *preview = [@"Title" attributedSingleLinePreviewFromBodyText:[self bodyOfLength:100000] upToWidth:300];
	XCTAssertTrue([[preview string] containsString:@"body text"]);
	XCTAssertLessThan([preview length], (NSUInteger)200);
}

- (BOOL)isStruck:(NSAttributedString *)text at:(NSUInteger)index {
	return [text attribute:NSStrikethroughStyleAttributeName atIndex:index effectiveRange:NULL] != nil;
}

- (void)testDoneLinesAreStruckAndUnstruck {
	XCTAssertTrue([[GlobalPrefs defaultPrefs] autoFormatsDoneTag]);
	NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"plain\nbuy milk @done\nother"];
	[text addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [text length])];
	XCTAssertFalse([self isStruck:text at:1]);
	XCTAssertTrue([self isStruck:text at:7]);
	XCTAssertFalse([self isStruck:text at:22]);
	//the tag deleted: the line is no longer struck, though no @done is left anywhere
	[text replaceCharactersInRange:NSMakeRange(14, 6) withString:@""];
	[text addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [text length])];
	XCTAssertFalse([self isStruck:text at:7]);
}

//Which characters are struck, as a string of 1s and 0s; and the same for the hidden-tag attribute.
- (NSString *)strikeMapOf:(NSAttributedString *)text attribute:(NSString *)name {
	NSMutableString *map = [NSMutableString string];
	for (NSUInteger i = 0; i < [text length]; i++)
		[map appendString:[text attribute:name atIndex:i effectiveRange:NULL] ? @"1" : @"0"];
	return map;
}

//pins the line rules: a line is struck up to its first " @done", the tag and what follows are not,
//lines are only scanned within the range, and a struck line that loses its tag is unstruck
- (void)testDoneScanFollowsTheLineRules {
	//lines (one string each in the maps below): "a @done\n" "b\n" "c @done x @done y\r\n" "d\n" " e @done"
	NSString *source = @"a @done\nb\nc @done x @done y\r\nd\n e @done";
	NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:source];
	[text addAttribute:NSStrikethroughStyleAttributeName value:@1 range:NSMakeRange(8, 1)];   //"b": struck by hand, not by a tag
	[text addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [text length])];
	XCTAssertEqualObjects([self strikeMapOf:text attribute:NSStrikethroughStyleAttributeName],
						  @"10000000" @"10" @"1000000000000000000" @"00" @"11000000");
	XCTAssertEqualObjects([self strikeMapOf:text attribute:NVHiddenDoneTagAttributeName],
						  @"10000000" @"00" @"1000000000000000000" @"00" @"11000000");
	//a range that starts mid-line treats its start as a line start
	NSMutableAttributedString *partial = [[NSMutableAttributedString alloc] initWithString:@"xx yy @done"];
	[partial addStrikethroughNearDoneTagsForRange:NSMakeRange(3, 8)];
	XCTAssertEqualObjects([self strikeMapOf:partial attribute:NSStrikethroughStyleAttributeName], @"00011000000");
	//tags removed from the first and third lines
	[text replaceCharactersInRange:NSMakeRange(2, 5) withString:@"     "];
	[text replaceCharactersInRange:NSMakeRange(12, 15) withString:@"               "];
	[text addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [text length])];
	XCTAssertEqualObjects([self strikeMapOf:text attribute:NVHiddenDoneTagAttributeName],
						  @"00000000" @"00" @"0000000000000000000" @"00" @"11000000");
	XCTAssertTrue([self isStruck:text at:8], @"a strikethrough made by hand stays");
}

@end
