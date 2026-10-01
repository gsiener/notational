//
//  NVTheme.m
//  Notation
//

#import "NVTheme.h"
#import "GlobalPrefs.h"

NSString *const NVThemeDidChangeNotification = @"NVThemeDidChangeNotification";
static NSString *const SchemeKey = @"ColorScheme";

@interface NVTheme () {
	NSUserDefaults *defaults;
	NSArray *(^customColors)(void);
}
@property (nonatomic, readwrite) NSColor *foregroundColor;
@property (nonatomic, readwrite) NSColor *backgroundColor;
@end

@implementation NVTheme

@synthesize scheme = _scheme;

+ (NVTheme *)currentTheme {
	static NVTheme *theme = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		theme = [[NVTheme alloc] initWithDefaults:[NSUserDefaults standardUserDefaults] customColors:^NSArray *{
			GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
			NSColor *fg = [prefs foregroundTextColor], *bg = [prefs backgroundTextColor];
			return (fg && bg) ? [NSArray arrayWithObjects:fg, bg, nil] : nil;
		}];
	});
	return theme;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)someDefaults customColors:(NSArray *(^)(void))someCustomColors {
	if ((self = [super init])) {
		defaults = someDefaults;
		customColors = [someCustomColors copy];
		NSInteger saved = [defaults integerForKey:SchemeKey];
		[self applyScheme:(saved == NVThemeSchemeLowContrast || saved == NVThemeSchemeCustom) ? (NVThemeScheme)saved : NVThemeSchemeLight];
	}
	return self;
}

- (void)applyScheme:(NVThemeScheme)newScheme {
	_scheme = newScheme;
	switch (newScheme) {
		case NVThemeSchemeLowContrast:
			self.foregroundColor = [NSColor colorWithCalibratedRed:0.2430 green:0.2430 blue:0.2430 alpha:1.0];
			self.backgroundColor = [NSColor colorWithCalibratedRed:0.902 green:0.902 blue:0.902 alpha:1.0];
			break;
		case NVThemeSchemeCustom: {
			NSArray *colors = customColors ? customColors() : nil;
			if ([colors count] == 2) {
				self.foregroundColor = [colors objectAtIndex:0];
				self.backgroundColor = [colors objectAtIndex:1];
				break;
			}
			//no colours saved yet: fall through to the light scheme's colours
		}
		default:
			self.foregroundColor = [[NSColor colorWithCalibratedWhite:0.02f alpha:1.0f] colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
			self.backgroundColor = [[NSColor colorWithCalibratedWhite:0.98f alpha:1.0f] colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
			break;
	}
}

- (void)setScheme:(NVThemeScheme)newScheme notify:(BOOL)notify {
	[defaults setInteger:newScheme forKey:SchemeKey];
	[self applyScheme:newScheme];
	if (notify) [[NSNotificationCenter defaultCenter] postNotificationName:NVThemeDidChangeNotification object:self];
}

- (void)setScheme:(NVThemeScheme)newScheme {
	[self setScheme:newScheme notify:YES];
}

- (void)customColorsDidChange {
	if (self.scheme == NVThemeSchemeCustom) [self setScheme:NVThemeSchemeCustom notify:YES];
}

@end
