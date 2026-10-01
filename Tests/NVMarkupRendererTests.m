//
//  NVMarkupRendererTests.m
//  The Markup renderer (#4): format routing, the TaskPaper pre-pass, page assembly,
//  and golden files rendered by the real tools.
//

#import <XCTest/XCTest.h>
#import "NVMarkupRenderer.h"
#import "NVTaskPaperMarkdown.h"

//records what it was asked to convert and answers with a fixed prefix
@interface FakeMarkupTool : NSObject <NVMarkupTool>
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, copy) NSString *lastInput;
@property (nonatomic, assign) BOOL fails;
@end

@implementation FakeMarkupTool
@synthesize prefix, lastInput, fails;
+ (FakeMarkupTool *)toolWithPrefix:(NSString *)aPrefix {
	FakeMarkupTool *tool = [[self alloc] init];
	[tool setPrefix:aPrefix];
	return tool;
}
- (NSString *)convertText:(NSString *)text error:(NSError **)error {
	[self setLastInput:text];
	if (fails) {
		if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:[NSDictionary dictionaryWithObject:@"tool broke" forKey:NSLocalizedDescriptionKey]];
		return nil;
	}
	return [prefix stringByAppendingString:text];
}
@end

@interface NVMarkupRendererTests : XCTestCase {
	FakeMarkupTool *markdown, *multiMarkdown, *taskPaper;
	NVMarkupRenderer *renderer;
}
@end

@implementation NVMarkupRendererTests

- (void)setUp {
	[super setUp];
	markdown = [FakeMarkupTool toolWithPrefix:@"md:"];
	multiMarkdown = [FakeMarkupTool toolWithPrefix:@"mmd:"];
	taskPaper = [FakeMarkupTool toolWithPrefix:@"tp:"];
	NSDictionary *tools = [NSDictionary dictionaryWithObjectsAndKeys:
						   markdown, [NSNumber numberWithInteger:NVMarkupMarkdown],
						   multiMarkdown, [NSNumber numberWithInteger:NVMarkupMultiMarkdown], nil];
	renderer = [[NVMarkupRenderer alloc] initWithTools:tools taskPaperTool:taskPaper];
}

- (void)tearDown {
	[super tearDown];
}

#pragma mark Formats

- (void)testEachFormatUsesItsTool {
	XCTAssertEqualObjects([renderer htmlForText:@"x" format:NVMarkupMarkdown], @"md:x");
	XCTAssertEqualObjects([renderer htmlForText:@"x" format:NVMarkupMultiMarkdown], @"mmd:x");
}

- (void)testUnknownFormatsAreMultiMarkdown {
	XCTAssertEqual([NVMarkupRenderer formatFromInteger:0], (NVMarkupFormat)NVMarkupMultiMarkdown);
	XCTAssertEqual([NVMarkupRenderer formatFromInteger:NVMarkupMarkdown], (NVMarkupFormat)NVMarkupMarkdown);
	//13373 was Textile
	XCTAssertEqual([NVMarkupRenderer formatFromInteger:13373], (NVMarkupFormat)NVMarkupMultiMarkdown);
	XCTAssertEqualObjects([renderer htmlForText:@"x" format:42], @"mmd:x");
}

- (void)testTaskPaperOutlinesAreConvertedFirst {
	XCTAssertEqualObjects([renderer htmlForText:@"Home:\n\t- task @taskpaper" format:NVMarkupMultiMarkdown], @"mmd:tp:Home:\n\t- task @taskpaper");
	XCTAssertEqualObjects([renderer htmlForText:@"Archive:\n\t- done" format:NVMarkupMarkdown], @"md:tp:Archive:\n\t- done");
}

- (void)testOrdinaryNotesSkipTheTaskPaperPass {
	[renderer htmlForText:@"just a note" format:NVMarkupMultiMarkdown];
	XCTAssertNil([taskPaper lastInput]);
}

- (void)testAFailingToolShowsTheTextAndWhy {
	[multiMarkdown setFails:YES];
	NSString *html = [renderer htmlForText:@"a < b" format:NVMarkupMultiMarkdown];
	XCTAssertTrue([html rangeOfString:@"tool broke"].location != NSNotFound, @"%@", html);
	XCTAssertTrue([html rangeOfString:@"<pre>a &lt; b</pre>"].location != NSNotFound, @"%@", html);
}

#pragma mark Pages

- (void)testTemplateIsFilledIn {
	NSString *page = [NVMarkupRenderer documentWithHTML:@"<p>hi</p>" title:@"Tom & Jerry" templateHTML:@"<title>{%title%}</title><style>{%style%}</style><base href=\"{%support%}\">{%content%}"
													css:@"p{}" supportPath:@"/support"];
	XCTAssertEqualObjects(page, @"<title>Tom &amp; Jerry</title><style>p{}</style><base href=\"/support\"><p>hi</p>");
}

- (void)testContentThatLooksLikeAPlaceholderIsLeftAlone {
	NSString *page = [NVMarkupRenderer documentWithHTML:@"<p>{%title%}</p>" title:@"T" templateHTML:@"{%content%}" css:nil supportPath:nil];
	XCTAssertEqualObjects(page, @"<p>{%title%}</p>");
}

