//
//  NVTestSupport.h
//  NotationTests
//
//  Helpers shared by the unit tests.
//

#import <XCTest/XCTest.h>

@class NoteObject;

//a test case with its own empty temporary directory: made in -setUp, removed in -tearDown
@interface NVTestCase : XCTestCase
@property (nonatomic, readonly) NSString *temporaryDirectory;
@end

//the repository root, and a folder under Tests/Fixtures
NSString *NVTestRepoPath(void);
NSString *NVTestFixturesPath(NSString *name);

//a NoteObject built from plain strings, with no delegate
NSAttributedString *NVTestBody(NSString *text);
NoteObject *NVTestNote(NSString *title, NSString *body, NSString *labels);
