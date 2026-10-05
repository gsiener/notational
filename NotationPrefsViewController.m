//
//  NotationPrefsViewController.m
//  Notation
//

#import "NotationPrefsViewController.h"
#import "AppController_Simplenote.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NVHereNowPrefsViewController.h"

static const CGFloat PaneWidth = 368, Margin = 20;

@interface NotationPrefsViewController () {
	__weak id<NVNotesPaneAccount> account;
	NSView *view;
	NSTextField *accountLabel, *statusLabel;
	NSButton *secureTextEntryButton;
	NVHereNowPrefsViewController *hereNow;
}
@end

@implementation NotationPrefsViewController

static NSTextField *Label(NSRect frame, NSString *text, NSFont *font) {
	NSTextField *label = [NSTextField wrappingLabelWithString:text];
	[label setFrame:frame];
	[label setFont:font];
	//a wrapping label is selectable and uses the (slightly lighter) label colour by default
	[label setSelectable:NO];
	[label setTextColor:[NSColor controlTextColor]];
	return label;
}

- (id)initWithAccount:(id<NVNotesPaneAccount>)anAccount {
	if ((self = [super init])) {
		account = anAccount;
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh)
													 name:NVSyncStatusDidChangeNotification object:nil];
		[[GlobalPrefs defaultPrefs] registerForSettingChange:@selector(setNotationPrefs:sender:) withTarget:self];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSView *)view {
	if (view) return view;

	NSFont *small = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	NSFont *bold = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
	CGFloat width = PaneWidth - 2 * Margin;
	//the here.now section goes between Simplenote and Secure Text Entry, raising everything above it
	id<NVHereNowSettingsSource> sites = [account respondsToSelector:@selector(hereNowSites)] ? [account hereNowSites] : nil;
	if (sites) hereNow = [[NVHereNowPrefsViewController alloc] initWithSource:sites];
	CGFloat raise = hereNow ? NSHeight([[hereNow view] frame]) + 24 : 0;
	view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, PaneWidth, 250 + raise)];

	//laid out top-down
	[view addSubview:Label(NSMakeRect(Margin, 214 + raise, width, 18), NSLocalizedString(@"Simplenote", nil), bold)];

	accountLabel = Label(NSMakeRect(Margin, 172 + raise, width, 36), @"", [NSFont systemFontOfSize:[NSFont systemFontSize]]);
	[view addSubview:accountLabel];

	statusLabel = Label(NSMakeRect(Margin, 152 + raise, width, 18), @"", small);
	[statusLabel setTextColor:[NSColor secondaryLabelColor]];
	[view addSubview:statusLabel];

	NSButton *accountButton = [[NSButton alloc] initWithFrame:NSMakeRect(Margin - 6, 112 + raise, 200, 32)];
	[accountButton setBezelStyle:NSBezelStyleRounded];
	[accountButton setTitle:NSLocalizedString(@"Simplenote Account…", nil)];
	[accountButton setTarget:self];
	[accountButton setAction:@selector(showAccount:)];
	[view addSubview:accountButton];

	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(Margin, 96 + raise, width, 1)];
	[separator setBoxType:NSBoxSeparator];
	[view addSubview:separator];

	if (hereNow) {
		NSView *section = [hereNow view];
		[section setFrameOrigin:NSMakePoint(0, 96 + 12)];
		[view addSubview:section];
		NSBox *below = [[NSBox alloc] initWithFrame:NSMakeRect(Margin, 96, width, 1)];
		[below setBoxType:NSBoxSeparator];
		[view addSubview:below];
	}

	secureTextEntryButton = [[NSButton alloc] initWithFrame:NSMakeRect(Margin, 62, width, 20)];
	[secureTextEntryButton setButtonType:NSButtonTypeSwitch];
	[secureTextEntryButton setTitle:NSLocalizedString(@"Secure Text Entry", nil)];
	[secureTextEntryButton setTarget:self];
	[secureTextEntryButton setAction:@selector(changedSecureTextEntry:)];
	[view addSubview:secureTextEntryButton];

	[view addSubview:Label(NSMakeRect(Margin + 18, 16, width - 18, 44),
						   NSLocalizedString(@"Keeps other apps from reading what you type while Notational is in front.", nil), small)];

	[self refresh];
	return view;
}

- (void)refresh {
	if (!view) return;
	NSString *email = [account simplenoteAccountEmail];
	NVSyncStatus status = email ? [account simplenoteSyncStatus] : NVSyncStatusSignedOut;

	if (!email) {
		[accountLabel setStringValue:NSLocalizedString(@"Not signed in. Sign in to sync your notes with Simplenote.", nil)];
		[statusLabel setStringValue:@""];
	} else {
		[accountLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Notes sync with %@.", nil), email]];
		[statusLabel setStringValue:NVSyncStatusDescription(status, [account simplenoteLastError])];
	}
	[secureTextEntryButton setState:[[[GlobalPrefs defaultPrefs] notationPrefs] secureTextEntry]];
}

- (void)settingChangedForSelectorString:(NSString *)selectorString {
	if ([selectorString isEqualToString:SEL_STR(setNotationPrefs:sender:)]) [self refresh];
}

- (IBAction)showAccount:(id)sender {
	[account showSimplenoteAccount:sender];
}

- (IBAction)changedSecureTextEntry:(id)sender {
	[[[GlobalPrefs defaultPrefs] notationPrefs] setSecureTextEntry:[secureTextEntryButton state]];
}

@end
