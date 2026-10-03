//
//  PTKeyComboPanel.m
//  Protein
//
//  Created by Quentin Carnicelli on Sun Aug 03 2003.
//  Copyright (c) 2003 Quentin D. Carnicelli. All rights reserved.
//

#import "PTKeyComboPanel.h"

#import "PTKeyCombo.h"
#import "PTKeyBroadcaster.h"

@implementation PTKeyComboPanel

static id _sharedKeyComboPanel = nil;

+ (id)sharedPanel
{
	if( _sharedKeyComboPanel == nil )
	{
		_sharedKeyComboPanel = [[self alloc] init];
	}

	return _sharedKeyComboPanel;
}

- (id)init
{
    mTitleFormat = @"empty";
    mKeyName = @"empty";
	return [self initWithWindowNibName: @"PTKeyComboPanel"];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[mKeyName release];
	[mTitleFormat release];

	[super dealloc];
}

- (void)windowDidLoad
{
	mTitleFormat = [[mTitleField stringValue] retain];

	[[NSNotificationCenter defaultCenter]
		addObserver: self
		selector: @selector( noteKeyBroadcast: )
		name: PTKeyBroadcasterKeyEvent
		object: mKeyBcaster];
}

- (void)_refreshContents
{
    if( mComboField)
		[mComboField setStringValue: [mKeyCombo description]];
    

	if( mTitleField )
		[mTitleField setStringValue: [NSString stringWithFormat: mTitleFormat, mKeyName]];
     
}

- (void)chooseHotKeyDidEnd:(NSWindow *)sheet returnCode:(int)returnCode {
    [[self window] close];
    if (returnCode == NSModalResponseOK &&
        [currentModalDelegate respondsToSelector:@selector(keyComboPanelEnded:)])
        [currentModalDelegate keyComboPanelEnded:self];
    [currentModalDelegate release];
    currentModalDelegate = nil;
}

- (void)showSheetForKeyCombo:(PTKeyCombo*)combo name:(NSString*)name forWindow:(NSWindow*)mainWindow modalDelegate:(id)delegate {
    [[self window] makeFirstResponder:mKeyBcaster];
    [self setKeyCombo:combo];
    [self setKeyBindingName:name];
    currentModalDelegate = [delegate retain];
    [mainWindow beginSheet:[self window] completionHandler:^(NSModalResponse returnCode) {
        [self chooseHotKeyDidEnd:[self window] returnCode:(int)returnCode];
    }];
}

#pragma mark -

- (void)setKeyCombo: (PTKeyCombo*)combo
{
    if (combo == nil)
        combo = [PTKeyCombo clearKeyCombo];
    else
        [combo retain];
    
	[mKeyCombo release];
	mKeyCombo = combo;
	[self _refreshContents];
}

- (PTKeyCombo*)keyCombo
{
	return mKeyCombo;
}

- (void)setKeyBindingName: (NSString*)name
{
	[name retain];
	[mKeyName release];
	mKeyName = name;
	[self _refreshContents];
}

- (NSString*)keyBindingName
{
	return mKeyName;
}

#pragma mark -

- (IBAction)ok: (id)sender {
	if ([[self window] isModalPanel])
		[NSApp stopModalWithCode:NSModalResponseOK];
	else
		[NSApp endSheet:[self window] returnCode:NSModalResponseOK];
		
}

- (IBAction)cancel: (id)sender {
	if ([[self window] isModalPanel])
		[NSApp stopModalWithCode:NSModalResponseCancel];
	else
		[NSApp endSheet:[self window] returnCode:NSModalResponseCancel];
}

- (IBAction)clear: (id)sender
{
    [self setKeyCombo: [PTKeyCombo clearKeyCombo]];
	if ([[self window] isModalPanel])
		[NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)noteKeyBroadcast: (NSNotification*)note
{
	PTKeyCombo* keyCombo = [[note userInfo] objectForKey: @"keyCombo"];

	[self setKeyCombo: keyCombo];
}

@end
