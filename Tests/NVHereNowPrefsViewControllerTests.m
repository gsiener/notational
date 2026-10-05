//
//  NVHereNowPrefsViewControllerTests.m
//  The here.now section of Settings ▸ Notes: connect, refresh and disconnect live here, not in a menu.
//  A fake source stands in for NVHereNowSites, since connecting with a real key writes to Keychain.
//

#import <XCTest/XCTest.h>
#import "NVHereNowPrefsViewController.h"
#import "NotationPrefsViewController.h"

@interface FakeHereNowSettingsSource : NSObject <NVHereNowSettingsSource>
@property (nonatomic, copy) NSString *status;
@property (nonatomic) BOOL connected;
@property (nonatomic, copy) NSString *keyReceived;
@property (nonatomic, strong) NSError *connectError;
@property (nonatomic) NSUInteger refreshes, disconnects;
@end

@implementation FakeHereNowSettingsSource
- (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:NVHereNowSitesDidChangeNotification object:self]; }
- (void)connectWithKey:(NSString *)key completion:(void (^)(NSError *))completion {
	self.keyReceived = key;
	if (!self.connectError) { self.connected = YES; self.status = @"3 Sites"; [self changed]; }
	completion(self.connectError);
}
- (void)disconnect { self.disconnects++; self.connected = NO; self.status = @"Not connected"; [self changed]; }
- (void)refresh { self.refreshes++; }
@end

@interface HereNowPaneAccount : NSObject <NVNotesPaneAccount>
@property (nonatomic, strong) NVHereNowSites *sites;
@end
@implementation HereNowPaneAccount
- (NSString *)simplenoteAccountEmail { return nil; }
- (NVSyncStatus)simplenoteSyncStatus { return NVSyncStatusSignedOut; }
- (NSError *)simplenoteLastError { return nil; }
- (void)simplenoteAccountDidSignInAs:(NSString *)anEmail token:(NSString *)token completion:(void (^)(BOOL, NSError *))completion { completion(YES, nil); }
- (void)simplenoteAccountSignOut {}
- (void)simplenoteSyncNow {}
- (void)showSimplenoteAccount:(id)sender {}
- (NVHereNowSites *)hereNowSites { return self.sites; }
@end

@interface NVHereNowPrefsViewControllerTests : XCTestCase {
	FakeHereNowSettingsSource *source;
	NVHereNowPrefsViewController *controller;
}
@end

@implementation NVHereNowPrefsViewControllerTests

- (void)setUp {
	[super setUp];
	source = [FakeHereNowSettingsSource new];
	source.status = @"Not connected";
	controller = [[NVHereNowPrefsViewController alloc] initWithSource:source];
	[controller view];
}

- (void)testNotConnectedOffersOnlyConnect {
	XCTAssertEqualObjects(controller.statusField.stringValue, @"Not connected");
	XCTAssertTrue(controller.keyField.enabled);
	XCTAssertTrue(controller.connectButton.enabled);
	XCTAssertFalse(controller.refreshButton.enabled);
	XCTAssertFalse(controller.disconnectButton.enabled);
}

- (void)testConnectWithoutAKeyDoesNothing {
	controller.keyField.stringValue = @"   ";
	[controller connect:nil];
	XCTAssertNil(source.keyReceived);
}

- (void)testConnectingSendsTheTrimmedKeyAndSwitchesToConnected {
	controller.keyField.stringValue = @" key-123\n";
	[controller connect:nil];
	XCTAssertEqualObjects(source.keyReceived, @"key-123");
	XCTAssertEqualObjects(controller.keyField.stringValue, @"", @"the key isn't left in the field");
	XCTAssertEqualObjects(controller.statusField.stringValue, @"3 Sites");
	XCTAssertFalse(controller.connectButton.enabled);
	XCTAssertTrue(controller.refreshButton.enabled);
	XCTAssertTrue(controller.disconnectButton.enabled);
}

- (void)testAFailedConnectionIsShownInThePane {
	source.connectError = [NSError errorWithDomain:@"test" code:401 userInfo:@{NSLocalizedDescriptionKey: @"here.now rejected the API key."}];
	controller.keyField.stringValue = @"bad";
	[controller connect:nil];
	XCTAssertEqualObjects(controller.errorField.stringValue, @"here.now rejected the API key.");
	XCTAssertTrue(controller.connectButton.enabled, @"so the key can be corrected and tried again");
}

- (void)testRefreshAndDisconnectGoToTheSource {
	controller.keyField.stringValue = @"key";
	[controller connect:nil];
	[controller refresh:nil];
	XCTAssertEqual(source.refreshes, (NSUInteger)1);
	[controller disconnect:nil];
	XCTAssertEqual(source.disconnects, (NSUInteger)1);
	XCTAssertTrue(controller.connectButton.enabled);
	XCTAssertFalse(controller.disconnectButton.enabled);
}

- (void)testTheNotesPaneShowsTheSectionWhenTheAppHasHereNow {
	HereNowPaneAccount *account = [HereNowPaneAccount new];
	NotationPrefsViewController *withoutSites = [[NotationPrefsViewController alloc] initWithAccount:account];
	CGFloat plainHeight = NSHeight([[withoutSites view] frame]);
	account = [HereNowPaneAccount new];
	account.sites = [[NVHereNowSites alloc] initWithTransport:nil cacheURL:nil];
	NotationPrefsViewController *pane = [[NotationPrefsViewController alloc] initWithAccount:account];
	NSView *view = [pane view];
	XCTAssertGreaterThan(NSHeight([view frame]), plainHeight);
	BOOL found = NO;
	for (NSView *subview in [view subviews])
		for (NSView *inner in [subview subviews])
			if ([inner isKindOfClass:[NSButton class]] && [[(NSButton *)inner title] isEqualToString:@"Connect"]) found = YES;
	XCTAssertTrue(found, @"the here.now Connect button is in the Notes pane");
}

@end
