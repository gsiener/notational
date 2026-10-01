//
//  NotationPrefsViewController.m
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "GlobalPrefs.h"
#import "NotationPrefsViewController.h"
#import "AppController_Simplenote.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NSCollection_utils.h"
#import "NSFileManager_NV.h"
//#import "AppController.h"

@implementation FileKindListView 

- (BOOL)acceptsFirstResponder {
    
    if (storageFormatPopupButton)
		return ([storageFormatPopupButton selectedTag] != SingleDatabaseFormat);
	
    return YES;
}
@end

enum {VERIFY_NOT_ATTEMPTED, VERIFY_FAILED, VERIFY_IN_PROGRESS, VERIFY_SUCCESS};

@implementation NotationPrefsViewController

- (NSView*)view {
    if (!view) {
		if (![NSBundle loadNibNamed:@"NotationPrefsView" owner:self])  {
			NSLog(@"Failed to load NotationPrefsView.nib");
			return nil;
		}
    }
    
    return view;
}

- (id)init {
    if (self=[super init]) {
        
		didAwakeFromNib = NO;
		notationPrefs = [[[GlobalPrefs defaultPrefs] notationPrefs] retain];
		
		disableEncryptionString = NSLocalizedString(@"Turn Off Note Encryption...",nil);
		enableEncryptionString = NSLocalizedString(@"Turn On Note Encryption...",nil);
	
		[[GlobalPrefs defaultPrefs] registerForSettingChange:@selector(setNotationPrefs:sender:) withTarget:self];
    
        return self;
    }
	return nil;
}
- (void)dealloc {
	[notationPrefs release];
	[postStorageFormatInvocation release];
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[super dealloc];
}

- (void)awakeFromNib {
    didAwakeFromNib = YES;
    [allowedExtensionsTable setDataSource:self];
    [allowedTypesTable setDataSource:self];
    [allowedExtensionsTable setDelegate:self];
    [allowedTypesTable setDelegate:self];
	
	
	//this additional management for sync prefs, plus the need for per-service settings and externally triggering updates really demands its own class
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	if (syncAccountField) [center addObserver:self selector:@selector(syncCredentialsDidChange:) name:NSControlTextDidChangeNotification object:syncAccountField];
	if (syncPasswordField) {
		[center addObserver:self selector:@selector(syncCredentialsDidChange:) name:NSControlTextDidChangeNotification object:syncPasswordField];
		[center addObserver:self selector:@selector(syncEditingDidEnd:) name:NSControlTextDidEndEditingNotification object:syncPasswordField];
	}
	[center addObserver:self selector:@selector(initializeControls) name:NotationPrefsDidChangeNotification object:nil];

    [self initializeControls];
}

- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	return (notationPrefs && [notationPrefs notesStorageFormat]);
}
- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex {
    return (notationPrefs && [notationPrefs notesStorageFormat]);
}
- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	NSTableView *tv = [aNotification object];
	BOOL isRowSelected = (([tv selectedRow] > -1)&&([tv selectedRow]!=NSNotFound));
	
	if (tv == allowedExtensionsTable) {
		[removeExtensionButton setEnabled:isRowSelected];
		[makeDefaultExtensionButton setEnabled:isRowSelected];
	} else if (tv == allowedTypesTable) {
		[removeTypeButton setEnabled:isRowSelected];
	}
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
	
	
	if ([selectorString isEqualToString:SEL_STR(setNotationPrefs:sender:)]) {
		
		//force these objects to re-init with the new notationprefs
		
		[notationPrefs release];
		notationPrefs = [[[GlobalPrefs defaultPrefs] notationPrefs] retain];
		
		if (didAwakeFromNib)
			[self initializeControls];
	}
}

- (void)initializeControls {
    //set up outlets to reflect new settings
    if (notationPrefs) {
		
		[keyLengthField setIntValue:[notationPrefs keyLengthInBits]];
		[keyLengthStepper setIntValue:[notationPrefs keyLengthInBits]];
		[self setEncryptionControlsState:[notationPrefs doesEncryption]];
		[self setSeparateFileControlsState:[notationPrefs notesStorageFormat]];
		[self updateRemoveKeychainItemStatus];
		[confirmFileDeletionButton setState:[notationPrefs confirmFileDeletion]];
		
		[self setSyncControlsState:NO];
		
		[secureTextEntryButton setState:[notationPrefs secureTextEntry]];
		
		[allowedTypesTable reloadData];
		[allowedExtensionsTable reloadData];
        if (!IsMavericksOrLater||([notationPrefs notesStorageFormat]==SingleDatabaseFormat)) {
            [useFinderTaggingButton setHidden:YES];
        }
    }
}

