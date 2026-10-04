//
//  PreviewController.m
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "PreviewController.h"
#import "AppController.h" // TODO for the defines only, can you get around that?
#import "AppController_Preview.h"
#import "NVMarkupRenderer.h"
#import "NoteObject.h"
#import "NSFileManager_NV.h"

#define kDefaultMarkupPreviewVisible @"markupPreviewVisible"

//a WKUserContentController retains its script message handlers, so handing it the controller would keep the
//controller alive for good (and the removal in -dealloc would never run); this forwards to it without owning it
@interface NVWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation NVWeakScriptMessageHandler
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
	[[self target] userContentController:userContentController didReceiveScriptMessage:message];
}
@end

//the scroll position a reloaded page restores; not one of the template's own scripts
static NSString *const RestoreScrollScriptID = @"nv-restore-scroll";

@interface PreviewController () {
	//notes render off the main thread, one at a time; only the latest request's result is shown
	dispatch_queue_t renderQueue;
	NSUInteger renderGeneration;
	//the last text rendered and its HTML, so text that hasn't changed isn't rendered again
	NSString *renderedText, *renderedHTML;

	//the page in the web view: what it was made from, and whether it has finished loading
	WKNavigation *pageNavigation;
	BOOL pageLoaded;
	__weak NoteObject *pageNote;
	NSString *pageTitle, *pageContentElementID;
	id pageTemplateKey;
}
@end

@implementation PreviewController

@synthesize preview;
@synthesize isPreviewOutdated;
@synthesize isPreviewSticky;

+(void)initialize
{
    NSDictionary *appDefaults = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO]
                                                            forKey:kDefaultMarkupPreviewVisible];

    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];

}

-(id)init
{
    if ((self = [super initWithWindowNibName:@"MarkupPreview" owner:self])) {
        self.isPreviewOutdated = YES;
        self.isPreviewSticky = NO;
        renderQueue = dispatch_queue_create("net.elasticthreads.nv.preview-render", DISPATCH_QUEUE_SERIAL);
        BOOL showPreviewWindow = [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultMarkupPreviewVisible];
        if (showPreviewWindow) {
            [[self window] orderFront:self];
        }

        [tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];

        // [[[self window] contentView] setNeedsDisplay:YES];

        //		[preview setPolicyDelegate:self];
        //		[preview setUIDelegate:self];
    }
    return self;
}

-(void)awakeFromNib
{
    [self installWebView];
    lastNote = [(AppController *)[NSApp delegate] selectedNoteObject];
    [sourceView setTextContainerInset:NSMakeSize(10.0,12.0)];
    NSScrollView *scrlView=[sourceView enclosingScrollView];
    [scrlView setScrollsDynamically:YES];
    [scrlView setHorizontalScrollElasticity:NSScrollElasticityNone];
    [scrlView setVerticalScrollElasticity:NSScrollElasticityAutomatic];
}

//the "Cocoa" object custom templates can call, e.g. Cocoa.log("…"), as they could with the old WebView
static NSString *const LogBridgeScript = @"window.Cocoa = {log: function(s) { window.webkit.messageHandlers.log.postMessage(String(s)); }};";

//notes, as the page loads, whether any of its own scripts ran: one fetched from a file, or an inline one
//that didn't throw. An update in place needs to know (see ContentUpdateScript).
static NSString *const ScriptWatchingScript = @"(function() {"
	"var loaded = 0, errors = 0;"
	"function watch(e) { if (e.type === 'error' ? e instanceof ErrorEvent : (e.target && e.target.tagName === 'SCRIPT')) e.type === 'error' ? errors++ : loaded++; }"
	//a script element's load event doesn't reach the window, only the document
	"document.addEventListener('load', watch, true);"
	"window.addEventListener('error', watch, true);"
	"window.addEventListener('load', function() {"
		"document.removeEventListener('load', watch, true);"
		"window.removeEventListener('error', watch, true);"
		"var inline = document.querySelectorAll('script:not([src]):not(#%@)').length;"
		"window.NVPreviewScriptsRan = loaded > 0 || errors < inline;"
	"});"
	"})();";

