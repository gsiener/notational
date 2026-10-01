//
//  NotationPrefsViewController.m
//  Notation
//

#import "NotationPrefsViewController.h"
#import "AppController_Simplenote.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"

static const CGFloat PaneWidth = 368, Margin = 20;

@interface NotationPrefsViewController () {
	id<NVNotesPaneAccount> account;
	NSView *view;
	NSTextField *accountLabel, *statusLabel;
	NSButton *secureTextEntryButton;
}
@end

@implementation NotationPrefsViewController

static NSTextField *Label(NSRect frame, NSString *text, NSFont *font) {
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setDrawsBackground:NO];
	[[label cell] setWraps:YES];
	[label setFont:font];
	[label setStringValue:text];
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
	[view release];
	[super dealloc];
}

- (NSView *)view {
	if (view) return view;

	NSFont *small = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
	NSFont *bold = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
	CGFloat width = PaneWidth - 2 * Margin;
	view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, PaneWidth, 250)];

	//laid out top-down
	[view addSubview:Label(NSMakeRect(Margin, 214, width, 18), NSLocalizedString(@"Simplenote", nil), bold)];

	accountLabel = Label(NSMakeRect(Margin, 172, width, 36), @"", [NSFont systemFontOfSize:[NSFont systemFontSize]]);
	[view addSubview:accountLabel];

	statusLabel = Label(NSMakeRect(Margin, 152, width, 18), @"", small);
	[statusLabel setTextColor:[NSColor secondaryLabelColor]];
	[view addSubview:statusLabel];

	NSButton *accountButton = [[[NSButton alloc] initWithFrame:NSMakeRect(Margin - 6, 112, 200, 32)] autorelease];
	[accountButton setBezelStyle:NSBezelStyleRounded];
	[accountButton setTitle:NSLocalizedString(@"Simplenote Account…", nil)];
	[accountButton setTarget:self];
	[accountButton setAction:@selector(showAccount:)];
	[view addSubview:accountButton];

	NSBox *separator = [[[NSBox alloc] initWithFrame:NSMakeRect(Margin, 96, width, 1)] autorelease];
	[separator setBoxType:NSBoxSeparator];
	[view addSubview:separator];

	secureTextEntryButton = [[[NSButton alloc] initWithFrame:NSMakeRect(Margin, 62, width, 20)] autorelease];
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
