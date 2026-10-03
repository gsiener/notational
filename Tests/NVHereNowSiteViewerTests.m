//
//  NVHereNowSiteViewerTests.m
//  NotationTests
//
//  The selected here.now Site shown read-only in the editor pane (ADR 0009). A local file:// page
//  stands in for the Site, and an injected handler stands in for the browser: nothing here
//  touches the network or NSWorkspace.
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "NVTestSupport.h"
#import "NVHereNowSiteViewer.h"
#import "NVHereNowSites.h"

static NSString *const SitePage =
	@"<html><head><title>Site</title></head><body>"
	@"<a id='same' href='other.html'>same</a>"
	@"<a id='far' href='https://elsewhere.example/page'>far</a>"
	@"<a id='blank' href='https://elsewhere.example/new' target='_blank'>blank</a>"
	@"<a id='sameBlank' href='other.html' target='_blank'>same blank</a>"
	@"<a id='mail' href='mailto:someone@example.com'>mail</a>"
	@"<a id='broken' href='missing.html'>missing</a>"
	@"</body></html>";

@interface NVHereNowSiteViewerTests : NVTestCase {
	NVHereNowSiteViewer *viewer;
	NSMutableArray<NSURL *> *opened;
	NVHereNowSite *site;
	NSWindow *window;
}
@end

@implementation NVHereNowSiteViewerTests

- (NVHereNowSite *)siteNamed:(NSString *)name {
	NSString *folder = [self.temporaryDirectory stringByAppendingPathComponent:name];
	[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	[SitePage writeToFile:[folder stringByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[@"<html><head><title>Other</title></head><body>other</body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"other.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	NVHereNowSite *result = [NVHereNowSite new];
	result.identity = [@"account:personal:" stringByAppendingString:name];
	result.title = [name capitalizedString];
	result.searchText = name;
	result.URL = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"index.html"]];
	return result;
}

- (void)setUp {
	[super setUp];
	opened = [NSMutableArray array];
	viewer = [[NVHereNowSiteViewer alloc] initWithFrame:NSMakeRect(0, 0, 500, 400)];
	NSMutableArray *sink = opened;
	viewer.openExternally = ^(NSURL *url) { [sink addObject:url]; };
	//in a window, as in the app, so clicks and layout behave normally
	window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 400) styleMask:NSWindowStyleMaskTitled
										   backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[[window contentView] addSubview:viewer];
	site = [self siteNamed:@"report"];
}

- (void)tearDown {
	[viewer hide];
	[window close];
	viewer = nil;
	[super tearDown];
}

- (BOOL)waitFor:(BOOL (^)(void))condition {
	NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:20];
	while (!condition() && [limit timeIntervalSinceNow] > 0)
		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	return condition();
}

