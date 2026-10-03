#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "PreviewController.h"
#import "NVMarkupRenderer.h"
#import "NoteObject.h"

@interface PreviewController (LifecycleTesting)
- (void)preview:(id)sender;
- (NVMarkupRenderer *)markupRenderer;
- (id)currentPreviewSource;
- (void)showHTML:(NSString *)html ofNote:(NoteObject *)note title:(NSString *)title sameNote:(BOOL)sameNote generation:(NSUInteger)generation;
- (void)loadPageForHTML:(NSString *)html ofNote:(NoteObject *)note title:(NSString *)title sameNote:(BOOL)sameNote generation:(NSUInteger)generation;
@end

@interface PreviewTestWindow : NSObject
@property (nonatomic) BOOL visible;
@property (nonatomic, copy) NSString *title;
@end
@implementation PreviewTestWindow
- (BOOL)isVisible { return self.visible; }
- (void)orderOut:(id)sender { self.visible = NO; }
- (void)orderFront:(id)sender { self.visible = YES; }
- (void)setHidesOnDeactivate:(BOOL)value {}
@end

@interface PreviewTestApp : NSObject
@property (nonatomic, copy) NSString *noteContent;
@property (nonatomic, strong) NoteObject *selectedNoteObject;
@end
@implementation PreviewTestApp
@end

@interface PreviewTestRenderer : NVMarkupRenderer
@property (nonatomic, strong) dispatch_semaphore_t started;
@property (nonatomic, strong) dispatch_semaphore_t releaseRender;
@property (nonatomic, strong) dispatch_group_t activeRenders;
@property (nonatomic, strong) XCTestExpectation *nextStarted;
@end
@implementation PreviewTestRenderer
- (NSString *)htmlForText:(NSString *)text {
    dispatch_group_enter(self.activeRenders);
    dispatch_semaphore_signal(self.started);
    [self.nextStarted fulfill];
    self.nextStarted = nil;
    long waitResult = dispatch_semaphore_wait(self.releaseRender, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    dispatch_group_leave(self.activeRenders);
    return waitResult == 0 ? [@"<p>" stringByAppendingFormat:@"%@</p>", text] : @"<p>render timed out</p>";
}
@end

@interface PreviewTestWebView : WKWebView
@property (nonatomic, copy) NSString *evaluatedScript;
@property (nonatomic, copy) void (^evaluationCompletion)(id, NSError *);
@property (nonatomic) NSUInteger pageLoads;
@end
@implementation PreviewTestWebView
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))completionHandler {
    self.evaluatedScript = script;
    self.evaluationCompletion = completionHandler;
}
- (WKNavigation *)loadFileURL:(NSURL *)URL allowingReadAccessToURL:(NSURL *)readAccessURL {
    self.pageLoads++;
    return nil;
}
- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    self.pageLoads++;
    return nil;
}
@end

@interface PreviewTestController : PreviewController
@property (nonatomic, strong) PreviewTestWindow *testWindow;
@property (nonatomic, strong) PreviewTestRenderer *testRenderer;
@property (nonatomic, strong) NSMutableArray *shown;
@property (nonatomic, strong) XCTestExpectation *nextShown;
@property (nonatomic, strong) PreviewTestApp *testApp;
@property (nonatomic) NSUInteger reloads;
- (void)useTestWebView:(PreviewTestWebView *)webView;
- (void)showActualHTML:(NSString *)html note:(NoteObject *)note title:(NSString *)title;
- (void)loadActualPageForHTML:(NSString *)html note:(NoteObject *)note title:(NSString *)title generation:(NSUInteger)generation;
@end
@implementation PreviewTestController
- (NSWindow *)window { return (NSWindow *)self.testWindow; }
- (NVMarkupRenderer *)markupRenderer { return self.testRenderer; }
- (id)currentPreviewSource { return self.testApp; }
- (void)useTestWebView:(PreviewTestWebView *)webView { preview = webView; }
- (void)showActualHTML:(NSString *)html note:(NoteObject *)note title:(NSString *)title {
    [super showHTML:html ofNote:note title:title sameNote:YES generation:0];
}
- (void)loadPageForHTML:(NSString *)html ofNote:(NoteObject *)note title:(NSString *)title sameNote:(BOOL)sameNote generation:(NSUInteger)generation {
    self.reloads++;
}
- (void)loadActualPageForHTML:(NSString *)html note:(NoteObject *)note title:(NSString *)title generation:(NSUInteger)generation {
    [super loadPageForHTML:html ofNote:note title:title sameNote:YES generation:generation];
}
- (void)showHTML:(NSString *)html ofNote:(NoteObject *)note title:(NSString *)title sameNote:(BOOL)sameNote generation:(NSUInteger)generation {
    [self.shown addObject:@{ @"html": html, @"note": note ?: [NSNull null], @"title": title, @"sameNote": @(sameNote) }];
    self.isPreviewOutdated = NO;
    [self.nextShown fulfill];
    self.nextShown = nil;
}
@end

