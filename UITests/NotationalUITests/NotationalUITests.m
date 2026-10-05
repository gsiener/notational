//
//  NotationalUITests.m
//  UI smoke tests (#31): launch the real app in a throwaway home folder and walk the main
//  flows, so crashes that only happen at runtime (nib loading, ARC, AppKit) fail CI.
//

#import <XCTest/XCTest.h>
#import <sqlite3.h>

@interface NotationalUITests : XCTestCase {
	XCUIApplication *app;
	NSString *home;
}
@end

@implementation NotationalUITests

- (void)setUp {
	[super setUp];
	self.continueAfterFailure = NO;

	NSString *appPath = [[[NSProcessInfo processInfo] environment] objectForKey:@"NOTATIONAL_APP"];
	if (![appPath length]) {
		XCTFail(@"set TEST_RUNNER_NOTATIONAL_APP to the built Notational.app");
		return;
	}
	home = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
	[self seedStore];

	app = [[XCUIApplication alloc] initWithURL:[NSURL fileURLWithPath:appPath]];
	//store, caches and the old-database lookup all resolve inside the throwaway home
	app.launchEnvironment = @{@"CFFIXED_USER_HOME": home};
	//a normal app with a menu bar, whatever the machine's saved preferences say
	//closing the main window would otherwise quit the app (the default)
	app.launchArguments = @[@"-ShowDockIcon", @"YES", @"-StatusBarItem", @"NO", @"-ConfirmNoteDeletion", @"NO",
							 @"-QuitWhenClosingMainWindow", @"NO"];
	[app launch];
	XCTAssertTrue([app.windows[@"Notational"] waitForExistenceWithTimeout:20], @"main window never appeared");
	XCTAssertFalse(app.windows[@"Simplenote Account"].exists, @"local-only launch opened the account window");
	//an unreadable store is moved aside and the app starts empty, so check the seeded notes are listed
	XCTAssertTrue([[self rowTitled:[[[self class] seedNotes] lastObject][0]] waitForExistenceWithTimeout:10], @"the seeded notes aren't listed");
}

//Notes the flows start from. Typing them with XCUITest takes seconds per note on CI, so they go
//straight into the store the app opens (the same schema as NVNotesStore, a local-only store).
+ (NSArray *)seedNotes {
	return @[
		@[@"Preview note", @"# Heading\n\n- one\n- two\n\nA [link](https://example.com)."],
		@[@"Layout note", @"some words to count"],
		@[@"Divider note", @"the divider is dragged"],
		@[@"Collapse note", @"the list is collapsed"],
	];
}

