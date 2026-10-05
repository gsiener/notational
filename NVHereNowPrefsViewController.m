//
//  NVHereNowPrefsViewController.m
//  Notation
//

#import "NVHereNowPrefsViewController.h"

//laid out top-down
@interface NVHereNowPrefsView : NSView
@end
@implementation NVHereNowPrefsView
- (BOOL)isFlipped { return YES; }
@end

@interface NVHereNowPrefsViewController () {
	id<NVHereNowSettingsSource> source;
	BOOL connecting;
}
@property(readwrite) NSTextField *statusField, *errorField;
@property(readwrite) NSSecureTextField *keyField;
@property(readwrite) NSButton *connectButton, *refreshButton, *disconnectButton;
@end

@implementation NVHereNowPrefsViewController

- (instancetype)initWithSource:(id<NVHereNowSettingsSource>)aSource {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		source = aSource;
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sourceChanged:)
													 name:NVHereNowSitesDidChangeNotification object:aSource];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

static const CGFloat Width = 368, Margin = 20;

static NSTextField *Label(NSString *text, NSRect frame, NSFont *font) {
	NSTextField *label = [NSTextField wrappingLabelWithString:text];
	label.frame = frame;
	label.font = font;
	label.selectable = NO;
	label.textColor = [NSColor controlTextColor];
	return label;
}

static NSButton *Button(NSString *title, NSRect frame, id target, SEL action) {
	NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
	button.frame = frame;
	return button;
}

- (void)loadView {
	//styled like the Simplenote section of the Notes pane, which it sits in
	NSFont *small = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	CGFloat width = Width - 2 * Margin;
	NSView *view = [[NVHereNowPrefsView alloc] initWithFrame:NSMakeRect(0, 0, Width, 172)];

	[view addSubview:Label(@"here.now", NSMakeRect(Margin, 0, width, 18), [NSFont boldSystemFontOfSize:[NSFont systemFontSize]])];

	NSTextField *about = Label(@"Show your here.now Sites, read-only, in the Notes list. "
							   "The API key is kept in Keychain and used only to list Sites.", NSMakeRect(Margin, 22, width, 30), small);
	about.textColor = [NSColor secondaryLabelColor];
	[view addSubview:about];

	self.statusField = Label(@"", NSMakeRect(Margin, 58, width, 18), [NSFont systemFontOfSize:[NSFont systemFontSize]]);
	self.statusField.maximumNumberOfLines = 1;
	self.statusField.lineBreakMode = NSLineBreakByTruncatingTail;
	[view addSubview:self.statusField];

	self.keyField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(Margin, 84, 214, 22)];
	self.keyField.target = self;
	self.keyField.action = @selector(connect:);
	[view addSubview:self.keyField];
	self.connectButton = Button(@"Connect", NSMakeRect(Margin + 218, 79, 112, 32), self, @selector(connect:));
	[view addSubview:self.connectButton];

	self.errorField = Label(@"", NSMakeRect(Margin, 110, width, 28), small);
	self.errorField.textColor = [NSColor systemRedColor];
	self.errorField.maximumNumberOfLines = 2;
	[view addSubview:self.errorField];

	self.refreshButton = Button(@"Refresh Now", NSMakeRect(Margin - 6, 138, 124, 32), self, @selector(refresh:));
	[view addSubview:self.refreshButton];
	self.disconnectButton = Button(@"Disconnect", NSMakeRect(Margin + 118, 138, 112, 32), self, @selector(disconnect:));
	[view addSubview:self.disconnectButton];

	self.view = view;
	[self update];
}

- (void)update {
	BOOL connected = [source connected];
	self.statusField.stringValue = connecting ? @"Connecting…" : ([source status] ?: @"");
	self.keyField.enabled = !connected && !connecting;
	self.keyField.placeholderString = connected ? @"Stored in Keychain" : @"Paste a here.now API key";
	self.connectButton.enabled = !connected && !connecting;
	self.refreshButton.enabled = connected && !connecting;
	self.disconnectButton.enabled = connected && !connecting;
}

- (void)sourceChanged:(NSNotification *)notification {
	if ([NSThread isMainThread]) [self update];
	else dispatch_async(dispatch_get_main_queue(), ^{ [self update]; });
}

- (IBAction)connect:(id)sender {
	NSString *key = [self.keyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (![key length] || connecting || [source connected]) return;
	connecting = YES;
	self.errorField.stringValue = @"";
	[self update];
	__weak NVHereNowPrefsViewController *weakSelf = self;
	[source connectWithKey:key completion:^(NSError *error) {
		dispatch_block_t finish = ^{
			NVHereNowPrefsViewController *strongSelf = weakSelf;
			if (!strongSelf) return;
			strongSelf->connecting = NO;
			if (error) strongSelf.errorField.stringValue = error.localizedDescription ?: @"Could not connect to here.now.";
			else strongSelf.keyField.stringValue = @"";
			[strongSelf update];
		};
		if ([NSThread isMainThread]) finish(); else dispatch_async(dispatch_get_main_queue(), finish);
	}];
}

- (IBAction)refresh:(id)sender {
	self.errorField.stringValue = @"";
	[source refresh];
}

- (IBAction)disconnect:(id)sender {
	self.errorField.stringValue = @"";
	[source disconnect];
	[self update];
}

@end
