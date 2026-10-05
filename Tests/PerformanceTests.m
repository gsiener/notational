//
//  PerformanceTests.m
//  NotationTests
//
//  Performance baseline (#62): how long the everyday paths take and how much memory they use, on
//  a synthetic corpus (NVPerfCorpus) of 2,500, 10,000 and 25,000 notes. Never the live store.
//
//  Slow, and meaningless under Address Sanitizer, so scripts/test.sh skips them; run them with
//  scripts/perf.sh. Results are XCTest's "measured [...]" lines plus NVPERF lines for one-off
//  figures (memory per note, leaks); scripts/perf-report.py tabulates both.
//  See docs/research/performance-baseline.md.
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <mach/mach.h>
#import <libproc.h>
#import <malloc/malloc.h>
#import "NVTestSupport.h"
#import "NVPerfCorpus.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NVSyncEngine.h"
#import "NVFakeSimplenoteService.h"
#import "NotationController.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NoteAttributeColumn.h"
#import "FastListDataSource.h"
#import "LinkingEditor.h"
#import "AppController.h"
#import "GlobalPrefs.h"
#import "NVMarkupRenderer.h"
#import "NVHereNowSites.h"
#import "PreviewController.h"

@interface NotationController (PerformanceAccess) <NVSyncEngineDelegate>
- (NSArray *)perfAllNotes;
@end
@implementation NotationController (PerformanceAccess)
- (NSArray *)perfAllNotes { return allNotes; }
@end

@interface NVHereNowSites (PerformanceAccess)
- (NSArray *)sitesFromRows:(NSArray *)rows accountID:(NSString *)accountID;
@end

#pragma mark Helpers

static uint64_t const CorpusSeed = 62;

//the process's footprint as Activity Monitor's Memory column shows it
static uint64_t Footprint(pid_t pid) {
	struct rusage_info_v4 info;
	if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return 0;
	return info.ri_phys_footprint;
}

//bytes allocated and not yet freed, in every malloc zone. Unlike the footprint, it doesn't depend on
//whether earlier tests left freed pages to reuse, so deltas measure what the code under test holds.
static double LiveHeapBytes(void) {
	malloc_statistics_t stats;
	malloc_zone_statistics(NULL, &stats);
	return (double)stats.size_in_use;
}

static void Report(NSString *test, NSString *name, double value, NSString *unit) {
	fprintf(stderr, "NVPERF %s %s %.3f %s\n", [test UTF8String], [name UTF8String], value, [unit UTF8String]);
}

static double Milliseconds(CFAbsoluteTime start) {
	return (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
}

static NSArray *TimeAndMemory(void) {
	return @[[XCTClockMetric new], [XCTCPUMetric new], [XCTMemoryMetric new]];
}

static XCTMeasureOptions *ManualOptions(NSUInteger iterations) {
	XCTMeasureOptions *options = [XCTMeasureOptions defaultOptions];
	options.iterationCount = iterations;
	options.invocationOptions = XCTMeasurementInvocationManuallyStart | XCTMeasurementInvocationManuallyStop;
	return options;
}

static NoteAttributeColumn *Column(NSString *identifier) {
	NSDictionary *functions = @{ NoteTitleColumnString: @[[NSValue valueWithPointer:compareTitleString], [NSValue valueWithPointer:compareTitleStringReverse]],
								 NoteLabelsColumnString: @[[NSValue valueWithPointer:compareLabelString], [NSValue valueWithPointer:compareLabelStringReverse]],
								 NoteDateModifiedColumnString: @[[NSValue valueWithPointer:compareDateModified], [NSValue valueWithPointer:compareDateModifiedReverse]],
								 NoteDateCreatedColumnString: @[[NSValue valueWithPointer:compareDateCreated], [NSValue valueWithPointer:compareDateCreatedReverse]] };
	NoteAttributeColumn *column = [[NoteAttributeColumn alloc] initWithIdentifier:identifier];
	[column setSortingFunction:(NSInteger (*)(__unsafe_unretained id *, __unsafe_unretained id *))[functions[identifier][0] pointerValue]];
	[column setReverseSortingFunction:(NSInteger (*)(__unsafe_unretained id *, __unsafe_unretained id *))[functions[identifier][1] pointerValue]];
	return column;
}

//an editor as the main window has it: in a scroll view, wrapping to its width
static LinkingEditor *Editor(void) {
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 700, 800)];
	NSSize size = [scroll contentSize];
	LinkingEditor *editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
	[editor setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	[editor setVerticallyResizable:YES];
	[editor setHorizontallyResizable:NO];
	[editor setAutoresizingMask:NSViewWidthSizable];
	[[editor textContainer] setWidthTracksTextView:YES];
	[[editor textContainer] setContainerSize:NSMakeSize(size.width, CGFLOAT_MAX)];
	[scroll setDocumentView:editor];
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 800) styleMask:NSWindowStyleMaskTitled
													 backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[window setContentView:scroll];
	//first responder, as in the main window: otherwise each change begins and ends an editing session
	[window makeFirstResponder:editor];
	return editor;
}

//what reaches the screen: lay out and draw the visible part, into a bitmap so no window is shown
static void DrawVisible(NSTextView *editor) {
	NSRect visible = [editor visibleRect];
	if (NSIsEmptyRect(visible)) visible = NSMakeRect(0, 0, 700, 800);
	[[editor layoutManager] ensureLayoutForBoundingRect:visible inTextContainer:[editor textContainer]];
	NSBitmapImageRep *bitmap = [editor bitmapImageRepForCachingDisplayInRect:visible];
	[editor cacheDisplayInRect:visible toBitmapImageRep:bitmap];
}

//preferences with ShowWordCount off
@interface WordCountPrefs : GlobalPrefs
@end
@implementation WordCountPrefs
- (BOOL)showWordCount { return NO; }
@end

