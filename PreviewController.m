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
#import "BTTransparentScroller.h"
#import "NSFileManager+DirectoryLocations.h"

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
    [scrlView setScrollerStyle:NSScrollerStyleOverlay];
}

//the "Cocoa" object custom templates can call, e.g. Cocoa.log("…"), as they could with the old WebView
static NSString *const LogBridgeScript = @"window.Cocoa = {log: function(s) { window.webkit.messageHandlers.log.postMessage(String(s)); }};";

//the page is written to a file and loaded from there, so the template can use files from the support
//folder ({%support%}) and notes can show local images, as the old WebView allowed
+ (NSURL *)previewPageURL {
	static NSURL *url = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *folder = [[NSFileManager defaultManager] findOrCreateDirectory:NSCachesDirectory inDomain:NSUserDomainMask
														   appendPathComponent:[[NSBundle mainBundle] bundleIdentifier] ?: @"Notational" error:NULL];
		url = [NSURL fileURLWithPath:[(folder ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"preview.html"]];
	});
	return url;
}

- (void)installWebView {
	if (preview || !previewContainer) return;
	WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
	[[configuration preferences] setValue:[NSNumber numberWithBool:YES] forKey:@"developerExtrasEnabled"];
	WKUserContentController *content = [configuration userContentController];
	[content addUserScript:[[WKUserScript alloc] initWithSource:LogBridgeScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart
												 forMainFrameOnly:YES]];
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
        return;
    }

    if (self.isPreviewSticky) {
        return;
    }


    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(preview:) object:app];

    [self performSelector:@selector(preview:) withObject:app afterDelay:0.05];
}

- (BOOL)previewIsVisible{
    return [[self window] isVisible];
}

-(void)togglePreview:(id)sender
{

    NSWindow *wnd = [self window];
    if ([wnd isVisible]) {
        //      // TODO: should the "stuck" note remain stuck when preview is closed?
        //      if (self.isPreviewSticky)
        //        [self makePreviewNotSticky:self];
        [wnd orderOut:self];
    } else {
        if (self.isPreviewOutdated) {
            // TODO high coupling; too many assumptions on architecture:
            [self performSelector:@selector(preview:) withObject:[[NSApplication sharedApplication] delegate] afterDelay:0.0];
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
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:NO]
                                              forKey:kDefaultMarkupPreviewVisible];
    NSMenu *previewMenu = [[[NSApp mainMenu] itemWithTitle:@"Preview"] submenu];
    [[previewMenu itemWithTitle:@"Toggle Preview Window"]setState:0];
}

-(void)preview:(id)object
{
    if (self.isPreviewSticky) {
        return;
    }
    AppController *app = object;
    NSString *rawString = [app noteContent];
    NoteObject *note = [app selectedNoteObject];
    NVMarkupRenderer *renderer = [NVMarkupRenderer defaultRenderer];
    NSString *processedString = [renderer htmlForText:rawString];
    NSString *noteTitle = note ? [NSString stringWithFormat:@"%@",titleOfNote(note)] : @"";
    BOOL sameNote = (lastNote == note);
    lastNote = note;
    [[self window] setTitle:noteTitle];
    [sourceView replaceCharactersInRange:NSMakeRange(0, [[sourceView string] length]) withString:processedString];
    self.isPreviewOutdated = NO;

    //the same note again: keep the reader's place (the page is replaced, so ask where it was first)
    [self installWebView];
    NSString *scrollScript = @"(document.scrollingElement || document.body).scrollTop";
    [preview evaluateJavaScript:sameNote ? scrollScript : @"0" completionHandler:^(id result, NSError *error) {
        NSString *previewString = processedString;
        if (sameNote && [result respondsToSelector:@selector(doubleValue)] && [result doubleValue] > 0) {
            previewString = [processedString stringByAppendingFormat:@"\n<script>window.addEventListener('load', function() { (document.scrollingElement || document.body).scrollTop = %f; });</script>", [result doubleValue]];
        }
        NSString *page = [renderer pageForHTML:previewString title:noteTitle];
        NSURL *pageURL = [[self class] previewPageURL];
        if (![page writeToURL:pageURL atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            [preview loadHTMLString:page baseURL:nil];
            return;
        }
        [preview loadFileURL:pageURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
    }];
}

-(IBAction)makePreviewSticky:(id)sender
{
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
    [self performSelector:@selector(preview:) withObject:[[NSApplication sharedApplication] delegate] afterDelay:0.0];
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
