//
//  NoteTitleRuleTests.m
//  NotationTests
//
//  Characterization tests for #33: what title and body a new note gets on each way in,
//  what content the Notes store keeps for it, and what title it has once that content is
//  split again — after a relaunch (-initWithNoteRecord:) and after a Simplenote round trip
//  (an edit made elsewhere coming back through -applyNoteRecord:).
//
//  Two rules split a note today:
//   - -[NSString syntheticTitleAndSeparatorWithContext:...] when a note is made by paste or
//     Services (36 characters), file import (36, but see below) and Stickies (60). Ends the
//     title at a tab as well as at a line break.
//   - NVNoteContent whenever stored content is read back. 60 characters; tabs stay in the title.
//  Typing a new note's name in the search field uses neither: the field's text is the title.
//
//  These assert today's behavior, surprises included; they are not a specification.
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
#import "NVFakeSimplenoteService.h"
#import "GlobalPrefs.h"
#import "DualField.h"
#import "AttributedPlainText.h"

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

//longer than any of the inputs' first lines, so import titles the note with it
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
	NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
	[pasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
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
	NSString *title = [string trimLeadingSyntheticTitle];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:string title:title delegate:nil labels:nil];
	NotationController *notation = controller;
	return [self noteAddedBy:^{ [notation addNotes:@[note]]; }];
}

#pragma mark The round trip

//The note as made, its stored content, the note read back from the store, and the note after
//an edit elsewhere appends a line on Simplenote and comes back through -applyNoteRecord:.
- (void)assertNote:(NoteObject *)note title:(NSString *)title body:(NSString *)body
			stored:(NSString *)stored reloadedTitle:(NSString *)reloadedTitle reloadedBody:(NSString *)reloadedBody {
	XCTAssertEqualObjects(titleOfNote(note), title, @"title as made");
	XCTAssertEqualObjects([[note contentString] string], body, @"body as made");

	//adding a note saves it to the store at once
	NVNoteRecord *record = [store noteWithID:[note noteRecordID]];
	XCTAssertEqualObjects([record content], stored, @"stored content");

	//relaunch
	NoteObject *reloaded = [[NoteObject alloc] initWithNoteRecord:record delegate:nil];
	XCTAssertEqualObjects(titleOfNote(reloaded), reloadedTitle, @"title after relaunch");
	XCTAssertEqualObjects([[reloaded contentString] string], reloadedBody, @"body after relaunch");

	//Simplenote gets the stored content unchanged, and the push doesn't come back to the open note
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	XCTAssertEqualObjects([[server currentDataOfNote:[note noteRecordID]] objectForKey:@"content"], stored, @"content on Simplenote");
	XCTAssertEqualObjects(titleOfNote(note), title, @"title after pushing");

	//an edit made elsewhere re-splits the content in the running app, as a relaunch does
	[server remoteSetContent:[stored stringByAppendingString:@"\nphone"] ofNote:[note noteRecordID]];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	XCTAssertEqualObjects(titleOfNote(note), reloadedTitle, @"title after a Simplenote edit");
	XCTAssertEqualObjects([[note contentString] string],
						  [reloadedBody length] ? [reloadedBody stringByAppendingString:@"\nphone"] : @"phone", @"body after a Simplenote edit");
}

#pragma mark Paste and Services

//Pasting keeps the whole text as the body and puts a synthetic title (36 characters, ends at
//a tab) in front of it, so the stored content repeats the first line (#33 question 3: always).
//The title survives relaunch because NVNoteContent finds that same short line again.

- (void)testPasteShortFirstLine {
	[self assertNote:[self pasted:ShortLine] title:@"Groceries" body:ShortLine
			  stored:@"Groceries\nGroceries\neggs\nmilk" reloadedTitle:@"Groceries" reloadedBody:ShortLine];
}

- (void)testPasteFiftyCharacterFirstLine {
	//cut at the last space before 36 characters
	[self assertNote:[self pasted:Line50] title:@"Meeting notes for the quarterly" body:Line50
			  stored:[@"Meeting notes for the quarterly\n" stringByAppendingString:Line50]
	   reloadedTitle:@"Meeting notes for the quarterly" reloadedBody:Line50];
}

- (void)testPasteHundredCharacterFirstLine {
	[self assertNote:[self pasted:Line100] title:@"Notes from the long planning" body:Line100
			  stored:[@"Notes from the long planning\n" stringByAppendingString:Line100]
	   reloadedTitle:@"Notes from the long planning" reloadedBody:Line100];
}

- (void)testPasteFirstLineWithATab {
	//the title ends at the tab
	[self assertNote:[self pasted:TabLine] title:@"Name" body:TabLine
			  stored:@"Name\nName\tValue\nbody" reloadedTitle:@"Name" reloadedBody:TabLine];
}

