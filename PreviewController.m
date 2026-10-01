//
//  PreviewController.m
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import "PreviewController.h"
#import "AppController.h" // TODO for the defines only, can you get around that?
#import "AppController_Preview.h"
#import "NVMarkupRenderer.h"
#import "NoteObject.h"
#import "ETTransparentButtonCell.h"
#import "ETTransparentButton.h"
#import "BTTransparentScroller.h"
#import "NSFileManager_NV.h"
#import "NSFileManager+DirectoryLocations.h"

#define kDefaultMarkupPreviewVisible @"markupPreviewVisible"

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
        //        [[self class] createCustomFiles];
        BOOL showPreviewWindow = [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultMarkupPreviewVisible];
        if (showPreviewWindow) {
            [[self window] orderFront:self];
        }

        //        tabSwitcher = [[[ETTransparentButton alloc]initWithFrame:shCon] retain];
        //        shCon.origin.x = [[[self window] contentView]visibleRect].origin.x + [[[self window] contentView]visibleRect].size.width - 80;
        //        shCon.size.width = 56;
        //        saveButton = [[[ETTransparentButton alloc]initWithFrame:shCon] retain];
        //        shCon.origin.x -= 65;
        //        stickyPreviewButton = [[[ETTransparentButton alloc]initWithFrame:shCon] retain];
        //        shCon.origin.x -= 65;
        //        printPreviewButton = [[[ETTransparentButton alloc]initWithFrame:shCon] retain];
        //        [tabSwitcher setTitle:@"View Source"];
        //        [tabSwitcher setTarget:self];
        //        [tabSwitcher setAction:@selector(switchTabs:)];
        //        [tabSwitcher setAutoresizingMask:NSViewMaxXMargin];
        //        [saveButton setTitle:@"Save"];
        //        [saveButton setToolTip:@"Save the current preview as an HTML file"];
        //        [saveButton setTarget:self];
        //        [saveButton setAction:@selector(saveHTML:)];
        //        [saveButton setAutoresizingMask:NSViewMinXMargin];
        //        [stickyPreviewButton setTitle:@"Stick"];
        //        [stickyPreviewButton setToolTip:@"Maintain current note in Preview, even if you switch to other notes."];
        //        [stickyPreviewButton setTarget:self];
        //        [stickyPreviewButton setAction:@selector(makePreviewSticky:)];
        //        [stickyPreviewButton setAutoresizingMask:NSViewMinXMargin];
        //        [printPreviewButton setTitle:@"Print"];
        //        [printPreviewButton setToolTip:@"Print to Printer or PDF."];
        //        [printPreviewButton setTarget:self];
        //        [printPreviewButton setAction:@selector(printPreview:)];
        //        [printPreviewButton setAutoresizingMask:NSViewMinXMargin];
        //        [[[self window] contentView] addSubview:tabSwitcher];
        //        [[[self window] contentView] addSubview:saveButton];
        //        [[[self window] contentView] addSubview:stickyPreviewButton];
        //        [[[self window] contentView] addSubview:printPreviewButton];
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
    cssString = [[[self class] css] retain];
    htmlString = [[[self class] html] retain];
    lastNote = [[NSApp delegate] selectedNoteObject];
    [sourceView setTextContainerInset:NSMakeSize(10.0,12.0)];
    NSScrollView *scrlView=[sourceView enclosingScrollView];
    if (!IsLionOrLater) {
        NSRect vsRect=[[scrlView verticalScroller]frame];
        BTTransparentScroller *theScroller=[[BTTransparentScroller alloc]initWithFrame:vsRect];
        [scrlView setVerticalScroller:theScroller];
        [theScroller release];
    }
    [scrlView setScrollsDynamically:YES];
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
    if (IsLionOrLater) {
        [scrlView setHorizontalScrollElasticity:NSScrollElasticityNone];
        [scrlView setVerticalScrollElasticity:NSScrollElasticityAutomatic];
        [scrlView setScrollerStyle:NSScrollerStyleOverlay];
    }
#endif
}

//the "Cocoa" object custom templates can call, e.g. Cocoa.log("…"), as they could with the old WebView
static NSString *const LogBridgeScript = @"window.Cocoa = {log: function(s) { window.webkit.messageHandlers.log.postMessage(String(s)); }};";

//the page is written to a file and loaded from there, so the template can use files from the support
//folder ({%support%}) and notes can show local images, as the old WebView allowed
+ (NSURL *)previewPageURL {
	NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	NSString *folder = [caches stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier] ?: @"Notational"];
	[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	return [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"preview.html"]];
}