- (void)setSyncControlsState:(BOOL)syncState {
	//Simplenote sign-in now lives in its own window (ADR 0001); the old password-based
	//controls and the encryption and per-file storage options no longer apply
	NSArray *obsolete = [NSArray arrayWithObjects:syncingFrequency, syncAccountField, syncPasswordField, syncEncAlertView,
						 syncEncAlertField, verifyStatusImageView, verifyStatusField, enableEncryptionButton, changePasswordButton,
						 passwordSettingsMatrix, keyLengthField, keyLengthStepper, removeFromKeychainButton, storageFormatPopupButton,
						 useFinderTaggingButton, nil];
	for (NSView *control in obsolete) [control setHidden:YES];
	
	static NSInteger AccountButtonTag = 0x534e4143; //'SNAC'
	NSView *container = [enabledSyncButton superview];
	if (enabledSyncButton && ![container viewWithTag:AccountButtonTag]) {
		NSButton *account = [[[NSButton alloc] initWithFrame:NSMakeRect(NSMinX([enabledSyncButton frame]), NSMinY([enabledSyncButton frame]) - 4, 200, 30)] autorelease];
		[account setBezelStyle:NSBezelStyleRounded];
		[account setTitle:NSLocalizedString(@"Simplenote Account…", nil)];
		[account setTag:AccountButtonTag];
		[account setTarget:self];
		[account setAction:@selector(toggledSyncing:)];
		[container addSubview:account];
	}
	[enabledSyncButton setHidden:YES];
}

- (void)setEncryptionControlsState:(BOOL)encryptionState {
    [enableEncryptionButton setTitle:(encryptionState ? disableEncryptionString : enableEncryptionString)];
    [changePasswordButton setEnabled:encryptionState];
	[passwordSettingsMatrix setEnabled:encryptionState];
	
	[passwordSettingsMatrix setState:[notationPrefs storesPasswordInKeychain] atRow:0 column:0];
	[passwordSettingsMatrix setState:![notationPrefs storesPasswordInKeychain] atRow:1 column:0];
	
    [keyLengthField setEnabled:encryptionState];
    [keyLengthStepper setEnabled:encryptionState];
}

- (void)setSeparateFileControlsState:(BOOL)separateFileControlsState {
	[newExtensionButton setEnabled:separateFileControlsState];
	[removeExtensionButton setEnabled:separateFileControlsState && [allowedExtensionsTable selectedRow] > -1];
	[makeDefaultExtensionButton setEnabled:separateFileControlsState && [allowedExtensionsTable selectedRow] > -1];
	[newTypeButton setEnabled:separateFileControlsState];
	[removeTypeButton setEnabled:separateFileControlsState && [allowedTypesTable selectedRow] > -1];
	
	[allowedTypesTable setEnabled:separateFileControlsState];
	[allowedExtensionsTable setEnabled:separateFileControlsState];
	
	[confirmFileDeletionButton setEnabled:separateFileControlsState];
	
	[storageFormatPopupButton selectItemWithTag:[notationPrefs notesStorageFormat]];
	
	[fileAttributesHelpText setTextColor: separateFileControlsState ? [NSColor controlTextColor] : [NSColor grayColor]];	
}

- (void)updateRemoveKeychainItemStatus {
	
	if (![removeFromKeychainButton isHidden]) {
		SecKeychainItemRef itemRef = [notationPrefs currentKeychainItem];
		
		[removeFromKeychainButton setEnabled:(itemRef != NULL)];
		
		if (itemRef)
			CFRelease(itemRef);
	}
}

- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject 
   forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {

	if (aTableView == allowedExtensionsTable) {
		if (![notationPrefs setExtension:anObject atIndex:(unsigned int)rowIndex])
			[self removedExtension:self];
	} else if (aTableView == allowedTypesTable) {
		if (![notationPrefs setType:anObject atIndex:(unsigned int)rowIndex])
			[self removedType:self];
	}
}


- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {

	if (aTableView == allowedExtensionsTable) {
		NSString *extension = [notationPrefs pathExtensionAtIndex:rowIndex];
		
		if ([notationPrefs indexOfChosenPathExtension] == (unsigned int)rowIndex) {
			return [[[NSAttributedString alloc] initWithString:extension attributes:
					[NSDictionary dictionaryWithObjectsAndKeys:
					 [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, nil]] autorelease];
		}
		return extension;
			
	} else if (aTableView == allowedTypesTable) {
		
		return [notationPrefs typeStringAtIndex:rowIndex];
	}
	return 0;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView {
	if (aTableView == allowedExtensionsTable)
		return [notationPrefs pathExtensionsCount];
	else if (aTableView == allowedTypesTable)
		return [notationPrefs typeStringsCount];
	
	return 0;
}

- (IBAction)addedExtension:(id)sender {
    [notationPrefs addAllowedPathExtension:@""];
	[allowedExtensionsTable reloadData];
	
	[allowedExtensionsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:[notationPrefs pathExtensionsCount]-1] byExtendingSelection:NO];
	[allowedExtensionsTable editColumn:0 row:[notationPrefs pathExtensionsCount]-1 withEvent:nil select:YES];
}

- (IBAction)addedType:(id)sender {
    [notationPrefs addAllowedType:@""];
	[allowedTypesTable reloadData];
	
	[allowedTypesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:[notationPrefs typeStringsCount]-1] byExtendingSelection:NO];
	[allowedTypesTable editColumn:0 row:[notationPrefs typeStringsCount]-1 withEvent:nil select:YES];

}

- (IBAction)changedKeyLength:(id)sender {
    
    int bits = [keyLengthStepper intValue];
    [keyLengthField setIntValue:bits];
    [notationPrefs setKeyLengthInBits:bits];
}

- (IBAction)changedKeychainSettings:(id)sender {
	//matrix does not change until the next runloop iteration, apparently
	if (sender != self)
		[self performSelector:@selector(changedKeychainSettings:) withObject:self afterDelay:0.0];
	else
		[notationPrefs setStoresPasswordInKeychain:[[passwordSettingsMatrix cellAtRow:0 column:0] state]];
		
}

- (IBAction)changedFileDeletionWarningSettings:(id)sender {
    [notationPrefs setConfirmsFileDeletion:[confirmFileDeletionButton state]];
}

- (IBAction)removeFromKeychain:(id)sender {
	[notationPrefs removeKeychainData];

	[self updateRemoveKeychainItemStatus];
}

- (NSInteger)notesStorageFormatInProgress {
	return notesStorageFormatInProgress;
}

- (void)runQueuedStorageFormatChangeInvocation {
	[postStorageFormatInvocation performSelector:@selector(invoke) withObject:nil afterDelay:0.0];
	[postStorageFormatInvocation release];
	postStorageFormatInvocation = nil;
}

- (void)notesStorageFormatDidChange {
	notesStorageFormatInProgress = [notationPrefs notesStorageFormat];
	[self setSeparateFileControlsState:notesStorageFormatInProgress];
	
    [allowedExtensionsTable reloadData];
    [allowedTypesTable reloadData];
}

- (IBAction)changedFileStorageFormat:(id)sender {
    NSInteger storageTag = [storageFormatPopupButton selectedTag];
	if (storageTag != SingleDatabaseFormat && [notationPrefs doesEncryption]) {
		if (NSRunAlertPanel(NSLocalizedString(@"Encryption is currently on, but storing notes individually requires it to be off. Disable encryption?",nil),
							NSLocalizedString(@"Warning: Your notes will be written to disk in clear text.",nil), NSLocalizedString(@"Disable Encryption",nil), 
							NSLocalizedString(@"Cancel",nil), NULL) == NSAlertDefaultReturn) {
			
			//disable encryption
			[self disableEncryptionWithWarning:NO];
		} else {
			//cancelled
			[self notesStorageFormatDidChange];
			return;
		}
	}
	
	notesStorageFormatInProgress = storageTag;
	
	//if we're changing to a database format from a non-database-format, ask to trash existing files
    if ([notationPrefs shouldDisplaySheetForProposedFormat:notesStorageFormatInProgress]) {
		
		NSAlert *alert = [NSAlert alertWithMessageText:NSLocalizedString(@"Individual files remain in the notes directory. Leave them alone or move them to the Trash?",nil) 
										 defaultButton:NSLocalizedString(@"Keep Files", @"button title for not discarding note files") 
									   alternateButton:NSLocalizedString(@"Cancel",nil) otherButton:NSLocalizedString(@"Move to Trash", @"button title for trashing notes")
							 informativeTextWithFormat:NSLocalizedString(@"When notes are stored in a single database individual files become redundant.",nil)];
		
		[alert beginSheetModalForWindow:[view window] modalDelegate:notationPrefs 
						 didEndSelector:@selector(noteFilesCleanupSheetDidEnd:returnCode:contextInfo:) contextInfo:self];
		//will ultimately call -notesStorageFormatDidChange
	} else {
		//just call setNotesStorageFormat straight-out
		[notationPrefs setNotesStorageFormat:notesStorageFormatInProgress];
		[self notesStorageFormatDidChange];
		
		//sheet ending will not do this for us--there is no sheet
		[self runQueuedStorageFormatChangeInvocation];
	}
	
	
	if ([[storageFormatPopupButton objectValue] intValue]==0) {
		[[NSUserDefaults standardUserDefaults] setObject:nil forKey:@"TextEditor"];
		[[NSUserDefaults standardUserDefaults] synchronize];
	}else {
		[[NSUserDefaults standardUserDefaults] setObject:@"Default" forKey:@"TextEditor"];
		[[NSUserDefaults standardUserDefaults] synchronize];
//		if ( [[NSApp delegate] respondsToSelector: @selector(updateTextApp:)] ) {
//			[[NSApp delegate] updateTextApp:self];
//		}
	}

	
}