//AppControllers made without -init: their -dealloc expects a launched app
static NSMutableArray *KeptObjects;

#pragma mark - Corpus-size tests

//Runs every test once per corpus size, through the three subclasses at the end of this section.
@interface NVPerfTestCase : NVTestCase {
	NVNotesStore *store;
	NotationController *controller;
	AppController *typingApp;   //kept for good (see KeptObjects); let go of what it points to after each test
}
+ (NSUInteger)corpusSize;
@end

static NSMutableDictionary *CorpusPaths;     //size -> store file, made once per run
static NSMutableDictionary *CorpusServers;   //size -> fake server holding the same notes

@implementation NVPerfTestCase

+ (NSUInteger)corpusSize { return 0; }

//the base class only holds the tests
+ (XCTestSuite *)defaultTestSuite {
	if ([self corpusSize] == 0) return [XCTestSuite testSuiteWithName:NSStringFromClass(self)];
	return [super defaultTestSuite];
}

+ (NSString *)corpusPath {
	NSNumber *size = @([self corpusSize]);
	if (!CorpusPaths) CorpusPaths = [NSMutableDictionary dictionary];
	NSString *path = CorpusPaths[size];
	if (!path) {
		path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"NVPerfCorpus-%@-%@.sqlite", size, [[NSUUID UUID] UUIDString]]];
		CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
		//its temporary objects would otherwise stay in the first test's autorelease pool
		@autoreleasepool {
			NVNotesStore *made = [NVPerfCorpus storeAtPath:path count:[size unsignedIntegerValue] seed:CorpusSeed];
			[made close];
		}
		NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
		Report(NSStringFromClass(self), @"corpusFileSize", [attributes fileSize] / 1048576.0, @"MB");
		Report(NSStringFromClass(self), @"corpusGeneration", Milliseconds(start), @"ms");
		CorpusPaths[size] = path;
	}
	return path;
}

+ (void)tearDown {
	NSString *path = CorpusPaths[@([self corpusSize])];
	if (path) {
		for (NSString *suffix in @[@"", @"-wal", @"-shm"])
			[[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:suffix] error:NULL];
		[CorpusPaths removeObjectForKey:@([self corpusSize])];
	}
	[CorpusServers removeObjectForKey:@([self corpusSize])];
	[super tearDown];
}

- (NSString *)testName {
	return [NSString stringWithFormat:@"%@.%@", NSStringFromClass([self class]), NSStringFromSelector([self.invocation selector])];
}

- (void)setUp {
	[super setUp];
	if (!KeptObjects) KeptObjects = [NSMutableArray array];
	self.continueAfterFailure = NO;
}

- (void)tearDown {
	for (NSString *key in @[@"currentNote", @"textView", @"notationController", @"prefsController"])
		[typingApp setValue:nil forKey:key];
	typingApp = nil;
	[self closeController];
	[super tearDown];
}

//a private copy of the corpus store, so writes never change the shared one
- (NVNotesStore *)openCorpusCopy {
	NSString *copy = [self.temporaryDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] copyItemAtPath:[[self class] corpusPath] toPath:copy error:NULL];
	return [NVNotesStore storeAtPath:copy error:NULL];
}

//The list's title column as the main window has it: its width sets how much of each note the list's
//preview shows. Until the window gives it one (after loading), the controller has width 0.
static NSTableColumn *TitleColumn(void) {
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:NoteTitleColumnString];
	[column setWidth:300];
	return column;
}

//the notes list as launch leaves it, previews included
- (void)openController {
	@autoreleasepool {
		[self openControllerNow];
	}
}

- (void)openControllerNow {
	store = [self openCorpusCopy];
	controller = [[NotationController alloc] initWithNotesStore:store];
	[controller setSortColumn:Column(NoteDateModifiedColumnString)];
	[controller refilterNotes];
	[controller regeneratePreviewsForColumn:TitleColumn() visibleFilteredRows:NSMakeRange(0, 40) forceUpdate:YES];
	[NSObject cancelPreviousPerformRequestsWithTarget:controller selector:@selector(regenerateAllPreviews) object:nil];
	[controller regenerateAllPreviews];
}

- (void)closeController {
	if (controller) {
		[NSObject cancelPreviousPerformRequestsWithTarget:controller];
		[controller closeAllResources];
		controller = nil;
	}
	[store close];
	store = nil;
}

- (NoteObject *)noteTitled:(NSString *)title {
	for (NoteObject *note in [controller perfAllNotes])
		if ([titleOfNote(note) isEqualToString:title]) return note;
	return nil;
}

#pragma mark Launch

//reading every note from SQLite, as launch does before building the list
- (void)testLaunchReadStore {
	NSString *path = [[self class] corpusPath];
	[self measureWithMetrics:TimeAndMemory() options:ManualOptions(5) block:^{
		[self startMeasuring];
		NVNotesStore *opened = [NVNotesStore storeAtPath:path error:NULL];
		NSArray *records = [opened allNotesWithoutServerData];
		[self stopMeasuring];
		XCTAssertEqual([records count], [[self class] corpusSize]);
		[opened close];
	}];
}

//Store to a sorted, unfiltered notes list with its visible rows' previews: what launch does before the
//list can draw. Each note's preview is first made while the controller's title column width is still 0.
- (void)testLaunchNotesListReady {
	[self measureWithMetrics:TimeAndMemory() options:ManualOptions(5) block:^{
		NVNotesStore *opened = [self openCorpusCopy];
		[self startMeasuring];
		NotationController *notation = [[NotationController alloc] initWithNotesStore:opened];
		[notation setSortColumn:Column(NoteDateModifiedColumnString)];
		[notation refilterNotes];
		[notation regeneratePreviewsForColumn:TitleColumn() visibleFilteredRows:NSMakeRange(0, 40) forceUpdate:YES];
		[self stopMeasuring];
		[NSObject cancelPreviousPerformRequestsWithTarget:notation];
		XCTAssertEqual([[notation notesListDataSource] count], [[self class] corpusSize]);
		[notation closeAllResources];
		[opened close];
	}];
}

