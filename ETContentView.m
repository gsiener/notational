//
//  ETContentView.m
//  Notation
//
//  Created by elasticthreads on 3/15/11.
//

#import "ETContentView.h"
#import "AppController.h"
#import "NVTheme.h"

@implementation ETContentView

//- (id)initWithFrame:(NSRect)frame
//{
//    self = [super initWithFrame:frame];
//    if (self) {
//        // Initialization code here.
//    }
//    
//    return self;
//}
//
- (void)drawRect:(NSRect)dirtyRect
{
//    [super drawRect:dirtyRect];
    if (!backColor) {
        backColor = [[NVTheme currentTheme] backgroundColor];
    }
    [backColor set];
    NSRectFill([self bounds]);
    
}

- (void)setBackgroundColor:(NSColor *)inCol{
    if (backColor) {
    }
    backColor = inCol;
}

- (NSColor *)backgroundColor{    
    if (!backColor) {
        backColor = [[NVTheme currentTheme] backgroundColor];
    }
    return backColor;
}

@end