//replaces the content element's HTML and answers true, or answers false when the page must be loaded
//again: it isn't loaded yet, lacks the element, or has scripts that ran at load and so would not see the
//new content (the app's own template asks for a jquery.js that isn't there, and its script then throws)
static NSString *const ContentUpdateScript = @"(function(elementID, html) {"
	"var element = document.getElementById(elementID);"
	"if (!element || document.readyState !== 'complete' || window.NVPreviewScriptsRan !== false) return false;"
	"element.innerHTML = html;"
	"return true;"
	"}).apply(null, %@);";

//the page is written to a file and loaded from there, so the template can use files from the support
//folder ({%support%}) and notes can show local images, as the old WebView allowed
+ (NSURL *)previewPageURL {
	static NSURL *url = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *folder = [[NSFileManager defaultManager] findOrCreateDirectory:NSCachesDirectory
																  appendingPathComponent:[[NSBundle mainBundle] bundleIdentifier] ?: @"Notational"];
		url = [NSURL fileURLWithPath:[(folder ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"preview.html"]];
	});
	return url;
}

+ (WKUserScript *)scriptWatchingScript {
	return [[WKUserScript alloc] initWithSource:[NSString stringWithFormat:ScriptWatchingScript, RestoreScrollScriptID]
								  injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
}

+ (NSString *)scriptReplacingContentOfElement:(NSString *)elementID withHTML:(NSString *)html {
	NSData *arguments = [NSJSONSerialization dataWithJSONObject:[NSArray arrayWithObjects:elementID, html, nil] options:0 error:NULL];
	return [NSString stringWithFormat:ContentUpdateScript, [[NSString alloc] initWithData:arguments encoding:NSUTF8StringEncoding]];
}

- (void)installWebView {
	if (preview || !previewContainer) return;
	WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
	[[configuration preferences] setValue:[NSNumber numberWithBool:YES] forKey:@"developerExtrasEnabled"];
	WKUserContentController *content = [configuration userContentController];
	[content addUserScript:[[WKUserScript alloc] initWithSource:LogBridgeScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart
												 forMainFrameOnly:YES]];
	[content addUserScript:[[self class] scriptWatchingScript]];
	NVWeakScriptMessageHandler *logHandler = [[NVWeakScriptMessageHandler alloc] init];
	[logHandler setTarget:self];
	[content addScriptMessageHandler:logHandler name:@"log"];
	
	preview = [[WKWebView alloc] initWithFrame:[previewContainer bounds] configuration:configuration];
	[preview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[preview setNavigationDelegate:self];
	[preview setUIDelegate:self];
	[previewContainer addSubview:preview];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
	NSLog(@"JavaScript: %@", [message body]);
}

//links clicked in the preview open in the browser; only the preview's own page loads here
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
	NSURL *url = [[navigationAction request] URL];
	BOOL samePage = [url isFileURL] && [[url path] isEqualToString:[[[self class] previewPageURL] path]];
	if ([navigationAction navigationType] == WKNavigationTypeOther || (samePage && [url fragment])) {
		decisionHandler(WKNavigationActionPolicyAllow);
	} else {
		[[NSWorkspace sharedWorkspace] openURL:url];
		decisionHandler(WKNavigationActionPolicyCancel);
	}
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
	if (navigation && navigation == pageNavigation) pageLoaded = YES;
}

//target="_blank" and window.open
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
	if ([[navigationAction request] URL]) [[NSWorkspace sharedWorkspace] openURL:[[navigationAction request] URL]];
	return nil;
}