//the autocomplete prefix tree, rebuilt at launch and whenever a note is added, removed or retitled
- (void)testLaunchTitlePrefixConnections {
	[self openController];
	[self measureWithMetrics:@[[XCTClockMetric new]] block:^{
		[controller updateTitlePrefixConnections];
	}];
}

//the list's title and preview strings for every note at the window's width: queued right after launch,
//and again on every title column resize
- (void)testNotesListAllPreviewStrings {
	[self openController];
	[self measureWithMetrics:@[[XCTClockMetric new]] block:^{
		[controller regenerateAllPreviews];
	}];
}

//memory the notes hold once loaded, in total and per note: while the controller has no column width
//yet (each preview then holds the whole note), and once the window has given it one
//(Each step runs in its own autorelease pool, as each run loop pass in the app does, so the records read
//from the store and other temporaries are gone before the heap is measured.)
- (void)testLaunchMemoryPerNote {
	NVNotesStore *opened = [self openCorpusCopy];
	double before = LiveHeapBytes(), size = [[self class] corpusSize];
	NotationController *notation = nil;
	@autoreleasepool {
		notation = [[NotationController alloc] initWithNotesStore:opened];
		[notation setSortColumn:Column(NoteDateModifiedColumnString)];
		[notation refilterNotes];
	}
	double loaded = LiveHeapBytes();
	@autoreleasepool {
		[notation regeneratePreviewsForColumn:TitleColumn() visibleFilteredRows:NSMakeRange(0, 40) forceUpdate:YES];
		[NSObject cancelPreviousPerformRequestsWithTarget:notation];
		[notation regenerateAllPreviews];
	}
	double after = LiveHeapBytes();
	Report([self testName], @"heapBeforeColumnWidth", (loaded - before) / 1048576.0, @"MB");
	Report([self testName], @"heapPerNoteBeforeColumnWidth", (loaded - before) / size, @"bytes");
	Report([self testName], @"heap", (after - before) / 1048576.0, @"MB");
	Report([self testName], @"heapPerNote", (after - before) / size, @"bytes");
	[notation closeAllResources];
	[opened close];
}

//What stays allocated after a notes controller is closed and released, as when the account changes.
//Three rounds, so a one-time cache doesn't count as a leak.
- (void)testMemoryClosedControllerIsFreed {
	double retained = 0;
	for (NSUInteger round = 0; round < 3; round++) {
		double before = 0;
		@autoreleasepool {
			before = LiveHeapBytes();
			NVNotesStore *opened = [self openCorpusCopy];
			NotationController *notation = [[NotationController alloc] initWithNotesStore:opened];
			[notation setSortColumn:Column(NoteDateModifiedColumnString)];
			[notation refilterNotes];
			[NSObject cancelPreviousPerformRequestsWithTarget:notation];
			[notation closeAllResources];
			[opened close];
		}
		[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
		if (round > 0) retained += LiveHeapBytes() - before;
	}
	Report([self testName], @"heapRetainedPerClosedController", retained / 2 / 1048576.0, @"MB");
}

#pragma mark Search

- (void)typeSearch:(NSString *)typed {
	for (NSUInteger i = 1; i <= [typed length]; i++)
		[controller filterNotesFromString:[typed substringToIndex:i]];
}

//typing a two-word search one keystroke at a time, each narrowing the last result
- (void)testSearchTypingByKeystroke {
	[self openController];
	NSString *typed = @"meeting agenda";
	[self measureWithMetrics:@[[XCTClockMetric new], [XCTCPUMetric new]] options:ManualOptions(5) block:^{
		[controller filterNotesFromString:@""];
		[self startMeasuring];
		[self typeSearch:typed];
		[self stopMeasuring];
	}];
	//the slowest single keystroke, which is what the user feels
	double slowest = 0;
	[controller filterNotesFromString:@""];
	for (NSUInteger i = 1; i <= [typed length]; i++) {
		CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
		[controller filterNotesFromString:[typed substringToIndex:i]];
		slowest = MAX(slowest, Milliseconds(start));
	}
	Report([self testName], @"slowestKeystroke", slowest, @"ms");
}

- (void)measureSearchFromEmpty:(NSString *)search {
	[self openController];
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(10) block:^{
		[controller filterNotesFromString:@""];
		[self startMeasuring];
		[controller filterNotesFromString:search];
		[self stopMeasuring];
	}];
	Report([self testName], @"matches", [[controller notesListDataSource] count], @"notes");
}

//the first keystroke scans every note; a single common letter matches almost all of them
- (void)testSearchFirstLetter { [self measureSearchFromEmpty:@"e"]; }
- (void)testSearchCommonWord { [self measureSearchFromEmpty:NVPerfCommonTerm]; }
- (void)testSearchRareWord { [self measureSearchFromEmpty:NVPerfRareTerm]; }
- (void)testSearchMissingWord { [self measureSearchFromEmpty:NVPerfMissingTerm]; }

//deleting a character can't narrow the last result, so every note is scanned again
- (void)testSearchBackspace {
	[self openController];
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(10) block:^{
		[controller filterNotesFromString:@"meeting agenda"];
		[self startMeasuring];
		[controller filterNotesFromString:@"meeting agend"];
		[self stopMeasuring];
	}];
}

#pragma mark Notes list

- (void)measureSortBy:(NSString *)identifier {
	[self openController];
	NoteAttributeColumn *column = Column(identifier), *other = Column([identifier isEqualToString:NoteTitleColumnString] ? NoteDateModifiedColumnString : NoteTitleColumnString);
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(5) block:^{
		[controller setSortColumn:other];
		[self startMeasuring];
		[controller setSortColumn:column];
		[self stopMeasuring];
	}];
}