- (void)settle {
	//long enough for a navigation the policy let through to commit
	[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
}

- (NSString *)pageTitle:(WKWebView *)webView {
	__block NSString *title = nil;
	__block BOOL done = NO;
	[webView evaluateJavaScript:@"document.title" completionHandler:^(id result, NSError *error) { title = result; done = YES; }];
	[self waitFor:^BOOL{ return done; }];
	return title;
}

- (void)showAndLoad {
	[viewer showSite:site];
	XCTAssertTrue([self waitFor:^BOOL{ return viewer.webView && !viewer.webView.loading && [[viewer.webView.URL lastPathComponent] isEqual:@"index.html"]; }]);
	XCTAssertEqualObjects([self pageTitle:viewer.webView], @"Site");
}

- (void)click:(NSString *)elementID {
	__block BOOL done = NO;
	[viewer.webView evaluateJavaScript:[NSString stringWithFormat:@"document.getElementById('%@').click(); true", elementID]
					 completionHandler:^(id result, NSError *error) { done = YES; }];
	XCTAssertTrue([self waitFor:^BOOL{ return done; }]);
}

- (void)testShowsTheSiteWithItsTitleAndAddress {
	XCTAssertTrue([viewer isHidden]);
	XCTAssertNil(viewer.webView, @"nothing loads before a Site is selected");
	[self showAndLoad];
	XCTAssertFalse([viewer isHidden]);
	XCTAssertEqualObjects([viewer.titleField stringValue], @"Report");
	XCTAssertTrue([[viewer.addressButton title] hasSuffix:@"report/index.html"], @"%@", [viewer.addressButton title]);
	XCTAssertEqualObjects([viewer.addressButton toolTip], [site.URL absoluteString]);
	XCTAssertEqualObjects([viewer.statusField stringValue], @"");
	XCTAssertEqual(viewer.webView.configuration.websiteDataStore, [WKWebsiteDataStore defaultDataStore]);
	XCTAssertFalse(viewer.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically);
	XCTAssertEqual(opened.count, (NSUInteger)0);
}

- (void)testShowingASiteLeavesFocusWhereItWas {
	//a search field keeps typing focus even when the page focuses one of its own fields
	NSTextField *search = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 370, 200, 22)];
	[[window contentView] addSubview:search];
	[viewer setFrame:NSMakeRect(0, 0, 500, 360)];
	XCTAssertTrue([window makeFirstResponder:search]);
	NSTextView *editor = (NSTextView *)[search currentEditor];
	[editor insertText:@"gro" replacementRange:[editor selectedRange]];
	XCTAssertTrue(NSEqualRanges([editor selectedRange], NSMakeRange(3, 0)));
	NSString *folder = [[site.URL path] stringByDeletingLastPathComponent];
	[@"<html><head><title>Form</title></head><body><input id='q' autofocus><script>document.getElementById('q').focus();</script></body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"form.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	site.URL = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"form.html"]];
	[viewer showSite:site];
	XCTAssertTrue([self waitFor:^BOOL{ return viewer.webView && !viewer.webView.loading && [[viewer.webView.URL lastPathComponent] isEqual:@"form.html"]; }]);
	[self settle];
	XCTAssertEqual([window firstResponder], [search currentEditor], @"%@", [window firstResponder]);
	XCTAssertEqualObjects([search stringValue], @"gro");
	XCTAssertTrue(NSEqualRanges([(NSTextView *)[search currentEditor] selectedRange], NSMakeRange(3, 0)), @"typing continues at the caret");
	XCTAssertFalse([viewer acceptsFirstResponder]);
	XCTAssertFalse([viewer.webView acceptsFirstResponder], @"only a click in the page focuses it");
}

- (void)testSameHostLinkNavigatesInPlace {
	[self showAndLoad];
	[self click:@"same"];
	XCTAssertTrue([self waitFor:^BOOL{ return [[viewer.webView.URL lastPathComponent] isEqual:@"other.html"] && !viewer.webView.loading; }]);
	XCTAssertEqualObjects([self pageTitle:viewer.webView], @"Other");
	XCTAssertEqual(opened.count, (NSUInteger)0);
}

- (void)testOtherHostLinkOpensExternallyAndStays {
	[self showAndLoad];
	[self click:@"far"];
	XCTAssertTrue([self waitFor:^BOOL{ return opened.count == 1; }]);
	XCTAssertEqualObjects(opened.firstObject, [NSURL URLWithString:@"https://elsewhere.example/page"]);
	[self settle];
	XCTAssertEqualObjects([viewer.webView.URL lastPathComponent], @"index.html");
	XCTAssertEqualObjects([self pageTitle:viewer.webView], @"Site");
}

- (void)testNewWindowLinksOpenExternally {
	[self showAndLoad];
	[self click:@"blank"];
	XCTAssertTrue([self waitFor:^BOOL{ return opened.count == 1; }]);
	XCTAssertEqualObjects(opened.firstObject, [NSURL URLWithString:@"https://elsewhere.example/new"]);
	//target=_blank goes to the browser even on the Site's own host
	[self click:@"sameBlank"];
	XCTAssertTrue([self waitFor:^BOOL{ return opened.count == 2; }]);
	XCTAssertEqualObjects([opened.lastObject lastPathComponent], @"other.html");
	[self settle];
	XCTAssertEqualObjects([viewer.webView.URL lastPathComponent], @"index.html");
}

