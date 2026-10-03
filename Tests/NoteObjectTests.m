//
//  NoteObjectTests.m
//  A note can be built and changed without a notes controller, and tells its delegate
//  (NVNoteDelegate) what changed without reaching past it (#2).
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"
#import "GlobalPrefs.h"
#import "AttributedPlainText.h"

@class ODBEditor;
@interface NoteObject (ExternalEditing)
-(void)odbEditor:(ODBEditor *)editor didModifyFile:(NSString *)path newFileLocation:(NSString *)newPath context:(NSDictionary *)context;
-(void)odbEditor:(ODBEditor *)editor didClosefile:(NSString *)path context:(NSDictionary *)context;
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

@interface NoteObjectTests : NVTestCase
@end

@implementation NoteObjectTests

- (void)testANoteWorksWithoutAController {
	NoteObject *note = NVTestNote(@"Title", @"body text", @"work home");
	XCTAssertEqualObjects(titleOfNote(note), @"Title");
	XCTAssertEqualObjects([[note contentString] string], @"body text");
	[note setTitleString:@"New title"];
	[note setLabelString:@"home"];
	[note setContentString:NVTestBody(@"new body")];
	XCTAssertEqualObjects(titleOfNote(note), @"New title");
	XCTAssertEqualObjects(labelsOfNote(note), @"home");
	XCTAssertEqualObjects([[note contentString] string], @"new body");
}

- (void)testANoteWithNoTitleIsTitledUntitledForSearchToo {
	//search and autocompletion compare C titles; an empty title once left the C title NULL (#33)
	NoteObject *untitled = NVTestNote(@"", @"body", nil);
	NoteObject *other = NVTestNote(@"Untitled Note and more", @"body", nil);
	XCTAssertEqualObjects(titleOfNote(untitled), @"Untitled Note");
	XCTAssertTrue(noteTitleIsAPrefixOfOtherNoteTitle(other, untitled));
	XCTAssertFalse(noteTitleIsAPrefixOfOtherNoteTitle(untitled, other));
	XCTAssertTrue(noteTitleHasPrefixOfUTF8String(untitled, "untitled", 8));
}

- (void)testRenamingTellsTheDelegate {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"body") title:@"Title" delegate:delegate labels:nil];
	[delegate.events removeAllObjects];
	[note setTitleString:@"Renamed"];
	XCTAssertTrue([delegate.events containsObject:@"changed Title"], @"%@", delegate.events);
}

- (void)testRelabelingReportsTheLabelSets {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"body") title:@"Title" delegate:delegate labels:@"old"];
	[delegate.events removeAllObjects];
	[note setLabelString:@"new"];
	XCTAssertTrue([delegate.events containsObject:@"removed labels"], @"%@", delegate.events);
	XCTAssertTrue([delegate.events containsObject:@"added new"], @"%@", delegate.events);
}

- (void)testExternalEditsAskTheDelegateToRefresh {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"body") title:@"Title" delegate:delegate labels:nil];
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"external.txt"];
	[@"edited in another app" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[delegate.events removeAllObjects];
	[note odbEditor:nil didModifyFile:path newFileLocation:nil context:nil];
	XCTAssertEqualObjects([[note contentString] string], @"edited in another app");
	XCTAssertTrue([delegate.events containsObject:@"contents"], @"%@", delegate.events);
	XCTAssertTrue([delegate.events containsObject:@"write"], @"%@", delegate.events);
}

