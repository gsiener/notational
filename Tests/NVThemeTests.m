//
//  NVThemeTests.m
//  The colour scheme (#5): which colours each scheme gives, remembering the choice,
//  and telling views when it changes.
//

#import <XCTest/XCTest.h>
#import "NVTheme.h"

@interface NVThemeTests : XCTestCase {
	NSString *suite;
	NSUserDefaults *defaults;
	NSArray *custom;
	NSUInteger notifications;
}
@end

@implementation NVThemeTests

- (void)setUp {
	[super setUp];
	suite = [@"NVThemeTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
	defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
	custom = @[[NSColor redColor], [NSColor blueColor]];
	notifications = 0;
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:) name:NVThemeDidChangeNotification object:nil];
}

- (void)tearDown {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[defaults removePersistentDomainForName:suite];
	[super tearDown];
}

- (void)themeChanged:(NSNotification *)note { notifications++; }

- (NVTheme *)theme {
	NSArray *colors = custom;
	return [[NVTheme alloc] initWithDefaults:defaults customColors:^NSArray *{ return colors; }];
}

static CGFloat White(NSColor *color) {
	return [[color colorUsingColorSpace:[NSColorSpace genericGrayColorSpace]] whiteComponent];
}

- (void)testLightSchemeIsNearBlackOnNearWhite {
	//(a suite's defaults also see values registered elsewhere in the test run, so set it)
	[defaults setInteger:NVThemeSchemeLight forKey:@"ColorScheme"];
	NVTheme *theme = [self theme];
	XCTAssertEqual(theme.scheme, NVThemeSchemeLight);
	XCTAssertLessThan(White(theme.foregroundColor), 0.1);
	XCTAssertGreaterThan(White(theme.backgroundColor), 0.9);
}

- (void)testLowContrastIsGreyOnGrey {
	NVTheme *theme = [self theme];
	[theme setScheme:NVThemeSchemeLowContrast];
	XCTAssertEqualWithAccuracy(White(theme.foregroundColor), 0.24, 0.05);
	XCTAssertEqualWithAccuracy(White(theme.backgroundColor), 0.90, 0.05);
}

- (void)testCustomSchemeUsesTheSettingsColours {
	NVTheme *theme = [self theme];
	[theme setScheme:NVThemeSchemeCustom];
	XCTAssertEqualObjects(theme.foregroundColor, [NSColor redColor]);
	XCTAssertEqualObjects(theme.backgroundColor, [NSColor blueColor]);
}

- (void)testCustomSchemeWithoutColoursFallsBackToLight {
	custom = nil;
	NVTheme *theme = [self theme];
	[theme setScheme:NVThemeSchemeCustom];
	XCTAssertGreaterThan(White(theme.backgroundColor), 0.9);
}

- (void)testSchemeIsRememberedAcrossLaunches {
	[[self theme] setScheme:NVThemeSchemeLowContrast];
	XCTAssertEqual([defaults integerForKey:@"ColorScheme"], (NSInteger)NVThemeSchemeLowContrast);
	XCTAssertEqual([self theme].scheme, NVThemeSchemeLowContrast);
}

- (void)testAnUnknownSavedSchemeIsLight {
	[defaults setInteger:7 forKey:@"ColorScheme"];
	XCTAssertEqual([self theme].scheme, NVThemeSchemeLight);
}

- (void)testChangesAreAnnounced {
	NVTheme *theme = [self theme];
	[theme setScheme:NVThemeSchemeLowContrast];
	XCTAssertEqual(notifications, (NSUInteger)1);
	//Settings colours only matter to the custom scheme
	[theme customColorsDidChange];
	XCTAssertEqual(notifications, (NSUInteger)1);
	[theme setScheme:NVThemeSchemeCustom];
	custom = @[[NSColor greenColor], [NSColor yellowColor]];
	[theme customColorsDidChange];
	XCTAssertEqual(notifications, (NSUInteger)3);
}

@end
