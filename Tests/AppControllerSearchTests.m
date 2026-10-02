//
//  AppControllerSearchTests.m
//  -searchForString: (URL scheme, Services, AppleScript, bookmarks, the saved search at
//  launch) shows the string in the search field and filters the list by it, whether or
//  not the field can be focused (#24).
//

#import <XCTest/XCTest.h>
#import "AppController.h"
#import "NotationController.h"
#import "NoteObject.h"
#import "DualField.h"

@interface AppControllerSearchTests : XCTestCase {
	AppController *app;
	NotationController *notation;
	DualField *field;
}
@end

@implementation AppControllerSearchTests

//the app controller isn't initialized or loaded from its nib, only given the outlets search uses;
//kept alive for the run, since its -dealloc expects a launched app
static NSMutableArray *KeptControllers;

- (void)setUp {
	[super setUp];
	notation = [[NotationController alloc] init];
	NSMutableArray *notes = [NSMutableArray array];
	for (NSString *title in @[@"Groceries", @"Garden plan", @"Taxes"]) {
		NSAttributedString *body = [[NSAttributedString alloc] initWithString:@"body"];
		[notes addObject:[[NoteObject alloc] initWithNoteBody:body title:title delegate:notation labels:nil]];
	}
	[notation addNotes:notes];

	field = [[DualField alloc] initWithFrame:NSMakeRect(0, 0, 200, 22)];
	app = [AppController alloc];
	if (!KeptControllers) KeptControllers = [NSMutableArray array];
	[KeptControllers addObject:app];
	[app setValue:field forKey:@"field"];
	[app setValue:notation forKey:@"notationController"];
}

- (void)tearDown {
	[NSObject cancelPreviousPerformRequestsWithTarget:notation];
	[super tearDown];
}

- (NSUInteger)listedNotes {
	return [[notation notesListDataSource] count];
}

- (void)testWithoutAFocusableFieldTheFieldAndListAgree {
	//no window: the field can't be edited, so there is no field editor
	[app searchForString:@"gar"];
	XCTAssertEqualObjects([field stringValue], @"gar");
	XCTAssertEqual([self listedNotes], (NSUInteger)1);
}

- (void)testAFocusedFieldIsTypedIntoLeavingTheCaretAtTheEnd {
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 100) styleMask:NSWindowStyleMaskTitled
													 backing:NSBackingStoreBuffered defer:NO];
	[window setReleasedWhenClosed:NO];
	[[window contentView] addSubview:field];
	[field setDelegate:(id<NSTextFieldDelegate>)app];
	[app setValue:window forKey:@"window"];

	[app searchForString:@"gar"];
	NSTextView *editor = (NSTextView *)[field currentEditor];
	XCTAssertNotNil(editor);
	XCTAssertEqualObjects([editor string], @"gar");
	XCTAssertTrue(NSEqualRanges([editor selectedRange], NSMakeRange(3, 0)), @"%@", NSStringFromRange([editor selectedRange]));
	XCTAssertEqual([self listedNotes], (NSUInteger)1);

	[window makeFirstResponder:nil];
	XCTAssertEqualObjects([field stringValue], @"gar");
	[window close];
}

@end
