//
//  AppControllerThemeTests.m
//  View ▸ Color Schemes (#5): the menu items switch the Theme and show its scheme, a
//  colour chosen in Settings switches to the custom scheme, and a Theme change recolours
//  the window's views from the Theme.
//

#import <XCTest/XCTest.h>
#import "AppController.h"
#import "LinkingEditor.h"
#import "NVTheme.h"

@interface AppController (ThemeTestAccess)
- (void)settingChangedForSelectorString:(NSString *)selectorString;
- (void)themeDidChange:(NSNotification *)notification;
@end

@interface AppControllerThemeTests : XCTestCase {
	AppController *app;
	id savedScheme;
	NVThemeScheme themeScheme;
}
@end

@implementation AppControllerThemeTests

//the app controller isn't initialized or loaded from its nib, only given the outlets used here;
//kept alive for the run, since its -dealloc expects a launched app
static NSMutableArray *KeptControllers;

- (void)setUp {
	[super setUp];
	savedScheme = [[NSUserDefaults standardUserDefaults] objectForKey:@"ColorScheme"];
	themeScheme = [[NVTheme currentTheme] scheme];
	app = [AppController alloc];
	if (!KeptControllers) KeptControllers = [NSMutableArray array];
	[KeptControllers addObject:app];
}

- (void)tearDown {
	[[NVTheme currentTheme] setScheme:themeScheme];
	if (savedScheme) [[NSUserDefaults standardUserDefaults] setObject:savedScheme forKey:@"ColorScheme"];
	else [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ColorScheme"];
	[super tearDown];
}

- (NSMenuItem *)itemFor:(SEL)action {
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"scheme" action:action keyEquivalent:@""];
	[item setTarget:app];
	XCTAssertTrue([(id<NSMenuItemValidation>)app validateMenuItem:item]);
	return item;
}

- (void)testTheMenuItemsSwitchTheSchemeAndShowIt {
	[app setLCColorScheme:nil];
	XCTAssertEqual([[NVTheme currentTheme] scheme], NVThemeSchemeLowContrast);
	XCTAssertEqual([[self itemFor:@selector(setLCColorScheme:)] state], NSControlStateValueOn);
	XCTAssertEqual([[self itemFor:@selector(setBWColorScheme:)] state], NSControlStateValueOff);
	XCTAssertEqual([[self itemFor:@selector(setUserColorScheme:)] state], NSControlStateValueOff);

	[app setBWColorScheme:nil];
	XCTAssertEqual([[NVTheme currentTheme] scheme], NVThemeSchemeLight);
	XCTAssertEqual([[self itemFor:@selector(setBWColorScheme:)] state], NSControlStateValueOn);
	XCTAssertEqual([[self itemFor:@selector(setLCColorScheme:)] state], NSControlStateValueOff);

	[app setUserColorScheme:nil];
	XCTAssertEqual([[NVTheme currentTheme] scheme], NVThemeSchemeCustom);
	XCTAssertEqual([[self itemFor:@selector(setUserColorScheme:)] state], NSControlStateValueOn);
	XCTAssertEqual([[NSUserDefaults standardUserDefaults] integerForKey:@"ColorScheme"], (NSInteger)NVThemeSchemeCustom);
}

- (void)testChoosingAColourInSettingsSwitchesToTheCustomScheme {
	[app setLCColorScheme:nil];
	[app settingChangedForSelectorString:@"setBackgroundTextColor:sender:"];
	XCTAssertEqual([[NVTheme currentTheme] scheme], NVThemeSchemeCustom);
}

- (void)testAThemeChangeRecoloursTheViews {
	NSTableView *list = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
	LinkingEditor *editor = [[LinkingEditor alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
	[app setValue:list forKey:@"notesTableView"];
	[app setValue:editor forKey:@"textView"];

	[[NVTheme currentTheme] setScheme:NVThemeSchemeLowContrast];
	[app themeDidChange:nil];
	XCTAssertEqualObjects([list backgroundColor], [[NVTheme currentTheme] backgroundColor]);
	XCTAssertEqualObjects([editor backgroundColor], [[NVTheme currentTheme] backgroundColor]);
	XCTAssertEqualObjects([list gridColor], [[NVTheme currentTheme] foregroundColor]);
}

@end
