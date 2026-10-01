//
//  NVTextMergeTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVTextMerge.h"

@interface NVTextMergeTests : XCTestCase
@end

@implementation NVTextMergeTests

#pragma mark Three-way merge

- (void)testUnchangedSidesReturnTheOther {
	XCTAssertEqualObjects([NVTextMerge mergeBase:@"a\nb\n" ours:@"a\nb\n" theirs:@"a\nB\n"], @"a\nB\n");
	XCTAssertEqualObjects([NVTextMerge mergeBase:@"a\nb\n" ours:@"A\nb\n" theirs:@"a\nb\n"], @"A\nb\n");
	XCTAssertEqualObjects([NVTextMerge mergeBase:@"a\n" ours:@"x\n" theirs:@"x\n"], @"x\n");
}

- (void)testEditsOnDifferentLinesBothSurvive {
	NSString *base = @"title\none\ntwo\nthree\n";
	NSString *merged = [NVTextMerge mergeBase:base ours:@"title\nONE\ntwo\nthree\n" theirs:@"title\none\ntwo\nTHREE\n"];
	XCTAssertEqualObjects(merged, @"title\nONE\ntwo\nTHREE\n");
}

- (void)testAppendsFromBothSidesBothSurvive {
	NSString *base = @"title\n\nbase line";
	NSString *merged = [NVTextMerge mergeBase:base ours:@"title\n\nbase line\nfrom A" theirs:@"title\n\nbase line\nfrom B"];
	//both appended at the same point: keep both, ours first (matches Simplenote's server, write spike #14)
	XCTAssertEqualObjects(merged, @"title\n\nbase line\nfrom A\nfrom B");
	//identical insertions aren't duplicated
	XCTAssertEqualObjects([NVTextMerge mergeBase:base ours:@"title\n\nbase line\nsame" theirs:@"title\n\nbase line\nsame"],
						  @"title\n\nbase line\nsame");

	merged = [NVTextMerge mergeBase:base ours:@"title\nfrom A\n\nbase line" theirs:@"title\n\nbase line\nfrom B"];
	XCTAssertEqualObjects(merged, @"title\nfrom A\n\nbase line\nfrom B");
}

- (void)testConflictingEditsToTheSameLinePreferOurs {
	XCTAssertEqualObjects([NVTextMerge mergeBase:@"a\nb\nc\n" ours:@"a\nours\nc\n" theirs:@"a\ntheirs\nc\n"], @"a\nours\nc\n");
}

- (void)testMatchesSimplenoteServerMergeFromWriteSpike {
	//observed on the real server: v1 "nvALT spike\n\nbase line", A appended at v2, B posted against v1
	NSString *merged = [NVTextMerge mergeBase:@"nvALT spike\n\nbase line"
										 ours:@"nvALT spike\n\nbase line\nedit from machine B"
									   theirs:@"nvALT spike\n\nbase line\nedit from machine A"];
	XCTAssertEqualObjects(merged, @"nvALT spike\n\nbase line\nedit from machine B\nedit from machine A");
}

- (void)testInsertionsAndDeletions {
	NSString *base = @"1\n2\n3\n4\n5\n";
	NSString *merged = [NVTextMerge mergeBase:base ours:@"1\n3\n4\n5\n" theirs:@"1\n2\n3\n4\n4.5\n5\n"];
	XCTAssertEqualObjects(merged, @"1\n3\n4\n4.5\n5\n");
}

- (void)testUnterminatedLastLine {
	XCTAssertEqualObjects([NVTextMerge mergeBase:@"a\nb" ours:@"a\nb!" theirs:@"A\nb"], @"A\nb!");
	XCTAssertFalse([[NVTextMerge mergeBase:@"a" ours:@"a b" theirs:@"a"] hasSuffix:@"\n"]);
}

- (void)testEmptyAndNilInputs {
	XCTAssertEqualObjects([NVTextMerge mergeBase:@"" ours:@"new" theirs:@""], @"new");
	XCTAssertEqualObjects([NVTextMerge mergeBase:nil ours:nil theirs:@"x"], @"x");
}

- (void)testUnicodeLinesAreComparedExactly {
	NSString *base = @"🗒️ list\nàéîõü\n";
	XCTAssertEqualObjects([NVTextMerge mergeBase:base ours:@"🗒️ list ✓\nàéîõü\n" theirs:@"🗒️ list\nàéîõü ✓\n"],
						  @"🗒️ list ✓\nàéîõü ✓\n");
}