- (void)installWebView {
	if (preview || !previewContainer) return;
	WKWebViewConfiguration *configuration = [[[WKWebViewConfiguration alloc] init] autorelease];
	[[configuration preferences] setValue:[NSNumber numberWithBool:YES] forKey:@"developerExtrasEnabled"];
	WKUserContentController *content = [configuration userContentController];
	[content addUserScript:[[[WKUserScript alloc] initWithSource:LogBridgeScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart
												 forMainFrameOnly:YES] autorelease]];
	[content addScriptMessageHandler:self name:@"log"];
	
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
    [pb setString:rawString forType:(NSString*)kUTTypeUTF8PlainText];

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

+(NSString*)css {
    NSFileManager *mgr = [NSFileManager defaultManager];
    NSString *folder = [[NSFileManager defaultManager] applicationSupportDirectory];
    NSString *cssFileName = @"custom.css";
    NSString *customCSSPath = [folder stringByAppendingPathComponent: cssFileName];
    if ([mgr fileExistsAtPath:customCSSPath]) {
        return [NSString stringWithContentsOfFile:customCSSPath
                                         encoding:NSUTF8StringEncoding
                                            error:NULL];
    } else {
        NSString *cssPath = [[NSBundle mainBundle] pathForResource:@"custom" ofType:@"css" inDirectory:nil];
        return [NSString stringWithContentsOfFile:cssPath encoding:NSUTF8StringEncoding error:nil];
    }

    //	if (![mgr fileExistsAtPath:customCSSPath]) {
    //		[[self class] createCustomFiles];
    //	}


}

+(NSString*)html {
    NSFileManager *mgr = [NSFileManager defaultManager];

    NSString *folder = [[NSFileManager defaultManager] applicationSupportDirectory];
    NSString *htmlFileName = @"template.html";
    NSString *customHTMLPath = [folder stringByAppendingPathComponent: htmlFileName];
    if ([mgr fileExistsAtPath:customHTMLPath]) {
        return [NSString stringWithContentsOfFile:customHTMLPath
                                         encoding:NSUTF8StringEncoding
                                            error:NULL];
    } else {
        NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"template" ofType:@"html" inDirectory:nil];
        return [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil];
    }
    //	if (![mgr fileExistsAtPath:customHTMLPath]) {
    //		[[self class] createCustomFiles];
    //	}
}

-(void)preview:(id)object
{
    if (self.isPreviewSticky) {
        return;
    }
    AppController *app = object;
    NSString *rawString = [app noteContent];
    NoteObject *note = [app selectedNoteObject];
    NSString *processedString = [[NVMarkupRenderer defaultRenderer] htmlForText:rawString format:[app currentPreviewMode]];
    NSString *noteTitle = note ? [NSString stringWithFormat:@"%@",titleOfNote(note)] : @"";
    BOOL sameNote = (lastNote == note);
    if (!sameNote) {
        [cssString release];
        [htmlString release];
        cssString = [[[self class] css] retain];
        htmlString = [[[self class] html] retain];
        lastNote = note;
    }
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
        NSString *page = [NVMarkupRenderer documentWithHTML:previewString title:noteTitle templateHTML:htmlString css:cssString
                                                supportPath:[[NSFileManager defaultManager] applicationSupportDirectory]];
        NSURL *pageURL = [[self class] previewPageURL];
        if (![page writeToURL:pageURL atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            [preview loadHTMLString:page baseURL:nil];
            return;
        }
        [preview loadFileURL:pageURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
    }];
}

+ (void) createCustomFiles
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSString *folder = [[NSFileManager defaultManager] applicationSupportDirectory];
    if ([fileManager fileExistsAtPath: folder] == NO)
    {
        [fileManager createFolderAtPath:folder];
        //				[fileManager createDirectoryAtPath: folder attributes: nil];

    }

    NSString *cssFileName = @"custom.css";
    NSString *cssFile = [folder stringByAppendingPathComponent: cssFileName];

    if ([fileManager fileExistsAtPath:cssFile] == NO)
    {
        NSString *cssPath = [[NSBundle mainBundle] pathForResource:@"customclean" ofType:@"css" inDirectory:nil];
        NSString *cssString = [NSString stringWithContentsOfFile:cssPath encoding:NSUTF8StringEncoding error:nil];
        NSData *cssData = [NSData dataWithBytes:[cssString UTF8String] length:[cssString length]];
        [fileManager createFileAtPath:cssFile contents:cssData attributes:nil];
    }

    NSString *htmlFileName = @"template.html";
    NSString *htmlFile = [folder stringByAppendingPathComponent: htmlFileName];

    if ([fileManager fileExistsAtPath:htmlFile] == NO)
    {
        NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"templateclean" ofType:@"html" inDirectory:nil];
        NSString *htmlString = [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil];
        NSData *htmlData = [NSData dataWithBytes:[htmlString UTF8String] length:[htmlString length]];
        [fileManager createFileAtPath:htmlFile contents:htmlData attributes:nil];
    }

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
    NSPrintInfo* printInfo = [[[NSPrintInfo sharedPrintInfo] copy] autorelease];

    [printInfo setHorizontallyCentered:YES];
    [printInfo setVerticallyCentered:NO];
    [printInfo setHorizontalPagination:NSPrintingPaginationModeFit];
    NSPrintOperation *printOp=[preview printOperationWithPrintInfo:printInfo];
    //WKWebView's print view needs a frame, or it prints blank pages
    [[printOp view] setFrame:[preview bounds]];
    [printOp runOperationModalForWindow:tabView.window delegate:self didRunSelector:@selector(printOperationDidRun:success:contextInfo:) contextInfo:selectedTab];
}