- (void)testPasteLeadingBlankLines {
	//the blank lines stay at the top of the body until relaunch, when they become part of the separator
	[self assertNote:[self pasted:LeadingBlanks] title:@"Indented title" body:LeadingBlanks
			  stored:@"Indented title\n\n\n  Indented title\nbody" reloadedTitle:@"Indented title" reloadedBody:@"Indented title\nbody"];
}

- (void)testPasteEmptyFirstLine {
	[self assertNote:[self pasted:EmptyFirstLine] title:@"Groceries" body:EmptyFirstLine
			  stored:@"Groceries\n\nGroceries\neggs" reloadedTitle:@"Groceries" reloadedBody:@"Groceries\neggs"];
}

#pragma mark File import, first line as title

//When the first line is at least as long as the file name, it is the title, taken whole up to
//the line break (#29); the 36-character synthetic title only decides which branch runs.

- (void)testImportShortFirstLine {
	[self assertNote:[self imported:ShortLine fileName:@"a"] title:@"Groceries" body:@"eggs\nmilk"
			  stored:ShortLine reloadedTitle:@"Groceries" reloadedBody:@"eggs\nmilk"];
}

- (void)testImportFiftyCharacterFirstLine {
	[self assertNote:[self imported:Line50 fileName:@"b"] title:Long50 body:@"body"
			  stored:Line50 reloadedTitle:Long50 reloadedBody:@"body"];
}

- (void)testImportHundredCharacterFirstLineIsRetitledOnRelaunch {
	//SURPRISE: the whole line is the title until relaunch (or an edit from Simplenote), when
	//NVNoteContent's 60-character limit moves the end of it into the body
	[self assertNote:[self imported:Line100 fileName:@"c"] title:Long100 body:@"body" stored:Line100
	   reloadedTitle:@"Notes from the long planning meeting about the new office"
		reloadedBody:@"layout and the budget for next year, part2\nbody"];
}

- (void)testImportFirstLineWithATab {
	//the tab stays in the title on both sides
	[self assertNote:[self imported:TabLine fileName:@"d"] title:@"Name\tValue" body:@"body"
			  stored:TabLine reloadedTitle:@"Name\tValue" reloadedBody:@"body"];
}

- (void)testImportLeadingBlankLinesIsUntitledUntilRelaunch {
	//SURPRISE: -trimLeadingWhitespace trims nothing (its NSScanner skips the very whitespace it
	//means to scan), so the "first line" is the empty one: the note is "Untitled Note" with the
	//rest as its body, the placeholder isn't stored, and relaunch titles it from the text
	[self assertNote:[self imported:LeadingBlanks fileName:@"e"] title:@"Untitled Note" body:@"\n  Indented title\nbody"
			  stored:@"\n  Indented title\nbody" reloadedTitle:@"Indented title" reloadedBody:@"body"];
}

- (void)testImportEmptyFirstLineIsUntitledUntilRelaunch {
	[self assertNote:[self imported:EmptyFirstLine fileName:@"f"] title:@"Untitled Note" body:@"Groceries\neggs"
			  stored:@"Groceries\neggs" reloadedTitle:@"Groceries" reloadedBody:@"eggs"];
}

- (void)testImportingAFileThatStartsBlankIntoALibraryDoesNotCrash {
	//#33: the empty first line once reached -initWithNoteBody:title: as @"", leaving the note's
	//C title NULL, and search autocompletion's prefix connections strncmp()ed it as soon as the
	//library held another note
	XCTAssertTrue([[GlobalPrefs defaultPrefs] autoCompleteSearches], @"the prefix connections run only with autocompletion on");
	NoteObject *other = [self imported:ShortLine fileName:@"a"];
	NoteObject *note = [self imported:LeadingBlanks fileName:@"e"];
	XCTAssertEqual([[controller allNotesForTitleRuleTesting] count], (NSUInteger)2);
	XCTAssertNotNil(other);
	Ivar cTitle = class_getInstanceVariable([NoteObject class], "cTitle");
	char *title = *(char **)((uint8_t *)(__bridge void *)note + ivar_getOffset(cTitle));
	XCTAssertTrue(title != NULL);
	XCTAssertFalse(noteTitleIsAPrefixOfOtherNoteTitle(other, note));
}

#pragma mark File import, file name as title

//When the file name is longer than the first line, it is the title and the whole text is the
//body; the stored content is the name, a line break, then the text.

- (void)testImportByFileNameKeepsTheTextWhole {
	NSDictionary *inputs = @{@"a": ShortLine, @"b": Line50, @"c": Line100, @"d": TabLine};
	for (NSString *key in inputs) {
		[self startOver];
		NSString *name = [NSString stringWithFormat:@"%@ %@", LongFileName, key];
		[self assertNote:[self imported:inputs[key] fileName:name] title:name body:inputs[key]
				  stored:[NSString stringWithFormat:@"%@\n%@", name, inputs[key]] reloadedTitle:name reloadedBody:inputs[key]];
	}
}