- (void)testWithoutATemplateTheHTMLGetsAPlainPage {
	NSString *page = [NVMarkupRenderer documentWithHTML:@"<p>hi</p>" title:@"Note" templateHTML:nil css:nil supportPath:nil];
	XCTAssertTrue([page hasPrefix:@"<!DOCTYPE html"]);
	XCTAssertTrue([page rangeOfString:@"<title>Note</title>"].location != NSNotFound);
	XCTAssertTrue([page rangeOfString:@"<body>\n<p>hi</p>"].location != NSNotFound);
}

- (void)testCompleteDocumentsAreNotWrapped {
	NSString *document = @"<?xml version=\"1.0\"?>\n<html><body>x</body></html>";
	XCTAssertEqualObjects([NVMarkupRenderer documentWithHTML:document title:@"T" templateHTML:@"<div>{%content%}</div>" css:nil supportPath:nil], document);
	XCTAssertTrue([NVMarkupRenderer isCompleteDocument:@"  <!DOCTYPE html><html></html>"]);
	XCTAssertFalse([NVMarkupRenderer isCompleteDocument:@"<p>x</p>"]);
}

#pragma mark Process tools

- (void)testProcessToolPipesTextThroughAProgram {
	NVMarkupProcessTool *tool = [NVMarkupProcessTool toolWithLaunchPath:@"/usr/bin/tr" arguments:[NSArray arrayWithObjects:@"a-z", @"A-Z", nil]];
	XCTAssertEqualObjects([tool convertText:@"hello" error:NULL], @"HELLO");
}

- (void)testProcessToolHandlesTextLargerThanAPipeBuffer {
	//the old code wrote all input before reading any output, which hangs once both pipes fill
	NSMutableString *big = [NSMutableString string];
	while ([big length] < 1024 * 1024) [big appendString:@"line of text that goes on for a while\n"];
	NVMarkupProcessTool *tool = [NVMarkupProcessTool toolWithLaunchPath:@"/bin/cat" arguments:nil];
	XCTAssertEqualObjects([tool convertText:big error:NULL], big);
}

- (void)testProcessToolReportsAMissingProgram {
	NSError *error = nil;
	NVMarkupProcessTool *tool = [NVMarkupProcessTool toolWithLaunchPath:@"/nonexistent/tool" arguments:nil];
	XCTAssertNil([tool convertText:@"x" error:&error]);
	XCTAssertNotNil(error);
}

- (void)testProcessToolReportsAFailingProgram {
	NSError *error = nil;
	NVMarkupProcessTool *tool = [NVMarkupProcessTool toolWithLaunchPath:@"/usr/bin/false" arguments:nil];
	XCTAssertNil([tool convertText:@"x" error:&error]);
	XCTAssertEqual([error code], (NSInteger)1);
}

#pragma mark Golden files (the real tools)

static NSString *RepoPath(void) {
	return [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

//the multimarkdown binary is built with the app; these run once the app has been built (CI builds it first)
static NSString *MultiMarkdownPath(void) {
	NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_MULTIMARKDOWN"];
	if ([path length]) return path;
	path = [RepoPath() stringByAppendingPathComponent:@"build/Notational.xcarchive/Products/Applications/Notational.app/Contents/Resources/multimarkdown"];
	return [[NSFileManager defaultManager] isExecutableFileAtPath:path] ? path : nil;
}

- (NVMarkupRenderer *)realRenderer {
	NVMarkupProcessTool *mmd = [NVMarkupProcessTool toolWithLaunchPath:MultiMarkdownPath() arguments:nil];
	NSDictionary *tools = [NSDictionary dictionaryWithObjectsAndKeys:
						   mmd, [NSNumber numberWithInteger:NVMarkupMarkdown],
						   mmd, [NSNumber numberWithInteger:NVMarkupMultiMarkdown], nil];
	NVTaskPaperMarkdown *taskPaperTool = [[NVTaskPaperMarkdown alloc] init];
	return [[NVMarkupRenderer alloc] initWithTools:tools taskPaperTool:taskPaperTool];
}

- (void)assertFixture:(NSString *)name format:(NVMarkupFormat)format {
	NSString *fixtures = [RepoPath() stringByAppendingPathComponent:@"Tests/Fixtures/Markup"];
	NSString *text = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]] encoding:NSUTF8StringEncoding error:NULL];
	NSString *expected = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"html"]] encoding:NSUTF8StringEncoding error:NULL];
	XCTAssertNotNil(text);
	XCTAssertEqualObjects([[self realRenderer] htmlForText:text format:format], expected, @"%@", name);
}

- (void)testGoldenMultiMarkdown {
	if (!MultiMarkdownPath()) { NSLog(@"skipped: build the app first for the multimarkdown binary"); return; }
	[self assertFixture:@"multimarkdown" format:NVMarkupMultiMarkdown];
}

- (void)testGoldenMarkdown {
	if (!MultiMarkdownPath()) { NSLog(@"skipped: build the app first for the multimarkdown binary"); return; }
	[self assertFixture:@"markdown" format:NVMarkupMarkdown];
}

- (void)testGoldenTaskPaper {
	if (!MultiMarkdownPath()) { NSLog(@"skipped: build the app first for the multimarkdown binary"); return; }
	[self assertFixture:@"taskpaper" format:NVMarkupMultiMarkdown];
}


@end