- (void)testLargeNotesMergeQuickly {
	NSMutableString *base = [NSMutableString string];
	NSUInteger i;
	for (i = 0; i < 3000; i++) [base appendFormat:@"line %lu\n", (unsigned long)i];
	NSString *ours = [base stringByReplacingOccurrencesOfString:@"line 10\n" withString:@"line ten\n"];
	NSString *theirs = [base stringByReplacingOccurrencesOfString:@"line 2990\n" withString:@"line 2990!\n"];
	NSDate *start = [NSDate date];
	NSString *merged = [NVTextMerge mergeBase:base ours:ours theirs:theirs];
	XCTAssertLessThan(-[start timeIntervalSinceNow], 1.0);
	XCTAssertTrue([merged rangeOfString:@"line ten\n"].location != NSNotFound);
	XCTAssertTrue([merged rangeOfString:@"line 2990!\n"].location != NSNotFound);
}

#pragma mark Minimal edits

- (void)testChangeRange {
	NSRange range; NSString *replacement = nil;
	XCTAssertTrue([NVTextMerge changeFrom:@"hello world" to:@"hello brave world" range:&range replacement:&replacement]);
	XCTAssertEqual(range.location, (NSUInteger)6);
	XCTAssertEqual(range.length, (NSUInteger)0);
	XCTAssertEqualObjects(replacement, @"brave ");
	XCTAssertFalse([NVTextMerge changeFrom:@"same" to:@"same" range:&range replacement:&replacement]);
}

- (void)testChangeRangeDoesNotSplitComposedCharacters {
	NSRange range; NSString *replacement = nil;
	//👍🏽 and 👍🏿 share the leading surrogate pair; the change must cover the whole sequence
	XCTAssertTrue([NVTextMerge changeFrom:@"a👍🏽b" to:@"a👍🏿b" range:&range replacement:&replacement]);
	NSString *applied = [@"a👍🏽b" stringByReplacingCharactersInRange:range withString:replacement];
	XCTAssertEqualObjects(applied, @"a👍🏿b");
	XCTAssertEqual(range.location, (NSUInteger)1);
}

- (void)testSelectionFollowsTheChange {
	//cursor after the change shifts by the inserted length
	NSRange moved = [NVTextMerge selection:NSMakeRange(11, 0) afterChangeFrom:@"hello world" to:@"hello brave world"];
	XCTAssertEqual(moved.location, (NSUInteger)17);
	//cursor before the change stays put
	moved = [NVTextMerge selection:NSMakeRange(2, 3) afterChangeFrom:@"hello world" to:@"hello brave world"];
	XCTAssertEqual(moved.location, (NSUInteger)2);
	XCTAssertEqual(moved.length, (NSUInteger)3);
	//cursor inside a replaced region moves to the end of the replacement
	moved = [NVTextMerge selection:NSMakeRange(8, 0) afterChangeFrom:@"hello world" to:@"hello there"];
	XCTAssertEqual(moved.location, (NSUInteger)11);
}

- (void)testUpdatingTheEditorKeepsTheCursorWithItsText {
	NSTextStorage *storage = [[[NSTextStorage alloc] initWithString:@"line one\nline two\n"] autorelease];
	//cursor at the start of "two"
	NSArray *selection = [NSArray arrayWithObject:[NSValue valueWithRange:NSMakeRange(14, 0)]];
	NSAttributedString *merged = [[[NSAttributedString alloc] initWithString:@"line zero\nline one\nline two\n"] autorelease];
	NSArray *moved = [NVTextMerge updateStorage:storage toContent:merged selectedRanges:selection];
	XCTAssertEqualObjects([storage string], [merged string]);
	XCTAssertEqual([[moved lastObject] rangeValue].location, (NSUInteger)24);
	XCTAssertEqualObjects([[storage string] substringFromIndex:24], @"two\n");
	
	//a change after the cursor leaves it alone
	moved = [NVTextMerge updateStorage:storage toContent:[[[NSAttributedString alloc] initWithString:@"line zero\nline one\nline two\nline three"] autorelease]
						selectedRanges:moved];
	XCTAssertEqual([[moved lastObject] rangeValue].location, (NSUInteger)24);
}

@end
