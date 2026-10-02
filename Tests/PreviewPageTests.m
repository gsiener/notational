//
//  PreviewPageTests.m
//  NotationTests
//
//  The preview updates the page for an edited note in place, when that shows what loading the
//  page again would: the content element's HTML is replaced, unless the template's scripts ran.
//

#import <XCTest/XCTest.h>
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

@interface PreviewPageTests : XCTestCase {
	NSString *folder;
	WKWebView *webView;
	PreviewPageLoadWaiter *waiter;
	NVMarkupRenderer *renderer;
}
@end

@implementation PreviewPageTests

- (void)setUp {
	[super setUp];
	folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
	[[configuration userContentController] addUserScript:[PreviewController scriptWatchingScript]];
	webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration];
	waiter = [[PreviewPageLoadWaiter alloc] init];
	[webView setNavigationDelegate:waiter];
	renderer = [[NVMarkupRenderer alloc] initWithMarkdownTool:nil taskPaperTool:nil];
	//the app's own template and style; the support folder has no jquery.js, as in the app
	[renderer setBundledTemplateFolder:[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]];
	[renderer setCustomTemplateFolder:folder];
}

- (void)tearDown {
	[webView setNavigationDelegate:nil];
	webView = nil;
	[[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
	[super tearDown];
}

- (void)load:(NSString *)page {
	NSURL *url = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"preview.html"]];
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
	NSString *next = @"<h1 id=\"two\">Two</h1>\n<p>second <a href=\"#two\">link</a></p>\n<div class=\"footnotes\"><p>f</p></div>";
	NSString *elementID = nil;
	NSString *inner = [renderer contentElementHTMLForHTML:next title:@"Note" elementID:&elementID];
	XCTAssertNotNil(inner);
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:elementID withHTML:inner]], @YES);
	NSString *updated = [self evaluate:@"document.documentElement.outerHTML"];

	[self load:[renderer pageForHTML:next title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:@"document.documentElement.outerHTML"], updated);
}

- (void)testATemplateWhoseScriptsRanIsLoadedAgain {
	[renderer setBundledTemplateFolder:folder];
	[@"<html><body><div id=\"c\">{%content%}</div><script>document.title = 'ran';</script></body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @NO);
	XCTAssertEqualObjects([self evaluate:@"document.getElementById('c').innerHTML"], @"<p>one</p>");
}

- (void)testATemplateWhoseScriptsFailedIsUpdatedInPlace {
	[renderer setBundledTemplateFolder:folder];
	[@"<html><body><div id=\"c\">{%content%}</div><script src=\"missing.js\"></script><script>missing();</script></body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @YES);
}

- (void)testATemplateWithAScriptFileThatLoadedIsLoadedAgain {
	[renderer setBundledTemplateFolder:folder];
	[@"window.fromFile = 1;" writeToFile:[folder stringByAppendingPathComponent:@"present.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[@"<html><body><div id=\"c\">{%content%}</div><script src=\"present.js\"></script><script>missing();</script></body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:@"String(window.fromFile)"], @"1");
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @NO);
}

- (void)testATemplateWithoutScriptsIsUpdatedInPlace {
	[renderer setBundledTemplateFolder:folder];
	[@"<html><body><div id=\"c\">{%content%}</div><img src=\"missing.png\"></body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"template.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[self load:[renderer pageForHTML:@"<p>one</p>" title:@"Note"]];
	XCTAssertEqualObjects([self evaluate:[PreviewController scriptReplacingContentOfElement:@"c" withHTML:@"<p>two</p>"]], @YES);
	XCTAssertEqualObjects([self evaluate:@"document.getElementById('c').innerHTML"], @"<p>two</p>");
}

@end
