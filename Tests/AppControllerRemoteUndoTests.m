// Selected-editor remote merge, Undo, and Redo. No app window is launched.
#import <XCTest/XCTest.h>
#import "AppController.h"
#import "LinkingEditor.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"
#import "GlobalPrefs.h"

@interface RemoteUndoNoteDelegate : NSObject <NVNoteDelegate>
@property (nonatomic) NSUInteger writes;
@property (nonatomic, strong) NSMutableArray *changedAttributes;
@end
@implementation RemoteUndoNoteDelegate
- (instancetype)init { if ((self = [super init])) _changedAttributes = [NSMutableArray array]; return self; }
- (void)note:(NoteObject *)note attributeChanged:(NSString *)attribute { [_changedAttributes addObject:attribute]; }
- (void)note:(NoteObject *)note didAddLabelSet:(NSSet *)labels {}
- (void)note:(NoteObject *)note didRemoveLabelSet:(NSSet *)labels {}
- (void)scheduleWriteForNote:(NoteObject *)note { self.writes++; }
- (void)noteContentsDidChange:(NoteObject *)note {}
- (float)titleColumnWidth { return 300; }
- (NSImage *)labelImageForWord:(NSString *)word highlighted:(BOOL)highlighted { return nil; }
@end

@interface AppControllerRemoteUndoTests : XCTestCase
@end

@implementation AppControllerRemoteUndoTests

//AppController's dealloc expects a launched app, as in AppControllerSearchTests.
static NSMutableArray *KeptControllers;

- (NVNoteRecord *)record:(NSString *)content tags:(NSArray *)tags version:(NSInteger)version {
	return [NVNoteRecord recordWithNoteID:@"undo-repro"
						 serverData:@{ @"content": content, @"tags": tags }
							version:version];
}

