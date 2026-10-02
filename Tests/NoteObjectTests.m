//
//  NoteObjectTests.m
//  A note can be built and changed without a notes controller, and tells its delegate
//  (NVNoteDelegate) what changed without reaching past it (#2).
//

#import <XCTest/XCTest.h>
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"

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

#pragma mark Changes from Simplenote

static NVNoteRecord *Record(NSString *content, NSArray *tags) {
	NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:content, @"content", tags, @"tags",
						  [NSNumber numberWithDouble:1700000000], @"creationDate", [NSNumber numberWithDouble:1700000500], @"modificationDate", nil];
	return [NVNoteRecord recordWithNoteID:@"abc" serverData:data version:1];
}

- (void)testApplyingARecordUpdatesTheNoteWithoutSchedulingAWrite {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:Record(@"Title\nbody", @[@"old"]) delegate:delegate];
	XCTAssertFalse([delegate.events containsObject:@"write"], @"%@", delegate.events);
	[delegate.events removeAllObjects];

	XCTAssertTrue([note applyNoteRecord:Record(@"Renamed\nnew body", @[@"new"])]);
	XCTAssertEqualObjects(titleOfNote(note), @"Renamed");
	XCTAssertEqualObjects([[note contentString] string], @"new body");
	XCTAssertEqualObjects(labelsOfNote(note), @"new");
	XCTAssertEqual(modifiedDateOfNote(note), 1700000500 - kCFAbsoluteTimeIntervalSince1970);
	//the list and the label index still hear about it
	XCTAssertTrue([delegate.events containsObject:@"changed Title"], @"%@", delegate.events);
	XCTAssertTrue([delegate.events containsObject:@"changed Tags"], @"%@", delegate.events);
	XCTAssertTrue([delegate.events containsObject:@"added new"], @"%@", delegate.events);
	XCTAssertFalse([delegate.events containsObject:@"write"], @"%@", delegate.events);

	//the search cache follows the new text
	NoteFilterContext context = {(char *)"new body", NO};
	XCTAssertTrue(noteContainsUTF8String(note, &context));

	//an edit by the user is still written
	[note setContentString:Body(@"typed here")];
	XCTAssertTrue([delegate.events containsObject:@"write"], @"%@", delegate.events);
}

- (void)testApplyingAnUnchangedRecordChangesNothing {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:Record(@"Title\nbody", @[@"a"]) delegate:delegate];
	[delegate.events removeAllObjects];
	XCTAssertFalse([note applyNoteRecord:Record(@"Title\nbody", @[@"a"])]);
	XCTAssertEqual([delegate.events count], (NSUInteger)0, @"%@", delegate.events);
}

@end
