#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "PreviewController.h"
#import "NVMarkupRenderer.h"
#import "NoteObject.h"

@interface PreviewController (LifecycleTesting)
- (void)preview:(id)sender;
- (NVMarkupRenderer *)markupRenderer;
- (void)showHTML:(NSString *)html ofNote:(NoteObject *)note title:(NSString *)title sameNote:(BOOL)sameNote generation:(NSUInteger)generation;
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
@end
@implementation PreviewTestRenderer
- (NSString *)htmlForText:(NSString *)text {
    dispatch_semaphore_signal(self.started);
    dispatch_semaphore_wait(self.releaseRender, DISPATCH_TIME_FOREVER);
    return [@"<p>" stringByAppendingFormat:@"%@</p>", text];
}
@end

@interface PreviewTestController : PreviewController
@property (nonatomic, strong) PreviewTestWindow *testWindow;
@property (nonatomic, strong) PreviewTestRenderer *testRenderer;
@property (nonatomic, strong) NSMutableArray *shown;
@end
@implementation PreviewTestController
- (NSWindow *)window { return (NSWindow *)self.testWindow; }
- (NVMarkupRenderer *)markupRenderer { return self.testRenderer; }
- (void)showHTML:(NSString *)html ofNote:(NoteObject *)note title:(NSString *)title sameNote:(BOOL)sameNote generation:(NSUInteger)generation {
    [self.shown addObject:@{ @"html": html, @"note": note ?: [NSNull null], @"title": title, @"sameNote": @(sameNote) }];
    self.isPreviewOutdated = NO;
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
    self.controller.shown = [NSMutableArray array];
    self.app = [[PreviewTestApp alloc] init];
}
- (void)tearDown {
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    self.controller = nil;
    self.app = nil;
    [super tearDown];
}
- (void)drainMainQueue {
    XCTestExpectation *done = [self expectationWithDescription:@"render completion delivered"];
    dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectationsWithTimeout:5 handler:nil];
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
    [self.controller preview:self.app];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    XCTAssertEqual(dispatch_semaphore_wait(self.controller.testRenderer.started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    [self drainMainQueue];
    [self drainMainQueue];
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
    [self drainMainQueue];
    XCTAssertTrue(self.controller.isPreviewOutdated);
    XCTAssertEqual(self.controller.shown.count, 0u);
    self.controller.testWindow.visible = YES;
    [self startRenderForNote:note text:@"new"];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    [self drainMainQueue];
    XCTAssertEqual(self.controller.shown.count, 1u);
    XCTAssertEqualObjects(self.controller.shown.firstObject[@"html"], @"<p>new</p>");
}
- (void)testEnteringStickyModeRejectsPendingRender {
    NoteObject *note = NVTestNote(@"Note", @"", nil);
    [self startRenderForNote:note text:@"old"];
    [self.controller makePreviewSticky:nil];
    dispatch_semaphore_signal(self.controller.testRenderer.releaseRender);
    [self drainMainQueue];
    XCTAssertTrue(self.controller.isPreviewSticky);
    XCTAssertEqual(self.controller.shown.count, 0u);
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
@end
