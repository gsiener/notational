//
//  NVMarkupRendererTests.m
//  The Markup renderer (#4): the TaskPaper pre-pass, page assembly, the preview template,
//  and golden files rendered by the real tools.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
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

@interface NVMarkupRendererTests : NVTestCase {
	FakeMarkupTool *markdown, *taskPaper;
	NVMarkupRenderer *renderer;
}
@end

@implementation NVMarkupRendererTests

- (void)setUp {
	[super setUp];
	markdown = [FakeMarkupTool toolWithPrefix:@"md:"];
	taskPaper = [FakeMarkupTool toolWithPrefix:@"tp:"];
	renderer = [[NVMarkupRenderer alloc] initWithMarkdownTool:markdown taskPaperTool:taskPaper];
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
	NSString *dir = [self.temporaryDirectory stringByAppendingPathComponent:subfolder];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
	NSString *path = [dir stringByAppendingPathComponent:name];
	XCTAssertTrue([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
	[[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-secondsAgo]} ofItemAtPath:path error:NULL];
	return path;
}

- (void)useTemplateFolders {
	[renderer setCustomTemplateFolder:[self.temporaryDirectory stringByAppendingPathComponent:@"custom"]];
	[renderer setBundledTemplateFolder:[self.temporaryDirectory stringByAppendingPathComponent:@"bundled"]];
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

#pragma mark Updating a page in place

- (void)testTheAppTemplateHasAContentElement {
	[renderer setCustomTemplateFolder:[self.temporaryDirectory stringByAppendingPathComponent:@"custom"]];
	[renderer setBundledTemplateFolder:NVTestRepoPath()];
	NSString *elementID = nil;
	NSString *inner = [renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"T" elementID:&elementID];
	XCTAssertEqualObjects(elementID, @"contentdiv");
	//exactly what the page puts inside the element
	NSString *page = [renderer pageForHTML:@"<p>x</p>" title:@"T"];
	NSString *element = [NSString stringWithFormat:@"<div id=\"contentdiv\">%@</div>", inner];
	XCTAssertTrue([page rangeOfString:element].location != NSNotFound, @"%@", inner);
	XCTAssertTrue([inner rangeOfString:@"<p>x</p>"].location != NSNotFound);
}

- (void)testOnlyAnElementHoldingTheContentAloneCanBeUpdated {
	[self useTemplateFolders];
	NSString *elementID = nil;
	[self write:@"<main class='a' id='body'>{%content%}</main>" to:@"template.html" inFolder:@"custom" modified:90];
	XCTAssertEqualObjects([renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"T" elementID:&elementID], @"<p>x</p>");
	XCTAssertEqualObjects(elementID, @"body");
	[self write:@"<div id=\"c\"><h1>{%title%}</h1>{%content%}</div>" to:@"template.html" inFolder:@"custom" modified:80];
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"T" elementID:&elementID]);
	[self write:@"<div id=\"c\">{%content%}</div><p>{%content%}</p>" to:@"template.html" inFolder:@"custom" modified:70];
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"T" elementID:&elementID]);
	[self write:@"<div data-id=\"c\">{%content%}</div>" to:@"template.html" inFolder:@"custom" modified:60];
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"T" elementID:&elementID]);
	[self write:@"<div id=\"c\">{%content%}</div><div id=\"c\"></div>" to:@"template.html" inFolder:@"custom" modified:50];
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"T" elementID:&elementID]);
}

- (void)testHTMLThatWouldParseDifferentlyOnItsOwnIsNotUpdatedInPlace {
	[self useTemplateFolders];
	[self write:@"<div id=\"c\">\n{%content%}\n</div>" to:@"template.html" inFolder:@"custom" modified:50];
	XCTAssertEqualObjects([renderer contentElementHTMLForHTML:@"<div class=\"footnotes\"><p>x</p></div>" title:@"T" elementID:NULL],
						  @"\n<div class=\"footnotes\"><p>x</p></div>\n");
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p></div><p>y</p>" title:@"T" elementID:NULL]);
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p><SCRIPT>alert(1)</SCRIPT>" title:@"T" elementID:NULL]);
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<!DOCTYPE html><html><body>x</body></html>" title:@"T" elementID:NULL]);
	XCTAssertNil([renderer contentElementHTMLForHTML:@"<p>x</p>" title:@"{%content%}" elementID:NULL]);
}

