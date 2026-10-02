//
//  NVSplitViewTests.m
//  The main split view (#12): reading the divider position RBSplitView saved.
//

#import <XCTest/XCTest.h>
#import "NVSplitView.h"

@interface NVSplitViewTests : XCTestCase
@end

@implementation NVSplitViewTests

- (void)testSideBySideStateBecomesFramesWithTheSameListWidth {
	NSArray *frames = [NVSplitView savedFramesFromLegacyState:@"2 230.25 569.75" vertical:YES
														  size:NSMakeSize(808, 500) dividerThickness:8];
	XCTAssertEqualObjects(frames, (@[@"0.000000, 0.000000, 230.000000, 500.000000, NO, NO",
									 @"238.000000, 0.000000, 570.000000, 500.000000, NO, NO"]));
}

- (void)testStackedStateBecomesFramesWithTheSameListHeight {
	NSArray *frames = [NVSplitView savedFramesFromLegacyState:@"2 150.5 349.5" vertical:NO
														  size:NSMakeSize(700, 508) dividerThickness:8];
	XCTAssertEqualObjects(frames, (@[@"0.000000, 0.000000, 700.000000, 150.000000, NO, NO",
									 @"0.000000, 158.000000, 700.000000, 350.000000, NO, NO"]));
}

- (void)testCollapsedListKeepsItsDimensionAndIsMarkedCollapsed {
	NSArray *frames = [NVSplitView savedFramesFromLegacyState:@"2 -200.3 800" vertical:YES
														  size:NSMakeSize(1000, 600) dividerThickness:5];
	XCTAssertEqualObjects(frames, (@[@"0.000000, 0.000000, 200.000000, 600.000000, YES, NO",
									 @"5.000000, 0.000000, 995.000000, 600.000000, NO, NO"]));
}

- (void)testListWiderThanTheWindowLeavesRoomForTheEditor {
	NSArray *frames = [NVSplitView savedFramesFromLegacyState:@"2 900 100" vertical:YES
														  size:NSMakeSize(500, 400) dividerThickness:8];
	XCTAssertEqualObjects([frames objectAtIndex:0], @"0.000000, 0.000000, 491.000000, 400.000000, NO, NO");
}

- (void)testGarbageStatesAreIgnored {
	NSSize size = NSMakeSize(800, 600);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:nil vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"" vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"garbage" vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"3 100 200 300" vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"2 abc 500" vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"2 100x 500" vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"2 100" vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:(id)@42 vertical:YES size:size dividerThickness:8]);
	XCTAssertNil([NVSplitView savedFramesFromLegacyState:@"2 100 500" vertical:YES size:NSZeroSize dividerThickness:8]);
}

- (void)testLegacyKeyIsKeyedByDividerOrientation {
	XCTAssertEqualObjects([NVSplitView legacyDefaultsKeyForName:@"centralSplitView" vertical:YES], @"RBSplitView V centralSplitView");
	XCTAssertEqualObjects([NVSplitView legacyDefaultsKeyForName:@"centralSplitView" vertical:NO], @"RBSplitView H centralSplitView");
	XCTAssertEqualObjects([NVSplitView defaultsKeyForAutosaveName:@"x"], @"NSSplitView Subview Frames x");
}

- (NSUserDefaults *)freshDefaults {
	return [[NSUserDefaults alloc] initWithSuiteName:[@"NVSplitViewTests-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
}

- (void)testMigrationWritesTheNewKeyOnce {
	NSUserDefaults *defaults = [self freshDefaults];
	[defaults setObject:@"2 240.5 700" forKey:@"RBSplitView V central"];
	BOOL migrated = [NVSplitView migrateLegacyStateNamed:@"central" toAutosaveName:@"central V" vertical:YES
													size:NSMakeSize(900, 600) dividerThickness:8 defaults:defaults];
	XCTAssertTrue(migrated);
	XCTAssertEqualObjects([defaults arrayForKey:@"NSSplitView Subview Frames central V"],
						  (@[@"0.000000, 0.000000, 240.000000, 600.000000, NO, NO",
							 @"248.000000, 0.000000, 652.000000, 600.000000, NO, NO"]));

	//a second launch keeps what NSSplitView has saved since
	[defaults setObject:@[@"saved"] forKey:@"NSSplitView Subview Frames central V"];
	XCTAssertFalse([NVSplitView migrateLegacyStateNamed:@"central" toAutosaveName:@"central V" vertical:YES
												   size:NSMakeSize(900, 600) dividerThickness:8 defaults:defaults]);
	XCTAssertEqualObjects([defaults arrayForKey:@"NSSplitView Subview Frames central V"], @[@"saved"]);
}

- (void)testMigrationUsesTheKeyForTheCurrentOrientation {
	NSUserDefaults *defaults = [self freshDefaults];
	[defaults setObject:@"2 240 700" forKey:@"RBSplitView V central"];
	XCTAssertFalse([NVSplitView migrateLegacyStateNamed:@"central" toAutosaveName:@"central H" vertical:NO
												   size:NSMakeSize(900, 600) dividerThickness:8 defaults:defaults]);
	XCTAssertNil([defaults objectForKey:@"NSSplitView Subview Frames central H"]);
}

- (void)testMigrationIgnoresGarbageAndMissingState {
	NSUserDefaults *defaults = [self freshDefaults];
	XCTAssertFalse([NVSplitView migrateLegacyStateNamed:@"central" toAutosaveName:@"central V" vertical:YES
												   size:NSMakeSize(900, 600) dividerThickness:8 defaults:defaults]);
	[defaults setObject:@"nonsense" forKey:@"RBSplitView V central"];
	XCTAssertFalse([NVSplitView migrateLegacyStateNamed:@"central" toAutosaveName:@"central V" vertical:YES
												   size:NSMakeSize(900, 600) dividerThickness:8 defaults:defaults]);
	XCTAssertNil([defaults objectForKey:@"NSSplitView Subview Frames central V"]);
}

@end
