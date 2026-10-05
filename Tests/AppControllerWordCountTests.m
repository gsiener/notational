//
//  AppControllerWordCountTests.m
//  NotationTests
//
//  With ShowWordCount off the editor's word count stays visible. Counting the whole note on every
//  keystroke made typing in long notes slow (#63), so it is counted once typing pauses.
//

#import <XCTest/XCTest.h>
#import "AppController.h"
#import "LinkingEditor.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NVTestSupport.h"

//preferences with ShowWordCount off: the count is kept up to date while editing
@interface AlwaysCountingPrefs : GlobalPrefs
@end
@implementation AlwaysCountingPrefs
- (BOOL)showWordCount { return NO; }
@end

@interface WordCountTestDelegate : NSObject <NVNoteDelegate>
@end
@implementation WordCountTestDelegate
- (void)note:(NoteObject *)note attributeChanged:(NSString *)attribute {}
- (void)note:(NoteObject *)note didAddLabelSet:(NSSet *)labels {}
- (void)note:(NoteObject *)note didRemoveLabelSet:(NSSet *)labels {}
- (void)scheduleWriteForNote:(NoteObject *)note {}
- (void)noteContentsDidChange:(NoteObject *)note {}
- (float)titleColumnWidth { return 300; }
- (NSImage *)labelImageForWord:(NSString *)word highlighted:(BOOL)highlighted { return nil; }
@end

@interface AppControllerWordCountTests : XCTestCase
@end

@implementation AppControllerWordCountTests

//AppController's dealloc expects a launched app, as in AppControllerSearchTests
static NSMutableArray *Kept;

- (void)testWordCountWaitsForTypingToPause {
	if (!Kept) Kept = [NSMutableArray array];
	WordCountTestDelegate *delegate = [WordCountTestDelegate new];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"one two") title:@"Title" delegate:delegate labels:nil];
	LinkingEditor *editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
	[editor setValue:[GlobalPrefs defaultPrefs] forKey:@"prefsController"];
	[editor setString:@"one two"];
	NSTextField *counter = [[NSTextField alloc] initWithFrame:NSZeroRect];
	AppController *app = [AppController alloc];
	GlobalPrefs *prefs = [AlwaysCountingPrefs new];
	[Kept addObjectsFromArray:@[app, prefs, delegate]];
	[app setValue:note forKey:@"currentNote"];
	[app setValue:editor forKey:@"textView"];
	[app setValue:counter forKey:@"wordCounter"];
	[app setValue:prefs forKey:@"prefsController"];
	[editor setDelegate:app];

	[editor insertText:@" three" replacementRange:NSMakeRange(7, 0)];
	[editor insertText:@" four" replacementRange:NSMakeRange(13, 0)];
	XCTAssertEqualObjects([counter stringValue], @"", @"counted while typing");

	XCTNSPredicateExpectation *counted = [[XCTNSPredicateExpectation alloc]
		initWithPredicate:[NSPredicate predicateWithFormat:@"stringValue == '4 words'"] object:counter];
	XCTAssertEqual([XCTWaiter waitForExpectations:@[counted] timeout:3], XCTWaiterResultCompleted, @"counter shows %@", [counter stringValue]);
	XCTAssertEqualObjects([[note contentString] string], @"one two three four");
}

@end