-(void)requestPreviewUpdate:(NSNotification *)notification
{
    AppController *app = [notification object];
    NSString *rawString = [app noteContent];
    NSPasteboard* pb = [NSPasteboard pasteboardWithName:@"mkStreamingPreview"];
    [pb clearContents];
    [pb setString:rawString forType:UTTypeUTF8PlainText.identifier];

    if (![[self window] isVisible]) {
        self.isPreviewOutdated = YES;
        //a render still in flight is for older text; it mustn't mark the preview up to date
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        renderGeneration++;
        return;
    }

    if (self.isPreviewSticky) {
        self.isPreviewOutdated = YES;
        return;
    }


    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(preview:) object:app];

    [self performSelector:@selector(preview:) withObject:app afterDelay:0.05];
}

- (BOOL)previewIsVisible{
    return [[self window] isVisible];
}

- (id)currentPreviewSource {
    return [[NSApplication sharedApplication] delegate];
}

-(void)togglePreview:(id)sender
{

    NSWindow *wnd = [self window];
    if ([wnd isVisible]) {
        //      // TODO: should the "stuck" note remain stuck when preview is closed?
        //      if (self.isPreviewSticky)
        //        [self makePreviewNotSticky:self];
        [wnd orderOut:self];
        [NSObject cancelPreviousPerformRequestsWithTarget:self];
        renderGeneration++;
        self.isPreviewOutdated = YES;
    } else {
        if (self.isPreviewOutdated) {
            // TODO high coupling; too many assumptions on architecture:
            [self performSelector:@selector(preview:) withObject:[self currentPreviewSource] afterDelay:0.0];
        }
        [tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];
        [tabSwitcher setTitle:@"View Source"];

        [wnd orderFront:self];
    }

    // save visibility to defaults
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:[wnd isVisible]]
                                              forKey:kDefaultMarkupPreviewVisible];
}

-(void)windowWillClose:(NSNotification *)notification
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    renderGeneration++;
    self.isPreviewOutdated = YES;
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:NO]
                                              forKey:kDefaultMarkupPreviewVisible];
    NSMenu *previewMenu = [[[NSApp mainMenu] itemWithTitle:@"Preview"] submenu];
    [[previewMenu itemWithTitle:@"Toggle Preview Window"]setState:0];
}

-(void)preview:(id)object
{
    if (self.isPreviewSticky || ![[self window] isVisible]) {
        return;
    }
    AppController *app = object;
    NSString *rawString = [app noteContent];
    NSString *text = rawString ? [rawString copy] : @"";
    NoteObject *note = [app selectedNoteObject];
    NSString *noteTitle = note ? [NSString stringWithFormat:@"%@",titleOfNote(note)] : @"";
    BOOL sameNote = (lastNote == note);
    lastNote = note;
    NSUInteger generation = ++renderGeneration;

    if (renderedText && [text isEqualToString:renderedText]) {
        [self showHTML:renderedHTML ofNote:note title:noteTitle sameNote:sameNote generation:generation];
        return;
    }
    //rendering runs a separate program; keep it off the main thread, and show only the latest
    NVMarkupRenderer *renderer = [self markupRenderer];
    dispatch_async(renderQueue, ^{
        NSString *html = [renderer htmlForText:text];
        dispatch_async(dispatch_get_main_queue(), ^{
            renderedText = text;
            renderedHTML = html;
            if (generation != renderGeneration || self.isPreviewSticky || ![[self window] isVisible]) return;
            [self showHTML:html ofNote:note title:noteTitle sameNote:sameNote generation:generation];
        });
    });
}

- (NVMarkupRenderer *)markupRenderer {
    return [NVMarkupRenderer defaultRenderer];
}