- (void)testSortByTitle { [self measureSortBy:NoteTitleColumnString]; }
- (void)testSortByDateModified { [self measureSortBy:NoteDateModifiedColumnString]; }
- (void)testSortByDateCreated { [self measureSortBy:NoteDateCreatedColumnString]; }
- (void)testSortByTags { [self measureSortBy:NoteLabelsColumnString]; }

//rebuilding the rows with 1,000 here.now Sites interleaved, as on every list change once connected
- (void)testNotesListMixedWithSites {
	[self openController];
	NSMutableArray *sites = [NSMutableArray array];
	for (NSUInteger i = 0; i < 1000; i++) {
		NVHereNowSite *site = [NVHereNowSite new];
		site.identity = [NSString stringWithFormat:@"perf:owned:site%lu", (unsigned long)i];
		site.title = [NSString stringWithFormat:@"Site %lu", (unsigned long)i];
		site.searchText = [site.title lowercaseString];
		site.URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://site%lu.here.now/", (unsigned long)i]];
		site.modifiedDate = [NSDate dateWithTimeIntervalSince1970:1300000000 + i * 400000];
		[sites addObject:site];
	}
	NVHereNowMixedList *mixed = [NVHereNowMixedList new];
	mixed.sites = sites;
	[self measureWithMetrics:@[[XCTClockMetric new]] block:^{
		[mixed setNotes:[controller notesListDataSource] sortKey:NoteDateModifiedColumnString reversed:YES search:nil];
	}];
	XCTAssertEqual(mixed.count, [[self class] corpusSize] + 1000);
}

#pragma mark Note switching

//showing a note as -displayContentsForNoteAtRow: does: link detection on first view, the text into
//the editor, search terms highlighted, and the visible part laid out and drawn. 20 notes never shown
//before, of every size, per iteration.
- (void)testOpenNotes {
	[self openController];
	NSMutableArray *notes = [[controller perfAllNotes] mutableCopy];
	//a fixed shuffle, so every run opens the same notes
	uint64_t state = 1;
	for (NSUInteger i = [notes count] - 1; i > 0; i--) {
		state = state * 6364136223846793005ULL + 1442695040888963407ULL;
		[notes exchangeObjectAtIndex:i withObjectAtIndex:(NSUInteger)((state >> 33) % (i + 1))];
	}
	LinkingEditor *editor = Editor();
	__block NSUInteger next = 0;
	[self measureWithMetrics:@[[XCTClockMetric new], [XCTMemoryMetric new]] options:ManualOptions(5) block:^{
		[self startMeasuring];
		for (NSUInteger i = 0; i < 20; i++) {
			NoteObject *note = notes[next++];
			[[editor textStorage] setAttributedString:[note contentString]];
			[editor highlightTermsTemporarilyReturningFirstRange:@"the" avoidHighlight:NO];
			[editor scrollRangeToVisible:NSMakeRange(0, 0)];
			DrawVisible(editor);
		}
		[self stopMeasuring];
	}];
}

//the same for the 1 MB note, first view each time
- (void)testOpenHugeNote {
	[self openController];
	NVNoteRecord *record = [store noteWithID:[[self noteTitled:NVPerfHugeNoteTitle] noteRecordID]];
	LinkingEditor *editor = Editor();
	[self measureWithMetrics:@[[XCTClockMetric new], [XCTMemoryMetric new]] options:ManualOptions(5) block:^{
		NoteObject *note = [[NoteObject alloc] initWithNoteRecord:record delegate:controller];
		[[editor textStorage] setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
		[self startMeasuring];
		[[editor textStorage] setAttributedString:[note contentString]];
		[editor highlightTermsTemporarilyReturningFirstRange:@"the" avoidHighlight:NO];
		[editor scrollRangeToVisible:NSMakeRange(0, 0)];
		DrawVisible(editor);
		[self stopMeasuring];
	}];
}

#pragma mark Typing

//An editor showing note, wired to an AppController as the main window is, so each keystroke runs
//the app's real -textDidChange: (undo snapshots, the note's copy of the text, write scheduling).
- (LinkingEditor *)editorTypingInto:(NoteObject *)note wordCount:(BOOL)wordCount {
	LinkingEditor *editor = Editor();
	[editor setAllowsUndo:YES];
	[[note undoManager] setGroupsByEvent:NO];
	[[editor textStorage] setAttributedString:[note contentString]];
	AppController *app = [AppController alloc];
	[KeptObjects addObject:app];
	typingApp = app;
	[app setValue:note forKey:@"currentNote"];
	[app setValue:editor forKey:@"textView"];
	[app setValue:controller forKey:@"notationController"];
	//With ShowWordCount on (the default) the count is only made on hover; with it off, -textDidChange:
	//counts every word of the note on each keystroke
	GlobalPrefs *prefs = wordCount ? [WordCountPrefs new] : [GlobalPrefs defaultPrefs];
	[KeptObjects addObject:prefs];
	[app setValue:prefs forKey:@"prefsController"];
	[editor setDelegate:app];
	[editor setSelectedRange:NSMakeRange([[editor string] length] / 2, 0)];
	[editor scrollRangeToVisible:[editor selectedRange]];
	DrawVisible(editor);
	return editor;
}

- (void)measureTypingInto:(NoteObject *)note wordCount:(BOOL)wordCount {
	LinkingEditor *editor = [self editorTypingInto:note wordCount:wordCount];
	NSUInteger keystrokes = 20;
	[self measureWithMetrics:@[[XCTClockMetric new], [XCTCPUMetric new]] options:ManualOptions(5) block:^{
		[self startMeasuring];
		for (NSUInteger i = 0; i < keystrokes; i++) {
			[[note undoManager] beginUndoGrouping];
			[editor insertText:(i % 6 == 5) ? @" " : @"x" replacementRange:[editor selectedRange]];
			[[note undoManager] endUndoGrouping];
			DrawVisible(editor);
		}
		[self stopMeasuring];
	}];
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
}

//20 keystrokes in the middle of the 1 MB note, each laid out and drawn
- (void)testTypingInHugeNote {
	[self openController];
	[self measureTypingInto:[self noteTitled:NVPerfHugeNoteTitle] wordCount:NO];
}

//the same with ShowWordCount off, as some users have it
- (void)testTypingInHugeNoteCountingWords {
	[self openController];
	[self measureTypingInto:[self noteTitled:NVPerfHugeNoteTitle] wordCount:YES];
}

//A 100 KB note added to the list, about the size of the largest note in the real account (125 KB)
- (NoteObject *)addNoteOf100KB {
	NVNoteRecord *record = [[NVNoteRecord alloc] init];
	[record setNoteID:@"perf-100kb"];
	[record setContent:[NVPerfCorpus contentWithLength:100000 seed:100]];
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:record delegate:controller];
	[controller _addNote:note];
	return note;
}

