//
//  ETScrollView.m
//  Notation
//
//  Created by elasticthreads on 3/14/11.
//

#import <Foundation/Foundation.h>



@interface ETScrollView : NSScrollView {
    Class scrollerClass;
}

//- (void)setNeedsOverlayTiling:(BOOL)overlay;
//- (void)setScrollerClassWithString:(NSString *)scrollerClassName;
- (void)changeUseETScrollbarsOnLion;
- (void)settingChangedForSelectorString:(NSString*)selectorString;

@end
