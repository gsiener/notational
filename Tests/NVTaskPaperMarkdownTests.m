//
//  NVTaskPaperMarkdownTests.m
//  The native TaskPaper to Markdown pass (#10/#28). The fixtures under Fixtures/TaskPaper
//  are exact outputs of the old tp2md.rb, except where it mangled the link of a tag that
//  ends a @done task (01, 06, 08), which are the corrected output.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "NVTaskPaperMarkdown.h"

static NSString *const StyleHeader = @"<style>.tag strong {font-weight:normal;color:#555} .tag a {text-decoration:none;border:none;color:#777}</style>\n";

@interface NVTaskPaperMarkdownTests : XCTestCase
@end

@implementation NVTaskPaperMarkdownTests

- (void)testFixturesMatchTheRubyScriptOutput {
	NSString *dir = NVTestFixturesPath(@"TaskPaper");
	NSUInteger count = 0;
	for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
		if (![[file pathExtension] isEqualToString:@"txt"]) continue;
		NSString *input = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:NULL];
		NSString *expected = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:[[file stringByDeletingPathExtension] stringByAppendingPathExtension:@"md"]] encoding:NSUTF8StringEncoding error:NULL];
		XCTAssertNotNil(input, @"%@", file);
		XCTAssertNotNil(expected, @"%@", file);
		XCTAssertEqualObjects([NVTaskPaperMarkdown markdownFromTaskPaper:input], expected, @"%@", file);
		count++;
	}
	XCTAssertEqual(count, (NSUInteger)11);
}

- (void)testToolInterfaceConverts {
	NSError *error = nil;
	id<NVMarkupTool> tool = [[NVTaskPaperMarkdown alloc] init];
	NSString *md = [tool convertText:@"Home:\n\t- eggs @today\n" error:&error];
	XCTAssertNil(error);
	NSString *expected = [StyleHeader stringByAppendingString:@"* **Home**\n* eggs <em class=\"tag\"><a href=\"nvalt://find/@today\">@today<strong></strong></a></em>\n"];
	XCTAssertEqualObjects(md, [@"\n" stringByAppendingString:expected]);
}

- (void)testDoneTaskIsStruckThroughAndItsTagStaysALink {
	NSString *md = [NVTaskPaperMarkdown markdownFromTaskPaper:@"- call mom @done\n"];
	NSString *expected = [StyleHeader stringByAppendingString:@"* *<del>call mom <em class=\"tag\"><a href=\"nvalt://find/@done\">@done<strong></strong></a></em></del>*\n"];
	XCTAssertEqualObjects(md, [@"\n" stringByAppendingString:expected]);
}

- (void)testTagValueIsKeptInTheLinkAndShownDimmed {
	NSString *md = [NVTaskPaperMarkdown markdownFromTaskPaper:@"- pay @due(2026-10-01)\n"];
	XCTAssertTrue([md hasSuffix:@"* pay <em class=\"tag\"><a href=\"nvalt://find/@due(2026-10-01)\">@due(<strong>2026-10-01</strong>)</a></em>\n"], @"%@", md);
}

- (void)testWikiLinkBecomesAFindLink {
	NSString *md = [NVTaskPaperMarkdown markdownFromTaskPaper:@"see [[Other Note]]\n"];
	XCTAssertTrue([md hasSuffix:@"\n*see <a href=\"nvalt://find/Other Note\">Other Note</a>*\n"], @"%@", md);
}

- (void)testEmptyTextIsJustTheHeader {
	NSString *expected = [NSString stringWithFormat:@"\n%@\n", StyleHeader];
	XCTAssertEqualObjects([NVTaskPaperMarkdown markdownFromTaskPaper:@""], expected);
}

@end