- (void)testTypingIn100KBNote {
	[self openController];
	[self measureTypingInto:[self addNoteOf100KB] wordCount:NO];
}

- (void)testTypingIn100KBNoteCountingWords {
	[self openController];
	[self measureTypingInto:[self addNoteOf100KB] wordCount:YES];
}

//the same in a note of about 3 KB, the 90th percentile
- (void)testTypingInTypicalNote {
	[self openController];
	NoteObject *typical = nil;
	for (NoteObject *note in [controller perfAllNotes]) {
		NSUInteger length = [[[note contentString] string] length];
		if (length > 2500 && length < 3500) { typical = note; break; }
	}
	[self measureTypingInto:typical wordCount:NO];
}

//the autosave after typing in the 1 MB note: the controller's flush to the store
- (void)testAutosaveHugeNote {
	[self openController];
	NoteObject *note = [self noteTitled:NVPerfHugeNoteTitle];
	NSMutableAttributedString *text = [[note contentString] mutableCopy];
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(5) block:^{
		[text appendAttributedString:[[NSAttributedString alloc] initWithString:@"x"]];
		[note setContentString:text];
		[self startMeasuring];
		[controller synchronizeNoteChanges:nil];
		[self stopMeasuring];
	}];
	XCTAssertTrue([[store noteWithID:[note noteRecordID]] pending]);
}

#pragma mark Sync

+ (NVFakeSimplenoteService *)corpusServer {
	if (!CorpusServers) CorpusServers = [NSMutableDictionary dictionary];
	NVFakeSimplenoteService *server = CorpusServers[@([self corpusSize])];
	if (!server) {
		server = [[NVFakeSimplenoteService alloc] init];
		server.changesOmitData = YES;   //as the real feed
		for (NVNoteRecord *record in [NVPerfCorpus recordsWithCount:[self corpusSize] seed:CorpusSeed])
			[server remoteCreateNoteWithContent:[record content] tags:[record tags]];
		CorpusServers[@([self corpusSize])] = server;
	}
	return server;
}

//first sync of the whole account into an empty store (the in-memory server costs almost nothing)
- (void)testSyncInitialFull {
	NVFakeSimplenoteService *server = [[self class] corpusServer];
	[self measureWithMetrics:TimeAndMemory() options:ManualOptions(3) block:^{
		NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
		NVNotesStore *empty = [NVNotesStore storeAtPath:path error:NULL];
		NVSyncEngine *engine = [[NVSyncEngine alloc] initWithStore:empty service:server];
		[self startMeasuring];
		XCTAssertTrue([engine syncOnceReturningError:NULL]);
		[self stopMeasuring];
		XCTAssertEqual([empty noteCount], [[self class] corpusSize]);
		[empty close];
	}];
}

//a routine cycle: 20 notes changed elsewhere and 20 edited here
- (void)testSyncIncremental {
	NVFakeSimplenoteService *server = [[self class] corpusServer];
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"incremental.sqlite"];
	NVNotesStore *synced = [NVNotesStore storeAtPath:path error:NULL];
	NVSyncEngine *engine = [[NVSyncEngine alloc] initWithStore:synced service:server];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	NSArray *ids = [[synced allNotesWithoutServerData] valueForKey:@"noteID"];
	__block NSUInteger round = 0;
	[self measureWithMetrics:@[[XCTClockMetric new], [XCTCPUMetric new]] options:ManualOptions(5) block:^{
		round++;
		for (NSUInteger i = 0; i < 20; i++) {
			NSString *remoteID = ids[(round * 97 + i * 13) % [ids count]];
			[server remoteSetContent:[NSString stringWithFormat:@"Remote %lu %lu\n\nchanged elsewhere", (unsigned long)round, (unsigned long)i] ofNote:remoteID];
			NVNoteRecord *local = [synced noteWithID:ids[(round * 89 + i * 17 + 1) % [ids count]]];
			[local setContent:[[local content] stringByAppendingString:@"\nedited here"]];
			[synced saveLocalEdit:local];
		}
		[self startMeasuring];
		XCTAssertTrue([engine syncOnceReturningError:NULL]);
		[self stopMeasuring];
	}];
	[synced close];
}

