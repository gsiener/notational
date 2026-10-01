//
//  NVSimplenoteAccountWindowController.m
//  Notation
//

#import "NVSimplenoteAccountWindowController.h"
#import "NVSimplenoteHTTPService.h"

typedef enum { StepEmail, StepCode, StepSignedIn } AccountStep;

@interface NVSimplenoteAccountWindowController () {
	NSTextField *messageLabel, *statusLabel;
	NSTextField *emailField, *codeField;
	NSButton *primaryButton, *secondaryButton;
	NSProgressIndicator *spinner;
	AccountStep step;
	NSString *pendingEmail;
	BOOL busy;
}
@end

@implementation NVSimplenoteAccountWindowController

@synthesize accountDelegate;

static NSTextField *Label(NSRect frame) {
	NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setDrawsBackground:NO];
	[[label cell] setWraps:YES];
	return label;
}

- (id)init {
	NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 210)
													styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
													  backing:NSBackingStoreBuffered defer:YES] autorelease];
	[window setTitle:NSLocalizedString(@"Simplenote Account", nil)];
	[window setReleasedWhenClosed:NO];
	if ((self = [super initWithWindow:window])) {
		NSView *content = [window contentView];

		messageLabel = Label(NSMakeRect(20, 130, 400, 60));
		[content addSubview:messageLabel];

		emailField = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 96, 400, 24)] autorelease];
		[[emailField cell] setPlaceholderString:NSLocalizedString(@"Email address", nil)];
		[content addSubview:emailField];

		codeField = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 96, 400, 24)] autorelease];
		[[codeField cell] setPlaceholderString:NSLocalizedString(@"Code from the email", nil)];
		[content addSubview:codeField];

		statusLabel = Label(NSMakeRect(20, 56, 400, 34));
		[statusLabel setTextColor:[NSColor secondaryLabelColor]];
		[statusLabel setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
		[content addSubview:statusLabel];

		primaryButton = [[[NSButton alloc] initWithFrame:NSMakeRect(270, 14, 156, 32)] autorelease];
		[primaryButton setBezelStyle:NSBezelStyleRounded];
		[primaryButton setKeyEquivalent:@"\r"];
		[primaryButton setTarget:self];
		[primaryButton setAction:@selector(primaryAction:)];
		[content addSubview:primaryButton];

		secondaryButton = [[[NSButton alloc] initWithFrame:NSMakeRect(120, 14, 150, 32)] autorelease];
		[secondaryButton setBezelStyle:NSBezelStyleRounded];
		[secondaryButton setTarget:self];
		[secondaryButton setAction:@selector(secondaryAction:)];
		[content addSubview:secondaryButton];

		spinner = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 22, 16, 16)] autorelease];
		[spinner setStyle:NSProgressIndicatorStyleSpinning];
		[spinner setControlSize:NSControlSizeSmall];
		[spinner setDisplayedWhenStopped:NO];
		[content addSubview:spinner];

		[window center];
	}
	return self;
}

- (void)dealloc {
	[pendingEmail release];
	[super dealloc];
}

- (void)setBusy:(BOOL)isBusy {
	busy = isBusy;
	if (busy) [spinner startAnimation:nil];
	else [spinner stopAnimation:nil];
	[primaryButton setEnabled:!busy];
	[secondaryButton setEnabled:!busy];
	[emailField setEnabled:!busy];
	[codeField setEnabled:!busy];
}

NSString *NVSyncStatusDescription(NVSyncStatus status, NSError *error) {
	switch (status) {
		case NVSyncStatusSyncing: return NSLocalizedString(@"Syncing…", nil);
		case NVSyncStatusOffline:
			return [NSString stringWithFormat:NSLocalizedString(@"Can't reach Simplenote right now; will keep trying. %@", nil),
					[error localizedDescription] ? [error localizedDescription] : @""];
		case NVSyncStatusSignedOut: return NSLocalizedString(@"Signed out. Sign in again to keep syncing.", nil);
		default: return NSLocalizedString(@"Up to date.", nil);
	}
}

