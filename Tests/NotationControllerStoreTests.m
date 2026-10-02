//
//  NotationControllerStoreTests.m
//  NotationTests
//
//  NotationController in Simplenote-backed mode, end to end: Notes store + Sync engine +
//  fake server, with the controller's real in-memory notes.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "NotationController.h"
#import "NVNotesStore.h"
#import "NVSyncEngine.h"
#import "NVNoteRecord.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVFakeSimplenoteService.h"
#import "NotationPrefs.h"

@interface NotationController (TestAccess)
- (NSArray *)allNotesForTesting;
@end
@implementation NotationController (TestAccess)
- (NSArray *)allNotesForTesting { return allNotes; }
@end

@interface NotationControllerStoreTests : NVTestCase {
	NVFakeSimplenoteService *server;
	NVNotesStore *store;
	NVSyncEngine *engine;
	NotationController *controller;
}
@end

@implementation NotationControllerStoreTests

- (void)setUp {
	[super setUp];
	server = [[NVFakeSimplenoteService alloc] init];
	store = [NVNotesStore storeAtPath:[self.temporaryDirectory stringByAppendingPathComponent:@"Notes.sqlite"] error:NULL];
	engine = [[NVSyncEngine alloc] initWithStore:store service:server];
}

- (void)tearDown {
	[controller closeAllResources];
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	[controller setSyncEngine:nil];
	[store close];
	[super tearDown];
}

- (void)openController {
	controller = [[NotationController alloc] initWithNotesStore:store];
	[controller setSyncEngine:engine];
}

- (void)syncAndDeliver {
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	//delegate callbacks arrive on the main queue
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}

- (NoteObject *)noteTitled:(NSString *)title {
	for (NoteObject *note in [controller allNotesForTesting])
		if ([titleOfNote(note) isEqualToString:title]) return note;
	return nil;
}

- (void)testLoadsNotesFromTheStoreSkippingTrash {
	NSString *a = [server remoteCreateNoteWithContent:@"Groceries\n\neggs" tags:[NSArray arrayWithObject:@"home"]];
	NSString *b = [server remoteCreateNoteWithContent:@"Old note\nbye" tags:nil];
	[server remoteTrashNote:b];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);

	[self openController];
	XCTAssertEqual([[controller allNotesForTesting] count], (NSUInteger)1);
	NoteObject *note = [self noteTitled:@"Groceries"];
	XCTAssertEqualObjects([[note contentString] string], @"eggs");
	XCTAssertEqualObjects(labelsOfNote(note), @"home");
	XCTAssertEqualObjects([note noteRecordID], a);
	//loading must not create local edits
	XCTAssertEqual([[store pendingNotes] count], (NSUInteger)0);
}

- (void)testLocalEditReachesSimplenoteExactly {
	NSString *noteID = [server remoteCreateNoteWithContent:@"Groceries\n\n\neggs" tags:nil];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[self openController];

	NoteObject *note = [self noteTitled:@"Groceries"];
	[note setContentString:[[NSAttributedString alloc] initWithString:@"eggs\nmilk"]];
	[controller synchronizeNoteChanges:nil];
	XCTAssertTrue([[store noteWithID:noteID] pending]);

	[self syncAndDeliver];
	//the original separator (three newlines) is kept
	XCTAssertEqualObjects([[server currentDataOfNote:noteID] objectForKey:@"content"], @"Groceries\n\n\neggs\nmilk");
	XCTAssertFalse([[store noteWithID:noteID] pending]);
}

- (void)testEditsToSeveralNotesAreSavedTogether {
	NSString *a = [server remoteCreateNoteWithContent:@"First\none" tags:nil];
	NSString *b = [server remoteCreateNoteWithContent:@"Second\ntwo" tags:nil];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[self openController];
	[[self noteTitled:@"First"] setContentString:[[NSAttributedString alloc] initWithString:@"one more"]];
	[[self noteTitled:@"Second"] setContentString:[[NSAttributedString alloc] initWithString:@"two more"]];
	[controller synchronizeNoteChanges:nil];

	XCTAssertEqual([[store pendingNotes] count], (NSUInteger)2);
	XCTAssertEqualObjects([[store noteWithID:a] content], @"First\none more");
	XCTAssertEqualObjects([[store noteWithID:b] content], @"Second\ntwo more");
	XCTAssertEqual([[store noteWithID:a] confirmedVersion], (NSInteger)1);
	[self syncAndDeliver];
	XCTAssertEqualObjects([[server currentDataOfNote:b] objectForKey:@"content"], @"Second\ntwo more");
}

