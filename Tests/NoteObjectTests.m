//
//  NoteObjectTests.m
//  A note can be built and changed without a notes controller, and tells its delegate
//  (NVNoteDelegate) what changed without reaching past it (#2).
//

#import <XCTest/XCTest.h>
#import "NoteObject.h"

@class ODBEditor;
@interface NoteObject (ExternalEditing)
-(void)odbEditor:(ODBEditor *)editor didModifyFile:(NSString *)path newFileLocation:(NSString *)newPath context:(NSDictionary *)context;
@end

@interface RecordingNoteDelegate : NSObject <NVNoteDelegate>
@property (nonatomic, strong) NSMutableArray *events;
@end

@implementation RecordingNoteDelegate
- (instancetype)init { if ((self = [super init])) _events = [NSMutableArray array]; return self; }
- (void)note:(NoteObject *)note attributeChanged:(NSString *)attribute { [_events addObject:[@"changed " stringByAppendingString:attribute]]; }
- (void)note:(NoteObject *)note didAddLabelSet:(NSSet *)labelSet {
	[_events addObject:[@"added " stringByAppendingString:[[[labelSet valueForKey:@"title"] allObjects] componentsJoinedByString:@","]]];
}
- (void)note:(NoteObject *)note didRemoveLabelSet:(NSSet *)labelSet { [_events addObject:@"removed labels"]; }
- (void)scheduleWriteForNote:(NoteObject *)note { [_events addObject:@"write"]; }
- (void)noteContentsDidChange:(NoteObject *)note { [_events addObject:@"contents"]; }
- (float)titleColumnWidth { return 300.0f; }
- (NSImage *)labelImageForWord:(NSString *)word highlighted:(BOOL)highlighted { return nil; }
@end

@interface NoteObjectTests : XCTestCase
@end

@implementation NoteObjectTests

static NSAttributedString *Body(NSString *text) {
	return [[NSAttributedString alloc] initWithString:text];
}

- (void)testANoteWorksWithoutAController {
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:Body(@"body text") title:@"Title" delegate:nil labels:@"work home"];
	XCTAssertEqualObjects(titleOfNote(note), @"Title");
	XCTAssertEqualObjects([[note contentString] string], @"body text");
	[note setTitleString:@"New title"];
	[note setLabelString:@"home"];
	[note setContentString:Body(@"new body")];
	XCTAssertEqualObjects(titleOfNote(note), @"New title");
	XCTAssertEqualObjects(labelsOfNote(note), @"home");
	XCTAssertEqualObjects([[note contentString] string], @"new body");
}

- (void)testRenamingTellsTheDelegate {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:Body(@"body") title:@"Title" delegate:delegate labels:nil];
	[delegate.events removeAllObjects];
	[note setTitleString:@"Renamed"];
	XCTAssertTrue([delegate.events containsObject:@"changed Title"], @"%@", delegate.events);
}

- (void)testRelabelingReportsTheLabelSets {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:Body(@"body") title:@"Title" delegate:delegate labels:@"old"];
	[delegate.events removeAllObjects];
	[note setLabelString:@"new"];
	XCTAssertTrue([delegate.events containsObject:@"removed labels"], @"%@", delegate.events);
	XCTAssertTrue([delegate.events containsObject:@"added new"], @"%@", delegate.events);
}

- (void)testExternalEditsAskTheDelegateToRefresh {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:Body(@"body") title:@"Title" delegate:delegate labels:nil];
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[@"edited in another app" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[delegate.events removeAllObjects];
	[note odbEditor:nil didModifyFile:path newFileLocation:nil context:nil];
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	XCTAssertEqualObjects([[note contentString] string], @"edited in another app");
	XCTAssertTrue([delegate.events containsObject:@"contents"], @"%@", delegate.events);
	XCTAssertTrue([delegate.events containsObject:@"write"], @"%@", delegate.events);
}

@end
