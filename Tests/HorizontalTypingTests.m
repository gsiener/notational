//
//  HorizontalTypingTests.m
//  NotationTests
//
//  Typing into a note with the notes list showing, in each layout (#68). CI's UI test once typed
//  the same text 2-3x slower in the horizontal layout than in the vertical one. That turned out to
//  be the first test of a CI run being slow while the runner warmed up (the layouts swapped places
//  between runs), not the app: a keystroke does the same work in both layouts. This measures what
//  one keystroke costs the main thread in each, with the real list view, its redraw and the run
//  loop's delayed performs, and fails if typing reloads or re-sorts the list.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "NVPerfCorpus.h"
#import "NVNotesStore.h"
#import "NotationController.h"
#import "NoteObject.h"
#import "NoteAttributeColumn.h"
#import "NotesTableView.h"
#import "LinkingEditor.h"
#import "AppController.h"
#import "GlobalPrefs.h"

static int ReloadCount;

//a list that counts how often it reloads
@interface CountingNotesTable : NotesTableView
@end
@implementation CountingNotesTable
- (void)reloadData { ReloadCount++; [super reloadData]; }
@end

static NSMutableArray *KeptObjects;   //AppControllers made without -init: their -dealloc expects a launched app

@interface HorizontalTypingTests : NVTestCase {
	NVNotesStore *store;
	NotationController *controller;
}
@end

@implementation HorizontalTypingTests

- (void)tearDown {
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	[controller closeAllResources];
	[store close];
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"HorizontalLayout"];
	[super tearDown];
}

- (CountingNotesTable *)listInWindow {
	NSTableView *plain = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 600)];
	NSMutableData *data = [NSMutableData data];
	NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
	[archiver setClassName:@"CountingNotesTable" forClass:[NSTableView class]];
	[archiver encodeObject:plain forKey:@"root"];
	[archiver finishEncoding];
	[data setData:[archiver encodedData]];
	NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:NULL];
	[unarchiver setRequiresSecureCoding:NO];
	CountingNotesTable *table = [unarchiver decodeObjectForKey:@"root"];
	XCTAssertTrue([table isKindOfClass:[CountingNotesTable class]]);
	[table restoreColumns];
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 600)];
	[scroll setDocumentView:table];
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 600) styleMask:NSWindowStyleMaskTitled
													 backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[window setContentView:scroll];
	[KeptObjects addObject:window];
	return table;
}

//microseconds the main thread spends per keystroke typing text into a new note
- (NSDictionary *)typeText:(NSString *)text horizontal:(BOOL)horizontal editorWidth:(CGFloat)editorWidth {
	if (!KeptObjects) KeptObjects = [NSMutableArray array];
	GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
	[[NSUserDefaults standardUserDefaults] setBool:horizontal forKey:@"HorizontalLayout"];
	XCTAssertEqual([prefs horizontalLayout], horizontal);
	XCTAssertTrue([prefs tableColumnsShowPreview]);

	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	store = [NVPerfCorpus storeAtPath:path count:30 seed:68];
	controller = [[NotationController alloc] initWithNotesStore:store];
	[controller setSortColumn:nil];
	CountingNotesTable *table = [self listInWindow];
	[controller setSortColumn:[table noteAttributeColumnForIdentifier:NoteDateModifiedColumnString]];
	[controller refilterNotes];
	[controller regeneratePreviewsForColumn:[table noteAttributeColumnForIdentifier:NoteTitleColumnString]
						visibleFilteredRows:NSMakeRange(0, 30) forceUpdate:YES];
	[table setDataSource:[controller notesListDataSource]];

	NSScrollView *editorScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, editorWidth, 800)];
	LinkingEditor *editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, editorWidth, 800)];
	[editor setValue:prefs forKey:@"prefsController"];
	[editor setVerticallyResizable:YES];
	[[editor textContainer] setWidthTracksTextView:YES];
	[editorScroll setDocumentView:editor];
	NSWindow *editorWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, editorWidth, 800) styleMask:NSWindowStyleMaskTitled
														   backing:NSBackingStoreBuffered defer:NO];
	[editorWindow setReleasedWhenClosed:NO];
	[editorWindow setContentView:editorScroll];
	[editorWindow makeFirstResponder:editor];
	[KeptObjects addObject:editorWindow];

	AppController *app = [AppController alloc];
	[KeptObjects addObject:app];
	[app setValue:editor forKey:@"textView"];
	[app setValue:controller forKey:@"notationController"];
	[app setValue:prefs forKey:@"prefsController"];
	[app setValue:table forKey:@"notesTableView"];
	[editor setDelegate:app];
	[editor setAllowsUndo:YES];

	//a new note, as Return in the search field makes one
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@""] title:@"" delegate:controller labels:@""];
	[controller addNewNote:note];
	[table reloadData];
	[[note undoManager] setGroupsByEvent:NO];
	[app setValue:note forKey:@"currentNote"];
	[[editor textStorage] setAttributedString:[note contentString]];
	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:[controller indexInFilteredListForNoteIdenticalTo:note]] byExtendingSelection:NO];
	//from here on, the app hears of changes to the list and notes, as in the running app
	[controller setDelegate:app];
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

	NSRect visible = [table visibleRect];
	ReloadCount = 0;
	double total = 0, typeTotal = 0, flushTotal = 0;
	for (NSUInteger i = 0; i < [text length]; i++) {
		CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
		[[note undoManager] beginUndoGrouping];
		[editor insertText:[text substringWithRange:NSMakeRange(i, 1)] replacementRange:[editor selectedRange]];
		[[note undoManager] endUndoGrouping];
		CFAbsoluteTime typed = CFAbsoluteTimeGetCurrent();
		[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
		CFAbsoluteTime flushed = CFAbsoluteTimeGetCurrent();
		typeTotal += typed - start;
		flushTotal += flushed - typed - 0.002;
		NSBitmapImageRep *bitmap = [table bitmapImageRepForCachingDisplayInRect:visible];
		[table cacheDisplayInRect:visible toBitmapImageRep:bitmap];
		total += CFAbsoluteTimeGetCurrent() - start;
	}
	XCTAssertEqualObjects([[note contentString] string], text);
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	return @{ @"usPerKey": @(total / [text length] * 1e6), @"reloads": @(ReloadCount),
			  @"typeUs": @(typeTotal / [text length] * 1e6), @"flushUs": @(flushTotal / [text length] * 1e6) };
}

- (void)testTypingCostPerKeystrokeInEachLayout {
	NSString *text = @"the list is collapsed when the app quits";
	NSDictionary *vertical = [self typeText:text horizontal:NO editorWidth:340];
	[controller closeAllResources]; [store close];
	NSDictionary *horizontal = [self typeText:text horizontal:YES editorWidth:340];
	//the list isn't reloaded or re-sorted by typing, in either layout; only the note's row is redrawn
	XCTAssertEqual([vertical[@"reloads"] intValue], 0);
	XCTAssertEqual([horizontal[@"reloads"] intValue], 0);
	for (NSString *name in @[@"vertical", @"horizontal"]) {
		NSDictionary *r = [name isEqualToString:@"vertical"] ? vertical : horizontal;
		fprintf(stderr, "NVTYPING %s: %.0f us/key (typing %.0f, delayed performs %.0f), %d reloads\n", [name UTF8String],
				[r[@"usPerKey"] doubleValue], [r[@"typeUs"] doubleValue], [r[@"flushUs"] doubleValue], [r[@"reloads"] intValue]);
	}
}

@end