- (void)testPopupsAPageOpensByItselfAreBlocked {
	//no click: WebKit refuses the window, so nothing reaches the browser either
	NSString *folder = [[site.URL path] stringByDeletingLastPathComponent];
	[@"<html><head><title>Popup</title><script>window.open('https://elsewhere.example/popup');</script></head><body></body></html>"
	 writeToFile:[folder stringByAppendingPathComponent:@"popup.html"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	site.URL = [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"popup.html"]];
	[viewer showSite:site];
	XCTAssertTrue([self waitFor:^BOOL{ return viewer.webView && !viewer.webView.loading && [[viewer.webView.URL lastPathComponent] isEqual:@"popup.html"]; }]);
	XCTAssertEqualObjects([self pageTitle:viewer.webView], @"Popup");
	[self settle];
	XCTAssertEqual(opened.count, (NSUInteger)0, @"%@", opened);
}

- (void)testAWindowOpenedFromAClickGoesToTheBrowser {
	[self showAndLoad];
	//evaluateJavaScript counts as a user gesture, like a click handler calling window.open
	__block BOOL done = NO;
	[viewer.webView evaluateJavaScript:@"window.open('https://elsewhere.example/popup'); true"
					 completionHandler:^(id result, NSError *error) { done = YES; }];
	XCTAssertTrue([self waitFor:^BOOL{ return done && opened.count == 1; }]);
	XCTAssertEqualObjects(opened.firstObject, [NSURL URLWithString:@"https://elsewhere.example/popup"]);
}

- (void)testMailtoOpensExternally {
	[self showAndLoad];
	[self click:@"mail"];
	XCTAssertTrue([self waitFor:^BOOL{ return opened.count == 1; }]);
	XCTAssertEqualObjects(opened.firstObject, [NSURL URLWithString:@"mailto:someone@example.com"]);
	[self settle];
	XCTAssertEqualObjects([viewer.webView.URL lastPathComponent], @"index.html");
}

- (void)testInPlacePolicyComparesTheSiteHost {
	NVHereNowSite *remote = [NVHereNowSite new];
	remote.identity = @"a:personal:remote"; remote.title = @"Remote";
	remote.URL = [NSURL URLWithString:@"https://remote.here.now/"];
	[viewer setValue:remote forKey:@"site"];   //the policy only; nothing loads
	XCTAssertTrue([viewer loadsInPlace:[NSURL URLWithString:@"https://REMOTE.here.now/page?x=1"]]);
	XCTAssertTrue([viewer loadsInPlace:[NSURL URLWithString:@"http://remote.here.now/"]]);
	XCTAssertFalse([viewer loadsInPlace:[NSURL URLWithString:@"https://other.here.now/"]]);
	XCTAssertFalse([viewer loadsInPlace:[NSURL URLWithString:@"https://here.now/"]]);
	XCTAssertFalse([viewer loadsInPlace:[NSURL URLWithString:@"mailto:x@remote.here.now"]]);
	XCTAssertFalse([viewer loadsInPlace:[NSURL URLWithString:@"ftp://remote.here.now/"]]);
}

- (void)testOpenInBrowserAndTheAddressLinkUseTheSiteURL {
	[self showAndLoad];
	[viewer.openButton performClick:nil];
	[viewer.addressButton performClick:nil];
	XCTAssertEqualObjects(opened, (@[site.URL, site.URL]));
	XCTAssertFalse([viewer.openButton acceptsFirstResponder]);
	XCTAssertFalse([viewer.addressButton acceptsFirstResponder]);
}

- (void)testStatusLineShowsAFailedLoadAndAStaleList {
	viewer.listStale = YES;
	NVHereNowSite *missing = [self siteNamed:@"gone"];
	missing.URL = [missing.URL URLByAppendingPathComponent:@"nothing-here.html"];
	[viewer showSite:missing];
	XCTAssertTrue([self waitFor:^BOOL{ return [[viewer.statusField stringValue] containsString:@"Couldn't load"]; }], @"%@", [viewer.statusField stringValue]);
	XCTAssertTrue([[viewer.statusField stringValue] containsString:@"Open in Browser"]);
	XCTAssertTrue([[viewer.statusField stringValue] containsString:@"out of date"]);
	viewer.listStale = NO;
	XCTAssertFalse([[viewer.statusField stringValue] containsString:@"out of date"]);
}

- (void)testSwitchingReplacesThePageAndHidingDiscardsIt {
	[self showAndLoad];
	WKWebView *first = viewer.webView;
	//the same Site again (a refreshed list row) keeps the page
	NVHereNowSite *refreshed = [NVHereNowSite new];
	refreshed.identity = site.identity; refreshed.title = @"Renamed"; refreshed.URL = site.URL;
	[viewer showSite:refreshed];
	XCTAssertEqual(viewer.webView, first);
	XCTAssertEqualObjects([viewer.titleField stringValue], @"Renamed");

	NVHereNowSite *other = [self siteNamed:@"other"];
	[viewer showSite:other];
	XCTAssertNotEqual(viewer.webView, first);
	XCTAssertNil([first superview]);
	XCTAssertTrue([self waitFor:^BOOL{ return !viewer.webView.loading && [[viewer.webView.URL path] containsString:@"/other/"]; }]);
	XCTAssertEqualObjects([viewer.titleField stringValue], @"Other");

	[viewer hide];
	XCTAssertTrue([viewer isHidden]);
	XCTAssertNil(viewer.webView);
	XCTAssertNil(viewer.site);
}

@end
