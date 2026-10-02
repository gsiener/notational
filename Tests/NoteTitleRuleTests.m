//
//  NoteTitleRuleTests.m
//  NotationTests
//
//  #33: every way a new note comes in splits its content into title and body by one rule,
//  NVNoteContent's (the rule the Notes store's content is read back with): leading blank space
//  skipped; the title is the first line, ending only at a line break; cut at 60 characters, at a
//  space in the last 10; "Untitled Note" when blank. So a note has from the start the title and
//  body it has after a relaunch (-initWithNoteRecord:) and after a Simplenote round trip (an edit
//  made elsewhere coming back through -applyNoteRecord:), and its stored content is the text it
//  was made from, its title line not repeated.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "NVTestSupport.h"
#import "AppController.h"
#import "AppController_Importing.h"
#import "NotationController.h"
#import "NVNotesStore.h"
#import "NVSyncEngine.h"
#import "NVNoteRecord.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteContent.h"
#import "NVFakeSimplenoteService.h"
#import "GlobalPrefs.h"
#import "DualField.h"
#import "AttributedPlainText.h"
#import "NSString_NV.h"

@interface NotationController (TitleRuleTestAccess)
- (NSArray *)allNotesForTitleRuleTesting;
@end
@implementation NotationController (TitleRuleTestAccess)
- (NSArray *)allNotesForTitleRuleTesting { return allNotes; }
@end

//the inputs from #33
static NSString *const ShortLine = @"Groceries\neggs\nmilk";
static NSString *const Line50 = @"Meeting notes for the quarterly planning review ok\nbody";
static NSString *const Long50 = @"Meeting notes for the quarterly planning review ok";
static NSString *const Line100 = @"Notes from the long planning meeting about the new office layout and the budget for next year, part2\nbody";
static NSString *const Long100 = @"Notes from the long planning meeting about the new office layout and the budget for next year, part2";
static NSString *const TabLine = @"Name\tValue\nbody";
static NSString *const LeadingBlanks = @"\n\n  Indented title\nbody";
static NSString *const EmptyFirstLine = @"\nGroceries\neggs";

//Long100 cut at the last space before 60 characters, and the rest of it
static NSString *const Cut100 = @"Notes from the long planning meeting about the new office";
static NSString *const Rest100 = @"layout and the budget for next year, part2";

//longer than the titles of the inputs but Line50's and Line100's, so import titles those notes with it
static NSString *const LongFileName = @"A file name longer than any first line here";

//the app controller is never initialized or loaded from its nib, only given the outlets the
//code under test uses; kept alive for the run, since its -dealloc expects a launched app
static NSMutableArray *KeptControllers;

@interface NoteTitleRuleTests : NVTestCase {
	NVFakeSimplenoteService *server;
	NVNotesStore *store;
	NVSyncEngine *engine;
	NotationController *controller;
}
@end

@implementation NoteTitleRuleTests

- (void)setUp {
	[super setUp];
	XCTAssertEqual([Long50 length], (NSUInteger)50);
	XCTAssertEqual([Long100 length], (NSUInteger)100);
	server = [[NVFakeSimplenoteService alloc] init];
	store = [NVNotesStore storeAtPath:[self.temporaryDirectory stringByAppendingPathComponent:@"Notes.sqlite"] error:NULL];
	engine = [[NVSyncEngine alloc] initWithStore:store service:server];
	controller = [[NotationController alloc] initWithNotesStore:store];
	[controller setSyncEngine:engine];
}

- (void)tearDown {
	[controller closeAllResources];
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	[controller setSyncEngine:nil];
	[store close];
	[super tearDown];
}

//one note per library: a fresh store, server and controller
- (void)startOver {
	[self tearDown];
	[self setUp];
}

#pragma mark The ways in

