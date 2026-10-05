//
//  PreviewPageTests.m
//  NotationTests
//
//  The preview updates the page for an edited note in place, when that shows what loading the
//  page again would: the content element's HTML is replaced, unless the template's scripts ran.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import <WebKit/WebKit.h>
#import "PreviewController.h"
#import "NVMarkupRenderer.h"

@interface PreviewController (PageScripts)
+ (WKUserScript *)scriptWatchingScript;
+ (NSString *)scriptReplacingContentOfElement:(NSString *)elementID withHTML:(NSString *)html;
@end

@interface PreviewPageLoadWaiter : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) XCTestExpectation *loaded;
@end

@implementation PreviewPageLoadWaiter
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { [_loaded fulfill]; }
@end

@interface PreviewPageTests : NVTestCase {
	WKWebView *webView;
	PreviewPageLoadWaiter *waiter;
	NVMarkupRenderer *renderer;
}
@end

@implementation PreviewPageTests

- (void)setUp {
	[super setUp];
	WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
	[[configuration userContentController] addUserScript:[PreviewController scriptWatchingScript]];
	webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration];
	waiter = [[PreviewPageLoadWaiter alloc] init];
	[webView setNavigationDelegate:waiter];
	renderer = [[NVMarkupRenderer alloc] initWithMarkdownTool:nil taskPaperTool:nil];
	//the app's own template and style
	[renderer setBundledTemplateFolder:NVTestRepoPath()];
	[renderer setCustomTemplateFolder:self.temporaryDirectory];
}

- (void)tearDown {
	[webView setNavigationDelegate:nil];
	webView = nil;
	[super tearDown];
}

- (void)load:(NSString *)page {
	NSURL *url = [NSURL fileURLWithPath:[self.temporaryDirectory stringByAppendingPathComponent:@"preview.html"]];
	XCTAssertTrue([page writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
	[waiter setLoaded:[self expectationWithDescription:@"page loaded"]];
	[webView loadFileURL:url allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
	[self waitForExpectationsWithTimeout:20 handler:nil];
}

- (id)evaluate:(NSString *)script {
	__block id value = nil;
	XCTestExpectation *done = [self expectationWithDescription:@"evaluated"];
	[webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
		value = result;
		[done fulfill];
	}];
	[self waitForExpectationsWithTimeout:20 handler:nil];
	return value;
}

- (void)testTheAppTemplateUpdatedInPlaceMatchesTheReloadedPage {
	[self load:[renderer pageForHTML:@"<h1 id=\"one\">One</h1>\n<p>first</p>" title:@"Note"]];
	//the heading's short last word is joined by the template's script, in place as on a reload
	NSString *next = @"<h1 id=\"two\">Second heading is here</h1>\n<p>second <a href=\"#two\">link</a></p>\n<div class=\"footnotes\"><p>f</p></div>";
	NSString *elementID = nil;
	NSString *inner = [renderer contentElementHTMLForHTML:next title:@"Note" elementID:&elementID];
	XCTAssertNotNil(inner);
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:elementID withHTML:inner]], @YES);
	NSString *updated = [self evaluate:@"document.documentElement.outerHTML"];

	[self load:[renderer pageForHTML:next title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:@"document.documentElement.outerHTML"], updated);
}

#pragma mark The app template's script (#57)

- (NSString *)tallNoteWithFootnote {
	NSMutableString *html = [NSMutableString stringWithString:@"<h2 id=\"top\">A heading with end</h2>\n<p>See note<a href=\"#fn:1\" id=\"fnref:1\" class=\"footnote\"><sup>1</sup></a></p>\n"];
	for (int i = 0; i < 80; i++) [html appendString:@"<p>filler paragraph</p>\n"];
	[html appendString:@"<div class=\"footnotes\"><ol><li id=\"fn:1\"><p>The note.</p></li></ol></div>"];
	return html;
}

- (void)testTheAppTemplateScriptRunsAndStillAllowsInPlaceUpdates {
	[self load:[renderer pageForHTML:[self tallNoteWithFootnote] title:@"Note"]];
	//it ran: the heading's last short word is joined to the one before
	XCTAssertEqualObjects([self evaluate:@"document.getElementById('top').textContent"], @"A heading with\u00a0end");
	//and being data-nv-live, it doesn't force a reload for every edit
	XCTAssertEqualObjects([self evaluate:@"String(window.NVPreviewScriptsRan)"], @"false");
}

