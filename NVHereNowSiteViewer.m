//
//  NVHereNowSiteViewer.m
//  Notation
//

#import "NVHereNowSiteViewer.h"
#import "NVHereNowSites.h"
#import "NVTheme.h"

static const CGFloat HeaderHeight = 46.0;
static const CGFloat Margin = 10.0;

//The header's background and the hairline under it.
@interface NVHereNowSiteHeader : NSView
@property (nonatomic, strong) NSColor *fillColor, *lineColor;
@end

@implementation NVHereNowSiteHeader
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
	[(self.fillColor ?: [NSColor windowBackgroundColor]) setFill];
	NSRectFill(dirtyRect);
	[(self.lineColor ?: [NSColor separatorColor]) setFill];
	NSRectFill(NSMakeRect(0, 0, NSWidth([self bounds]), 1.0));
}
@end

@class NVHereNowSiteViewer;

//Takes focus only from a click in the page. WebKit focuses the view itself when a page focuses one
//of its fields (autofocus, element.focus()), bypassing -acceptsFirstResponder; that is refused
//here and the viewer puts focus back where it was, so typing in the search field keeps working.
@interface NVHereNowSiteWebView : WKWebView
@property (nonatomic, weak) NVHereNowSiteViewer *viewer;
@end

@interface NVHereNowSiteViewer ()
- (void)restoreFocusAfterUninvitedFocus;
@end

static BOOL IsClickIn(NSView *view) {
	NSEvent *event = [NSApp currentEvent];
	NSEventType type = [event type];
	if (type != NSEventTypeLeftMouseDown && type != NSEventTypeRightMouseDown && type != NSEventTypeOtherMouseDown) return NO;
	if ([event window] != [view window]) return NO;
	return NSPointInRect([view convertPoint:[event locationInWindow] fromView:nil], [view bounds]);
}

@implementation NVHereNowSiteWebView
- (BOOL)acceptsFirstResponder {
	return IsClickIn(self) && [super acceptsFirstResponder];
}
- (BOOL)becomeFirstResponder {
	if (!IsClickIn(self)) {
		[_viewer restoreFocusAfterUninvitedFocus];
		return NO;
	}
	return [super becomeFirstResponder];
}
@end

@implementation NVHereNowSiteViewer {
	NVHereNowSiteHeader *_header;
	NSString *_loadProblem;
	//where focus was outside the page, to return it after a page grabs it
	__weak NSWindow *_observedWindow;
	__weak NSResponder *_focusOutside;
	__weak NSTextView *_focusEditor;    //the field editor, while _focusOutside is being edited
	NSRange _focusSelection;            //its caret
}

static void *FirstResponderContext = &FirstResponderContext;

