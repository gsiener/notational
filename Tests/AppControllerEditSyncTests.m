//
//  AppControllerEditSyncTests.m
//  NotationTests
//
//  Each edit in the editor reaches the note's own copy of its text. Copying the whole note on every
//  keystroke made typing in long notes slow (#65), so only the edited range is copied when that's
//  known; whichever way, the note must end up identical to the editor, attributes included.
//

#import <XCTest/XCTest.h>
#import "AppController.h"
#import "LinkingEditor.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"
#import "GlobalPrefs.h"

@interface EditSyncNoteDelegate : NSObject <NVNoteDelegate>
@end
@implementation EditSyncNoteDelegate
- (void)note:(NoteObject *)note attributeChanged:(NSString *)attribute {}
- (void)note:(NoteObject *)note didAddLabelSet:(NSSet *)labels {}
- (void)note:(NoteObject *)note didRemoveLabelSet:(NSSet *)labels {}
- (void)scheduleWriteForNote:(NoteObject *)note {}
- (void)noteContentsDidChange:(NoteObject *)note {}
- (float)titleColumnWidth { return 300; }
- (NSImage *)labelImageForWord:(NSString *)word highlighted:(BOOL)highlighted { return nil; }
@end

@interface AppControllerEditSyncTests : XCTestCase {
	NoteObject *note;
	LinkingEditor *editor;
}
@end

@implementation AppControllerEditSyncTests

//AppController's dealloc expects a launched app, as in AppControllerSearchTests
static NSMutableArray *Kept;

- (void)setUp {
	[super setUp];
	if (!Kept) Kept = [NSMutableArray array];
	EditSyncNoteDelegate *delegate = [EditSyncNoteDelegate new];
	NVNoteRecord *record = [NVNoteRecord recordWithNoteID:@"edit-sync" serverData:@{ @"content": @"Title\nfirst line\nbuy milk @done\nlast line", @"tags": @[] } version:1];
	note = [[NoteObject alloc] initWithNoteRecord:record delegate:delegate];
	editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	[editor setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	[editor setAllowsUndo:YES];
	[[note undoManager] setGroupsByEvent:NO];
	AppController *app = [AppController alloc];
	[Kept addObjectsFromArray:@[app, delegate]];
	[app setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	[app setValue:editor forKey:@"textView"];
	[app setValue:note forKey:@"currentNote"];
	[editor setDelegate:app];
	[[editor textStorage] setAttributedString:[note contentString]];
}

- (void)type:(NSString *)text at:(NSRange)range {
	[[note undoManager] beginUndoGrouping];
	[editor insertText:text replacementRange:range];
	[[note undoManager] endUndoGrouping];
}

- (void)assertNoteMatchesEditor {
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
	XCTAssertTrue([[note contentString] isEqualToAttributedString:[editor textStorage]], @"attributes differ");
}

- (void)testEditsReachTheNoteExactly {
	[self type:@"x" at:NSMakeRange(5, 0)];
	[self assertNoteMatchesEditor];
	[self type:@"" at:NSMakeRange(0, 3)];                         //a deletion at the start
	[self assertNoteMatchesEditor];
	[self type:@" see https://example.com/page" at:NSMakeRange([[editor string] length], 0)];
	[self assertNoteMatchesEditor];
	XCTAssertNotNil([[note contentString] attribute:NSLinkAttributeName atIndex:[[editor string] length] - 3 effectiveRange:NULL], @"the new link isn't in the note's copy");
	[self type:@"\nwalk dog @done" at:NSMakeRange([[editor string] length], 0)];
	[self assertNoteMatchesEditor];
	[self type:@"Z" at:NSMakeRange(8, 12)];                         //a replacement across lines
	[self assertNoteMatchesEditor];
}

- (void)testUndoAndRedoReachTheNote {
	[self type:@"abc" at:NSMakeRange(2, 0)];
	[[note undoManager] undo];
	[self assertNoteMatchesEditor];
	[[note undoManager] redo];
	[self assertNoteMatchesEditor];
}

@end
