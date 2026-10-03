//
//  ETScrollView.m
//  Notation
//

#import "ETScrollView.h"

@implementation ETScrollView

+ (NSScrollerKnobStyle)knobStyleForBackgroundColor:(NSColor *)color {
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    CGFloat red, green, blue, alpha;
    [rgb getRed:&red green:&green blue:&blue alpha:&alpha];
    CGFloat brightness = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    return brightness < 0.5 ? NSScrollerKnobStyleLight : NSScrollerKnobStyleDark;
}

+ (BOOL)isCompatibleWithResponsiveScrolling {
    // Selection and editor hit testing still require a separate parity review.
    return NO;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    if ([self.documentView isKindOfClass:[NSTableView class]]) {
        [self setAutohidesScrollers:YES];
    }
    [self setHorizontalScrollElasticity:NSScrollElasticityNone];
    [self setVerticalScrollElasticity:NSScrollElasticityAllowed];
    // The nib supplies an NSScroller. AppKit chooses its style from system settings.
}

@end