- (void)seedStore {
	NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/Notational"];
	[[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL];
	sqlite3 *db = NULL;
	XCTAssertEqual(sqlite3_open([[support stringByAppendingPathComponent:@"Notes.sqlite"] fileSystemRepresentation], &db), SQLITE_OK);
	const char *schema =
		"CREATE TABLE notes (id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, tags TEXT NOT NULL, deleted INTEGER NOT NULL, "
		"created REAL NOT NULL, modified REAL NOT NULL, server_data TEXT NOT NULL, "
		"confirmed_version INTEGER NOT NULL, pending INTEGER NOT NULL, revision INTEGER NOT NULL);"
		"CREATE INDEX notes_pending ON notes (pending) WHERE pending != 0;"
		"CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT);"
		"PRAGMA user_version = 1;";
	XCTAssertEqual(sqlite3_exec(db, schema, NULL, NULL, NULL), SQLITE_OK, @"%s", sqlite3_errmsg(db));
	sqlite3_stmt *insert = NULL;
	XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO notes VALUES (?, ?, '[]', 0, ?, ?, '{}', 0, 0, 0)", -1, &insert, NULL), SQLITE_OK);
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	NSArray *notes = [[self class] seedNotes];
	for (NSUInteger i = 0; i < [notes count]; i++) {
		NSString *content = [NSString stringWithFormat:@"%@\n\n%@", notes[i][0], notes[i][1]];
		sqlite3_bind_text(insert, 1, [[[NSUUID UUID] UUIDString] UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_text(insert, 2, [content UTF8String], -1, SQLITE_TRANSIENT);
		sqlite3_bind_double(insert, 3, now - 100 - i);
		sqlite3_bind_double(insert, 4, now - 100 - i);
		XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE);
		sqlite3_reset(insert);
	}
	sqlite3_finalize(insert);
	sqlite3_close(db);
}

- (void)tearDown {
	[app terminate];
	[[NSFileManager defaultManager] removeItemAtPath:home error:NULL];
	[super tearDown];
}

//Close the account window after an explicit request.
- (void)dismissAccountWindow {
	XCUIElement *account = app.windows[@"Simplenote Account"];
	if ([account waitForExistenceWithTimeout:2]) {
		[account.buttons[XCUIIdentifierCloseWindow] click];
		[self waitForGone:account];
	}
	XCTAssertFalse(account.exists, @"account window didn't close");
}

- (BOOL)waitForGone:(XCUIElement *)element {
	NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO"];
	XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:gone object:element];
	return [XCTWaiter waitForExpectations:@[expectation] timeout:10] == XCTWaiterResultCompleted;
}

- (void)choose:(NSString *)item inMenu:(NSString *)menu {
	XCUIElement *bar = app.menuBars.firstMatch;
	[bar.menuBarItems[menu] click];
	XCUIElement *menuItem = bar.menuBarItems[menu].menus.menuItems[item];
	if (![menuItem waitForExistenceWithTimeout:5]) {
		NSArray *titles = [bar.menuBarItems[menu].menus.menuItems.allElementsBoundByIndex valueForKey:@"title"];
		XCTFail(@"no %@ ▸ %@; the menu has: %@", menu, item, [titles componentsJoinedByString:@" | "]);
	}
	[menuItem click];
}

//the item reads Collapse or Expand depending on the list's state
- (void)toggleNotesList {
	XCUIElement *bar = app.menuBars.firstMatch;
	[bar.menuBarItems[@"View"] click];
	XCUIElementQuery *items = bar.menuBarItems[@"View"].menus.menuItems;
	XCUIElement *item = items[@"Collapse Notes List"].exists ? items[@"Collapse Notes List"] : items[@"Expand Notes List"];
	XCTAssertTrue(item.exists, @"no Collapse/Expand Notes List item");
	[item click];
}

- (XCUIElement *)mainWindow { return app.windows[@"Notational"]; }

- (void)assertStillRunning {
	XCTAssertEqual(app.state, XCUIApplicationStateRunningForeground, @"Notational quit or crashed");
}

- (void)createNoteTitled:(NSString *)title body:(NSString *)body {
	XCUIElement *window = [self mainWindow];
	[window typeKey:@"l" modifierFlags:XCUIKeyModifierCommand];
	[window typeText:title];
	[window typeKey:XCUIKeyboardKeyReturn modifierFlags:0];
	[window typeText:body];
}

- (XCUIElement *)rowTitled:(NSString *)title {
	NSPredicate *match = [NSPredicate predicateWithFormat:@"value CONTAINS %@ OR label CONTAINS %@ OR title CONTAINS %@", title, title, title];
	return [[[self mainWindow].tables.firstMatch descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:match].firstMatch;
}

//selects a seeded note, the way clicking it in the list does
- (void)openNoteTitled:(NSString *)title {
	XCUIElement *row = [self rowTitled:title];
	XCTAssertTrue([row waitForExistenceWithTimeout:5], @"no note titled %@", title);
	[row click];
}

#pragma mark Flows

//the only flow that still types: creating a note, finding it again and deleting it
- (void)testCreateSearchRelaunchAndDeleteANote {
	[self createNoteTitled:@"UI test note" body:@"written by the UI smoke test"];
	XCTAssertTrue([[self rowTitled:@"UI test note"] waitForExistenceWithTimeout:5], @"new note isn't in the list");

	//the note survives a relaunch
	[self relaunch];
	XCTAssertTrue([[self rowTitled:@"UI test note"] waitForExistenceWithTimeout:5], @"note was lost across a relaunch");

	//search narrows the list to it
	XCUIElement *window = [self mainWindow];
	[window typeKey:@"l" modifierFlags:XCUIKeyModifierCommand];
	[window typeText:@"UI test"];
	XCTAssertTrue([[self rowTitled:@"UI test note"] waitForExistenceWithTimeout:5]);

	//select it and delete it
	[window typeKey:XCUIKeyboardKeyDownArrow modifierFlags:0];
	[window typeKey:XCUIKeyboardKeyDelete modifierFlags:XCUIKeyModifierCommand];
	XCTAssertTrue([self waitForGone:[self rowTitled:@"UI test note"]], @"deleted note is still listed");
	[self assertStillRunning];
}

//flows that don't need a note, in one launch
- (void)testSignInSettingsAndColorSchemes {
	XCUIElement *signIn = [self mainWindow].buttons[@"Sign In to Simplenote…"];
	XCTAssertTrue([signIn waitForExistenceWithTimeout:5]);
	XCTAssertFalse(app.windows[@"Simplenote Account"].exists);
	[signIn click];
	XCTAssertTrue([app.windows[@"Simplenote Account"] waitForExistenceWithTimeout:5]);
	[self dismissAccountWindow];

	for (int i = 0; i < 3; i++) {
		[self choose:@"Settings…" inMenu:@"Notational"];
		//the Settings window is titled after its current pane
		NSPredicate *notMain = [NSPredicate predicateWithFormat:@"title != 'Notational' AND title != ''"];
		XCUIElement *settings = [app.windows matchingPredicate:notMain].firstMatch;
		XCTAssertTrue([settings waitForExistenceWithTimeout:5], @"Settings didn't open");
		[settings.buttons[XCUIIdentifierCloseWindow] click];
		XCTAssertTrue([self waitForGone:settings], @"Settings didn't close");
	}

	for (NSString *scheme in @[@"Low Contrast", @"User Scheme", @"B/W"]) {
		[app.menuBars.firstMatch.menuBarItems[@"View"] click];
		XCUIElement *schemes = app.menuBars.firstMatch.menuBarItems[@"View"].menus.menuItems[@"Color Schemes"];
		[schemes hover];
		XCUIElement *item = schemes.menus.menuItems[scheme];
		XCTAssertTrue([item waitForExistenceWithTimeout:5], @"no scheme %@", scheme);
		[item click];
	}
	[self assertStillRunning];
}

//the flows that work on one open note: the preview window and the word count
- (void)testPreviewAndWordCount {
	[self openNoteTitled:@"Preview note"];
	[self choose:@"Toggle Preview Window" inMenu:@"Preview"];
	XCUIElement *preview = app.windows[@"Preview note"];
	XCTAssertTrue([preview waitForExistenceWithTimeout:10], @"preview window didn't open");
	//the rendered heading shows up in the web view
	XCTAssertTrue([preview.webViews.firstMatch.staticTexts[@"Heading"] waitForExistenceWithTimeout:10], @"preview didn't render the note");

	[preview.buttons[@"View Source"] click];
	[preview.buttons[@"View Preview"] click];
	[self choose:@"Lock Note to Preview" inMenu:@"Preview"];
	[self choose:@"Lock Note to Preview" inMenu:@"Preview"];
	[self choose:@"Toggle Preview Window" inMenu:@"Preview"];

	[self openNoteTitled:@"Layout note"];
	[self choose:@"Show Word Count" inMenu:@"View"];
	[self choose:@"Show Word Count" inMenu:@"View"];
	[self assertStillRunning];
}

- (void)relaunch {
	[app terminate];
	[app launch];
	XCTAssertTrue([[self mainWindow] waitForExistenceWithTimeout:20], @"main window never reappeared");
	XCTAssertFalse(app.windows[@"Simplenote Account"].exists);
}

//the list's size along the divider's axis: width beside the editor, height above it
- (CGFloat)notesListSizeAcrossDivider:(XCUIElement *)splitter {
	CGRect list = [self mainWindow].tables.firstMatch.frame;
	return splitter.frame.size.width > splitter.frame.size.height ? list.size.height : list.size.width;
}

- (XCUIElement *)splitter {
	XCUIElement *splitter = [[self mainWindow].splitGroups.firstMatch.splitters elementBoundByIndex:0];
	XCTAssertTrue([splitter waitForExistenceWithTimeout:5], @"no divider in the main window");
	return splitter;
}

//drags the divider 80 points, toward whichever side has room, and returns the list's new size
//(preferences outlive a test on the CI runner, so the list may start anywhere)
- (CGFloat)dragDivider {
	XCUIElement *splitter = [self splitter];
	BOOL stacked = splitter.frame.size.width > splitter.frame.size.height;
	CGFloat before = [self notesListSizeAcrossDivider:splitter];
	CGRect group = [self mainWindow].splitGroups.firstMatch.frame;
	CGFloat extent = stacked ? group.size.height : group.size.width;
	CGFloat step = before > extent / 2 ? -80 : 80;
	XCUICoordinate *start = [splitter coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)];
	XCUICoordinate *end = [start coordinateWithOffset:stacked ? CGVectorMake(0, step) : CGVectorMake(step, 0)];
	[start clickForDuration:0.3 thenDragToCoordinate:end];
	CGFloat dragged = [self notesListSizeAcrossDivider:splitter];
	XCTAssertGreaterThan(fabs(dragged - before), 40, @"dragging the divider didn't resize the notes list (%g → %g)", before, dragged);
	return dragged;
}

//switches to the other layout, whichever the app is in
- (void)switchLayout {
	XCUIElement *bar = app.menuBars.firstMatch;
	[bar.menuBarItems[@"View"] click];
	XCUIElementQuery *items = bar.menuBarItems[@"View"].menus.menuItems;
	XCUIElement *item = items[@"Switch to Horizontal Layout"].exists ? items[@"Switch to Horizontal Layout"] : items[@"Switch to Vertical Layout"];
	XCTAssertTrue(item.exists, @"no Switch to … Layout item");
	[item click];
}

- (BOOL)notesListIsExpanded {
	XCUIElement *bar = app.menuBars.firstMatch;
	[bar.menuBarItems[@"View"] click];
	BOOL expanded = bar.menuBarItems[@"View"].menus.menuItems[@"Collapse Notes List"].exists;
	[app typeKey:XCUIKeyboardKeyEscape modifierFlags:0];   //closes the open menu
	return expanded;
}

//runs the check in the current layout, then in the other, and switches back so later tests
//start where they would have; each layout keeps its own divider position (#34)
- (void)inBothLayouts:(void (^)(NSString *layout))check {
	check(@"first layout");
	[self switchLayout];
	check(@"other layout");
	[self switchLayout];
}

- (void)testDividerPositionSurvivesRelaunch {
	[self openNoteTitled:@"Divider note"];
	[self inBothLayouts:^(NSString *layout) {
		CGFloat dragged = [self dragDivider];
		[self relaunch];
		XCTAssertEqualWithAccuracy([self notesListSizeAcrossDivider:[self splitter]], dragged, 2.0,
								   @"%@: the divider moved back after a relaunch", layout);
	}];
}

//a list collapsed at quit comes back expanded, at the size it had: the app opens with no note
//shown, and the empty view always reveals the list (#34)
- (void)testACollapsedListReturnsExpandedAtItsSizeAfterRelaunch {
	[self inBothLayouts:^(NSString *layout) {
		//the list only collapses while a note is open, and none is after a relaunch
		[self openNoteTitled:@"Collapse note"];
		CGFloat dragged = [self dragDivider];
		[self toggleNotesList];
		XCTAssertFalse([self notesListIsExpanded], @"%@: the list didn't collapse", layout);
		[self relaunch];
		XCTAssertTrue([self notesListIsExpanded], @"%@: the list is still collapsed after a relaunch", layout);
		XCTAssertEqualWithAccuracy([self notesListSizeAcrossDivider:[self splitter]], dragged, 2.0,
								   @"%@: the list came back at a different size", layout);
	}];
}

- (void)testExpandingRestoresTheListSize {
	[self openNoteTitled:@"Collapse note"];
	[self inBothLayouts:^(NSString *layout) {
		XCUIElement *splitter = [self splitter];
		CGFloat before = [self notesListSizeAcrossDivider:splitter];
		[self toggleNotesList];
		XCTAssertFalse([self notesListIsExpanded], @"%@: the list didn't collapse", layout);
		[self toggleNotesList];
		XCTAssertEqualWithAccuracy([self notesListSizeAcrossDivider:[self splitter]], before, 2.0,
								   @"%@: expanding didn't restore the list's size", layout);
	}];
}

@end
