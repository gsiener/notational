// Characterizes issue #39 through the selected editor, without launching the app UI.
#import <XCTest/XCTest.h>
#import "AppController.h"
#import "LinkingEditor.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"
#import "GlobalPrefs.h"

@interface AppControllerRemoteUndoTests : XCTestCase
@end

@implementation AppControllerRemoteUndoTests

- (void)testSelectedEditorLosesLocalUndoWhenRemoteBodyArrives {
	NSDictionary *original = @{ @"content": @"Title\none\ntwo", @"tags": @[] };
	NVNoteRecord *first = [NVNoteRecord recordWithNoteID:@"undo-repro" serverData:original version:1];
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:first delegate:nil];
	LinkingEditor *editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	[editor setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	[editor setString:[[note contentString] string]];
	[editor setSelectedRange:NSMakeRange(3, 0)];
	AppController *app = [AppController alloc];
	[app setValue:note forKey:@"currentNote"];
	[app setValue:editor forKey:@"textView"];
	[editor setDelegate:app];

	// A text-system edit is registered with the selected Note's undo manager.
	NSUndoManager *undo = [note undoManager];
	[undo beginUndoGrouping];
	[editor insertText:@" local" replacementRange:NSMakeRange(3, 0)];
	[undo endUndoGrouping];
	XCTAssertTrue([undo canUndo]);
	XCTAssertEqualObjects([editor string], @"one local\ntwo");

	NSDictionary *updated = @{ @"content": @"Title\none local\nTWO", @"tags": @[] };
	NVNoteRecord *second = [NVNoteRecord recordWithNoteID:@"undo-repro" serverData:updated version:2];
	XCTAssertTrue([note applyNoteRecord:second]);
	[app contentsUpdatedForNote:note];
	XCTAssertEqualObjects([editor string], @"one local\nTWO");
	XCTAssertEqualObjects([[note contentString] string], [editor string]);
	XCTAssertFalse([undo canUndo], @"Known issue #39: applying the record removes the local edit's Undo action");
}

@end