- (void)printOperationDidRun:(NSPrintOperation *)printOperation  success:(BOOL)success  contextInfo:(void *)contextInfo{
    NSTabViewItem *selTab=(NSTabViewItem *)contextInfo;
    if (selTab&&(tabView.selectedTabViewItem!=selTab)) {
        [tabView selectTabViewItem:selTab];
    }
}

//the same HTML as the preview, as a page of its own or inside the preview template
- (NSString *)savedHTMLForApp:(AppController *)app {
    NSString *html = [[NVMarkupRenderer defaultRenderer] htmlForText:[app noteContent] format:[app currentPreviewMode]];
    NSString *noteTitle = [app selectedNoteObject] ? titleOfNote([app selectedNoteObject]) : @"";
    BOOL embed = [includeTemplate state] == NSOnState;
    return [NVMarkupRenderer documentWithHTML:html title:noteTitle templateHTML:embed ? [[self class] html] : nil
                                          css:embed ? [[self class] css] : nil supportPath:[[NSFileManager defaultManager] applicationSupportDirectory]];
}

- (void)savePanelDidEnd:(NSSavePanel *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
    if (returnCode == NSFileHandlingPanelOKButton) {

        AppController *app = [[NSApplication sharedApplication] delegate];
        NSString *rawString = [app noteContent];
        NSString *processedString = [self savedHTMLForApp:app];
        NSURL *file = [sheet URL];
        NSError *error;
        [processedString writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }
}

-(IBAction)saveHTML:(id)sender
{
    if (!accessoryView) {
        if (![NSBundle loadNibNamed:@"SaveHTMLPreview" owner:self]) {
            NSLog(@"Failed to load SaveHTMLPreview.nib");
            NSBeep();
            return;
        }

    }
    // TODO high coupling; too many assumptions on architecture:
    AppController *app = [NSApp delegate];

    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setAccessoryView:accessoryView];
    [savePanel setCanCreateDirectories:YES];
    [savePanel setCanSelectHiddenExtension:YES];

    NSArray *fileTypes = [[NSArray alloc] initWithObjects:@"html",@"xhtml",@"htm",nil];
    [savePanel setAllowedFileTypes:fileTypes];


    NSString *rawString = [app noteContent];
    if ([NVMarkupRenderer isCompleteDocument:[[NVMarkupRenderer defaultRenderer] htmlForText:rawString format:[app currentPreviewMode]]]) {
        [includeTemplate setState:0];
        [includeTemplate setEnabled:NO];
        [templateNote setStringValue:@"Template embed unavailable because your note will render as a full XHTML document"];
    } else {
        [includeTemplate setEnabled:YES];
        [templateNote setStringValue:@"Select this to embed the ouput within your current preview HTML and CSS"];
    }

    NSString *noteTitle =  ([app selectedNoteObject]) ? [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])] : @"";
    //	[savePanel beginSheetForDirectory:nil file:noteTitle modalForWindow:[self window] modalDelegate:self didEndSelector:@selector(savePanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
    savePanel.nameFieldStringValue=noteTitle;
    [savePanel beginSheetModalForWindow:[self window] completionHandler:^(NSInteger returnCode) {
        if (returnCode == NSFileHandlingPanelOKButton) {
            NSString *processedString = [self savedHTMLForApp:app];
            NSURL *file = [savePanel URL];
            NSError *error;
            [processedString writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
        }
    }];
    [fileTypes release];

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
    [htmlString release];
    [cssString release];
    [lastNote release];
    [saveButton release];
    [tabSwitcher release];
    [[[preview configuration] userContentController] removeScriptMessageHandlerForName:@"log"];
    [preview release];
    [super dealloc];
}

@end
