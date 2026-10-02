//
//  NotationControllerStoreTests.m
//  NotationTests
//
//  NotationController in Simplenote-backed mode, end to end: Notes store + Sync engine +
//  fake server, with the controller's real in-memory notes.
//

#import <XCTest/XCTest.h>
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

@interface NotationControllerStoreTests : XCTestCase {
	NSString *directory;
	NVFakeSimplenoteService *server;
	NVNotesStore *store;
	NVSyncEngine *engine;
	NotationController *controller;
}
@end

@implementation NotationControllerStoreTests

- (void)setUp {
	[super setUp];
	directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	server = [[NVFakeSimplenoteService alloc] init];
	store = [NVNotesStore storeAtPath:[directory stringByAppendingPathComponent:@"Notes.sqlite"] error:NULL];
	engine = [[NVSyncEngine alloc] initWithStore:store service:server];
}

- (void)tearDown {
	[controller closeAllResources];
	[NSObject cancelPreviousPerformRequestsWithTarget:controller];
	[controller setSyncEngine:nil];
	[store close];
	[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
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