//What a routine cycle costs the main thread: the controller taking 20 changed notes. Today any change
//re-sorts and re-filters the whole list and rebuilds the prefix tree.
- (void)testSyncApplyChangesOnMainThread {
	[self openController];
	NSArray *notes = [controller perfAllNotes];
	__block NSUInteger round = 0;
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(10) block:^{
		round++;
		NSMutableArray *records = [NSMutableArray array];
		for (NSUInteger i = 0; i < 20; i++) {
			NoteObject *note = notes[(round * 101 + i * 37) % [notes count]];
			NVNoteRecord *record = [store noteWithID:[note noteRecordID]];
			[record setContent:[NSString stringWithFormat:@"%@\n\nchanged elsewhere %lu", titleOfNote(note), (unsigned long)round]];
			[records addObject:record];
		}
		[self startMeasuring];
		[controller syncEngine:nil didUpdateNotes:records removedNoteIDs:@[]];
		[self stopMeasuring];
	}];
}

//the first sync landing in an empty list: every note at once, on the main thread
- (void)testSyncApplyFirstSyncOnMainThread {
	NSArray *records = [NVPerfCorpus recordsWithCount:[[self class] corpusSize] seed:CorpusSeed];
	[self measureWithMetrics:TimeAndMemory() options:ManualOptions(3) block:^{
		NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
		NVNotesStore *empty = [NVNotesStore storeAtPath:path error:NULL];
		NotationController *notation = [[NotationController alloc] initWithNotesStore:empty];
		[notation setSortColumn:Column(NoteDateModifiedColumnString)];
		[self startMeasuring];
		[notation syncEngine:nil didUpdateNotes:records removedNoteIDs:@[]];
		[self stopMeasuring];
		XCTAssertEqual([[notation notesListDataSource] count], [[self class] corpusSize]);
		[notation closeAllResources];
		[empty close];
	}];
}

#pragma mark Memory

//An hour of use, compressed: open 300 notes, preview 60 of them, type in 10 and save. Reports the
//heap growth and the growth per note opened (link attributes stay on a note once it's been shown).
- (void)testMemoryWorkload {
	[self openController];
	double start = LiveHeapBytes();
	NSArray *notes = [controller perfAllNotes];
	LinkingEditor *editor = Editor();
	NVMarkupRenderer *renderer = [NVMarkupRenderer defaultRenderer];
	for (NSUInteger i = 0; i < 300; i++) {
		NoteObject *note = notes[(i * 7919) % [notes count]];
		[[editor textStorage] setAttributedString:[note contentString]];
		DrawVisible(editor);
	}
	double afterOpening = LiveHeapBytes();
	@autoreleasepool {
		for (NSUInteger i = 0; i < 60; i++) {
			NoteObject *note = notes[(i * 104729) % [notes count]];
			NSString *html = [renderer htmlForText:[[note contentString] string]];
			(void)[renderer pageForHTML:html title:titleOfNote(note)];
		}
	}
	double afterPreviews = LiveHeapBytes();
	for (NSUInteger i = 0; i < 10; i++) {
		NoteObject *note = notes[(i * 31337) % [notes count]];
		NSMutableAttributedString *text = [[note contentString] mutableCopy];
		[text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\nmore"]];
		[note setContentString:text];
	}
	[controller synchronizeNoteChanges:nil];
	double end = LiveHeapBytes();
	Report([self testName], @"heapGrowthOpening300Notes", (afterOpening - start) / 1048576.0, @"MB");
	Report([self testName], @"heapGrowthPerNoteOpened", (afterOpening - start) / 300.0 / 1024.0, @"KB");
	Report([self testName], @"heapGrowth60Previews", (afterPreviews - afterOpening) / 1048576.0, @"MB");
	Report([self testName], @"heapGrowthTotal", (end - start) / 1048576.0, @"MB");
	Report([self testName], @"processFootprint", Footprint(getpid()) / 1048576.0, @"MB");

}

//What `leaks` finds in this process after every other test of the class (XCTest runs them by name).
//It inspects the process while this test waits; it can't run under Address Sanitizer. The full report
//goes to a file named in the NVPERF-LEAKS-LOG line; run with MallocStackLogging=1 for stacks.
- (void)testZLeaks {
	NSTask *task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/leaks"];
	task.arguments = @[[NSString stringWithFormat:@"%d", getpid()]];
	NSPipe *pipe = [NSPipe pipe];
	task.standardOutput = pipe;
	task.standardError = [NSPipe pipe];
	if ([task launchAndReturnError:NULL]) {
		NSData *output = [[pipe fileHandleForReading] readDataToEndOfFile];
		[task waitUntilExit];
		NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
		NSRegularExpression *summary = [NSRegularExpression regularExpressionWithPattern:@"(\\d+) leaks? for (\\d+) total leaked bytes" options:0 error:NULL];
		NSTextCheckingResult *match = [summary firstMatchInString:text options:0 range:NSMakeRange(0, [text length])];
		if (match) {
			Report([self testName], @"leaks", [[text substringWithRange:[match rangeAtIndex:1]] doubleValue], @"leaks");
			Report([self testName], @"leakedBytes", [[text substringWithRange:[match rangeAtIndex:2]] doubleValue], @"bytes");
		}
		NSString *log = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"NVPerfLeaks-%@.txt", NSStringFromClass([self class])]];
		[text writeToFile:log atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		fprintf(stderr, "NVPERF-LEAKS-LOG %s\n", [log UTF8String]);
	}
}

@end

@interface PerformanceTests2500 : NVPerfTestCase
@end
@implementation PerformanceTests2500
+ (NSUInteger)corpusSize { return 2500; }
@end

@interface PerformanceTests10000 : NVPerfTestCase
@end
@implementation PerformanceTests10000
+ (NSUInteger)corpusSize { return 10000; }
@end

@interface PerformanceTests25000 : NVPerfTestCase
@end
@implementation PerformanceTests25000
+ (NSUInteger)corpusSize { return 25000; }
@end

#pragma mark - Tests that don't depend on the corpus size

@interface PreviewController (PerformanceAccess)
+ (NSString *)scriptReplacingContentOfElement:(NSString *)elementID withHTML:(NSString *)html;
@end

