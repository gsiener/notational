//
//  ETScrollView.m
//  Notation
//
//  Created by elasticthreads on 3/14/11.
//

#import "ETScrollView.h"
#import "ETOverlayScroller.h"
#import "GlobalPrefs.h"

@implementation ETScrollView


+ (BOOL)isCompatibleWithResponsiveScrolling{
    return NO;
}


- (void)awakeFromNib{
    if ([self.documentView isKindOfClass:[NSTableView class]]) {
        scrollerClass=NSClassFromString(@"ETOverlayScroller");
        [self setAutohidesScrollers:YES];
    }else{
        scrollerClass=NSClassFromString(@"ETTransparentScroller");
    }
    [[GlobalPrefs defaultPrefs] registerForSettingChange:@selector(setUseETScrollbarsOnLion:sender:) withTarget:self];
    [self setHorizontalScrollElasticity:NSScrollElasticityNone];
    [self setVerticalScrollElasticity:NSScrollElasticityAllowed];
    [self changeUseETScrollbarsOnLion];
}


- (void)settingChangedForSelectorString:(NSString*)selectorString{
    if ([selectorString isEqualToString:SEL_STR(setUseETScrollbarsOnLion:sender:)]){
        [self changeUseETScrollbarsOnLion];
    }
}

- (void)changeUseETScrollbarsOnLion{
    id theScroller;
    if ([[GlobalPrefs defaultPrefs]useETScrollbarsOnLion]) {
        theScroller=[[scrollerClass alloc]init];
        [theScroller setFillBackground:NO];
    }else{
        theScroller=[[NSScroller alloc]init];
    }
    NSScrollerStyle style=[[theScroller class] preferredScrollerStyle];
    [self setVerticalScroller:theScroller];

    [theScroller setScrollerStyle:style];
    [self setScrollerStyle:style];
    [self tile];
    [self reflectScrolledClipView:[self contentView]];
    //    [self flashScrollers];
}


@end
