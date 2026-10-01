//
//  NotationPrefsViewControllerTests.m
//  The "Notes" preferences pane: shows the Simplenote account and opens its window (#22).
//

#import <XCTest/XCTest.h>
#import "NotationPrefsViewController.h"

@interface FakeAccountApp : NSObject <NVNotesPaneAccount>
@property (nonatomic, copy) NSString *email;
@property (nonatomic, assign) NVSyncStatus status;
@property (nonatomic, assign) NSUInteger accountWindowRequests;
@end

@implementation FakeAccountApp
@synthesize email, status, accountWindowRequests;
- (NSString *)simplenoteAccountEmail { return email; }
- (NVSyncStatus)simplenoteSyncStatus { return status; }
- (NSError *)simplenoteLastError { return nil; }
- (BOOL)simplenoteAccountWillSignInAs:(NSString *)anEmail { return YES; }
- (void)simplenoteAccountDidSignInAs:(NSString *)anEmail token:(NSString *)token {}
- (void)simplenoteAccountSignOut {}
- (void)simplenoteSyncNow {}
- (void)showSimplenoteAccount:(id)sender { accountWindowRequests++; }
@end

@interface NotationPrefsViewControllerTests : XCTestCase {
	FakeAccountApp *app;
	NotationPrefsViewController *controller;
}
@end

@implementation NotationPrefsViewControllerTests

- (void)setUp {
	[super setUp];
	app = [[FakeAccountApp alloc] init];
	controller = [[NotationPrefsViewController alloc] initWithAccount:app];
}

- (void)tearDown {
	controller = nil;
	app = nil;
	[super tearDown];
}

static NSArray *SubviewsOfClass(NSView *view, Class cls) {
	NSMutableArray *found = [NSMutableArray array];
	for (NSView *subview in [view subviews]) if ([subview isKindOfClass:cls]) [found addObject:subview];
	return found;
}

static NSString *AllText(NSView *view) {
	NSMutableArray *strings = [NSMutableArray array];
	for (NSTextField *field in SubviewsOfClass(view, [NSTextField class])) [strings addObject:[field stringValue]];
	return [strings componentsJoinedByString:@"\n"];
}

static NSButton *ButtonTitled(NSView *view, NSString *title) {
	for (NSButton *button in SubviewsOfClass(view, [NSButton class])) if ([[button title] isEqualToString:title]) return button;
	return nil;
}

- (void)testSignedOutPaneSaysSo {
	NSString *text = AllText([controller view]);
	XCTAssertTrue([text rangeOfString:@"Not signed in"].location != NSNotFound, @"%@", text);
}

- (void)testSignedInPaneShowsAccountAndStatus {
	[app setEmail:@"someone@example.com"];
	[app setStatus:NVSyncStatusIdle];
	[controller view];
	[controller refresh];
	NSString *text = AllText([controller view]);
	XCTAssertTrue([text rangeOfString:@"someone@example.com"].location != NSNotFound, @"%@", text);
	XCTAssertTrue([text rangeOfString:NVSyncStatusDescription(NVSyncStatusIdle, nil)].location != NSNotFound, @"%@", text);
}

- (void)testAccountButtonOpensTheAccountWindow {
	NSButton *button = ButtonTitled([controller view], @"Simplenote Account…");
	XCTAssertNotNil(button);
	[button performClick:nil];
	XCTAssertEqual([app accountWindowRequests], (NSUInteger)1);
}

- (void)testControlsDoNotOverlap {
	//#22: the old account button was drawn over the tab bar and never got the click
	NSArray *subviews = [[controller view] subviews];
	for (NSUInteger i = 0; i < [subviews count]; i++) {
		NSRect frame = [[subviews objectAtIndex:i] frame];
		XCTAssertTrue(NSContainsRect([[controller view] bounds], frame), @"%@ outside the pane", [subviews objectAtIndex:i]);
		for (NSUInteger j = i + 1; j < [subviews count]; j++)
			XCTAssertFalse(NSIntersectsRect(frame, [[subviews objectAtIndex:j] frame]),
						   @"%@ overlaps %@", [subviews objectAtIndex:i], [subviews objectAtIndex:j]);
	}
}

- (void)testOnlySecureTextEntryRemainsAsASetting {
	NSUInteger checkboxes = 0;
	for (NSButton *button in SubviewsOfClass([controller view], [NSButton class]))
		if ([[button title] isEqualToString:@"Secure Text Entry"]) checkboxes++;
	XCTAssertEqual(checkboxes, (NSUInteger)1);
	XCTAssertNil(ButtonTitled([controller view], @"Turn On Note Encryption..."));
}

@end