- (void)testImportByFileNameLosesLeadingBlankLinesOnRelaunch {
	//the blank lines (not trimmed, as above) stay at the top of the body until relaunch
	NSString *name = [LongFileName stringByAppendingString:@" e"];
	[self assertNote:[self imported:LeadingBlanks fileName:name] title:name body:LeadingBlanks
			  stored:[NSString stringWithFormat:@"%@\n%@", name, LeadingBlanks] reloadedTitle:name reloadedBody:@"Indented title\nbody"];
	[self startOver];
	name = [LongFileName stringByAppendingString:@" f"];
	[self assertNote:[self imported:EmptyFirstLine fileName:name] title:name body:EmptyFirstLine
			  stored:[NSString stringWithFormat:@"%@\n%@", name, EmptyFirstLine] reloadedTitle:name reloadedBody:@"Groceries\neggs"];
}

#pragma mark Typing in the search field

//The search field's text, verbatim, is the title; the body starts empty. The field holds one
//line, so only the first-line cases apply.

- (void)testTypedShortTitle {
	[self assertNote:[self typed:@"Groceries"] title:@"Groceries" body:@""
			  stored:@"Groceries" reloadedTitle:@"Groceries" reloadedBody:@""];
}

- (void)testTypedFiftyCharacterTitle {
	[self assertNote:[self typed:Long50] title:Long50 body:@"" stored:Long50 reloadedTitle:Long50 reloadedBody:@""];
}

- (void)testTypedHundredCharacterTitleIsSplitOnRelaunch {
	//SURPRISE: after relaunch (or an edit from Simplenote) the title is cut at 60 characters
	//and the rest of the typed name becomes the body
	[self assertNote:[self typed:Long100] title:Long100 body:@"" stored:Long100
	   reloadedTitle:@"Notes from the long planning meeting about the new office"
		reloadedBody:@"layout and the budget for next year, part2"];
}

- (void)testTypedTitleWithATab {
	//a pasted tab stays in the title on both sides
	[self assertNote:[self typed:@"Name\tValue"] title:@"Name\tValue" body:@""
			  stored:@"Name\tValue" reloadedTitle:@"Name\tValue" reloadedBody:@""];
}

- (void)testTypedLeadingSpacesAreDroppedOnRelaunch {
	//the spaces are kept in the stored content but not in the title read back from it
	[self assertNote:[self typed:@"  Indented title"] title:@"  Indented title" body:@""
			  stored:@"  Indented title" reloadedTitle:@"Indented title" reloadedBody:@""];
}

#pragma mark Stickies

//-trimLeadingSyntheticTitle: 60 characters, ends at a tab, and takes the title and its
//separator out of the body; the stored content joins them with a line break.

- (void)testStickiesShortFirstLine {
	[self assertNote:[self fromStickies:ShortLine] title:@"Groceries" body:@"eggs\nmilk"
			  stored:ShortLine reloadedTitle:@"Groceries" reloadedBody:@"eggs\nmilk"];
}

- (void)testStickiesFiftyCharacterFirstLine {
	[self assertNote:[self fromStickies:Line50] title:Long50 body:@"body"
			  stored:Line50 reloadedTitle:Long50 reloadedBody:@"body"];
}

- (void)testStickiesHundredCharacterFirstLineGainsALineBreak {
	//the same 60-character cut as NVNoteContent, so the title is stable; the stored content
	//has a line break where the space was
	[self assertNote:[self fromStickies:Line100] title:@"Notes from the long planning meeting about the new office"
				body:@"layout and the budget for next year, part2\nbody"
			  stored:@"Notes from the long planning meeting about the new office\nlayout and the budget for next year, part2\nbody"
	   reloadedTitle:@"Notes from the long planning meeting about the new office"
		reloadedBody:@"layout and the budget for next year, part2\nbody"];
}

- (void)testStickiesTabBecomesALineBreak {
	//SURPRISE: the tab is the separator, so it is dropped and stored as a line break
	[self assertNote:[self fromStickies:TabLine] title:@"Name" body:@"Value\nbody"
			  stored:@"Name\nValue\nbody" reloadedTitle:@"Name" reloadedBody:@"Value\nbody"];
}

- (void)testStickiesLeadingBlankLinesAndEmptyFirstLine {
	[self assertNote:[self fromStickies:LeadingBlanks] title:@"Indented title" body:@"body"
			  stored:@"Indented title\nbody" reloadedTitle:@"Indented title" reloadedBody:@"body"];
	[self startOver];
	[self assertNote:[self fromStickies:EmptyFirstLine] title:@"Groceries" body:@"eggs"
			  stored:@"Groceries\neggs" reloadedTitle:@"Groceries" reloadedBody:@"eggs"];
}

@end
