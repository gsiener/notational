//
//  NotationalUIPerformanceTests.m
//  Performance baseline for the flows only the running app shows (#62): launch, scrolling the notes
//  list, moving through notes, typing in a long note, and the app's memory over a workload. Each runs
//  on a synthetic corpus store (2,500, 10,000 and 25,000 notes) copied into a throwaway home folder.
//
//  Run by the perf workflow (.github/workflows/perf.yml), which makes the stores with
//  PerformanceTestsCorpusExport and sets TEST_RUNNER_NOTATIONAL_CORPUS_DIR. They drive the real UI and
//  take keyboard focus, so run them in CI or a VM, not on your desktop. Without the corpus they skip.
//

#import <XCTest/XCTest.h>

@interface NotationalUIPerformanceTests : XCTestCase {
	XCUIApplication *app;
	NSString *home;
}
+ (NSUInteger)corpusSize;
@end

@implementation NotationalUIPerformanceTests

+ (NSUInteger)corpusSize { return 0; }

//the base class only holds the tests
+ (XCTestSuite *)defaultTestSuite {
	if ([self corpusSize] == 0) return [XCTestSuite testSuiteWithName:NSStringFromClass(self)];
	return [super defaultTestSuite];
}

- (void)setUp {
	[super setUp];
	self.continueAfterFailure = NO;
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSString *appPath = environment[@"NOTATIONAL_APP"], *corpusDir = environment[@"NOTATIONAL_CORPUS_DIR"];
	if (![appPath length] || ![corpusDir length]) {
		XCTSkip(@"set TEST_RUNNER_NOTATIONAL_APP and TEST_RUNNER_NOTATIONAL_CORPUS_DIR (see .github/workflows/perf.yml)");
	}
	NSString *corpus = [corpusDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Notes-%lu.sqlite", (unsigned long)[[self class] corpusSize]]];
	XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:corpus], @"no corpus store at %@", corpus);

	//the store where the app looks for it, inside a throwaway home: local-only, so nothing syncs
	home = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/Notational"];
	[[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL];
	XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath:corpus toPath:[support stringByAppendingPathComponent:@"Notes.sqlite"] error:NULL]);

	app = [[XCUIApplication alloc] initWithURL:[NSURL fileURLWithPath:appPath]];
	app.launchEnvironment = @{@"CFFIXED_USER_HOME": home};
	app.launchArguments = @[@"-ShowDockIcon", @"YES", @"-StatusBarItem", @"NO", @"-ConfirmNoteDeletion", @"NO",
							 @"-QuitWhenClosingMainWindow", @"NO"];
}

- (void)tearDown {
	[app terminate];
	if (home) [[NSFileManager defaultManager] removeItemAtPath:home error:NULL];
	[super tearDown];
}

- (XCUIElement *)mainWindow { return app.windows[@"Notational"]; }

- (void)launchAndWaitForList {
	[app launch];
	XCTAssertTrue([[self mainWindow] waitForExistenceWithTimeout:60], @"main window never appeared");
	XCTAssertTrue([[[self mainWindow].tables.firstMatch.tableRows elementBoundByIndex:0] waitForExistenceWithTimeout:60], @"the notes list stayed empty");
}

- (void)showNoteTitled:(NSString *)title {
	XCUIElement *window = [self mainWindow];
	[window typeKey:@"l" modifierFlags:XCUIKeyModifierCommand];
	[window typeText:title];
	[window typeKey:XCUIKeyboardKeyDownArrow modifierFlags:0];
}

- (NSArray *)appMetrics {
	return @[[XCTClockMetric new], [[XCTCPUMetric alloc] initWithApplication:app], [[XCTMemoryMetric alloc] initWithApplication:app]];
}

- (XCTMeasureOptions *)manualOptions:(NSUInteger)iterations {
	XCTMeasureOptions *options = [XCTMeasureOptions defaultOptions];
	options.iterationCount = iterations;
	options.invocationOptions = XCTMeasurementInvocationManuallyStart | XCTMeasurementInvocationManuallyStop;
	return options;
}

#pragma mark Launch

