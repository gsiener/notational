#import <XCTest/XCTest.h>
#import "ETScrollView.h"

@interface ETScrollViewTests : XCTestCase
@end

@implementation ETScrollViewTests

- (void)testListUsesNativeScrollerAndRetainsItsScrollConfiguration {
    ETScrollView *view = [[ETScrollView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];
    [view setDocumentView:table];
    [view setHasVerticalScroller:YES];
    [view awakeFromNib];
    XCTAssertEqual([view.verticalScroller class], [NSScroller class]);
    XCTAssertEqual(view.scrollerStyle, [NSScroller preferredScrollerStyle]);
    XCTAssertTrue(view.autohidesScrollers);
    XCTAssertEqual(view.horizontalScrollElasticity, NSScrollElasticityNone);
    XCTAssertEqual(view.verticalScrollElasticity, NSScrollElasticityAllowed);
}

- (void)testResponsiveScrollingRemainsDisabledPendingSelectionParity {
    XCTAssertFalse([ETScrollView isCompatibleWithResponsiveScrolling]);
}

- (void)testKnobContrastFollowsNoteBackground {
    XCTAssertEqual([ETScrollView knobStyleForBackgroundColor:[NSColor blackColor]], NSScrollerKnobStyleLight);
    XCTAssertEqual([ETScrollView knobStyleForBackgroundColor:[NSColor whiteColor]], NSScrollerKnobStyleDark);
}

- (void)testUnknownBackgroundUsesSystemKnobStyle {
    XCTAssertEqual([ETScrollView knobStyleForBackgroundColor:nil], NSScrollerKnobStyleDefault);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(2, 2)];
    NSColor *pattern = [NSColor colorWithPatternImage:image];
    XCTAssertNil([pattern colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]]);
    XCTAssertEqual([ETScrollView knobStyleForBackgroundColor:pattern], NSScrollerKnobStyleDefault);
}

@end
