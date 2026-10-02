//
//  NVArchivingTests.m
//  NotationTests
//
//  Preferences saved by nvALT are NSArchiver typedstreams; this app writes keyed archives. Both must load.
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "NVArchiving.h"

@interface NVArchivingTests : XCTestCase
@end

@implementation NVArchivingTests

//an NSArchiver typedstream, as nvALT stored in user defaults
- (NSData *)legacyArchivedObject:(id)object {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return [NSArchiver archivedDataWithRootObject:object];
#pragma clang diagnostic pop
}

- (void)testDecodesKeyedArchivedColor {
	NSColor *color = [NSColor colorWithCalibratedRed:0.945 green:0.702 blue:0.702 alpha:1.0];
	NSData *data = NVKeyedArchivedData(color);
	XCTAssertNotNil(data);
	NSColor *decoded = NVUnarchivePreferenceValue(data);
	XCTAssertTrue([decoded isKindOfClass:[NSColor class]]);
	XCTAssertEqualWithAccuracy([[decoded colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] redComponent],
							   [[color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] redComponent], 0.001);
}

- (void)testDecodesLegacyArchivedColor {
	NSData *data = [self legacyArchivedObject:[NSColor colorWithCalibratedRed:1.0 green:0.0 blue:0.0 alpha:1.0]];
	XCTAssertNotNil(data);
	NSColor *decoded = NVUnarchivePreferenceValue(data);
	XCTAssertTrue([decoded isKindOfClass:[NSColor class]]);
	XCTAssertEqualWithAccuracy([[decoded colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]] redComponent], 1.0, 0.001);
}

- (void)testDecodesKeyedArchivedFont {
	NSFont *font = [NSFont fontWithName:@"Helvetica" size:14.0];
	NSFont *decoded = NVUnarchivePreferenceValue(NVKeyedArchivedData(font));
	XCTAssertTrue([decoded isKindOfClass:[NSFont class]]);
	XCTAssertEqualObjects([decoded fontName], [font fontName]);
	XCTAssertEqual([decoded pointSize], 14.0);
}

- (void)testDecodesLegacyArchivedFont {
	NSFont *font = [NSFont fontWithName:@"Helvetica" size:14.0];
	NSFont *decoded = NVUnarchivePreferenceValue([self legacyArchivedObject:font]);
	XCTAssertTrue([decoded isKindOfClass:[NSFont class]]);
	XCTAssertEqualObjects([decoded fontName], [font fontName]);
	XCTAssertEqual([decoded pointSize], 14.0);
}

- (void)testGarbageAndEmptyDataDecodeToNil {
	XCTAssertNil(NVUnarchivePreferenceValue(nil));
	XCTAssertNil(NVUnarchivePreferenceValue([NSData data]));
	XCTAssertNil(NVUnarchivePreferenceValue([@"this is not an archive" dataUsingEncoding:NSUTF8StringEncoding]));
	XCTAssertNil(NVUnarchivePreferenceValue([NSData dataWithBytes:"\x04\x0bstreamtyped garbage" length:20]));
}

- (void)testUnarchiveKeyedObjectRejectsLegacyData {
	XCTAssertNil(NVUnarchiveKeyedObject([self legacyArchivedObject:[NSColor redColor]]));
	XCTAssertNotNil(NVUnarchiveKeyedObject(NVKeyedArchivedData(@[ @"a", @"b" ])));
}

@end