- (IBAction)toggledSyncing:(id)sender {
	[(AppController *)[NSApp delegate] showSimplenoteAccount:sender];
}

- (IBAction)syncFrequencyChange:(id)sender {
	//the Sync engine decides how often to sync
}

- (void)syncEditingDidEnd:(NSNotification *)aNotification {
}

- (void)syncCredentialsDidChange:(NSNotification *)aNotification {
}


- (void)setVerificationStatus:(int)status withString:(NSString*)aString {
	
	switch (status) {
		case VERIFY_NOT_ATTEMPTED:
			verificationAttempted = NO;
			[verifyStatusImageView setImage:nil];
			break;
		case VERIFY_FAILED:
			verificationAttempted = YES;
			[verifyStatusImageView setImage:[NSImage imageNamed:@"statusError"]];
			break;
		case VERIFY_IN_PROGRESS:
			[verifyStatusImageView setImage:[NSImage imageNamed:@"statusInProgress"]];
			break;
		case VERIFY_SUCCESS:
			verificationAttempted = YES;
			[verifyStatusImageView setImage:[NSImage imageNamed:@"statusValidated"]];
			break;
	}
	[verifyStatusImageView setHidden: VERIFY_NOT_ATTEMPTED == status];
	[verifyStatusField setStringValue: aString ? aString : @""];
}

- (IBAction)changedSecureTextEntry:(id)sender {
	[notationPrefs setSecureTextEntry:[secureTextEntryButton state]];
}

- (IBAction)changePassphrase:(id)sender {
	//encryption no longer applies: notes live in Simplenote (ADR 0001); the control is hidden
}

- (IBAction)visitSimplenoteSite:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://simplenote.com/"]];
}

- (IBAction)makeDefaultExtension:(id)sender {
	[[allowedExtensionsTable window] makeFirstResponder:allowedExtensionsTable];
	
	NSUInteger selectedRow = (NSUInteger)[allowedExtensionsTable selectedRow];
	if (selectedRow != NSNotFound)
		[notationPrefs setChosenPathExtensionAtIndex:selectedRow];
	
	[allowedExtensionsTable reloadData];	
}

- (IBAction)removedExtension:(id)sender {
	[allowedExtensionsTable abortEditing];
	
	NSUInteger selectedRow = (NSUInteger)[allowedExtensionsTable selectedRow];
	if (selectedRow != NSNotFound)
		if (![notationPrefs removeAllowedPathExtensionAtIndex:selectedRow]) NSBeep();
	
	[allowedExtensionsTable reloadData];
}

- (IBAction)removedType:(id)sender {
	[allowedTypesTable abortEditing];
	
	NSUInteger selectedRow =(NSUInteger)[allowedTypesTable selectedRow];
	if (selectedRow !=NSNotFound)
		[notationPrefs removeAllowedTypeAtIndex:selectedRow];
	
	[allowedTypesTable reloadData];
}

- (IBAction)toggledEncryption:(id)sender {
	//encryption no longer applies: notes live in Simplenote (ADR 0001); the control is hidden
}


#pragma mark nvALT Finder tagging

- (IBAction)switchToFinderTags:(id)sender{
    if (IsMavericksOrLater) {
        NSAlert *tagWarning=[NSAlert new];
        [tagWarning setMessageText:NSLocalizedString(@"This will permanently convert all your nvALT tags to Finder tags, and use Finder tags from here on out.", @"Finder tag warning message text")];
        [tagWarning setInformativeText:NSLocalizedString(@"This cannot be undone.", @"Finder tag warning informative text")];
        [tagWarning addButtonWithTitle:NSLocalizedString(@"Do It", @"name of delete button")];
        [tagWarning addButtonWithTitle:NSLocalizedString(@"Cancel", @"name of cancel button")];
        [tagWarning beginSheetModalForWindow:[view window] completionHandler:^(NSModalResponse returnCode) {
            if (returnCode == NSAlertFirstButtonReturn) {
                [[GlobalPrefs defaultPrefs]setUseFinderTags:sender];
            }
        }];
        [tagWarning release];
    }
}

@end
