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
	return [(id)CFPreferencesCopyValue((CFStringRef)key, (CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) autorelease];
}

- (void)setUp {
	[super setUp];
	NSString *unique = [[[NSUUID UUID] UUIDString] substringToIndex:8];
	sourceDomain = [[NSString stringWithFormat:@"com.gsiener.notational.tests.legacy-%@", unique] retain];
	targetSuite = [[NSString stringWithFormat:@"com.gsiener.notational.tests.target-%@", unique] retain];
	
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
		CFPreferencesSetValue((CFStringRef)key, (CFPropertyListRef)[old objectForKey:key], (CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize((CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

- (void)tearDown {
	CFArrayRef keys = CFPreferencesCopyKeyList((CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	for (NSString *key in (NSArray *)keys) CFPreferencesSetValue((CFStringRef)key, NULL, (CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (keys) CFRelease(keys);
	CFPreferencesSynchronize((CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	keys = CFPreferencesCopyKeyList((CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	for (NSString *key in (NSArray *)keys) CFPreferencesSetValue((CFStringRef)key, NULL, (CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (keys) CFRelease(keys);
	CFPreferencesSynchronize((CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	[sourceDomain release];
	[targetSuite release];
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
	CFPreferencesSetValue(CFSTR("TableSortColumn"), CFSTR("Title"), (CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	[NVLegacyPreferences importFromDomain:sourceDomain intoDomain:targetSuite];
	XCTAssertEqualObjects([self saved:@"TableSortColumn"], @"Title");
	
	CFPreferencesSetValue(CFSTR("AppActivationKeyCode"), NULL, (CFStringRef)targetSuite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	XCTAssertEqual([NVLegacyPreferences importFromDomain:sourceDomain intoDomain:targetSuite], (NSUInteger)0);
	XCTAssertNil([self saved:@"AppActivationKeyCode"]);
}

@end
