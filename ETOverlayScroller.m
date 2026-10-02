//
//  ETOverlayScroller.m
//  Notation
//
//  Created by elasticthreads on 9/15/11.
//  Copyright 2011 elasticthreads. All rights reserved.
//

#import "ETOverlayScroller.h"

@implementation ETOverlayScroller

+ (BOOL)isCompatibleWithOverlayScrollers {
    return self == [ETOverlayScroller class];
}

- (void)setScrollerStyle:(NSScrollerStyle)newScrollerStyle{
    if (newScrollerStyle==NSScrollerStyleOverlay) {
        verticalPaddingLeft = 4.5f;
    }else{
        verticalPaddingLeft = 4.0f;
    }
    [super setScrollerStyle:newScrollerStyle];
}

+ (NSScrollerStyle)preferredScrollerStyle{
   
    return [[NSScroller class]preferredScrollerStyle];
}


- (id)initWithFrame:(NSRect)frameRect{
	if ((self=[super initWithFrame:frameRect])) {	
        verticalPaddingRight = 3.0f;
        if ([self scrollerStyle]==NSScrollerStyleOverlay) {
            verticalPaddingLeft = 4.5f;
        }else{
            verticalPaddingLeft = 4.0f;
        }
        knobAlpha=0.6f;
        slotAlpha=0.55f;
        fillBackground=NO;
//        isOverlay=YES;
	}
	return self;
}


@end