- (void)testExternalAtomicReplacementImportsTheCurrentPath {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"original") title:@"Title" delegate:delegate labels:nil];
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"external.txt"];
	[@"before" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	[@"replacement" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	[note odbEditor:nil didModifyFile:path newFileLocation:nil context:nil];
	XCTAssertEqualObjects([[note contentString] string], @"replacement");
	XCTAssertTrue([delegate.events containsObject:@"write"]);
}

- (void)testExternalSaveAsStillImportsOriginalPath {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"original") title:@"Title" delegate:delegate labels:nil];
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"external.txt"];
	NSString *newPath = [self.temporaryDirectory stringByAppendingPathComponent:@"renamed.txt"];
	[@"original file" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	[@"saved as" writeToFile:newPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	[note odbEditor:nil didModifyFile:path newFileLocation:newPath context:nil];
	XCTAssertEqualObjects([[note contentString] string], @"original file");
	XCTAssertTrue([delegate.events containsObject:@"write"]);
}

- (void)testExternalDeletionDoesNotEraseNoteAndCloseCleansUpFile {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"original") title:@"Title" delegate:delegate labels:nil];
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"external.txt"];
	[delegate.events removeAllObjects];
	[note odbEditor:nil didModifyFile:path newFileLocation:nil context:nil];
	XCTAssertEqualObjects([[note contentString] string], @"original");
	XCTAssertFalse([delegate.events containsObject:@"write"]);
	[@"temporary" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	[note odbEditor:nil didClosefile:path context:nil];
	XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
}

- (void)testExternalSaveAfterConcurrentLocalEditCurrentlyReplacesLocalBody {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:NVTestBody(@"base") title:@"Title" delegate:delegate labels:nil];
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"external.txt"];
	[@"external change" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
	[note setContentString:NVTestBody(@"local change")];
	[note odbEditor:nil didModifyFile:path newFileLocation:nil context:nil];
	XCTAssertEqualObjects([[note contentString] string], @"external change");
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
	[note setContentString:NVTestBody(@"typed here")];
	XCTAssertTrue([delegate.events containsObject:@"write"], @"%@", delegate.events);
}

- (void)testApplyingAnUnchangedRecordChangesNothing {
	RecordingNoteDelegate *delegate = [[RecordingNoteDelegate alloc] init];
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:Record(@"Title\nbody", @[@"a"]) delegate:delegate];
	[delegate.events removeAllObjects];
	XCTAssertFalse([note applyNoteRecord:Record(@"Title\nbody", @[@"a"])]);
	XCTAssertEqual([delegate.events count], (NSUInteger)0, @"%@", delegate.events);
}

- (void)testRecordTagsAreSplitAsTheTagUISplitsThem {
	NoteObject *note = NVTestNote(@"Title", @"body", @"work;home\tideas, later work");
	NSArray *expected = @[@"work", @"home", @"ideas", @"later"];
	XCTAssertEqualObjects([note orderedLabelTitles], expected);
	XCTAssertEqualObjects([[note noteRecordRepresentation] tags], expected);
}

- (void)testARecordWithoutLabelsHasNoTags {
	NoteObject *note = NVTestNote(@"Title", @"body", nil);
	XCTAssertEqualObjects([[note noteRecordRepresentation] tags], [NSArray array]);
}

//links are found when the body is first asked for, not at load; what the editor shows is the same
- (void)testANoteFromARecordShowsItsLinksAndDoneLines {
	NSString *body = @"see https://example.com and [[Other note]]\nbuy milk @done\nplain";
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:Record([@"Title\n" stringByAppendingString:body], @[]) delegate:nil];

	NSMutableAttributedString *expected = [[NSMutableAttributedString alloc] initWithString:body attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	[expected addLinkAttributesForRange:NSMakeRange(0, [expected length])];
	[expected addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [expected length])];
	XCTAssertEqualObjects([note contentString], expected);
	XCTAssertEqualObjects([[note contentString] attribute:NSLinkAttributeName atIndex:6 effectiveRange:NULL], [NSURL URLWithString:@"https://example.com"]);
	//the record written back is unchanged by the styling
	XCTAssertEqualObjects([[note noteRecordRepresentation] content], [@"Title\n" stringByAppendingString:body]);
}

- (void)testAnEditBeforeTheBodyIsShownKeepsTheEditorsAttributes {
	NoteObject *note = [[NoteObject alloc] initWithNoteRecord:Record(@"Title\nhttps://example.com", @[]) delegate:nil];
	[note setContentString:NVTestBody(@"https://example.com typed")];
	XCTAssertNil([[note contentString] attribute:NSLinkAttributeName atIndex:0 effectiveRange:NULL]);
}

@end
