//
//  NVHereNowSiteViewer.h
//  Notation
//
//  Shows one here.now Site read-only in the editor pane (ADR 0009): a compact header with the
//  Site's title, its address as a link, an Open in Browser button and a status line, above a
//  WKWebView. Same-host navigation loads in place; other links, new-window requests, non-web
//  schemes and downloads are handed to openExternally and cancelled in the view.
//
//  The web view uses the default persistent website data store, so a restricted Site the user
//  signs into stays signed in, the same as any other WebKit browser. The app caches nothing
//  itself beyond WebKit's own cache.
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class NVHereNowSite;

@interface NVHereNowSiteViewer : NSView <WKNavigationDelegate, WKUIDelegate>

//receives every URL the viewer won't load in place; defaults to opening it in the default browser
@property (nonatomic, copy) void (^openExternally)(NSURL *url);

//the cached Site list could not be refreshed; shown in the status line
@property (nonatomic, assign) BOOL listStale;

@property (nonatomic, readonly) NVHereNowSite *site;
@property (nonatomic, readonly) WKWebView *webView;      //nil until a Site is shown
@property (nonatomic, readonly) NSTextField *titleField;
@property (nonatomic, readonly) NSButton *addressButton;
@property (nonatomic, readonly) NSButton *openButton;
@property (nonatomic, readonly) NSTextField *statusField;

//shows and loads the Site; showing the Site already shown (same identity and URL) keeps its page
- (void)showSite:(NVHereNowSite *)site;
//stops loading, discards the page and hides the viewer
- (void)hide;

- (IBAction)openInBrowser:(id)sender;

//whether a main-frame navigation to url stays in the viewer (same scheme family and host as the Site)
- (BOOL)loadsInPlace:(NSURL *)url;

@end