@interface PerformanceTestsPreview : NVTestCase <WKNavigationDelegate> {
	XCTestExpectation *loaded;
}
@end

@implementation PerformanceTestsPreview

- (NVMarkupRenderer *)renderer {
	NVMarkupRenderer *renderer = [NVMarkupRenderer defaultRenderer];
	renderer.bundledTemplateFolder = NVTestRepoPath();
	renderer.customTemplateFolder = self.temporaryDirectory;
	return renderer;
}

- (void)measureRenderOfLength:(NSUInteger)length {
	NSString *text = [NVPerfCorpus contentWithLength:length seed:length];
	NVMarkupRenderer *renderer = [self renderer];
	[self measureWithMetrics:TimeAndMemory() block:^{
		(void)[renderer htmlForText:text];
	}];
}

//MultiMarkdown 6 by note size (it runs off the main thread)
- (void)testPreviewRender1KB { [self measureRenderOfLength:1000]; }
- (void)testPreviewRender10KB { [self measureRenderOfLength:10000]; }
- (void)testPreviewRender100KB { [self measureRenderOfLength:100000]; }
- (void)testPreviewRender1MB { [self measureRenderOfLength:1000000]; }

//What -showHTML: does on the main thread once a render arrives, before WebKit: the source view's
//text, the content element and the whole page written to a file
- (void)testPreviewMainThreadWork100KB {
	NVMarkupRenderer *renderer = [self renderer];
	NSString *html = [renderer htmlForText:[NVPerfCorpus contentWithLength:100000 seed:3]];
	NSTextView *sourceView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 600)];
	NSString *file = [self.temporaryDirectory stringByAppendingPathComponent:@"preview.html"];
	[self measureWithMetrics:@[[XCTClockMetric new]] block:^{
		[sourceView replaceCharactersInRange:NSMakeRange(0, [[sourceView string] length]) withString:html];
		NSString *elementID = nil;
		(void)[renderer contentElementHTMLForHTML:html title:@"Title" elementID:&elementID];
		NSString *page = [renderer pageForHTML:html title:@"Title"];
		[page writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	}];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
	[loaded fulfill];
}

- (WKWebView *)webView {
	WKWebView *web = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 700, 800) configuration:[WKWebViewConfiguration new]];
	web.navigationDelegate = self;
	return web;
}

- (void)load:(NSString *)page into:(WKWebView *)web {
	loaded = [self expectationWithDescription:@"page loaded"];
	[web loadHTMLString:page baseURL:nil];
	[self waitForExpectations:@[loaded] timeout:30];
	//laid out, as the reader would see it
	XCTestExpectation *laidOut = [self expectationWithDescription:@"laid out"];
	[web evaluateJavaScript:@"document.body.offsetHeight" completionHandler:^(id result, NSError *error) { [laidOut fulfill]; }];
	[self waitForExpectations:@[laidOut] timeout:30];
}

//a new note in the preview: the whole page loaded again
- (void)measureReloadOfLength:(NSUInteger)length {
	NVMarkupRenderer *renderer = [self renderer];
	NSString *page = [renderer pageForHTML:[renderer htmlForText:[NVPerfCorpus contentWithLength:length seed:length]] title:@"Title"];
	WKWebView *web = [self webView];
	//WebKit's first load of a page this size is much slower; leave it out
	[self load:page into:web];
	[self load:@"<html><body></body></html>" into:web];
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(5) block:^{
		[self load:@"<html><body></body></html>" into:web];
		[self startMeasuring];
		[self load:page into:web];
		[self stopMeasuring];
	}];
}

//an edit to the note being previewed: only the content element replaced, as PreviewController does
- (void)measureUpdateInPlaceOfLength:(NSUInteger)length {
	NVMarkupRenderer *renderer = [self renderer];
	NSString *text = [NVPerfCorpus contentWithLength:length seed:length];
	NSString *html = [renderer htmlForText:text];
	WKWebView *web = [self webView];
	[self load:[renderer pageForHTML:html title:@"Title"] into:web];
	__block NSUInteger round = 0;
	[self measureWithMetrics:@[[XCTClockMetric new]] options:ManualOptions(5) block:^{
		NSString *elementID = nil;
		NSString *content = [renderer contentElementHTMLForHTML:[renderer htmlForText:[text stringByAppendingFormat:@"\n\nedit %lu", (unsigned long)++round]] title:@"Title" elementID:&elementID];
		NSString *script = [[PreviewController scriptReplacingContentOfElement:elementID withHTML:content] stringByAppendingString:@"; document.body.offsetHeight"];
		XCTestExpectation *done = [self expectationWithDescription:@"updated"];
		[self startMeasuring];
		[web evaluateJavaScript:script completionHandler:^(id result, NSError *error) { [done fulfill]; }];
		[self waitForExpectations:@[done] timeout:30];
		[self stopMeasuring];
	}];
}

- (void)testPreviewReload10KB { [self measureReloadOfLength:10000]; }
- (void)testPreviewReload100KB { [self measureReloadOfLength:100000]; }
- (void)testPreviewReload1MB { [self measureReloadOfLength:1000000]; }
- (void)testPreviewUpdateInPlace10KB { [self measureUpdateInPlaceOfLength:10000]; }
- (void)testPreviewUpdateInPlace100KB { [self measureUpdateInPlaceOfLength:100000]; }
- (void)testPreviewUpdateInPlace1MB { [self measureUpdateInPlaceOfLength:1000000]; }