- (void)testTheAppTemplateScrollsFootnoteLinksItself {
	[self load:[renderer pageForHTML:[self tallNoteWithFootnote] title:@"Note"]];
	NSString *click = @"(function() { var e = new MouseEvent('click', {bubbles: true, cancelable: true});"
		"return document.getElementById('fnref:1').dispatchEvent(e) ? 'default' : 'handled'; })()";
	XCTAssertEqualObjects([self evaluate:click], @"handled");
}

- (void)testTheAppTemplateShowsBackToTopOnceScrolled {
	[self load:[renderer pageForHTML:[self tallNoteWithFootnote] title:@"Note"]];
	NSString *scrollTo = @"(function(top) { var c = document.getElementById('contentdiv'); c.scrollTop = top;"
		"c.dispatchEvent(new Event('scroll')); return !!document.getElementById('backtotop'); })(%d)";
	id shownWhenScrolled = [self evaluate:[NSString stringWithFormat:scrollTo, 500]];
	XCTAssertEqualObjects(shownWhenScrolled, @YES);
	id shownAtTop = [self evaluate:[NSString stringWithFormat:scrollTo, 0]];
	XCTAssertEqualObjects(shownAtTop, @NO);
}

- (void)testInPlaceUpdateKeepsScrollPosition {
	[renderer setBundledTemplateFolder:self.temporaryDirectory];
	[@"<html><body><div id='scroll' style='height: 100px; overflow: auto'><div id='content'>{%content%}</div></div></body></html>"
	 writeToFile:[self.temporaryDirectory stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	NSString *tall = @"<div style='height: 2000px'>top</div><p>first</p><div style='height: 2000px'>bottom</div>";
	[self load:[renderer pageForHTML:tall title:@"Note"]];
	[self evaluate:@"document.getElementById('scroll').scrollTop = 500; true"];
	double before = [[self evaluate:@"document.getElementById('scroll').scrollTop"] doubleValue];
	XCTAssertGreaterThan(before, 0.0);
	NSString *inner = @"<div style='height: 2000px'>top</div><p>changed</p><div style='height: 4000px'>bottom</div>";
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"content" withHTML:inner]], @YES);
	XCTAssertEqualWithAccuracy([[self evaluate:@"document.getElementById('scroll').scrollTop"] doubleValue], before, 1.0);
}

- (void)testATemplateWhoseScriptsRanIsLoadedAgain {
	[renderer setBundledTemplateFolder:self.temporaryDirectory];
	[@"<html><body><div id=\"c\">{%content%}</div><script>document.title = 'ran';</script></body></html>"
	 writeToFile:[self.temporaryDirectory stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @NO);
	XCTAssertEqualObjects([self evaluate:@"document.getElementById('c').innerHTML"], @"<p>one</p>");
}

- (void)testATemplateWhoseScriptsFailedIsUpdatedInPlace {
	[renderer setBundledTemplateFolder:self.temporaryDirectory];
	[@"<html><body><div id=\"c\">{%content%}</div><script src=\"missing.js\"></script><script>missing();</script></body></html>"
	 writeToFile:[self.temporaryDirectory stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @YES);
}

- (void)testATemplateWithAScriptFileThatLoadedIsLoadedAgain {
	[renderer setBundledTemplateFolder:self.temporaryDirectory];
	[@"window.fromFile = 1;" writeToFile:[self.temporaryDirectory stringByAppendingPathComponent:@"present.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[@"<html><body><div id=\"c\">{%content%}</div><script src=\"present.js\"></script><script>missing();</script></body></html>"
	 writeToFile:[self.temporaryDirectory stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:@"String(window.fromFile)"], @"1");
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @NO);
}

- (void)testATemplateWithoutScriptsIsUpdatedInPlace {
	[renderer setBundledTemplateFolder:self.temporaryDirectory];
	[@"<html><body><div id=\"c\">{%content%}</div><img src=\"missing.png\"></body></html>"
	 writeToFile:[self.temporaryDirectory stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @YES);
	XCTAssertEqualObjects([self evaluate:@"document.getElementById('c').innerHTML"], @"<p>two</p>");
}

@end
