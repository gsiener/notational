//
//  NVTheme.h
//  Notation
//
//  The colour scheme: View ▸ Color Schemes (light, low contrast, or the user's own
//  colours from Settings ▸ Fonts & Colors) and the text and background colours it gives.
//  Views and models ask the Theme for colours instead of the app delegate (#5) and
//  listen for NVThemeDidChangeNotification.
//

#import <Cocoa/Cocoa.h>

extern NSString *const NVThemeDidChangeNotification;

typedef enum {
	NVThemeSchemeLight = 0,        //near-black on near-white
	NVThemeSchemeLowContrast = 1,  //dark grey on light grey
	NVThemeSchemeCustom = 2,       //the colours chosen in Settings
} NVThemeScheme;

@interface NVTheme : NSObject

//the app's theme, stored in the standard user defaults (ColorScheme) with GlobalPrefs' colours
+ (NVTheme *)currentTheme;

//a theme on the given defaults; customColors supplies the Settings colours (foreground, background)
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
					customColors:(NSArray *(^)(void))customColors;

@property (nonatomic, readonly) NVThemeScheme scheme;
@property (nonatomic, readonly) NSColor *foregroundColor;
@property (nonatomic, readonly) NSColor *backgroundColor;

//switches and remembers the scheme; posts NVThemeDidChangeNotification
- (void)setScheme:(NVThemeScheme)scheme;

//the Settings colours changed: choosing one means using it, so this switches to the custom
//scheme with the new colours; posts NVThemeDidChangeNotification
- (void)customColorsDidChange;

@end
