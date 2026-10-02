//
//  NVTestSupport.m
//  NotationTests
//

#import "NVTestSupport.h"
#import "NoteObject.h"

@implementation NVTestCase

- (void)setUp {
	[super setUp];
	_temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:_temporaryDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown {
	[[NSFileManager defaultManager] removeItemAtPath:_temporaryDirectory error:NULL];
	[super tearDown];
}

@end

NSString *NVTestRepoPath(void) {
	return [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

NSString *NVTestFixturesPath(NSString *name) {
	return [[NVTestRepoPath() stringByAppendingPathComponent:@"Tests/Fixtures"] stringByAppendingPathComponent:name];
}

NSAttributedString *NVTestBody(NSString *text) {
	return [[NSAttributedString alloc] initWithString:text];
}

NoteObject *NVTestNote(NSString *title, NSString *body, NSString *labels) {
	return [[NoteObject alloc] initWithNoteBody:NVTestBody(body) title:title delegate:nil labels:labels];
}