- (void)showHTML:(NSString *)processedString ofNote:(NoteObject *)note title:(NSString *)noteTitle sameNote:(BOOL)sameNote generation:(NSUInteger)generation
{
    NVMarkupRenderer *renderer = [self markupRenderer];
    [[self window] setTitle:noteTitle];
    [sourceView replaceCharactersInRange:NSMakeRange(0, [[sourceView string] length]) withString:processedString];
    self.isPreviewOutdated = NO;
    [self installWebView];

    //the same note, already showing in this template: replace just its content, which keeps the reader's place
    NSString *elementID = nil;
    NSString *content = [renderer contentElementHTMLForHTML:processedString title:noteTitle elementID:&elementID];
    if (content && pageLoaded && note == pageNote && [noteTitle isEqualToString:pageTitle] &&
        [elementID isEqualToString:pageContentElementID] && [[renderer templateKey] isEqual:pageTemplateKey]) {
        [preview evaluateJavaScript:[[self class] scriptReplacingContentOfElement:elementID withHTML:content] completionHandler:^(id result, NSError *error) {
            if ([result isKindOfClass:[NSNumber class]] && [result boolValue]) return;
            if (generation == renderGeneration && !self.isPreviewSticky && [[self window] isVisible])
                [self loadPageForHTML:processedString ofNote:note title:noteTitle sameNote:sameNote generation:generation];
        }];
        return;
    }
    [self loadPageForHTML:processedString ofNote:note title:noteTitle sameNote:sameNote generation:generation];
}