- (void)testTheTemplateKeyFollowsTheTemplate {
	[self useTemplateFolders];
	id before = [renderer templateKey];
	XCTAssertEqualObjects([renderer templateKey], before);
	[self write:@"mine {%content%}" to:@"template.html" inFolder:@"custom" modified:50];
	XCTAssertNotEqualObjects([renderer templateKey], before);
	before = [renderer templateKey];
	[self write:@"mine{}" to:@"custom.css" inFolder:@"custom" modified:40];
	XCTAssertNotEqualObjects([renderer templateKey], before);
}

#pragma mark MultiMarkdown

- (void)testMultiMarkdownDoesNotIncludeLocalFiles {
	//transclusion stays off (ADR 0010): a synced note must not pull a file from this Mac into the page
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nv-transclusion-secret.txt"];
	XCTAssertTrue([@"SECRET-CONTENTS" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
	NSString *html = [[[NVMultiMarkdownTool alloc] init] convertText:[NSString stringWithFormat:@"before {{%@}} after", path] error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	XCTAssertNotNil(html);
	XCTAssertEqual([html rangeOfString:@"SECRET-CONTENTS"].location, (NSUInteger)NSNotFound, @"%@", html);
}

- (void)testMultiMarkdownLeavesCriticMarkupAsText {
	NSString *html = [[[NVMultiMarkdownTool alloc] init] convertText:@"a {++b++} c" error:NULL];
	XCTAssertEqual([html rangeOfString:@"<ins>"].location, (NSUInteger)NSNotFound, @"%@", html);
}

- (void)testMultiMarkdownMakesAWholeDocumentFromMetadata {
	NSString *html = [[[NVMultiMarkdownTool alloc] init] convertText:@"Title: Shopping\n\nEggs" error:NULL];
	XCTAssertTrue([NVMarkupRenderer isCompleteDocument:html], @"%@", html);
	XCTAssertTrue([html rangeOfString:@"<title>Shopping</title>"].location != NSNotFound, @"%@", html);
}

- (void)testMultiMarkdownConvertsOnManyThreadsAtOnce {
	//the preview renders in the background while Save HTML or Print can render on the main thread
	NSString *text = [NSString stringWithContentsOfFile:[NVTestFixturesPath(@"Markup") stringByAppendingPathComponent:@"multimarkdown.txt"]
											   encoding:NSUTF8StringEncoding error:NULL];
	NVMultiMarkdownTool *tool = [[NVMultiMarkdownTool alloc] init];
	NSString *expected = [tool convertText:text error:NULL];
	__block NSUInteger mismatches = 0;
	NSLock *lock = [[NSLock alloc] init];
	dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
		if (![[tool convertText:text error:NULL] isEqualToString:expected]) {
			[lock lock]; mismatches++; [lock unlock];
		}
	});
	XCTAssertEqual(mismatches, (NSUInteger)0);
}

#pragma mark Golden files (the real tools)

- (NVMarkupRenderer *)realRenderer {
	return [[NVMarkupRenderer alloc] initWithMarkdownTool:[[NVMultiMarkdownTool alloc] init]
											taskPaperTool:[[NVTaskPaperMarkdown alloc] init]];
}

- (void)assertFixture:(NSString *)name {
	NSString *fixtures = NVTestFixturesPath(@"Markup");
	NSString *text = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]] encoding:NSUTF8StringEncoding error:NULL];
	NSString *expected = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"html"]] encoding:NSUTF8StringEncoding error:NULL];
	XCTAssertNotNil(text);
	XCTAssertEqualObjects([[self realRenderer] htmlForText:text], expected, @"%@", name);
}

- (void)testGoldenMultiMarkdown {
	[self assertFixture:@"multimarkdown"];
}

- (void)testGoldenMarkdown {
	[self assertFixture:@"markdown"];
}

- (void)testGoldenTaskPaper {
	[self assertFixture:@"taskpaper"];
}


@end
