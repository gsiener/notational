//
//  NSFileManagerNVTests.m
//  Notation
//

#import <XCTest/XCTest.h>
#import "NSFileManager_NV.h"

@interface NSFileManagerNVTests : XCTestCase
@end

@implementation NSFileManagerNVTests

//the notes store lives under this folder, so its path must stay what the old DirectoryLocations category gave (#54)
- (void)testFindOrCreateDirectoryMatchesTheSearchPathAndCreatesIt {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *component = [@"NotationalTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	NSString *expected = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0]
						  stringByAppendingPathComponent:component];
	
	NSString *folder = [fm findOrCreateDirectory:NSCachesDirectory appendingPathComponent:component];
	XCTAssertEqualObjects(folder, expected);
	BOOL isDirectory = NO;
	XCTAssertTrue([fm fileExistsAtPath:folder isDirectory:&isDirectory] && isDirectory);
	XCTAssertEqualObjects([fm findOrCreateDirectory:NSCachesDirectory appendingPathComponent:component], expected);
	[fm removeItemAtPath:folder error:NULL];
}

- (void)testApplicationSupportIsInTheUsersLibrary {
	NSString *expected = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
	XCTAssertEqualObjects(NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0], expected);
	XCTAssertEqualObjects([[[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
													  appropriateForURL:nil create:NO error:NULL] path], expected);
}

@end
