//
//  NVMarkupRendererTests.m
//  The Markup renderer (#4): the TaskPaper pre-pass, page assembly, the preview template,
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
	FakeMarkupTool *markdown, *taskPaper;
	NVMarkupRenderer *renderer;
	NSString *folder;
}
@end

@implementation NVMarkupRendererTests

- (void)setUp {
	[super setUp];
	markdown = [FakeMarkupTool toolWithPrefix:@"md:"];
	taskPaper = [FakeMarkupTool toolWithPrefix:@"tp:"];
	renderer = [[NVMarkupRenderer alloc] initWithMarkdownTool:markdown taskPaperTool:taskPaper];
	folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
}

- (void)tearDown {
	[[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
	[super tearDown];
}

#pragma mark Converting

- (void)testTheTextGoesThroughTheMarkdownTool {
	XCTAssertEqualObjects([renderer htmlForText:@"x"], @"md:x");
	XCTAssertEqualObjects([renderer htmlForText:nil], @"md:");
}

- (void)testTaskPaperOutlinesAreConvertedFirst {
	XCTAssertEqualObjects([renderer htmlForText:@"Home:\n\t- task @taskpaper"], @"md:tp:Home:\n\t- task @taskpaper");
	XCTAssertEqualObjects([renderer htmlForText:@"Archive:\n\t- done"], @"md:tp:Archive:\n\t- done");
}

- (void)testOrdinaryNotesSkipTheTaskPaperPass {
	[renderer htmlForText:@"just a note"];
	XCTAssertNil([taskPaper lastInput]);
}

- (void)testAFailingToolShowsTheTextAndWhy {
	[markdown setFails:YES];
	NSString *html = [renderer htmlForText:@"a < b"];
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

#pragma mark The preview template

- (NSString *)write:(NSString *)contents to:(NSString *)name inFolder:(NSString *)subfolder modified:(NSTimeInterval)secondsAgo {
	NSString *dir = [folder stringByAppendingPathComponent:subfolder];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
	NSString *path = [dir stringByAppendingPathComponent:name];
	XCTAssertTrue([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
	[[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-secondsAgo]} ofItemAtPath:path error:NULL];
	return path;
}

- (void)useTemplateFolders {
	[renderer setCustomTemplateFolder:[folder stringByAppendingPathComponent:@"custom"]];
	[renderer setBundledTemplateFolder:[folder stringByAppendingPathComponent:@"bundled"]];
	[self write:@"bundled {%content%} <style>{%style%}</style>" to:@"template.html" inFolder:@"bundled" modified:100];
	[self write:@"b{}" to:@"custom.css" inFolder:@"bundled" modified:100];
}

- (void)testThePageUsesTheAppTemplateUntilTheUserHasTheirOwn {
	[self useTemplateFolders];
	XCTAssertEqualObjects([renderer pageForHTML:@"<p>x</p>" title:@"T"], @"bundled <p>x</p> <style>b{}</style>");

	[self write:@"mine {%content%} {%support%} <style>{%style%}</style>" to:@"template.html" inFolder:@"custom" modified:50];
	NSString *support = [renderer customTemplateFolder];
	XCTAssertEqualObjects([renderer pageForHTML:@"<p>x</p>" title:@"T"], ([NSString stringWithFormat:@"mine <p>x</p> %@ <style>b{}</style>", support]));
}

- (void)testTemplateEditsAreSeenOnTheNextPage {
	[self useTemplateFolders];
	NSString *path = [self write:@"one {%content%}" to:@"template.html" inFolder:@"custom" modified:50];
	XCTAssertEqualObjects([renderer pageForHTML:@"x" title:@"T"], @"one x");

	//read once: new contents under the same modification date aren't read
	NSDate *readDate = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileModificationDate];
	[@"unseen {%content%}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: readDate} ofItemAtPath:path error:NULL];
	XCTAssertEqualObjects([renderer pageForHTML:@"x" title:@"T"], @"one x");

	[self write:@"two {%content%}" to:@"template.html" inFolder:@"custom" modified:10];
	XCTAssertEqualObjects([renderer pageForHTML:@"x" title:@"T"], @"two x");
}

- (void)testInstallingTheCustomTemplateKeepsTheUsersFiles {
	[self useTemplateFolders];
	[self write:@"starter css" to:@"customclean.css" inFolder:@"bundled" modified:100];
	[self write:@"starter html" to:@"templateclean.html" inFolder:@"bundled" modified:100];
	NSString *mine = [self write:@"my css" to:@"custom.css" inFolder:@"custom" modified:10];
	[renderer installCustomTemplate];
	XCTAssertEqualObjects([NSString stringWithContentsOfFile:mine encoding:NSUTF8StringEncoding error:NULL], @"my css");
	NSString *installed = [[renderer customTemplateFolder] stringByAppendingPathComponent:@"template.html"];
	XCTAssertEqualObjects([NSString stringWithContentsOfFile:installed encoding:NSUTF8StringEncoding error:NULL], @"starter html");
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
	NVTaskPaperMarkdown *taskPaperTool = [[NVTaskPaperMarkdown alloc] init];
	return [[NVMarkupRenderer alloc] initWithMarkdownTool:mmd taskPaperTool:taskPaperTool];
}

- (void)assertFixture:(NSString *)name {
	NSString *fixtures = [RepoPath() stringByAppendingPathComponent:@"Tests/Fixtures/Markup"];
	NSString *text = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]] encoding:NSUTF8StringEncoding error:NULL];
	NSString *expected = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"html"]] encoding:NSUTF8StringEncoding error:NULL];
	XCTAssertNotNil(text);
	XCTAssertEqualObjects([[self realRenderer] htmlForText:text], expected, @"%@", name);
}

- (void)testGoldenMultiMarkdown {
	if (!MultiMarkdownPath()) { NSLog(@"skipped: build the app first for the multimarkdown binary"); return; }
	[self assertFixture:@"multimarkdown"];
}

- (void)testGoldenMarkdown {
	if (!MultiMarkdownPath()) { NSLog(@"skipped: build the app first for the multimarkdown binary"); return; }
	[self assertFixture:@"markdown"];
}

- (void)testGoldenTaskPaper {
	if (!MultiMarkdownPath()) { NSLog(@"skipped: build the app first for the multimarkdown binary"); return; }
	[self assertFixture:@"taskpaper"];
}


@end