- (void)prepareNote:(NoteObject **)noteOut editor:(LinkingEditor **)editorOut
			  app:(AppController **)appOut delegate:(RemoteUndoNoteDelegate **)delegateOut {
	RemoteUndoNoteDelegate *delegate = [[RemoteUndoNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:[self record:@"Title\none\ntwo" tags:@[] version:1]
											 delegate:delegate];
	LinkingEditor *editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	[editor setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	[editor setAllowsUndo:YES];
	[[note undoManager] setGroupsByEvent:NO]; //the headless test supplies explicit event groups
	[editor setString:[[note contentString] string]];
	AppController *app = [AppController alloc];
	if (!KeptControllers) KeptControllers = [NSMutableArray array];
	[KeptControllers addObject:app];
	[app setValue:note forKey:@"currentNote"];
	[app setValue:editor forKey:@"textView"];
	[editor setDelegate:app];
	*noteOut = note; *editorOut = editor; *appOut = app; *delegateOut = delegate;
}

- (void)typeLocalEditIn:(LinkingEditor *)editor note:(NoteObject *)note {
	NSUndoManager *undo = [note undoManager];
	[undo beginUndoGrouping];
	[editor insertText:@" local" replacementRange:NSMakeRange(3, 0)];
	[undo endUndoGrouping];
	XCTAssertEqualObjects([editor string], @"one local\ntwo");
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
	XCTAssertTrue([undo canUndo]);
}

- (void)testRemoteEditAfterLocalEditSurvivesUndoAndRedo {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	NSUInteger writesBeforeRemote = delegate.writes;
	[editor setSelectedRange:NSMakeRange(4, 0)];
	XCTAssertTrue([note applyNoteRecord:[self record:@"Remote title\none local\nTWO" tags:@[@"urgent"] version:2]]);
	[app contentsUpdatedForNote:note];
	XCTAssertEqualObjects([editor string], @"one local\nTWO");
	XCTAssertEqual(delegate.writes, writesBeforeRemote, @"remote application must not echo as a local write");
	XCTAssertEqualObjects(labelsOfNote(note), @"urgent");
	XCTAssertEqualObjects(titleOfNote(note), @"Remote title");
	XCTAssertTrue([delegate.changedAttributes containsObject:NoteTitleColumnString]);
	XCTAssertTrue([delegate.changedAttributes containsObject:NoteLabelsColumnString]);
	XCTAssertTrue([delegate.changedAttributes containsObject:NotePreviewString]);
	NoteFilterContext context = {(char *)"two", NO};
	XCTAssertTrue(noteContainsUTF8String(note, &context), @"remote body must refresh the search cache");
	XCTAssertTrue(NSEqualRanges([editor selectedRange], NSMakeRange(4, 0)));
	NSUndoManager *undo = [note undoManager];
	XCTAssertTrue([undo canUndo]);
	[undo undo];
	XCTAssertEqualObjects([editor string], @"one\nTWO");
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
	XCTAssertTrue(NSEqualRanges([editor selectedRange], NSMakeRange(3, 0)));
	XCTAssertTrue([undo canRedo]);
	[undo redo];
	XCTAssertEqualObjects([editor string], @"one local\nTWO");
	XCTAssertEqualObjects(titleOfNote(note), @"Remote title", @"body Undo must keep the remote title");
}

- (void)testSecondRemoteUpdateAfterUndoKeepsEarlierRemoteText {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	[note applyNoteRecord:[self record:@"Title\none local\nTWO" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	[[note undoManager] undo];
	XCTAssertEqualObjects([editor string], @"one\nTWO");
	NSUInteger writesBeforeRemote = delegate.writes;
	[note applyNoteRecord:[self record:@"Title\nremote\none\nTWO" tags:@[] version:3]];
	[app contentsUpdatedForNote:note];
	XCTAssertEqual(delegate.writes, writesBeforeRemote);
	XCTAssertEqualObjects([editor string], @"remote\none\nTWO");
	XCTAssertFalse([[note undoManager] canRedo], @"a new remote version invalidates the old Redo branch");
}

- (void)testMultipleLocalEditsRemainSeparateUndoSteps {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	NSUndoManager *undo = [note undoManager];
	[undo beginUndoGrouping];
	[editor insertText:@"!" replacementRange:NSMakeRange(9, 0)];
	[undo endUndoGrouping];
	XCTAssertEqualObjects([editor string], @"one local!\ntwo");
	[note applyNoteRecord:[self record:@"Title\none local!\nTWO" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	[undo undo];
	XCTAssertEqualObjects([editor string], @"one local\nTWO");
	[undo undo];
	XCTAssertEqualObjects([editor string], @"one\nTWO");
	[undo redo];
	XCTAssertEqualObjects([editor string], @"one local\nTWO");
	[undo redo];
	XCTAssertEqualObjects([editor string], @"one local!\nTWO");
}

- (void)testGroupedTypingUndoBeforeRemoteRebasesAsOneStep {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	NSUndoManager *undo = [note undoManager];
	[undo beginUndoGrouping];
	[editor insertText:@" local" replacementRange:NSMakeRange(3, 0)];
	[editor insertText:@"!" replacementRange:NSMakeRange(9, 0)];
	[undo endUndoGrouping];
	XCTAssertEqualObjects([editor string], @"one local!\ntwo");
	[undo undo];
	XCTAssertEqualObjects([editor string], @"one\ntwo");
	[undo redo];
	XCTAssertEqualObjects([editor string], @"one local!\ntwo");
	[note applyNoteRecord:[self record:@"Title\none local!\nTWO" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	[undo undo];
	XCTAssertEqualObjects([editor string], @"one\nTWO");
	XCTAssertFalse([undo canUndo], @"the two typing changes were one Cocoa Undo group");
}

- (void)testRebasedUndoSurvivesSwitchingAwayAndBack {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	[note applyNoteRecord:[self record:@"Title\none local\nTWO" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	NoteObject *other = [[NoteObject alloc] initWithNoteRecord:[NVNoteRecord recordWithNoteID:@"other"
							serverData:@{ @"content": @"Other\nbody", @"tags": @[] } version:1]
											 delegate:delegate];
	[app _setCurrentNote:other];
	[editor setDelegate:nil];
	[editor setString:[[other contentString] string]];
	[app _setCurrentNote:note];
	[editor setString:[[note contentString] string]];
	[editor setDelegate:app];
	[[note undoManager] undo];
	XCTAssertEqualObjects([editor string], @"one\nTWO");
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
}

- (void)testLocalEditAfterRebasedUndoKeepsRemoteText {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	[note applyNoteRecord:[self record:@"Title\none local\nTWO" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	NSUndoManager *undo = [note undoManager];
	[undo undo];
	[undo beginUndoGrouping];
	[editor insertText:@" new" replacementRange:NSMakeRange(3, 0)];
	[undo endUndoGrouping];
	XCTAssertEqualObjects([editor string], @"one new\nTWO");
	[undo undo];
	XCTAssertEqualObjects([editor string], @"one\nTWO");
}

- (void)testPruningAfterRemoteKeepsRemainingUndoTargetsAligned {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	[note applyNoteRecord:[self record:@"Title\none local\nTWO" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	NSUndoManager *undo = [note undoManager];
	for (NSUInteger i = 0; i < 40; i++) {
		[undo beginUndoGrouping];
		[editor insertText:@"x" replacementRange:NSMakeRange(9 + i, 0)];
		[undo endUndoGrouping];
	}
	for (NSUInteger i = 0; i < 32; i++) [undo undo];
	XCTAssertEqualObjects([editor string], @"one localxxxxxxxx\nTWO");
	XCTAssertFalse([undo canUndo]);
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
}

- (void)testRemoteInsertionBeforeLocalEditShiftsUndoSafely {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	[editor setSelectedRange:NSMakeRange(10, 0)];
	[note applyNoteRecord:[self record:@"Title\nremote\none local\ntwo" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	XCTAssertEqualObjects([editor string], @"remote\none local\ntwo");
	XCTAssertTrue(NSEqualRanges([editor selectedRange], NSMakeRange(17, 0)));
	[[note undoManager] undo];
	XCTAssertEqualObjects([editor string], @"remote\none\ntwo");
	XCTAssertTrue(NSMaxRange([editor selectedRange]) <= [[editor string] length]);
}

- (void)testOverlappingRemoteLineWinsWhenLocalEditIsUndone {
	NoteObject *note; LinkingEditor *editor; AppController *app; RemoteUndoNoteDelegate *delegate;
	[self prepareNote:&note editor:&editor app:&app delegate:&delegate];
	[self typeLocalEditIn:editor note:note];
	[note applyNoteRecord:[self record:@"Title\none REMOTE\ntwo" tags:@[] version:2]];
	[app contentsUpdatedForNote:note];
	XCTAssertEqualObjects([editor string], @"one REMOTE\ntwo");
	[[note undoManager] undo];
	XCTAssertEqualObjects([editor string], @"one REMOTE\ntwo");
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
	[[note undoManager] redo];
	XCTAssertEqualObjects([editor string], @"one REMOTE\ntwo");
}

@end
