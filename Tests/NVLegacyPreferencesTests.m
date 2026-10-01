//
//  NVLegacyPreferencesTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVLegacyPreferences.h"

@interface NVLegacyPreferencesTests : XCTestCase {
	NSString *sourceDomain, *targetSuite;
}
@end

@implementation NVLegacyPreferencesTests

- (id)saved:(NSString *)key {
	return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, (__bridge CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
}

- (void)setUp {
	[super setUp];
	NSString *unique = [[[NSUUID UUID] UUIDString] substringToIndex:8];
	sourceDomain = [NSString stringWithFormat:@"com.gsiener.notational.tests.legacy-%@", unique];
	targetSuite = [NSString stringWithFormat:@"com.gsiener.notational.tests.target-%@", unique];
	
	NSDictionary *old = [NSDictionary dictionaryWithObjectsAndKeys:
						 [NSNumber numberWithInt:37], @"AppActivationKeyCode",
						 [NSNumber numberWithBool:NO], @"ShowDockIcon",
						 @"Date Modified", @"TableSortColumn",
						 @"1190 364 560 711 0 0 1800 1130 ", @"NSWindow Frame NotationWindow",
						 @"kc", @"LastSearchString",
						 [NSData dataWithBytes:"alias" length:5], @"DirectoryAlias",
						 @"https://example.com/feed", @"SUFeedURL",
						 [NSArray array], @"Bookmarks", nil];
	for (NSString *key in old)
		CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)[old objectForKey:key], (__bridge CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize((__bridge CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

- (void)tearDown {
	NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList((__bridge CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
	for (NSString *key in keys) CFPreferencesSetValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize((__bridge CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	keys = CFBridgingRelease(CFPreferencesCopyKeyList((__bridge CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
	for (NSString *key in keys) CFPreferencesSetValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize((__bridge CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	[super tearDown];
}

- (void)testCopiesLookAndFeelButNotSessionStateOrObsoleteKeys {
	//a registered default must not count as "already set" (GlobalPrefs registers ShowDockIcon=YES)
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"ShowDockIcon"]];
	NSUInteger copied = [NVLegacyPreferences importFromDomain:sourceDomain intoDomain:targetSuite];
	XCTAssertEqual(copied, (NSUInteger)4);
	XCTAssertEqualObjects([self saved:@"AppActivationKeyCode"], [NSNumber numberWithInt:37]);
	XCTAssertEqualObjects([self saved:@"ShowDockIcon"], [NSNumber numberWithBool:NO]);
	XCTAssertEqualObjects([self saved:@"TableSortColumn"], @"Date Modified");
	XCTAssertNotNil([self saved:@"NSWindow Frame NotationWindow"]);
	for (NSString *skipped in [NSArray arrayWithObjects:@"LastSearchString", @"DirectoryAlias", @"SUFeedURL", @"Bookmarks", nil])
		XCTAssertNil([self saved:skipped], @"%@", skipped);
}

- (void)testRunsOnceAndNeverOverwritesExistingSettings {
	CFPreferencesSetValue(CFSTR("TableSortColumn"), CFSTR("Title"), (__bridge CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	[NVLegacyPreferences importFromDomain:sourceDomain intoDomain:targetSuite];
	XCTAssertEqualObjects([self saved:@"TableSortColumn"], @"Title");
	
	CFPreferencesSetValue(CFSTR("AppActivationKeyCode"), NULL, (__bridge CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	XCTAssertEqual([NVLegacyPreferences importFromDomain:sourceDomain intoDomain:targetSuite], (NSUInteger)0);
	XCTAssertNil([self saved:@"AppActivationKeyCode"]);
}

@end