- (AppController *)app {
	AppController *app = [AppController alloc];
	if (!KeptControllers) KeptControllers = [NSMutableArray array];
	[KeptControllers addObject:app];
	[app setValue:controller forKey:@"notationController"];
	[app setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	return app;
}

- (NoteObject *)noteAddedBy:(void (^)(void))block {
	NSArray *before = [[controller allNotesForTitleRuleTesting] copy];
	block();
	for (NoteObject *note in [controller allNotesForTitleRuleTesting])
		if (![before containsObject:note]) return note;
	XCTFail(@"no note was added");
	return nil;
}

//Paste, Services, and nv://make without a title: -[AppController addNotesFromPasteboard:] with plain text
- (NoteObject *)pasted:(NSString *)text {
	return [self pasted:text fromURL:nil];
}

//the URL as a browser puts it on the pasteboard alongside the text it was copied from
- (NoteObject *)pasted:(NSString *)text fromURL:(NSString *)url {
	NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
	NSString *urlType = [NSString customPasteboardTypeOfCode:0x4D5A0003];
	[pasteboard declareTypes:url ? @[urlType, NSPasteboardTypeString] : @[NSPasteboardTypeString] owner:nil];
	if (url) [pasteboard setString:[url stringByAppendingString:@"\nPage title"] forType:urlType];
	[pasteboard setString:text forType:NSPasteboardTypeString];
	AppController *app = [self app];
	NoteObject *note = [self noteAddedBy:^{ XCTAssertTrue([app addNotesFromPasteboard:pasteboard]); }];
	[pasteboard releaseGlobally];
	return note;
}

//File import (Import…, opening or dropping a file, pasting a file): -[NotationController openFiles:]
- (NoteObject *)imported:(NSString *)text fileName:(NSString *)name {
	NSString *path = [[self.temporaryDirectory stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"txt"];
	XCTAssertTrue([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
	NotationController *notation = controller;
	return [self noteAddedBy:^{ XCTAssertTrue([notation openFiles:@[path]]); }];
}

//Typing a name in the search field and pressing Return: -[AppController createNoteIfNecessary]
- (NoteObject *)typed:(NSString *)searchString {
	AppController *app = [self app];
	DualField *field = [[DualField alloc] initWithFrame:NSMakeRect(0, 0, 200, 22)];
	[field setStringValue:searchString];
	[app setValue:field forKey:@"field"];
	[app setValue:[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)] forKey:@"textView"];
	return [self noteAddedBy:^{ [app createNoteIfNecessary]; }];
}

//Stickies import builds its note this way (-[AlienNoteImporter _importStickies:]); a Stickies
//database can't be written here, so these are its steps after decoding a sticky's RTFD
- (NoteObject *)fromStickies:(NSString *)text {
	NSMutableAttributedString *string = [[NSMutableAttributedString alloc] initWithString:text];
	[string removeAttachments];
	[string santizeForeignStylesForImporting];
	NVNoteContent *content = [string trimLeadingTitle];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:string content:content delegate:nil labels:nil];
	NotationController *notation = controller;
	return [self noteAddedBy:^{ [notation addNotes:@[note]]; }];
}

#pragma mark The round trip

//The note as made, its stored content, the note read back from the store, and the note after an
//edit elsewhere appends a line on Simplenote and comes back through -applyNoteRecord:. The title
//and body are the same throughout, and the title line is stored once.
- (void)assertNote:(NoteObject *)note title:(NSString *)title body:(NSString *)body stored:(NSString *)stored {
	XCTAssertEqualObjects(titleOfNote(note), title, @"title as made");
	XCTAssertEqualObjects([[note contentString] string], body, @"body as made");

	//adding a note saves it to the store at once
	NVNoteRecord *record = [store noteWithID:[note noteRecordID]];
	XCTAssertEqualObjects([record content], stored, @"stored content");
	XCTAssertEqual([[[record content] componentsSeparatedByString:title] count], (NSUInteger)2, @"the title is stored once");

	//relaunch
	NoteObject *reloaded = [[NoteObject alloc] initWithNoteRecord:record delegate:nil];
	XCTAssertEqualObjects(titleOfNote(reloaded), title, @"title after relaunch");
	XCTAssertEqualObjects([[reloaded contentString] string], body, @"body after relaunch");

	//Simplenote gets the stored content unchanged, and the push doesn't come back to the open note
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	XCTAssertEqualObjects([[server currentDataOfNote:[note noteRecordID]] objectForKey:@"content"], stored, @"content on Simplenote");
	XCTAssertEqualObjects(titleOfNote(note), title, @"title after pushing");

	//an edit made elsewhere re-splits the content in the running app, as a relaunch does
	[server remoteSetContent:[stored stringByAppendingString:@"\nphone"] ofNote:[note noteRecordID]];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	XCTAssertEqualObjects(titleOfNote(note), title, @"title after a Simplenote edit");
	XCTAssertEqualObjects([[note contentString] string],
						  [body length] ? [body stringByAppendingString:@"\nphone"] : @"phone", @"body after a Simplenote edit");
}

//Each input as the content of a new note: its title and body, the content stored as given.
//Tabs stay in the title; a long first line is cut at 60 characters with the rest in the body;
//blank lines before the title are skipped.
- (void)assertEachInputMadeBy:(NoteObject *(^)(NSString *text))make {
	NSArray *expectations = @[@[ShortLine, @"Groceries", @"eggs\nmilk"],
							  @[Line50, Long50, @"body"],
							  @[Line100, Cut100, [Rest100 stringByAppendingString:@"\nbody"]],
							  @[TabLine, @"Name\tValue", @"body"],
							  @[LeadingBlanks, @"Indented title", @"body"],
							  @[EmptyFirstLine, @"Groceries", @"eggs"]];
	for (NSArray *expected in expectations) {
		[self startOver];
		[self assertNote:make(expected[0]) title:expected[1] body:expected[2] stored:expected[0]];
	}
}

#pragma mark Paste and Services

- (void)testPaste {
	[self assertEachInputMadeBy:^NoteObject *(NSString *text) { return [self pasted:text]; }];
}

- (void)testPasteFromAPageStartsTheBodyWithTheSource {
	//the title is still the text's first line; the source heads the body
	[self assertNote:[self pasted:ShortLine fromURL:@"https://example.com/groceries"] title:@"Groceries"
				body:@"From <https://example.com/groceries>:\n\neggs\nmilk"
			  stored:@"Groceries\nFrom <https://example.com/groceries>:\n\neggs\nmilk"];
	[self startOver];
	//a title cut from a long line gets a line break of its own before the source
	[self assertNote:[self pasted:Long100 fromURL:@"https://example.com/plan"] title:Cut100
				body:[@"From <https://example.com/plan>:\n\n" stringByAppendingString:Rest100]
			  stored:[NSString stringWithFormat:@"%@ \nFrom <https://example.com/plan>:\n\n%@", Cut100, Rest100]];
}

#pragma mark File import, first line as title

- (void)testImport {
	[self assertEachInputMadeBy:^NoteObject *(NSString *text) { return [self imported:text fileName:@"a"]; }];
}

- (void)testImportingAFileThatStartsBlankIntoALibraryDoesNotCrash {
	//the empty first line once reached -initWithNoteBody:title: as @"", leaving the note's C title
	//NULL, and search autocompletion's prefix connections strncmp()ed it as soon as the library
	//held another note (an empty title itself is covered in NoteObjectTests)
	XCTAssertTrue([[GlobalPrefs defaultPrefs] autoCompleteSearches], @"the prefix connections run only with autocompletion on");
	NoteObject *other = [self imported:ShortLine fileName:@"a"];
	NoteObject *note = [self imported:LeadingBlanks fileName:@"e"];
	XCTAssertEqual([[controller allNotesForTitleRuleTesting] count], (NSUInteger)2);
	XCTAssertEqualObjects(titleOfNote(note), @"Indented title");
	Ivar cTitle = class_getInstanceVariable([NoteObject class], "cTitle");
	XCTAssertTrue(*(char **)((uint8_t *)(__bridge void *)note + ivar_getOffset(cTitle)) != NULL);
	XCTAssertFalse(noteTitleIsAPrefixOfOtherNoteTitle(other, note));
}

#pragma mark File import, file name as title

//When the file name is longer than the text's title (or the text is blank), the content is the
//name, a line break, then the text: the name is the title line, the text the body.

- (void)testImportByFileName {
	NSDictionary *inputs = @{@"a": ShortLine, @"d": TabLine, @"e": LeadingBlanks, @"f": EmptyFirstLine};
	NSDictionary *bodies = @{@"a": ShortLine, @"d": TabLine, @"e": @"Indented title\nbody", @"f": @"Groceries\neggs"};
	for (NSString *key in inputs) {
		[self startOver];
		NSString *name = [NSString stringWithFormat:@"%@ %@", LongFileName, key];
		[self assertNote:[self imported:inputs[key] fileName:name] title:name body:bodies[key]
				  stored:[NSString stringWithFormat:@"%@\n%@", name, inputs[key]]];
	}
}

- (void)testImportByFileNameComparesTheTextsTitle {
	//the 50-character first line, and the 57 characters of the 100-character one before the cut,
	//are longer than this name: the text titles the note
	NSString *name = [LongFileName stringByAppendingString:@" b"];
	[self assertNote:[self imported:Line50 fileName:name] title:Long50 body:@"body" stored:Line50];
	[self startOver];
	name = [LongFileName stringByAppendingString:@" c"];
	[self assertNote:[self imported:Line100 fileName:name] title:Cut100 body:[Rest100 stringByAppendingString:@"\nbody"] stored:Line100];
}

- (void)testImportByALongFileNameCutsItAt60Characters {
	NSString *name = @"An exceptionally long file name that keeps going past the sixty character title cap";
	[self assertNote:[self imported:ShortLine fileName:name] title:@"An exceptionally long file name that keeps going past the"
				body:[@"sixty character title cap\n" stringByAppendingString:ShortLine] stored:[NSString stringWithFormat:@"%@\n%@", name, ShortLine]];
}

- (void)testImportingABlankFileTitlesItByName {
	[self assertNote:[self imported:@"\n  \n" fileName:@"Blank"] title:@"Blank" body:@"" stored:@"Blank\n\n  \n"];
}

#pragma mark Typing in the search field

//The search field's text is the content; the field holds one line, so only the first-line cases apply.

- (void)testTyped {
	NSArray *expectations = @[@[@"Groceries", @"Groceries", @""],
							  @[Long50, Long50, @""],
							  @[Long100, Cut100, Rest100],
							  @[@"Name\tValue", @"Name\tValue", @""],
							  @[@"  Indented title", @"Indented title", @""]];
	for (NSArray *expected in expectations) {
		[self startOver];
		NoteObject *note = [self typed:expected[0]];
		[self assertNote:note title:expected[1] body:expected[2] stored:expected[0]];
		//typing goes on after the part of the name that wrapped into the body
		if ([expected[2] length]) XCTAssertEqual([note lastSelectedRange].location, [expected[2] length]);
	}
}

#pragma mark Stickies

- (void)testStickies {
	[self assertEachInputMadeBy:^NoteObject *(NSString *text) { return [self fromStickies:text]; }];
}

@end
