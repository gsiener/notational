//
//  LinkingEditorCopyTests.m
//  Notation
//
//  Copy from a note must put the selected text on the clipboard. NSTextView only writes its
//  legacy type names, so the editor writes plain text itself.
//

#import <XCTest/XCTest.h>
#import "LinkingEditor.h"

@interface LinkingEditorCopyTests : XCTestCase {
	NSPasteboard *pasteboard;
	LinkingEditor *editor;
}
@end

@implementation LinkingEditorCopyTests

- (void)setUp {
	//a private pasteboard, so the tests never touch the user's clipboard
	pasteboard = [NSPasteboard pasteboardWithUniqueName];
	editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
	[editor setString:@"Groceries\neggs and milk"];
}

- (void)tearDown {
	[pasteboard releaseGlobally];
}

- (void)testCopyPutsTheSelectedTextOnThePasteboard {
	[editor setSelectedRange:NSMakeRange(10, 4)];
	XCTAssertTrue([editor writeSelectionToPasteboard:pasteboard types:[editor writablePasteboardTypes]]);
	XCTAssertEqualObjects([pasteboard stringForType:NSPasteboardTypeString], @"eggs");
}

- (void)testCopyingStyledTextAlsoWritesRTF {
	[[editor textStorage] addAttribute:NSObliquenessAttributeName value:@0.2 range:NSMakeRange(10, 4)];
	[editor setSelectedRange:NSMakeRange(0, 14)];
	NSArray *types = [editor writablePasteboardTypes];
	XCTAssertTrue([types containsObject:NSPasteboardTypeRTF]);
	XCTAssertTrue([editor writeSelectionToPasteboard:pasteboard types:types]);
	XCTAssertEqualObjects([pasteboard stringForType:NSPasteboardTypeString], @"Groceries\neggs");
	XCTAssertGreaterThan([[pasteboard dataForType:NSPasteboardTypeRTF] length], (NSUInteger)0);
}

- (void)testCopyingSeveralSelectionsJoinsThemByLine {
	[editor setSelectedRanges:@[[NSValue valueWithRange:NSMakeRange(0, 9)], [NSValue valueWithRange:NSMakeRange(19, 4)]]];
	XCTAssertTrue([editor writeSelectionToPasteboard:pasteboard types:[editor writablePasteboardTypes]]);
	XCTAssertEqualObjects([pasteboard stringForType:NSPasteboardTypeString], @"Groceries\nmilk");
}

@end
