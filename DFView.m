//
//  DFView.m
//  Notation
//
//  Created by ElasticThreads on 2/15/11.
//

#import "DFView.h"
#import "AppController.h"
#import "NVTheme.h"


@implementation DFView

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {        
        if (!vColor) {
            [self setBackgroundColor:[[NVTheme currentTheme] backgroundColor]];
        }
        // Initialization code here.
    }
    return self;
}

- (void)setBackgroundColor:(NSColor *)inColor{
    CGFloat fWhite;
	
	fWhite = [[inColor colorUsingColorSpace:[NSColorSpace genericGrayColorSpace]] whiteComponent];
	if (fWhite < 0.75f) {
		if (fWhite<0.25f) {
			fWhite += 0.22f;
		}else {
			fWhite += 0.16f;
		}		
	}else {
		fWhite -= 0.20f;
	}	
	vColor = [NSColor colorWithCalibratedWhite:fWhite alpha:1.0f];
}



@end