@interface PreviewLifecycleTests : NVTestCase
@property (nonatomic, strong) PreviewTestController *controller;
@property (nonatomic, strong) PreviewTestApp *app;
@end
@implementation PreviewLifecycleTests
- (void)setUp {
    [super setUp];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"markupPreviewVisible"];
    self.controller = [[PreviewTestController alloc] init];
    self.controller.testWindow = [[PreviewTestWindow alloc] init];
    self.controller.testWindow.visible = YES;
    self.controller.testRenderer = [[PreviewTestRenderer alloc] initWithMarkdownTool:nil taskPaperTool:nil];
    self.controller.testRenderer.started = dispatch_semaphore_create(0);
    self.controller.testRenderer.releaseRender = dispatch_semaphore_create(0);
    self.controller.testRenderer.activeRenders = dispatch_group_create();
    self.controller.shown = [NSMutableArray array];
    self.app = [[PreviewTestApp alloc] init];
    self.controller.testApp = self.app;
}
- (void)tearDown {
    for (NSUInteger i = 0; i < 3; i++) dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    XCTAssertEqual(dispatch_group_wait(self.controller.testRenderer.activeRenders, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    self.controller = nil;
    self.app = nil;
    [super tearDown];
}
- (XCTestExpectation *)expectNextVisiblePage {
    XCTestExpectation *shown = [self expectationWithDescription:@"current render reached the page"];
    self.controller.nextShown = shown;
    return shown;
}
- (XCTestExpectation *)expectNextRenderStart {
    XCTestExpectation *started = [self expectationWithDescription:@"replacement render started"];
    self.controller.testRenderer.nextStarted = started;
    return started;
}
- (void)waitForRenderStart:(XCTestExpectation *)started {
    XCTAssertEqual([XCTWaiter waitForExpectations:@[started] timeout:5], XCTWaiterResultCompleted);
}
- (void)waitForVisiblePage:(XCTestExpectation *)shown {
    XCTAssertEqual([XCTWaiter waitForExpectations:@[shown] timeout:5], XCTWaiterResultCompleted);
}
- (void)startRenderForNote:(NoteObject *)note text:(NSString *)text {
    self.app.selectedNoteObject = note;
    self.app.noteContent = text;
    [self.controller preview:self.app];
    XCTAssertEqual(dispatch_semaphore_wait(self.controller.testRenderer.started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
}
- (void)testLateCompletionAfterRapidNoteSwitchShowsOnlyCurrentIdentityAndTitle {
    NoteObject *a = NVTestNote(@"First", @"", nil);
    NoteObject *b = NVTestNote(@"Second", @"", nil);
    [self startRenderForNote:a text:@"old"];
    self.app.selectedNoteObject = b;
    self.app.noteContent = @"new";
    XCTestExpectation *shown = [self expectNextVisiblePage];
    [self.controller preview:self.app];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    XCTAssertEqual(dispatch_semaphore_wait(self.controller.testRenderer.started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    [self waitForVisiblePage:shown];
    XCTAssertEqual(self.controller.shown.count, 1u);
    XCTAssertEqualObjects(self.controller.shown.firstObject[@"html"], @"<p>new</p>");
    XCTAssertEqual(self.controller.shown.firstObject[@"note"], b);
    XCTAssertEqualObjects(self.controller.shown.firstObject[@"title"], @"Second");
}
- (void)testHideAndReopenRejectsOldRender {
    NoteObject *note = NVTestNote(@"Note", @"", nil);
    [self startRenderForNote:note text:@"old"];
    [self.controller togglePreview:nil];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    XCTAssertTrue(self.controller.isPreviewOutdated);
    self.app.noteContent = @"new";
    XCTestExpectation *shown = [self expectNextVisiblePage];
    XCTestExpectation *started = [self expectNextRenderStart];
    [self.controller togglePreview:nil];
    [self waitForRenderStart:started];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    [self waitForVisiblePage:shown];
    XCTAssertEqual(self.controller.shown.count, 1u);
    XCTAssertEqualObjects(self.controller.shown.firstObject[@"html"], @"<p>new</p>");
}
- (void)testEnteringStickyModeRejectsPendingRender {
    NoteObject *note = NVTestNote(@"Note", @"", nil);
    [self startRenderForNote:note text:@"old"];
    [self.controller makePreviewSticky:nil];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    XCTAssertTrue(self.controller.isPreviewSticky);
    self.app.noteContent = @"after sticky";
    XCTestExpectation *shown = [self expectNextVisiblePage];
    XCTestExpectation *started = [self expectNextRenderStart];
    [self.controller makePreviewNotSticky:nil];
    [self waitForRenderStart:started];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    [self waitForVisiblePage:shown];
    XCTAssertFalse(self.controller.isPreviewSticky);
    XCTAssertEqual(self.controller.shown.count, 1u);
    XCTAssertEqualObjects(self.controller.shown.firstObject[@"html"], @"<p>after sticky</p>");
}
- (void)testHidingCancelsAnUpdateWaitingForItsDebounce {
    self.app.selectedNoteObject = NVTestNote(@"Note", @"", nil);
    self.app.noteContent = @"pending";
    [self.controller requestPreviewUpdate:[NSNotification notificationWithName:@"TextViewHasChangedContents" object:self.app]];
    [self.controller togglePreview:nil];
    XCTestExpectation *elapsed = [self expectationWithDescription:@"debounce elapsed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [elapsed fulfill]; });
    [self waitForExpectationsWithTimeout:2 handler:nil];
    XCTAssertNotEqual(dispatch_semaphore_wait(self.controller.testRenderer.started, DISPATCH_TIME_NOW), 0);
    XCTAssertEqual(self.controller.shown.count, 0u);
}
- (void)prepareLoadedPageForNote:(NoteObject *)note renderer:(PreviewTestRenderer *)renderer {
    renderer.customTemplateFolder = [self.temporaryDirectory stringByAppendingPathComponent:@"custom"];
    renderer.bundledTemplateFolder = NVTestRepoPath();
    [self.controller useTestWebView:[[PreviewTestWebView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)]];
    [self.controller setValue:@YES forKey:@"pageLoaded"];
    [self.controller setValue:note forKey:@"pageNote"];
    [self.controller setValue:@"First" forKey:@"pageTitle"];
    [self.controller setValue:@"contentdiv" forKey:@"pageContentElementID"];
    [self.controller setValue:[renderer templateKey] forKey:@"pageTemplateKey"];
}
- (void)testPageIdentityTitleAndTemplateMustAgreeBeforePatching {
    NoteObject *first = NVTestNote(@"First", @"", nil);
    NoteObject *second = NVTestNote(@"Second", @"", nil);
    [self prepareLoadedPageForNote:first renderer:self.controller.testRenderer];
    PreviewTestWebView *webView = (PreviewTestWebView *)self.controller.preview;
    [self.controller showActualHTML:@"<p>edit</p>" note:first title:@"First"];
    XCTAssertNotNil(webView.evaluationCompletion);
    if (!webView.evaluationCompletion) return;
    XCTAssertEqual(self.controller.reloads, 0u);
    webView.evaluationCompletion(@YES, nil);

    [self.controller showActualHTML:@"<p>edit</p>" note:second title:@"Second"];
    XCTAssertEqual(self.controller.reloads, 1u);
    [self.controller showActualHTML:@"<p>edit</p>" note:first title:@"Renamed"];
    XCTAssertEqual(self.controller.reloads, 2u);
    [self.controller setValue:@"older template" forKey:@"pageTemplateKey"];
    [self.controller showActualHTML:@"<p>edit</p>" note:first title:@"First"];
    XCTAssertEqual(self.controller.reloads, 3u);
}
- (void)testLatePatchFallbackDoesNotReloadHiddenOrStickyPage {
    NoteObject *note = NVTestNote(@"First", @"", nil);
    [self prepareLoadedPageForNote:note renderer:self.controller.testRenderer];
    PreviewTestWebView *webView = (PreviewTestWebView *)self.controller.preview;
    [self.controller showActualHTML:@"<p>edit</p>" note:note title:@"First"];
    XCTAssertNotNil(webView.evaluationCompletion);
    if (!webView.evaluationCompletion) return;
    self.controller.testWindow.visible = NO;
    webView.evaluationCompletion(@NO, nil);
    XCTAssertEqual(self.controller.reloads, 0u);

    self.controller.testWindow.visible = YES;
    [self.controller showActualHTML:@"<p>edit</p>" note:note title:@"First"];
    self.controller.isPreviewSticky = YES;
    webView.evaluationCompletion(@NO, nil);
    XCTAssertEqual(self.controller.reloads, 0u);
}
- (void)testLateScrollReadDoesNotLoadHiddenPage {
    NoteObject *note = NVTestNote(@"First", @"", nil);
    [self prepareLoadedPageForNote:note renderer:self.controller.testRenderer];
    PreviewTestWebView *webView = (PreviewTestWebView *)self.controller.preview;
    [self.controller loadActualPageForHTML:@"<p>edit</p>" note:note title:@"First" generation:0];
    XCTAssertNotNil(webView.evaluationCompletion);
    self.controller.testWindow.visible = NO;
    webView.evaluationCompletion(@500, nil);
    XCTAssertEqual(webView.pageLoads, 0u);

    self.controller.testWindow.visible = YES;
    [self.controller loadActualPageForHTML:@"<p>edit</p>" note:note title:@"First" generation:0];
    self.controller.isPreviewSticky = YES;
    webView.evaluationCompletion(@500, nil);
    XCTAssertEqual(webView.pageLoads, 0u);
}
@end