- (void)loadPageForHTML:(NSString *)processedString ofNote:(NoteObject *)note title:(NSString *)noteTitle sameNote:(BOOL)sameNote generation:(NSUInteger)generation
{
    NVMarkupRenderer *renderer = [self markupRenderer];
    //the same note again: keep the reader's place (the page is replaced, so ask where it was first)
    NSString *scrollScript = @"(document.scrollingElement || document.body).scrollTop";
    [preview evaluateJavaScript:sameNote ? scrollScript : @"0" completionHandler:^(id result, NSError *error) {
        if (generation != renderGeneration || self.isPreviewSticky || ![[self window] isVisible]) return;
        NSString *previewString = processedString;
        if (sameNote && [result respondsToSelector:@selector(doubleValue)] && [result doubleValue] > 0) {
            previewString = [processedString stringByAppendingFormat:@"\n<script id=\"%@\">window.addEventListener('load', function() { (document.scrollingElement || document.body).scrollTop = %f; });</script>", RestoreScrollScriptID, [result doubleValue]];
        }
        NSString *page = [renderer pageForHTML:previewString title:noteTitle];
        NSString *elementID = nil;
        pageNote = note;
        pageTitle = noteTitle;
        pageContentElementID = [renderer contentElementHTMLForHTML:processedString title:noteTitle elementID:&elementID] ? elementID : nil;
        pageTemplateKey = [renderer templateKey];
        pageLoaded = NO;
        NSURL *pageURL = [[self class] previewPageURL];
        if (![page writeToURL:pageURL atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            pageNavigation = [preview loadHTMLString:page baseURL:nil];
            return;
        }
        pageNavigation = [preview loadFileURL:pageURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
    }];
}

-(IBAction)makePreviewSticky:(id)sender
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    renderGeneration++;
    self.isPreviewSticky = YES;
    //  [[preview window] setTitle:@"Locked"];
    [stickyPreviewButton setState:YES];
    [stickyPreviewButton setToolTip:@"Return the preview to normal functionality."];
    [stickyPreviewButton setAction:@selector(makePreviewNotSticky:)];
    [saveButton setEnabled:NO];
    [[self window] setHidesOnDeactivate:NO];
}

-(IBAction)makePreviewNotSticky:(id)sender
{
    self.isPreviewSticky = NO;
    [[preview window] setTitle:@"Preview"];
    [stickyPreviewButton setState:NO];
    [stickyPreviewButton setToolTip:@"Maintain current note in Preview, even if you switch to other notes."];
    [stickyPreviewButton setAction:@selector(makePreviewSticky:)];
    [saveButton setEnabled:YES];
    self.isPreviewOutdated = YES;
    [self performSelector:@selector(preview:) withObject:[self currentPreviewSource] afterDelay:0.0];
    [[self window] setHidesOnDeactivate:YES];
}

-(IBAction)printPreview:(id)sender
{
    //print the rendered preview, so show that tab while printing
    NSTabViewItem *selectedTab=[tabView selectedTabViewItem];
    [tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];
    NSPrintInfo* printInfo = [[NSPrintInfo sharedPrintInfo] copy];

    [printInfo setHorizontallyCentered:YES];
    [printInfo setVerticallyCentered:NO];
    [printInfo setHorizontalPagination:NSPrintingPaginationModeFit];
    NSPrintOperation *printOp=[preview printOperationWithPrintInfo:printInfo];
    //WKWebView's print view needs a frame, or it prints blank pages
    [[printOp view] setFrame:[preview bounds]];
    [printOp runOperationModalForWindow:tabView.window delegate:self didRunSelector:@selector(printOperationDidRun:success:contextInfo:) contextInfo:(__bridge void *)selectedTab]; // the tab view keeps selectedTab alive
}

- (void)printOperationDidRun:(NSPrintOperation *)printOperation  success:(BOOL)success  contextInfo:(void *)contextInfo{
    NSTabViewItem *selTab=(__bridge NSTabViewItem *)contextInfo;
    if (selTab&&(tabView.selectedTabViewItem!=selTab)) {
        [tabView selectTabViewItem:selTab];
    }
}

//the same HTML as the preview, as a page of its own or inside the preview template
- (NSString *)savedPageForHTML:(NSString *)html title:(NSString *)noteTitle {
    if ([includeTemplate state] == NSControlStateValueOn)
        return [[NVMarkupRenderer defaultRenderer] pageForHTML:html title:noteTitle];
    return [NVMarkupRenderer documentWithHTML:html title:noteTitle templateHTML:nil css:nil supportPath:nil];
}

-(IBAction)saveHTML:(id)sender
{
    if (!accessoryView) {
        if (!NVLoadNib(@"SaveHTMLPreview", self)) {
            NSLog(@"Failed to load SaveHTMLPreview.nib");
            NSBeep();
            return;
        }

    }
    // TODO high coupling; too many assumptions on architecture:
    AppController *app = (AppController *)[NSApp delegate];

    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setAccessoryView:accessoryView];
    [savePanel setCanCreateDirectories:YES];
    [savePanel setCanSelectHiddenExtension:YES];

    NSArray *fileTypes = [[NSArray alloc] initWithObjects:@"html",@"xhtml",@"htm",nil];
    NSMutableArray *contentTypes = [NSMutableArray arrayWithCapacity:[fileTypes count]];
    for (NSString *extension in fileTypes) {
        UTType *contentType = [UTType typeWithFilenameExtension:extension];
        if (contentType) [contentTypes addObject:contentType];
    }
    [savePanel setAllowedContentTypes:contentTypes];


    //rendered once: for the template choice now, and for the file if the user saves
    NSString *html = [[NVMarkupRenderer defaultRenderer] htmlForText:[app noteContent]];
    if ([NVMarkupRenderer isCompleteDocument:html]) {
        [includeTemplate setState:0];
        [includeTemplate setEnabled:NO];
        [templateNote setStringValue:@"Template embed unavailable because your note will render as a full XHTML document"];
    } else {
        [includeTemplate setEnabled:YES];
        [templateNote setStringValue:@"Select this to embed the ouput within your current preview HTML and CSS"];
    }

    NSString *noteTitle =  ([app selectedNoteObject]) ? [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])] : @"";
    savePanel.nameFieldStringValue=noteTitle;
    [savePanel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
        if (returnCode == NSModalResponseOK) {
            NSString *processedString = [self savedPageForHTML:html title:noteTitle];
            NSURL *file = [savePanel URL];
            NSError *error;
            [processedString writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
        }
    }];

}

-(IBAction)switchTabs:(id)sender
{

    if ([tabView indexOfTabViewItem:[tabView selectedTabViewItem]] == 0) {
        [tabSwitcher setTitle:@"View Preview"];
        [tabView selectTabViewItem:[tabView tabViewItemAtIndex:1]];
    } else {
        [tabSwitcher setTitle:@"View Source"];
        [tabView selectTabViewItem:[tabView tabViewItemAtIndex:0]];
    }
}

- (void)dealloc {
    [[[preview configuration] userContentController] removeScriptMessageHandlerForName:@"log"];
}

@end