- (void)showStep:(AccountStep)newStep {
	step = newStep;
	[emailField setHidden:step != StepEmail];
	[codeField setHidden:step != StepCode];
	[secondaryButton setHidden:NO];
	switch (step) {
		case StepEmail:
			[messageLabel setStringValue:NSLocalizedString(@"Sign in to keep your notes in sync with Simplenote. Simplenote will email you a sign-in code.", nil)];
			[primaryButton setTitle:NSLocalizedString(@"Email Me a Code", nil)];
			[secondaryButton setHidden:YES];
			if (![[emailField stringValue] length] && [accountDelegate simplenoteAccountEmail])
				[emailField setStringValue:[accountDelegate simplenoteAccountEmail]];
			[[self window] makeFirstResponder:emailField];
			break;
		case StepCode:
			[messageLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Enter the code Simplenote emailed to %@.", nil), pendingEmail]];
			[primaryButton setTitle:NSLocalizedString(@"Sign In", nil)];
			[secondaryButton setTitle:NSLocalizedString(@"Back", nil)];
			[codeField setStringValue:@""];
			[[self window] makeFirstResponder:codeField];
			break;
		case StepSignedIn:
			[messageLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Signed in to Simplenote as %@.", nil), [accountDelegate simplenoteAccountEmail]]];
			[primaryButton setTitle:NSLocalizedString(@"Sync Now", nil)];
			[secondaryButton setTitle:NSLocalizedString(@"Sign Out", nil)];
			break;
	}
}

- (void)refresh {
	[self window];
	if (busy || step == StepCode) return;
	NVSyncStatus status = [accountDelegate simplenoteSyncStatus];
	BOOL signedIn = [accountDelegate simplenoteAccountEmail] && status != NVSyncStatusSignedOut;
	[self showStep:signedIn ? StepSignedIn : StepEmail];
	[statusLabel setStringValue:signedIn ? NVSyncStatusDescription(status, [accountDelegate simplenoteLastError]) :
	 ([accountDelegate simplenoteAccountEmail] ? NVSyncStatusDescription(NVSyncStatusSignedOut, nil) : @"")];
}

- (void)runInBackground:(id (^)(NSError **error))work completion:(void (^)(id result, NSError *error))completion {
	[self setBusy:YES];
	[statusLabel setStringValue:@""];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSError *error = nil;
		id result = [work(&error) retain];
		[error retain];
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setBusy:NO];
			completion(result, error);
			[result release];
			[error release];
		});
	});
}

- (void)primaryAction:(id)sender {
	if (busy) return;
	if (step == StepEmail) {
		NSString *email = [[emailField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if ([email rangeOfString:@"@"].location == NSNotFound) {
			[statusLabel setStringValue:NSLocalizedString(@"Enter the email address of your Simplenote account.", nil)];
			return;
		}
		if (![accountDelegate simplenoteAccountWillSignInAs:email]) return;
		[pendingEmail release];
		pendingEmail = [email copy];
		[self runInBackground:^id(NSError **error) {
			NVSimplenoteAuthenticator *auth = [[[NVSimplenoteAuthenticator alloc] init] autorelease];
			return [auth requestCodeForEmail:email error:error] ? @YES : nil;
		} completion:^(id result, NSError *error) {
			if (result) [self showStep:StepCode];
			else [statusLabel setStringValue:[error localizedDescription] ? [error localizedDescription] : NSLocalizedString(@"Couldn't reach Simplenote.", nil)];
		}];
	} else if (step == StepCode) {
		NSString *code = [codeField stringValue];
		NSString *email = [[pendingEmail copy] autorelease];
		[self runInBackground:^id(NSError **error) {
			NVSimplenoteAuthenticator *auth = [[[NVSimplenoteAuthenticator alloc] init] autorelease];
			return [auth tokenForEmail:email code:code error:error];
		} completion:^(id token, NSError *error) {
			if (token) {
				[accountDelegate simplenoteAccountDidSignInAs:email token:token];
				step = StepSignedIn;
				[self refresh];
			} else {
				[statusLabel setStringValue:[error localizedDescription] ? [error localizedDescription] : NSLocalizedString(@"Sign-in failed.", nil)];
			}
		}];
	} else {
		[accountDelegate simplenoteSyncNow];
		[statusLabel setStringValue:NSLocalizedString(@"Syncing…", nil)];
	}
}

- (void)secondaryAction:(id)sender {
	if (busy) return;
	if (step == StepCode) {
		[self showStep:StepEmail];
	} else if (step == StepSignedIn) {
		[accountDelegate simplenoteAccountSignOut];
		step = StepEmail;
		[self refresh];
	}
}

@end