- (void)testRemoteEditUpdatesTheNoteWithoutEchoing {
	NSString *noteID = [server remoteCreateNoteWithContent:@"Plan\nstep one" tags:nil];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[self openController];
	NSUInteger postsBefore = [[server requestCounts] countForObject:@"post"];

	[server remoteSetContent:@"Plan\nstep one\nstep two from phone" ofNote:noteID];
	[self syncAndDeliver];

	NoteObject *note = [self noteTitled:@"Plan"];
	XCTAssertEqualObjects([[note contentString] string], @"step one\nstep two from phone");
	[controller synchronizeNoteChanges:nil];
	[self syncAndDeliver];
	XCTAssertEqual([[server requestCounts] countForObject:@"post"], postsBefore);
	XCTAssertEqual([[store pendingNotes] count], (NSUInteger)0);
}

- (void)testRemoteCreateAndTrashUpdateTheList {
	[self openController];
	NSString *noteID = [server remoteCreateNoteWithContent:@"From the phone\nhello" tags:nil];
	[self syncAndDeliver];
	XCTAssertNotNil([self noteTitled:@"From the phone"]);

	[server remoteTrashNote:noteID];
	[self syncAndDeliver];
	XCTAssertNil([self noteTitled:@"From the phone"]);
}

- (void)testDeletingInTheAppMovesTheNoteToSimplenoteTrash {
	NSString *noteID = [server remoteCreateNoteWithContent:@"Delete me\nplease" tags:nil];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[self openController];

	[controller removeNote:[self noteTitled:@"Delete me"]];
	XCTAssertNil([self noteTitled:@"Delete me"]);
	[self syncAndDeliver];
	XCTAssertTrue([[[server currentDataOfNote:noteID] objectForKey:@"deleted"] boolValue]);
	XCTAssertEqualObjects([[server currentDataOfNote:noteID] objectForKey:@"content"], @"Delete me\nplease");
}

- (void)testNewNoteIsCreatedInSimplenote {
	[self openController];
	NSAttributedString *body = [[NSAttributedString alloc] initWithString:@"body text"];
	NoteObject *note = [[NoteObject alloc] initWithNoteBody:body title:@"Brand new" delegate:controller labels:@"inbox"];
	[controller addNotes:[NSArray arrayWithObject:note]];
	[self syncAndDeliver];

	NSDictionary *created = [server currentDataOfNote:[note noteRecordID]];
	XCTAssertTrue([[created objectForKey:@"content"] hasPrefix:@"Brand new\n"]);
	XCTAssertTrue([[created objectForKey:@"content"] hasSuffix:@"body text"]);
	XCTAssertEqualObjects([created objectForKey:@"tags"], [NSArray arrayWithObject:@"inbox"]);
}

- (void)testNotesAreFoundByRecordIDAsTheyComeAndGo {
	NSString *loaded = [server remoteCreateNoteWithContent:@"Loaded\nat launch" tags:nil];
	XCTAssertTrue([engine syncOnceReturningError:NULL]);
	[self openController];
	XCTAssertEqual([controller noteForRecordID:loaded], [self noteTitled:@"Loaded"]);

	NSString *remote = [server remoteCreateNoteWithContent:@"From the phone\nhi" tags:nil];
	[self syncAndDeliver];
	XCTAssertEqual([controller noteForRecordID:remote], [self noteTitled:@"From the phone"]);

	NoteObject *local = [[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@"body"] title:@"Local" delegate:controller labels:nil];
	[controller addNotes:[NSArray arrayWithObject:local]];
	XCTAssertEqual([controller noteForRecordID:[local noteRecordID]], local);

	[controller removeNote:local];
	XCTAssertNil([controller noteForRecordID:[local noteRecordID]]);
	[server remoteTrashNote:remote];
	[self syncAndDeliver];
	XCTAssertNil([controller noteForRecordID:remote]);
	XCTAssertNil([controller noteForRecordID:nil]);
}

- (void)testSettingsPersistInTheStore {
	[self openController];
	[[controller notationPrefs] setConfirmsFileDeletion:NO];
	[controller flushAllNoteChanges];
	[controller closeAllResources];
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	controller = nil;
	[self openController];
	XCTAssertFalse([[controller notationPrefs] confirmFileDeletion]);
}

@end