//Launch until the notes list shows its first row. The workflow purges the disk cache before this test,
//so the first iteration is a cold launch and the rest are warm.
- (void)testLaunchUntilListShows {
	[self measureWithMetrics:@[[XCTClockMetric new]] options:[self manualOptions:5] block:^{
		[self startMeasuring];
		[self launchAndWaitForList];
		[self stopMeasuring];
		[app terminate];
	}];
}

#pragma mark Notes list

//scrolling the whole list a page at a time: the app's CPU time is the useful figure
- (void)testScrollNotesList {
	[self launchAndWaitForList];
	XCUIElement *table = [self mainWindow].tables.firstMatch;
	[self measureWithMetrics:[self appMetrics] options:[self manualOptions:5] block:^{
		[self startMeasuring];
		for (NSUInteger i = 0; i < 20; i++) [table scrollByDeltaX:0 deltaY:-800];
		for (NSUInteger i = 0; i < 20; i++) [table scrollByDeltaX:0 deltaY:800];
		[self stopMeasuring];
	}];
}

//the arrow keys in the search field move through the list, showing each note in the editor
- (void)moveThroughNotes:(NSUInteger)count {
	XCUIElement *window = [self mainWindow];
	[window typeKey:@"l" modifierFlags:XCUIKeyModifierCommand];
	for (NSUInteger i = 0; i < count; i++) [window typeKey:XCUIKeyboardKeyDownArrow modifierFlags:0];
}

//moving down the list a note at a time
- (void)testMoveThroughNotes {
	[self launchAndWaitForList];
	[self measureWithMetrics:[self appMetrics] options:[self manualOptions:5] block:^{
		[self startMeasuring];
		[self moveThroughNotes:30];
		[self stopMeasuring];
	}];
}

//typing a search one key at a time
- (void)testSearchTyping {
	[self launchAndWaitForList];
	XCUIElement *window = [self mainWindow];
	[self measureWithMetrics:[self appMetrics] options:[self manualOptions:5] block:^{
		[window typeKey:@"l" modifierFlags:XCUIKeyModifierCommand];
		[window typeKey:XCUIKeyboardKeyDelete modifierFlags:0];
		[self startMeasuring];
		[window typeText:@"meeting agenda"];
		[self stopMeasuring];
	}];
}

#pragma mark Editing

//20 keystrokes in the middle of the 1 MB note
- (void)testTypingInHugeNote {
	[self launchAndWaitForList];
	[self showNoteTitled:@"Very long note"];
	XCUIElement *editor = [self mainWindow].textViews.firstMatch;
	XCTAssertTrue([editor waitForExistenceWithTimeout:30]);
	[editor click];
	[self measureWithMetrics:[self appMetrics] options:[self manualOptions:5] block:^{
		[self startMeasuring];
		[editor typeText:@"xxxxx xxxxx xxxxx xxx"];
		[self stopMeasuring];
	}];
}

#pragma mark Memory

//The app's memory across a workload: 100 notes shown, then 30 more with the preview open.
- (void)testMemoryWorkload {
	[self launchAndWaitForList];
	[self measureWithMetrics:@[[[XCTMemoryMetric alloc] initWithApplication:app], [[XCTCPUMetric alloc] initWithApplication:app]]
					 options:[self manualOptions:1] block:^{
		[self startMeasuring];
		[self moveThroughNotes:100];
		//Preview ▸ Toggle Preview Window
		[[self mainWindow] typeKey:@"p" modifierFlags:XCUIKeyModifierCommand | XCUIKeyModifierControl];
		[self moveThroughNotes:30];
		[self stopMeasuring];
	}];
}

@end

@interface NotationalUIPerformanceTests2500 : NotationalUIPerformanceTests
@end
@implementation NotationalUIPerformanceTests2500
+ (NSUInteger)corpusSize { return 2500; }
@end

@interface NotationalUIPerformanceTests10000 : NotationalUIPerformanceTests
@end
@implementation NotationalUIPerformanceTests10000
+ (NSUInteger)corpusSize { return 10000; }
@end

@interface NotationalUIPerformanceTests25000 : NotationalUIPerformanceTests
@end
@implementation NotationalUIPerformanceTests25000
+ (NSUInteger)corpusSize { return 25000; }
@end