//the WebKit content process's memory after showing the 1 MB note and 30 edits to it
- (void)testPreviewWebContentMemory {
	NVMarkupRenderer *renderer = [self renderer];
	NSString *text = [NVPerfCorpus contentWithLength:1000000 seed:9];
	WKWebView *web = [self webView];
	[self load:@"<html><body></body></html>" into:web];
	//test-only: WebKit doesn't publish its content process id
	pid_t pid = [[web valueForKey:@"_webProcessIdentifier"] intValue];
	uint64_t empty = Footprint(pid);
	[self load:[renderer pageForHTML:[renderer htmlForText:text] title:@"Title"] into:web];
	uint64_t shown = Footprint(pid);
	for (NSUInteger i = 0; i < 30; i++) {
		NSString *elementID = nil;
		NSString *content = [renderer contentElementHTMLForHTML:[renderer htmlForText:[text stringByAppendingFormat:@"\nedit %lu", (unsigned long)i]] title:@"Title" elementID:&elementID];
		XCTestExpectation *done = [self expectationWithDescription:@"updated"];
		[web evaluateJavaScript:[PreviewController scriptReplacingContentOfElement:elementID withHTML:content] completionHandler:^(id result, NSError *error) { [done fulfill]; }];
		[self waitForExpectations:@[done] timeout:30];
	}
	uint64_t edited = Footprint(pid);
	Report(@"PerformanceTestsPreview.testPreviewWebContentMemory", @"webContentEmpty", empty / 1048576.0, @"MB");
	Report(@"PerformanceTestsPreview.testPreviewWebContentMemory", @"webContentShowing1MBNote", shown / 1048576.0, @"MB");
	Report(@"PerformanceTestsPreview.testPreviewWebContentMemory", @"webContentAfter30Edits", edited / 1048576.0, @"MB");
}

@end

#pragma mark here.now

//serves count active Sites, 100 to a page as here.now does, answering at once
@interface PerfHereNowTransport : NSObject <NVHereNowPageTransport>
@property(assign) NSUInteger count;
@end
@implementation PerfHereNowTransport
- (void)getPath:(NSString *)path token:(NSString *)token completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
	NSUInteger page = 0;
	NSRange cursor = [path rangeOfString:@"&cursor="];
	if (cursor.location != NSNotFound) page = (NSUInteger)[[path substringFromIndex:NSMaxRange(cursor)] integerValue];
	NSMutableArray *rows = [NSMutableArray array];
	for (NSUInteger i = page * 100; i < MIN(self.count, (page + 1) * 100); i++) {
		[rows addObject:@{ @"slug": [NSString stringWithFormat:@"site-%lu", (unsigned long)i],
						   @"displayName": [NSString stringWithFormat:@"Site number %lu", (unsigned long)i],
						   @"status": @"active", @"ownership": @"owned",
						   @"siteUrl": [NSString stringWithFormat:@"https://site-%lu.here.now/", (unsigned long)i],
						   @"contentUpdatedAt": @"2026-09-01T12:00:00.000Z", @"updatedAt": @"2026-09-02T12:00:00.000Z" }];
	}
	BOOL more = (page + 1) * 100 < self.count;
	NSDictionary *body = @{ @"publishes": rows, @"nextCursor": more ? [NSString stringWithFormat:@"%lu", (unsigned long)page + 1] : [NSNull null] };
	NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://here.now/api/v1/publishes"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
	completion([NSJSONSerialization dataWithJSONObject:body options:0 error:NULL], response, nil);
}
@end

@interface PerformanceTestsHereNow : NVTestCase
@end

@implementation PerformanceTestsHereNow

//a full refresh: every page fetched (instantly here), parsed on the main thread, and the cache written
- (void)measureRefreshOfSites:(NSUInteger)count {
	PerfHereNowTransport *transport = [PerfHereNowTransport new];
	transport.count = count;
	NSURL *cache = [NSURL fileURLWithPath:[self.temporaryDirectory stringByAppendingPathComponent:@"sites.json"]];
	NVHereNowSites *sites = [[NVHereNowSites alloc] initWithTransport:transport cacheURL:cache];
	[sites setValue:@"perf-account" forKey:@"accountID"];
	[self measureWithMetrics:@[[XCTClockMetric new], [XCTCPUMetric new]] options:ManualOptions(5) block:^{
		XCTestExpectation *done = [self expectationWithDescription:@"refreshed"];
		[self startMeasuring];
		[sites refreshWithToken:@"perf-token" completion:^(NSError *error) { [done fulfill]; }];
		[self waitForExpectations:@[done] timeout:60];
		[self stopMeasuring];
	}];
	XCTAssertEqual(sites.sites.count, count);
}

- (void)testHereNowRefresh100Sites { [self measureRefreshOfSites:100]; }
- (void)testHereNowRefresh1000Sites { [self measureRefreshOfSites:1000]; }
- (void)testHereNowRefresh5000Sites { [self measureRefreshOfSites:5000]; }

@end

#pragma mark Corpus stores for the UI performance tests

//Writes Notes-<size>.sqlite for each corpus size into the folder in TEST_RUNNER_NV_PERF_EXPORT_DIR, for
//NotationalUIPerformanceTests (see .github/workflows/perf.yml). Skipped without it.
@interface PerformanceTestsCorpusExport : XCTestCase
@end

@implementation PerformanceTestsCorpusExport

- (void)testExportCorpusStores {
	NSString *folder = [[[NSProcessInfo processInfo] environment] objectForKey:@"NV_PERF_EXPORT_DIR"];
	if (![folder length]) XCTSkip(@"set TEST_RUNNER_NV_PERF_EXPORT_DIR to the folder for the stores");
	[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
	for (NSNumber *size in @[@2500, @10000, @25000]) {
		NSString *path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"Notes-%@.sqlite", size]];
		[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
		NVNotesStore *made = [NVPerfCorpus storeAtPath:path count:[size unsignedIntegerValue] seed:CorpusSeed];
		XCTAssertNotNil(made);
		//one file, with no WAL beside it, so it can be copied as is
		XCTAssertTrue([made closeReturningError:NULL]);
	}
}

@end