- (instancetype)initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_openExternally = ^(NSURL *url) { [[NSWorkspace sharedWorkspace] openURL:url]; };
		[self setAutoresizesSubviews:YES];

		_header = [[NVHereNowSiteHeader alloc] initWithFrame:NSMakeRect(0, NSHeight(frame) - HeaderHeight, NSWidth(frame), HeaderHeight)];
		[_header setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
		[self addSubview:_header];

		_titleField = [NSTextField labelWithString:@""];
		[_titleField setFont:[NSFont boldSystemFontOfSize:[NSFont systemFontSize]]];
		[_titleField setLineBreakMode:NSLineBreakByTruncatingTail];
		[_header addSubview:_titleField];

		_addressButton = [NSButton buttonWithTitle:@"" target:self action:@selector(openInBrowser:)];
		[_addressButton setBordered:NO];
		[_addressButton setRefusesFirstResponder:YES];
		[[_addressButton cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
		[_header addSubview:_addressButton];

		_statusField = [NSTextField labelWithString:@""];
		[_statusField setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[_statusField setLineBreakMode:NSLineBreakByTruncatingTail];
		[_header addSubview:_statusField];

		_openButton = [NSButton buttonWithTitle:@"Open in Browser" target:self action:@selector(openInBrowser:)];
		[_openButton setControlSize:NSControlSizeSmall];
		[_openButton setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[_openButton setRefusesFirstResponder:YES];
		[_openButton sizeToFit];
		[_header addSubview:_openButton];

		[self setHidden:YES];
		[self applyTheme];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:NVThemeDidChangeNotification object:nil];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self observeWindow:nil];
	[self discardWebView];
}

#pragma mark - Focus

- (void)viewDidMoveToWindow {
	[super viewDidMoveToWindow];
	[self observeWindow:[self window]];
}

- (void)observeWindow:(NSWindow *)window {
	NSWindow *observed = _observedWindow;
	if (observed == window) return;
	if (observed) [observed removeObserver:self forKeyPath:@"firstResponder" context:FirstResponderContext];
	_observedWindow = window;
	if (window) {
		[window addObserver:self forKeyPath:@"firstResponder" options:0 context:FirstResponderContext];
		[self rememberFocus];
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (context != FirstResponderContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
	[self rememberFocus];
}

- (void)rememberFocus {
	NSResponder *responder = [[self window] firstResponder];
	if (!responder || responder == [self window]) return;
	if ([responder isKindOfClass:[NSView class]] && [(NSView *)responder isDescendantOf:self]) return;
	if ([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder isFieldEditor]) {
		//a field being edited hands focus to the field editor; return focus to the field
		id delegate = [(NSTextView *)responder delegate];
		if ([delegate isKindOfClass:[NSControl class]]) _focusOutside = delegate;
		[self followEditor:(NSTextView *)responder];
		return;
	}
	_focusOutside = responder;
	[self followEditor:nil];
}

- (void)followEditor:(NSTextView *)editor {
	NSTextView *previous = _focusEditor;
	if (previous != editor) {
		if (previous) [[NSNotificationCenter defaultCenter] removeObserver:self name:NSTextViewDidChangeSelectionNotification object:previous];
		if (editor) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(editorSelectionChanged:) name:NSTextViewDidChangeSelectionNotification object:editor];
		_focusEditor = editor;
	}
	_focusSelection = editor ? [editor selectedRange] : NSMakeRange(NSNotFound, 0);
}

- (void)editorSelectionChanged:(NSNotification *)notification {
	NSTextView *editor = [notification object];
	//only while the field is being edited; ending the edit resets the field editor
	if ([[editor window] firstResponder] == editor && [editor delegate] == (id)_focusOutside)
		_focusSelection = [editor selectedRange];
}

- (void)restoreFocusAfterUninvitedFocus {
	NSResponder *target = _focusOutside;
	//the caret as it was, since focusing the field again selects all of it
	NSRange selection = _focusEditor ? _focusSelection : NSMakeRange(NSNotFound, 0);
	__weak NSResponder *weakTarget = target;
	__weak typeof(self) weakSelf = self;
	//after AppKit finishes the refused change
	dispatch_async(dispatch_get_main_queue(), ^{
		NSWindow *window = [weakSelf window];
		NSResponder *responder = weakTarget;
		if (!window || !responder || [window firstResponder] != window) return;
		if (![window makeFirstResponder:responder]) return;
		NSText *editor = [responder isKindOfClass:[NSControl class]] ? [(NSControl *)responder currentEditor] : nil;
		if (editor && selection.location != NSNotFound && NSMaxRange(selection) <= [[editor string] length])
			[editor setSelectedRange:selection];
	});
}

#pragma mark - Showing a Site

- (void)showSite:(NVHereNowSite *)site {
	if (!site.URL) { [self hide]; return; }
	BOOL same = _site && _webView && ![self isHidden] && [_site.identity isEqualToString:site.identity] && [_site.URL isEqual:site.URL];
	_site = site;
	[self updateHeader];
	[self setHidden:NO];
	if (same) return;

	[self discardWebView];
	_loadProblem = nil;
	WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
	//persistent, so signing into a restricted Site lasts like it would in a browser (ADR 0009)
	[configuration setWebsiteDataStore:[WKWebsiteDataStore defaultDataStore]];
	[[configuration preferences] setJavaScriptCanOpenWindowsAutomatically:NO];
	NSRect frame = [self bounds];
	frame.size.height = MAX(NSHeight(frame) - HeaderHeight, 0);
	_webView = [[NVHereNowSiteWebView alloc] initWithFrame:frame configuration:configuration];
	[_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[_webView setNavigationDelegate:self];
	[_webView setUIDelegate:self];
	[(NVHereNowSiteWebView *)_webView setViewer:self];
	[_webView setAllowsBackForwardNavigationGestures:YES];
	[self addSubview:_webView positioned:NSWindowBelow relativeTo:_header];
	if ([site.URL isFileURL]) {
		//a local page stands in for a Site in tests
		[_webView loadFileURL:site.URL allowingReadAccessToURL:[site.URL URLByDeletingLastPathComponent]];
	} else {
		[_webView loadRequest:[NSURLRequest requestWithURL:site.URL]];
	}
	[self updateHeader];
}

- (void)hide {
	[self discardWebView];
	_site = nil;
	_loadProblem = nil;
	[self setHidden:YES];
}

- (void)discardWebView {
	if (!_webView) return;
	[_webView stopLoading];
	[_webView setNavigationDelegate:nil];
	[_webView setUIDelegate:nil];
	[_webView removeFromSuperview];
	_webView = nil;
}

- (void)setListStale:(BOOL)listStale {
	_listStale = listStale;
	[self updateHeader];
}

- (IBAction)openInBrowser:(id)sender {
	if (_site.URL) [self openOutside:_site.URL];
}

- (void)openOutside:(NSURL *)url {
	if (url && _openExternally) _openExternally(url);
}

#pragma mark - Header

- (void)updateHeader {
	[_titleField setStringValue:_site.title ?: @""];
	[_addressButton setToolTip:[_site.URL absoluteString]];
	NSMutableArray *status = [NSMutableArray array];
	if (_loadProblem) [status addObject:_loadProblem];
	if (_listStale) [status addObject:@"Saved Site list; it may be out of date"];
	[_statusField setStringValue:[status componentsJoinedByString:@" · "]];
	[self applyTheme];
}

//the readable address: host and path, without the scheme
- (NSString *)displayAddress {
	NSURL *url = _site.URL;
	if (![url host].length) return [url absoluteString] ?: @"";
	return [[url host] stringByAppendingString:[url path].length > 1 ? [url path] : @""];
}

- (void)themeDidChange:(NSNotification *)notification { [self applyTheme]; }

- (void)applyTheme {
	NSString *address = [self displayAddress];
	NVTheme *theme = [NVTheme currentTheme];
	NSColor *foreground = [theme foregroundColor] ?: [NSColor textColor];
	NSColor *background = [theme backgroundColor] ?: [NSColor textBackgroundColor];
	[_header setFillColor:background];
	[_header setLineColor:[foreground colorWithAlphaComponent:0.15]];
	[_header setNeedsDisplay:YES];
	[_titleField setTextColor:foreground];
	[_statusField setTextColor:[foreground colorWithAlphaComponent:0.65]];
	NSDictionary *link = @{NSForegroundColorAttributeName: [foreground colorWithAlphaComponent:0.8],
						   NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
						   NSFontAttributeName: [NSFont systemFontOfSize:[NSFont smallSystemFontSize]]};
	[_addressButton setAttributedTitle:[[NSAttributedString alloc] initWithString:address attributes:link]];
	[self layoutHeader];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
	[super resizeSubviewsWithOldSize:oldSize];
	[self layoutHeader];
}

- (void)layoutHeader {
	CGFloat width = NSWidth([_header bounds]);
	NSSize button = [_openButton frame].size;
	CGFloat right = MAX(width - Margin - button.width, Margin);
	[_openButton setFrameOrigin:NSMakePoint(right, floor((HeaderHeight - button.height) / 2.0))];
	CGFloat textWidth = MAX(right - 2 * Margin, 0);
	[_titleField setFrame:NSMakeRect(Margin, HeaderHeight - 6 - 18, textWidth, 18)];
	[_addressButton sizeToFit];
	CGFloat linkWidth = MIN(NSWidth([_addressButton frame]), textWidth);
	[_addressButton setFrame:NSMakeRect(Margin, 5, linkWidth, 16)];
	CGFloat statusX = Margin + linkWidth + 8;
	[_statusField setFrame:NSMakeRect(statusX, 5, MAX(right - Margin - statusX, 0), 15)];
}

#pragma mark - Navigation policy

static BOOL IsWebScheme(NSString *scheme) {
	return [scheme caseInsensitiveCompare:@"https"] == NSOrderedSame || [scheme caseInsensitiveCompare:@"http"] == NSOrderedSame;
}

- (BOOL)loadsInPlace:(NSURL *)url {
	NSURL *home = _site.URL;
	if (!home || !url) return NO;
	NSString *scheme = [url scheme] ?: @"";
	//http(s), or the Site's own scheme (a file:// page standing in for a Site in tests)
	if (!IsWebScheme(scheme) && [scheme caseInsensitiveCompare:[home scheme] ?: @""] != NSOrderedSame) return NO;
	NSString *host = [url host] ?: @"", *homeHost = [home host] ?: @"";
	return [host caseInsensitiveCompare:homeHost] == NSOrderedSame;
}

//about:blank and about:srcdoc, and data:/blob: frames the page builds itself
static BOOL IsPageInternal(NSURL *url) {
	NSString *scheme = [url scheme] ?: @"";
	return [scheme caseInsensitiveCompare:@"about"] == NSOrderedSame || [scheme caseInsensitiveCompare:@"data"] == NSOrderedSame ||
		[scheme caseInsensitiveCompare:@"blob"] == NSOrderedSame;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
	NSURL *url = [[action request] URL];
	BOOL followedLink = [action navigationType] == WKNavigationTypeLinkActivated;
	BOOL wantsNewWindow = ([action modifierFlags] & NSEventModifierFlagCommand) != 0 ||
		([action buttonNumber] & (1 << 2)) != 0;    //WebKit reports a button mask: the middle button is 1 << 2
	BOOL download = NO;
	if (@available(macOS 11.3, *)) download = [action shouldPerformDownload];

	if (![action targetFrame] || (followedLink && wantsNewWindow) || download) {
		//new-window requests, Cmd-click, middle click and download links: the browser
		[self openOutside:url];
		decisionHandler(WKNavigationActionPolicyCancel);
		return;
	}
	if (IsPageInternal(url) && !followedLink) { decisionHandler(WKNavigationActionPolicyAllow); return; }
	if (!IsWebScheme([url scheme]) && ![self loadsInPlace:url]) {
		//mailto:, tel:, app schemes: the system handles them, never the viewer. A frame the page
		//loads by itself with such a scheme is just cancelled, so it can't launch an app unasked.
		if (followedLink || [[action targetFrame] isMainFrame]) [self openOutside:url];
		decisionHandler(WKNavigationActionPolicyCancel);
		return;
	}
	if (followedLink && ![self loadsInPlace:url]) {
		//a link the user followed to another host, in the page or in one of its frames
		[self openOutside:url];
		decisionHandler(WKNavigationActionPolicyCancel);
		return;
	}
	//Same-host links, and navigation the user didn't choose as a link (redirects, form posts,
	//reloads, back/forward, the page's own frames), load in place, so a restricted Site's
	//sign-in round trip can complete here.
	decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
	NSURLResponse *urlResponse = [response response];
	NSString *disposition = [urlResponse isKindOfClass:[NSHTTPURLResponse class]] ?
		[(NSHTTPURLResponse *)urlResponse valueForHTTPHeaderField:@"Content-Disposition"] : nil;
	BOOL attachment = [[disposition lowercaseString] hasPrefix:@"attachment"];
	if (![response canShowMIMEType] || attachment) {
		//no downloads in the app; the browser handles the file
		if ([response isForMainFrame]) [self openOutside:[urlResponse URL]];
		decisionHandler(WKNavigationResponsePolicyCancel);
		return;
	}
	decisionHandler(WKNavigationResponsePolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)windowFeatures {
	//target=_blank and window.open: the browser, never a second in-app window
	[self openOutside:[[action request] URL]];
	return nil;
}

#pragma mark - Load state

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
	if (_loadProblem) { _loadProblem = nil; [self updateHeader]; }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
	[self loadFailed:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
	[self loadFailed:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
	_loadProblem = @"The page stopped — Open in Browser";
	[self updateHeader];
}

- (void)loadFailed:(NSError *)error {
	//cancelled loads are the policy above or a new navigation, not failures
	if ([[error domain] isEqualToString:NSURLErrorDomain] && [error code] == NSURLErrorCancelled) return;
	if ([[error domain] isEqualToString:WKErrorDomain] || [[error domain] isEqualToString:@"WebKitErrorDomain"]) {
		if ([error code] == 102) return;    //frame load interrupted by a policy change
	}
	BOOL offline = [[error domain] isEqualToString:NSURLErrorDomain] &&
		([error code] == NSURLErrorNotConnectedToInternet || [error code] == NSURLErrorNetworkConnectionLost ||
		 [error code] == NSURLErrorDataNotAllowed || [error code] == NSURLErrorInternationalRoamingOff);
	_loadProblem = offline ? @"Offline — Open in Browser later" : @"Couldn't load — Open in Browser";
	[self updateHeader];
}

@end
