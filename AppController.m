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
//ET NV4

#import "AppController.h"
#import "NVTheme.h"
#import "AppController_Simplenote.h"
#import "NVSyncEngine.h"
#import "NVTextMerge.h"
#import "NSString_CustomTruncation.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteContent.h"
#import "AttributedPlainText.h"
#import "GlobalPrefs.h"
#import "AlienNoteImporter.h"
#import "AppController_Importing.h"
#import "NotationPrefs.h"
#import "PrefsWindowController.h"
#import "NoteAttributeColumn.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "ExporterManager.h"
#import "ExternalEditorListController.h"
#import "NSData_transformations.h"
#import "BufferUtils.h"
#import "LinkingEditor.h"
#import "EmptyView.h"
#import "NVAccountSession.h"
#import "DualField.h"
#import "TitlebarButton.h"
#import "BookmarksController.h"
#import "MultiplePageView.h"
#import "SecureTextEntryManager.h"
#import "TagEditingManager.h"
#import "NotesTableHeaderCell.h"
#import "DFView.h"
#import "ETContentView.h"
#import "PreviewController.h"
#import "ETClipView.h"
#import "ETScrollView.h"
#import "ETNoteScrollView.h"
#import "WordCountToken.h"
#import "NSFileManager+DirectoryLocations.h"
#import "nvaDevConfig.h"
#import "NVHereNowSites.h"

#define NSApplicationPresentationAutoHideMenuBar (1 <<  2)
#define NSApplicationPresentationHideMenuBar (1 <<  3)
//#define NSApplicationPresentationAutoHideDock (1 <<  0)
#define NSApplicationPresentationHideDock (1 <<  1)
//#define NSApplicationActivationPolicyAccessory

//http://abyss.designheresy.com/nvalt/betaupdates.xml

#define kSplitViewExpandedDividerThickness 8.0f
#define kSplitViewCollapsedDividerThickness 5.0f
#define kNotesListMinDimension 80.0f
#define kNotesListMaxDimension 600.0f

//#define NSTextViewChangedNotification @"TextViewHasChangedContents"
//#define kDefaultMarkupPreviewMode @"markupPreviewMode"
#define kDualFieldHeight 35.0

#define k_FinderTaggingReset 0
#define NVEditorUndoMaxStates 33
#define NVEditorUndoMaxBytes (8 * 1024 * 1024)
#define NVEditorUndoMaxNotes 8

NSInteger ModFlagger;
NSInteger popped;
BOOL splitViewAwoke;


static NSString *const NotesListCollapsedKey = @"NotesListCollapsed";

@implementation AppController

@synthesize isEditing;

//an instance of this class is designated in the nib as the delegate of the window, nstextfield and two nstextviews
/*
 + (void)initialize
 {
 NSDictionary *appDefaults = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:NVMarkupMultiMarkdown] forKey:kDefaultMarkupPreviewMode];
 
 [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
 } // initialize*/


- (id)init {
    self = [super init];
    if (self) {

        [NSWindow setAllowsAutomaticWindowTabbing:NO];
#if k_FinderTaggingReset
        [[NSUserDefaults standardUserDefaults]removeObjectForKey:@"UseFinderTags"];
#endif
        
        hasLaunched=NO;
        
        if (![[NSUserDefaults standardUserDefaults] boolForKey:@"ShowDockIcon"]){
            ProcessSerialNumber psn = { 0, kCurrentProcess };
            OSStatus returnCode = TransformProcessType(&psn, kProcessTransformToUIElementApplication);
            if( returnCode != 0) {
                NSLog(@"Could not bring the application to front. Error %d", returnCode);
            }                
            if (![[NSUserDefaults standardUserDefaults] boolForKey:@"StatusBarItem"]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"StatusBarItem"];
            }
        }
        
        splitViewAwoke = NO;
        windowUndoManager = [[NSUndoManager alloc] init];
        
        previewController = [[PreviewController alloc] init];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        
        
        NSString *folder = [fileManager applicationSupportDirectory];
        
        if ([fileManager fileExistsAtPath: folder] == NO)
        {
            [fileManager createFolderAtPath:folder];
            
//            [fileManager createDirectoryAtPath: folder attributes: nil];
            
        }
        
        NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
        [nc addObserver:previewController selector:@selector(requestPreviewUpdate:) name:@"TextViewHasChangedContents" object:self];
        [nc addObserver:self selector:@selector(togDockIcon:) name:@"AppShouldToggleDockIcon" object:nil];
        [nc addObserver:self selector:@selector(toggleStatusItem:) name:@"AppShouldToggleStatusItem" object:nil];
        
        [nc addObserver:self selector:@selector(resetModTimers:) name:@"ModTimersShouldReset" object:nil];
        [nc addObserver:self selector:@selector(releaseTagEditor:) name:@"TagEditorShouldRelease" object:nil];
        [nc addObserver:self selector:@selector(themeDidChange:) name:NVThemeDidChangeNotification object:nil];
        // Setup URL Handling
        NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
        [appleEventManager setEventHandler:self andSelector:@selector(handleGetURLEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
        
        isCreatingANote = isFilteringFromTyping = typedStringIsCached = NO;
        typedString = @"";
        self.isEditing=NO;
    }
    return self;
}

- (void)awakeFromNib {
    splitViewIsChangingLayout=NO;
    theFieldEditor = [[NSTextView alloc]initWithFrame:[window frame]];
	[theFieldEditor setFieldEditor:YES];
    // [theFieldEditor setDelegate:self];
    [self updateFieldAttributes];
    
	[NSApp setDelegate:self];
	[window setDelegate:self];
    
    //the split view is made in code, so the nib needs no plugin for it
    splitView = [[NVSplitView alloc] initWithFrame:[mainView frame]];
    [splitView setVertical:YES];
    [splitView setDividerStyle:NSSplitViewDividerStyleThin];
    [splitView setDelegate:self];
    [splitView setAutoresizesSubviews:YES];
    [splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [mainView addSubview:splitView];
    [splitView setNextKeyView:notesTableView];
    NSRect splitBounds = [splitView bounds];
    CGFloat initialListWidth = MIN(200.0, NSWidth(splitBounds) / 2.0);
    notesSubview = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, initialListWidth, NSHeight(splitBounds))];
    splitSubview = [[NSView alloc] initWithFrame:NSMakeRect(initialListWidth + kSplitViewExpandedDividerThickness, 0,
                                                            MAX(NSWidth(splitBounds) - initialListWidth - kSplitViewExpandedDividerThickness, 1.0),
                                                            NSHeight(splitBounds))];
    [splitView addSubview:notesSubview];
    [splitView addSubview:splitSubview];
    [notesSubview setAutoresizesSubviews:YES];
    [notesSubview addSubview:notesScrollView];
    [notesScrollView setFrame:[notesSubview bounds]];
    [notesScrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [splitSubview setAutoresizesSubviews:YES];
    [splitSubview addSubview:textScrollView];
    
    ETClipView *newClipView = [[ETClipView alloc] initWithFrame:[[textScrollView contentView] frame]];
    [newClipView setDrawsBackground:NO];
    [textScrollView setContentView:(ETClipView *)newClipView];
    [textScrollView setDocumentView:textView];
    
    [textScrollView setFrame:[splitSubview bounds]];
    [textScrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    
    [splitView adjustSubviews];
    [splitView needsDisplay];
    [mainView setNeedsDisplay:YES];
    splitViewAwoke = YES;
    
	[notesScrollView setBorderType:NSNoBorder];
	[textScrollView setBorderType:NSNoBorder];
	prefsController = [GlobalPrefs defaultPrefs];
	[NSColor setIgnoresAlpha:NO];
	
	//For ElasticThreads' fullscreen implementation.
	[self setDualFieldInToolbar];
	[notesTableView setDelegate:self];
	[field setDelegate:self];
	[textView setDelegate:self];
    
	//set up temporary FastListDataSource containing false visible notes
    
	//this will not make a difference
	
    
	//[window makeKeyAndOrderFront:self];
	//[self setEmptyViewState:YES];
   
    
	// Create elasticthreads' NSStatusItem.
	if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"StatusBarItem"]) {
		[self setUpStatusBarItem];
	}
	
	//which View ▸ Preview item is checked (-validateMenuItem:); a saved mode that no longer exists
	//(Textile) shows as MultiMarkdown
	currentPreviewMode = [[NSUserDefaults standardUserDefaults] integerForKey:@"markupPreviewMode"] == NVMarkupMarkdown ? NVMarkupMarkdown : NVMarkupMultiMarkdown;
	
	outletObjectAwoke(self);
}

//really need make AppController a subclass of NSWindowController and stick this junk in windowDidLoad
- (void)setupViewsAfterAppAwakened {
	static BOOL awakenedViews = NO;
	if (!awakenedViews) {
		//NSLog(@"all (hopefully relevant) views awakend!");
		[self _configureDividerForCurrentLayout];
		[self restoreSplitViewState];
		if ([self notesListDimension]<200.0) {
			if ([splitView isVertical]) {   ///vertical means "Horiz layout"/notes list is to the left of the note body
				if (([splitView frame].size.width < 600.0) && ([splitView frame].size.width - 400 > [self notesListDimension])) {
					[self setNotesListDimension:[splitView frame].size.width-400.0];
				}else if ([splitView frame].size.width >= 600.0) {
					[self setNotesListDimension:200.0];
				}
			}else{
				if (([splitView frame].size.height < 600.0) && ([splitView frame].size.height - 400 > [self notesListDimension])) {
					[self setNotesListDimension:[splitView frame].size.height-450.0];
				}else if ([splitView frame].size.height >= 600.0){
					[self setNotesListDimension:150.0];
				}
			}
		}
		[splitView adjustSubviews];
		[splitSubview addSubview:editorStatusView positioned:NSWindowAbove relativeTo:splitSubview];
		[editorStatusView setFrame:[textScrollView frame]];
		[editorStatusView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
		
		[notesTableView restoreColumns];
		
		[field setNextKeyView:textView];
		[textView setNextKeyView:field];
		[window setAutorecalculatesKeyViewLoop:NO];
		
        [self updateRTL];
        
		
		[self setEmptyViewState:YES];
		ModFlagger = 0;
        popped = 0;
		[self themeDidChange:nil];
		//this is necessary on 10.3; keep just in case
		[splitView display];
        
        
        //        if (![NSApp isActive]) {  probably a mistake to have put this in the begin with
        //            [NSApp activateIgnoringOtherApps:YES];
        //        }
		awakenedViews = YES;
	}
}

//what a hack
void outletObjectAwoke(id sender) {
	static NSMutableSet *awokenOutlets = nil;
	if (!awokenOutlets) awokenOutlets = [[NSMutableSet alloc] initWithCapacity:5];
    
    
	[awokenOutlets addObject:sender];
	
	AppController* appDelegate = (AppController*)[NSApp delegate];
	
	if ((appDelegate) && ([awokenOutlets containsObject:appDelegate] &&
                          [awokenOutlets containsObject:appDelegate->notesTableView] &&
                          [awokenOutlets containsObject:appDelegate->textView] &&
                          [awokenOutlets containsObject:appDelegate->editorStatusView]) &&(splitViewAwoke)) {
		// && [awokenOutlets containsObject:appDelegate->splitView])
		[appDelegate setupViewsAfterAppAwakened];
	}
}

- (void)runDelayedUIActionsAfterLaunch {
	[[prefsController bookmarksController] setAppController:self];
	[[prefsController bookmarksController] restoreWindowFromSave];
	[[prefsController bookmarksController] updateBookmarksUI];
    [self updateNoteMenus];
    [textView setupFontMenu];
    [prefsController registerAppActivationKeystrokeWithTarget:self selector:@selector(toggleNVActivation:)];
    [notationController updateLabelConnectionsAfterDecoding];
    [[SecureTextEntryManager sharedInstance] checkForIncompatibleApps];

    // add elasticthreads' menuitems
    [fsMenuItem setEnabled:YES];
    [fsMenuItem setHidden:NO];

    [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

    NSMenuItem *theMenuItem = [fsMenuItem copy];
    [statBarMenu insertItem:theMenuItem atIndex:14];
    [wordCounter setHidden:[prefsController showWordCount]];

	//
	[NSApp setServicesProvider:self];
    if (!hasLaunched) {
        hasLaunched=YES;
        [self focusControlField:self activate:NO];

    }
    
//    self.isEditing=NO;
    
    
    //    [NSApp activateIgnoringOtherApps:NO];
    //    [window makeKeyAndOrderFront:self];
}

//
//- (void)applicationWillFinishLaunching:(NSNotification *)aNotification{
//  
//}


- (void)applicationDidFinishLaunching:(NSNotification*)aNote {
	//on tiger dualfield is often not ready to add tracking tracks until this point:
	
	[field setTrackingRect];
	NSDate *before = [NSDate date];
	prefsWindowController = [[PrefsWindowController alloc] init];
	NSString *siteCache = [[[NSFileManager defaultManager] applicationSupportDirectory] stringByAppendingPathComponent:@"here-now-sites.json"];
	
	//notes live in a Simplenote-backed store (ADR 0001); the old database is migrated once
	NSError *storeError = nil;
	NotationController *newNotation = [self openSimplenoteBackedNotationReturningError:&storeError];
	if (!newNotation) {
		NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"Notational couldn't open its notes", nil), [storeError localizedDescription],
				   NSLocalizedString(@"Quit", nil), nil, nil);
		goto terminateApp;
	}
	[self setNotationController:newNotation];
	[self installSimplenoteMenuItem];
	hereNowSites = [[NVHereNowSites alloc] initWithTransport:[NVHereNowHTTPTransport new] cacheURL:[NSURL fileURLWithPath:siteCache]];
	mixedList = [NVHereNowMixedList new];
	mixedList.notes = [notationController notesListDataSource];
	[notesTableView setDataSource:mixedList];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hereNowSitesChanged:) name:NVHereNowSitesDidChangeNotification object:hereNowSites];
	[self installHereNowMenuItems];
	[hereNowSites restore];
	lastHereNowActivationRefresh = [NSDate date];
	
	NSLog(@"load time: %g, ",[[NSDate date] timeIntervalSinceDate:before]);
	//	NSLog(@"version: %s", PRODUCT_NAME);
	
	//import old database(s) here if necessary
	[AlienNoteImporter importBlorOrHelpFilesIfNecessaryIntoNotation:newNotation];
	
//	[newNotation release];
	if (pathsToOpenOnLaunch) {
		[notationController openFiles:pathsToOpenOnLaunch];//autorelease
		pathsToOpenOnLaunch = nil;
	}
	
	if (URLToInterpretOnLaunch) {
		[self interpretNVURL:[NSURL URLWithString:URLToInterpretOnLaunch]];
		URLToInterpretOnLaunch = nil;
	}
	
	//tell us..
	[prefsController registerWithTarget:self forChangesInSettings:
	 @selector(setSortedTableColumnKey:reversed:sender:),  //when sorting prefs changed
	 @selector(setNoteBodyFont:sender:),  //when to tell notationcontroller to restyle its notes
	 @selector(setForegroundTextColor:sender:),  //ditto
	 @selector(setBackgroundTextColor:sender:),  //ditto
	 @selector(setTableFontSize:sender:),  //when to tell notationcontroller to regenerate the (now potentially too-short) note-body previews
	 @selector(addTableColumn:sender:),  //ditto
	 @selector(removeTableColumn:sender:),  //ditto
	 @selector(setTableColumnsShowPreview:sender:),  //when to tell notationcontroller to generate or disable note-body previews
	 @selector(setConfirmNoteDeletion:sender:),  //whether "delete note" should have an ellipsis
     @selector(setUseFinderTags:),  //whether nvalt should use findertags
	 @selector(setAutoCompleteSearches:sender:), nil];   //when to tell notationcontroller to build its title-prefix connections
	
	[self performSelector:@selector(runDelayedUIActionsAfterLaunch) withObject:nil afterDelay:0.0];
    
	
    
	return;
terminateApp:
	[NSApp terminate:self];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	
	NSURL *fullURL = [NSURL URLWithString:[[event paramDescriptorForKeyword:keyDirectObject] stringValue]];
	
	if (notationController) {
		if (![self interpretNVURL:fullURL])
			NSBeep();
	} else {
		URLToInterpretOnLaunch = [fullURL path];
	}
}

- (void)setNotationController:(NotationController*)newNotation {
	
    if (newNotation) {
		if (notationController) {
			[notationController closeAllResources];
		}
		
		NotationController *oldNotation = notationController;
		notationController = newNotation;
		
		if (oldNotation) {
			[notesTableView abortEditing];
			[prefsController setLastSearchString:[self fieldSearchString] selectedNote:currentNote
						scrollOffsetForTableView:notesTableView sender:self];
			//if we already had a notation, appController should already be bookmarksController's delegate
			[[prefsController bookmarksController] performSelector:@selector(updateBookmarksUI) withObject:nil afterDelay:0.0];
		}
		[notationController setSortColumn:[notesTableView noteAttributeColumnForIdentifier:[prefsController sortedTableColumnKey]]];
		if (mixedList) {
			mixedList.notes = [notationController notesListDataSource];
			[notesTableView setDataSource:mixedList];
		} else [notesTableView setDataSource:[notationController notesListDataSource]];
		[notesTableView setLabelsListSource:[notationController labelsListDataSource]];
		[notationController setDelegate:self];
		
		//allow resolution of UUIDs to NoteObjects from saved searches
		[[prefsController bookmarksController] setDataSource:notationController];
		
		//update the list using the new notation and saved settings
		[self restoreListStateUsingPreferences];
		
		//window's undomanager could be referencing actions from the old notation object
		[[window undoManager] removeAllActions];
		[notationController setUndoManager:[window undoManager]];
		
		if ([prefsController tableColumnsShowPreview] || [prefsController horizontalLayout]) {
			[self _forceRegeneratePreviewsForTitleColumn];
			[notesTableView setNeedsDisplay:YES];
		}
		
		if ([[notationController notationPrefs] secureTextEntry]) {
			[[SecureTextEntryManager sharedInstance] enableSecureTextEntry];
		} else {
			[[SecureTextEntryManager sharedInstance] disableSecureTextEntry];
		}
		
		[field selectText:nil];
		
    }
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    if ((![prefsController quitWhenClosingWindow])&&(hasLaunched)) {
        [self bringFocusToControlField:nil];
        return YES;
    }
    
    return NO;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
	return [itemIdentifier isEqualToString:@"DualField"] ? dualFieldItem : nil;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)theToolbar {
	return [self toolbarDefaultItemIdentifiers:theToolbar];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)theToolbar {
	return [NSArray arrayWithObject:@"DualField"];
}


- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
	SEL selector = [menuItem action];
	NSInteger numberSelected = [notesTableView numberOfSelectedRows];
	NSInteger tag = [menuItem tag];
    if (selector == @selector(openSelectedHereNowSite:)) return [self selectedRowIsHereNowSite] && numberSelected == 1;
    if (selector == @selector(refreshHereNow:) || selector == @selector(disconnectHereNow:)) return [hereNowSites connected];
    if (selector == @selector(connectHereNow:)) return YES;
    if ([self selectionContainsHereNowSite] && (selector == @selector(printNote:) || selector == @selector(deleteNote:) ||
        selector == @selector(exportNote:) || selector == @selector(tagNote:) || selector == @selector(renameNote:) ||
        selector == @selector(copyNoteLink:) || selector == @selector(editNoteExternally:) || selector == @selector(previewNoteWithMarked:))) return NO;
    
    if ((tag == NVMarkupMarkdown) || (tag == NVMarkupMultiMarkdown)) {
        // Allow only one Preview mode to be selected at every one time
        [menuItem setState:((tag == currentPreviewMode) ? NSControlStateValueOn : NSControlStateValueOff)];
        return YES;
    } else if (selector == @selector(setBWColorScheme:) || selector == @selector(setLCColorScheme:) || selector == @selector(setUserColorScheme:)) {
        //the main and status-bar menus' Color Schemes items check the Theme's scheme
        NVThemeScheme itemScheme = selector == @selector(setLCColorScheme:) ? NVThemeSchemeLowContrast :
            selector == @selector(setUserColorScheme:) ? NVThemeSchemeCustom : NVThemeSchemeLight;
        [menuItem setState:([[NVTheme currentTheme] scheme] == itemScheme) ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    } else if (selector == @selector(printNote:) ||
               selector == @selector(deleteNote:) ||
               selector == @selector(exportNote:) ||
               selector == @selector(tagNote:)) {
		
		return (numberSelected > 0);
		
	} else if (selector == @selector(renameNote:) ||
			   selector == @selector(copyNoteLink:)) {
		
		return (numberSelected == 1);
		
	} else if (selector == @selector(toggleCollapse:)) {
        if ([self notesListIsCollapsed]) {
            [menuItem setTitle:NSLocalizedString(@"Expand Notes List",@"menu item title for expanding notes list")];
        }else{
            
            [menuItem setTitle:NSLocalizedString(@"Collapse Notes List",@"menu item title for collapsing notes list")];
            
            if (!currentNote){
                return NO;
            }
        }
	} else if ((selector == @selector(toggleFullScreen:))||(selector == @selector(switchFullScreen:))) {
        if([NSApp presentationOptions]>0){
            [menuItem setTitle:NSLocalizedString(@"Exit Full Screen",@"menu item title for exiting fullscreen")];
        }else{
            
            [menuItem setTitle:NSLocalizedString(@"Enter Full Screen",@"menu item title for entering fullscreen")];
            
        }
    } else if (selector == @selector(editNoteExternally:)) {
        return (numberSelected > 0) && [[menuItem representedObject] canEditAllNotes:[notationController notesAtIndexes:[notesTableView selectedRowIndexes]]];
	}else if (selector == @selector(previewNoteWithMarked:)){
        BOOL gotMarked=[[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marky"] isFileURL] || [[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marked2"] isFileURL]
            || [[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marked2.beta"] isFileURL]
            || [[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marked-setapp"] isFileURL];
        if ([menuItem isHidden]==gotMarked) {
            [menuItem setHidden:!gotMarked];
        }
        return gotMarked&&([[notesTableView selectedRowIndexes]count]>0);
    }else if (selector==@selector(togglePreview:)){        
          return (currentNote != nil);
    }
	return YES;
}

- (void)updateNoteMenus {
	NSMenu *notesMenu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
	
	NSInteger menuIndex = [notesMenu indexOfItemWithTarget:self andAction:@selector(deleteNote:)];
	NSMenuItem *deleteItem = nil;
	if (menuIndex > -1 && (deleteItem = [notesMenu itemAtIndex:menuIndex]))	{
		NSString *trailingQualifier = [prefsController confirmNoteDeletion] ? NSLocalizedString(@"...", @"ellipsis character") : @"";
		[deleteItem setTitle:[NSString stringWithFormat:@"%@%@",
							  NSLocalizedString(@"Delete", nil), trailingQualifier]];
	}
	
    [notesMenu setSubmenu:[[ExternalEditorListController sharedInstance] addEditNotesMenu] forItem:[notesMenu itemWithTag:88]];
	NSMenu *viewMenu = [[[NSApp mainMenu] itemWithTag:VIEW_MENU_ID] submenu];
	
	menuIndex = [viewMenu indexOfItemWithTarget:notesTableView andAction:@selector(toggleNoteBodyPreviews:)];
	NSMenuItem *bodyPreviewItem = nil;
	if (menuIndex > -1 && (bodyPreviewItem = [viewMenu itemAtIndex:menuIndex])) {
		[bodyPreviewItem setTitle: [prefsController tableColumnsShowPreview] ?
		 NSLocalizedString(@"Hide Note Previews in Title", @"menu item in the View menu to turn off note-body previews in the Title column") :
		 NSLocalizedString(@"Show Note Previews in Title", @"menu item in the View menu to turn on note-body previews in the Title column")];
	}
	menuIndex = [viewMenu indexOfItemWithTarget:self andAction:@selector(switchViewLayout:)];
	NSMenuItem *switchLayoutItem = nil;
	NSString *switchStr = [prefsController horizontalLayout] ?
	NSLocalizedString(@"Switch to Vertical Layout", @"title of alternate view layout menu item") :
	NSLocalizedString(@"Switch to Horizontal Layout", @"title of view layout menu item");
	
	if (menuIndex > -1 && (switchLayoutItem = [viewMenu itemAtIndex:menuIndex])) {
		[switchLayoutItem setTitle:switchStr];
	}
	// add to elasticthreads' statusbar menu
	menuIndex = [statBarMenu indexOfItemWithTarget:self andAction:@selector(switchViewLayout:)];
	if (menuIndex>-1) {
		NSMenuItem *anxItem = [statBarMenu itemAtIndex:menuIndex];
		[anxItem setTitle:switchStr];
	}
}

- (void)_forceRegeneratePreviewsForTitleColumn {
	[notationController regeneratePreviewsForColumn:[notesTableView noteAttributeColumnForIdentifier:NoteTitleColumnString]
								visibleFilteredRows:[self visibleNoteRows] forceUpdate:YES];
    
}

- (NSRange)visibleNoteRows {
	NSRange visible = [notesTableView rowsInRect:[notesTableView visibleRect]];
	NSUInteger noteCount = [[notationController notesListDataSource] count];
	if (visible.location == NSNotFound || visible.location >= noteCount) return NSMakeRange(noteCount, 0);
	return NSMakeRange(visible.location, MIN(visible.length, noteCount - visible.location));
}

#pragma mark notes list and divider

- (BOOL)notesListIsCollapsed {
    return [splitView isSubviewCollapsed:notesSubview];
}

//the notes list's width (side-by-side layout) or height (stacked); a collapsed list gives the
//size it will have when expanded
- (CGFloat)notesListDimension {
    NSRect frame = [notesSubview frame];
    CGFloat current = [splitView isVertical] ? NSWidth(frame) : NSHeight(frame);
    if ([self notesListIsCollapsed]) {
        return lastNotesDimension > 0.0 ? lastNotesDimension : current;
    }
    return current;
}

//moves the divider so the list has this size (within its limits)
- (void)setNotesListDimension:(CGFloat)dimension {
    dimension = MAX(dimension, kNotesListMinDimension);
    if ([self notesListIsCollapsed]) {
        lastNotesDimension = dimension;
        return;
    }
    [splitView setPosition:dimension ofDividerAtIndex:0];
    lastNotesDimension = [self notesListDimension];
}

//sets the list's frame outright, e.g. right after the layout changed and the old size is meaningless
- (void)forceNotesListDimension:(CGFloat)dimension {
    NSRect frame = [notesSubview frame];
    if ([splitView isVertical]) {
        frame.size.width = dimension;
    } else {
        frame.size.height = dimension;
    }
    [notesSubview setFrame:frame];
}

- (NSString *)splitViewAutosaveNameForCurrentLayout {
    //a saved position is for one layout; the other layout keeps its own
    return [splitView isVertical] ? @"centralSplitView V" : @"centralSplitView H";
}

//restores the divider position (and whether the list was collapsed) saved under the layout's
//autosave name, first converting what the old RBSplitView saved if that's all there is
- (void)restoreSplitViewState {
    NSString *name = [self splitViewAutosaveNameForCurrentLayout];
    [NVSplitView migrateLegacyStateNamed:@"centralSplitView"
                          toAutosaveName:name
                                vertical:[splitView isVertical]
                                    size:[splitView frame].size
                        dividerThickness:kSplitViewExpandedDividerThickness
                                defaults:[NSUserDefaults standardUserDefaults]];
    splitViewIsRestoring = YES;   //a collapsed list is restored even though no note is open yet
    [splitView setAutosaveName:name];
    splitViewIsRestoring = NO;
    //NSSplitView's autosave keeps sizes but not reliably a hidden subview, so collapsing is remembered separately
    if ([[NSUserDefaults standardUserDefaults] boolForKey:NotesListCollapsedKey] && ![self notesListIsCollapsed]) {
        lastNotesDimension = [self notesListDimension];
        [notesSubview setHidden:YES];
    }
    notesWasCollapsed = [self notesListIsCollapsed];
    if (notesWasCollapsed) {
        [splitView setCustomDividerThickness:kSplitViewCollapsedDividerThickness];
        NSRect frame = [notesSubview frame];
        CGFloat size = [splitView isVertical] ? NSWidth(frame) : NSHeight(frame);
        if (size >= kNotesListMinDimension) lastNotesDimension = size;
    } else {
        lastNotesDimension = [self notesListDimension];
    }
    [splitView adjustSubviews];
}

//the list was collapsed or expanded, by the menu, a double click on the divider, or dragging it
- (void)notesListCollapsedStateMayHaveChanged {
    BOOL collapsed = [self notesListIsCollapsed];
    if (collapsed == notesWasCollapsed) {
        if (!collapsed && !splitViewIsChangingLayout) lastNotesDimension = [self notesListDimension];
        return;
    }
    notesWasCollapsed = collapsed;
    if (splitViewIsChangingLayout) return;
    [[NSUserDefaults standardUserDefaults] setBool:collapsed forKey:NotesListCollapsedKey];
    if (collapsed) {
        [self setDualFieldIsVisible:NO];
        [splitView setCustomDividerThickness:kSplitViewCollapsedDividerThickness];
        [window makeFirstResponder:textView];
    } else {
        [self setDualFieldIsVisible:YES];
        [splitView setCustomDividerThickness:kSplitViewExpandedDividerThickness];
        lastNotesDimension = [self notesListDimension];
    }
    [mainView setNeedsDisplay:YES];
}

- (void)_configureDividerForCurrentLayout {
    splitViewIsChangingLayout=YES;
    self.isEditing = NO;
	BOOL horiz = [prefsController horizontalLayout];
    CGFloat dimension = [self notesListDimension];
    BOOL collapsed = [self notesListIsCollapsed];
    [splitView setVertical:horiz];
    if (collapsed) {
        [splitView setCustomDividerThickness:kSplitViewCollapsedDividerThickness];
    } else {
        [splitView setCustomDividerThickness:kSplitViewExpandedDividerThickness];
        [self forceNotesListDimension:dimension];
        if (![self dualFieldIsVisible]) {
            [self setDualFieldIsVisible:YES];
        }
    }
    [splitView adjustSubviews];
    splitViewIsChangingLayout=NO;
    notesWasCollapsed = [self notesListIsCollapsed];
}

- (IBAction)switchViewLayout:(id)sender {
    if ([self isInFullScreen]) {
        wasVert = YES;
    }
	ViewLocationContext ctx = [notesTableView viewingLocation];
	ctx.pivotRowWasEdge = NO;
	CGFloat colW = [self notesListDimension];
    if (![splitView isVertical]) {
        colW += 30.0f;
    }else{
        colW -= 30.0f;
    }
	
	[prefsController setHorizontalLayout:![prefsController horizontalLayout] sender:self];
	[notationController updateDateStringsIfNecessary];
	[self _configureDividerForCurrentLayout];
    //the other layout's saved position is stale; start its own from this size
    NSString *layoutName = [self splitViewAutosaveNameForCurrentLayout];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[NVSplitView defaultsKeyForAutosaveName:layoutName]];
    [splitView setAutosaveName:layoutName];
    //    [notesTableView noteFirstVisibleRow];
    [self setNotesListDimension:colW];
	[notationController regenerateAllPreviews];
	[splitView adjustSubviews];
    
	[notesTableView setViewingLocation:ctx];
	[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	
	[self updateNoteMenus];
    
	[notesTableView setBackgroundColor:[[NVTheme currentTheme] backgroundColor]];
	[notesTableView setNeedsDisplay:YES];
}

- (void)createFromSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
	if (!notationController || ![self addNotesFromPasteboard:pboard]) {
		*error = NSLocalizedString(@"Error: Couldn't create a note from the selection.", @"error message to set during a Service call when adding a note failed");
	}
}



- (IBAction)renameNote:(id)sender {
    if ([self selectionContainsHereNowSite]) return;
    if ([self notesListIsCollapsed]) {
        [self toggleCollapse:sender];
    }
    //edit the first selected note
    self.isEditing = YES;
    
	[notesTableView editRowAtColumnWithIdentifier:NoteTitleColumnString];
}

- (IBAction)deleteNote:(id)sender {
	if ([self selectionContainsHereNowSite]) return;
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	if ([indexes count] > 0) {
		
		if ([prefsController confirmNoteDeletion]) {
			NSString *warningSingleFormatString = NSLocalizedString(@"Delete the note titled quotemark%@quotemark?", @"alert title when asked to delete a note");
			NSString *warningMultipleFormatString = NSLocalizedString(@"Delete %d notes?", @"alert title when asked to delete multiple notes");
			NSString *warnString = currentNote ? [NSString stringWithFormat:warningSingleFormatString, titleOfNote(currentNote)] :
			[NSString stringWithFormat:warningMultipleFormatString, [indexes count]];
			
            NSAlert *alert=[NSAlert new];
            alert.messageText=warnString;
            alert.informativeText=NSLocalizedString(@"Press Command-Z to undo this action later.", @"informational delete-this-note? text");
            [alert addButtonWithTitle:NSLocalizedString(@"Delete", @"name of delete button")];
            [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"name of cancel button")];
            [alert setShowsSuppressionButton:YES];
            [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
                if (returnCode == NSAlertFirstButtonReturn) {
                    [notationController removeNotesAtIndexes:indexes];
                }
            }];
            
		} else {
            //just delete the notes outright
            [notationController removeNotesAtIndexes:indexes];
		}
	}
}

- (IBAction)copyNoteLink:(id)sender {
	if ([self selectionContainsHereNowSite]) return;
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	if ([indexes count] == 1) {
		[[[[[notationController notesAtIndexes:indexes] lastObject]
		   uniqueNoteLink] absoluteString] copyItemToPasteboard:nil];
	}
}

- (IBAction)exportNote:(id)sender {
	if ([self selectionContainsHereNowSite]) return;
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	NSArray *notes = [notationController notesAtIndexes:indexes];
	
	[notationController synchronizeNoteChanges:nil];
	[[ExporterManager sharedManager] exportNotes:notes forWindow:window];
}

- (IBAction)editNoteExternally:(id)sender {
    if ([self selectionContainsHereNowSite]) return;
    ExternalEditor *ed = [sender representedObject];
    if ([ed isKindOfClass:[ExternalEditor class]]) {
        NSIndexSet *indexes = [notesTableView selectedRowIndexes];
        if (kCGEventFlagMaskAlternate == ((NSUInteger)CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & NSEventModifierFlagDeviceIndependentFlagsMask)) {
            //allow changing the default editor directly from Notes menu
            [[ExternalEditorListController sharedInstance] setDefaultEditor:ed];
        }
        //save queued changes first so the temporary copy the editor opens is current
        [notationController synchronizeNoteChanges:nil];
        [[notationController notesAtIndexes:indexes] makeObjectsPerformSelector:@selector(editExternallyUsingEditor:) withObject:ed];
    } else {
        NSBeep();
    }
}

- (IBAction)previewNoteWithMarked:(id)sender {
    if ([self selectionContainsHereNowSite]) return;
    if (![[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marked2"] isFileURL] && ![[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marky"] isFileURL] && ![[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marked-setapp"] isFileURL] && ![[[NSWorkspace sharedWorkspace]URLForApplicationWithBundleIdentifier:@"com.brettterpstra.marked2.beta"] isFileURL])
    {
        NSBeep();
        NSLog(@"Marked not found");
    } else {
        NSIndexSet *indexes = [notesTableView selectedRowIndexes];
        //save queued changes first so the temporary copy Marked opens is current
        [notationController synchronizeNoteChanges:nil];
        [[notationController notesAtIndexes:indexes] makeObjectsPerformSelector:@selector(previewUsingMarked)];
    }
}

- (IBAction)printNote:(id)sender {
    if ([self selectionContainsHereNowSite]) return;
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	[MultiplePageView printNotes:[notationController notesAtIndexes:indexes] forWindow:window];
}

- (IBAction)tagNote:(id)sender {
    if ([self selectionContainsHereNowSite]) return;
    
    if ([self notesListIsCollapsed]) {
        [self toggleCollapse:sender];
    }
	//if single note, add the tag column if necessary and then begin editing
	
	NSIndexSet *selIndexes = [notesTableView selectedRowIndexes];
	
	if ([selIndexes count] > 1) {
        
        NSRect linkingFrame=[textScrollView convertRect:[textScrollView frame] toView:nil];
        
        linkingFrame=[window convertRectToScreen:linkingFrame];
        NSPoint cPoint=NSMakePoint(NSMidX(linkingFrame), NSMaxY(linkingFrame));
        
        //Multiple Notes selected, use ElasticThreads' multitagging implementation
        tagEditor = [[TagEditingManager alloc] initWithDelegate:self commonTags:[self commonLabelsForNotesAtIndexes:selIndexes] atPoint:cPoint];
        
		//Multiple Notes selected, use ElasticThreads' multitagging implementation
	} else if ([selIndexes count] == 1) {
        self.isEditing = YES;
		[notesTableView editRowAtColumnWithIdentifier:NoteLabelsColumnString];
	}
}

- (void)noteImporter:(AlienNoteImporter*)importer importedNotes:(NSArray*)notes {
	
	[notationController addNotes:notes];
}
- (IBAction)importNotes:(id)sender {
	AlienNoteImporter *importer = [[AlienNoteImporter alloc] init];
	[importer importNotesFromDialogAroundWindow:window receptionDelegate:self];
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    if ([selectorString isEqualToString:SEL_STR(setSortedTableColumnKey:reversed:sender:)]) {
		NoteAttributeColumn *oldSortCol = [notationController sortColumn];
		NoteAttributeColumn *newSortCol = [notesTableView noteAttributeColumnForIdentifier:[prefsController sortedTableColumnKey]];
		BOOL changedColumns = oldSortCol != newSortCol;
		
		ViewLocationContext ctx;
		if (changedColumns) {
			ctx = [notesTableView viewingLocation];
			ctx.pivotRowWasEdge = NO;
		}
		
		[notationController setSortColumn:newSortCol];
		
		if (changedColumns) [notesTableView setViewingLocation:ctx];
		
	} else if ([selectorString isEqualToString:SEL_STR(setNoteBodyFont:sender:)]) {
		
		[notationController restyleAllNotes];
		if (currentNote) {
			[self contentsUpdatedForNote:currentNote];
		}
	} else if ([selectorString isEqualToString:SEL_STR(setForegroundTextColor:sender:)] ||
			   [selectorString isEqualToString:SEL_STR(setBackgroundTextColor:sender:)]) {
		//choosing a colour in Settings switches to the custom scheme
		[[NVTheme currentTheme] customColorsDidChange];
		
	} else if ([selectorString isEqualToString:SEL_STR(setTableFontSize:sender:)] || [selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) {
		
		ResetFontRelatedTableAttributes();
		[notesTableView updateTitleDereferencorState];
		[[notationController labelsListDataSource] invalidateCachedLabelImages];
		[self _forceRegeneratePreviewsForTitleColumn];
        
		if ([selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) [self updateNoteMenus];
		
		[notesTableView performSelector:@selector(reloadData) withObject:nil afterDelay:0];
	} else if ([selectorString isEqualToString:SEL_STR(addTableColumn:sender:)] || [selectorString isEqualToString:SEL_STR(removeTableColumn:sender:)]) {
		
		ResetFontRelatedTableAttributes();
		[self _forceRegeneratePreviewsForTitleColumn];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0];
		
	} else if ([selectorString isEqualToString:SEL_STR(setConfirmNoteDeletion:sender:)]) {
		[self updateNoteMenus];
	} else if ([selectorString isEqualToString:SEL_STR(setAutoCompleteSearches:sender:)]) {
		if ([prefsController autoCompleteSearches])
			[notationController updateTitlePrefixConnections];
		
	}
	
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn {
    if (tableView == notesTableView) {
		//this sets global prefs options, which ultimately calls back to us
		[notesTableView setStatusForSortedColumn:tableColumn];
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldShowCellExpansionForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	return ![[tableColumn identifier] isEqualToString:NoteTitleColumnString];
}

- (IBAction)showHelpDocument:(id)sender {
	NSString *path = nil;
	
	switch ([sender tag]) {
		case 1:		//shortcuts
			path = [[NSBundle mainBundle] pathForResource:NSLocalizedString(@"Excruciatingly Useful Shortcuts", nil) ofType:@"nvhelp" inDirectory:nil];
		case 2:		//acknowledgments
			if (!path) path = [[NSBundle mainBundle] pathForResource:@"Acknowledgments" ofType:@"txt" inDirectory:nil];
			{
				NSURL *textEditURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
				if (textEditURL && path) {
					[[NSWorkspace sharedWorkspace] openURLs:[NSArray arrayWithObject:[NSURL fileURLWithPath:path]] withApplicationAtURL:textEditURL
											  configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
				}
			}
			break;
		case 3:		//product site
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:NSLocalizedString(@"SiteURL", nil)]];
			break;
		case 4:		//development site
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/ttscoff/nv/wiki"]];
			break;
        case 5:     //Notational home
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/gsiener/notational"]];
            break;
        case 6:     //ElasticThreads
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://elasticthreads.tumblr.com/nv"]];
            break;
        case 7:     //Brett Terpstra
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://brettterpstra.com"]];
            break;
		default:
			NSBeep();
	}
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames {
	
	if (notationController)
		[notationController openFiles:filenames];
	else
		pathsToOpenOnLaunch = [filenames mutableCopyWithZone:nil];
	
	[NSApp replyToOpenOrPrint:[filenames count] ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
}

//- (void)applicationWillBecomeActive:(NSNotification *)aNotification {
//	
//	if (IsLeopardOrLater) {
//		SpaceSwitchingContext thisSpaceSwitchCtx;
//        if ([window windowNumber]!=-1) {
//            CurrentContextForWindowNumber([window windowNumber], &thisSpaceSwitchCtx);
//            
//        }
//		//what if the app is switched-to in another way? then the last-stored spaceSwitchCtx will cause us to return to the wrong app
//		//unfortunately this notification occurs only after NV has become the front process, but we can still verify the space number
//		
//		if ((thisSpaceSwitchCtx.userSpace != spaceSwitchCtx.userSpace) ||
//			(thisSpaceSwitchCtx.windowSpace != spaceSwitchCtx.windowSpace)) {
//			//forget the last space-switch info if it's effectively different from how we're switching into the app now
//			bzero(&spaceSwitchCtx, sizeof(SpaceSwitchingContext));
//		}
//	}
//}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
	[notationController updateDateStringsIfNecessary];
	[[notationController syncEngine] setInBackground:NO];
	[[notationController syncEngine] syncNow];
	if ([hereNowSites connected] && (!lastHereNowActivationRefresh || [[NSDate date] timeIntervalSinceDate:lastHereNowActivationRefresh] > 300)) {
		lastHereNowActivationRefresh = [NSDate date];
		[hereNowSites refresh];
	}
}

- (void)applicationWillResignActive:(NSNotification *)aNotification {
	//sync note files when switching apps so user doesn't have to guess when they'll be updated
	[notationController synchronizeNoteChanges:nil];
	[[notationController syncEngine] setInBackground:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
    
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
	static NSMenu *dockMenu = nil;
	if (!dockMenu) {
		dockMenu = [[NSMenu alloc] initWithTitle:@"NV Dock Menu"];
		[[dockMenu addItemWithTitle:NSLocalizedString(@"Add New Note from Clipboard", @"menu item title in dock menu")
							 action:@selector(paste:) keyEquivalent:@""] setTarget:notesTableView];
	}
	return dockMenu;
}

- (void)cancel:(id)sender {
	//fallback for when other views are hidden/removed during toolbar collapse
	[self cancelOperation:sender];
}

- (void)cancelOperation:(id)sender {
	//simulate a search for nothing
	if ([window isKeyWindow]) {
		if ([textView textFinderIsVisible]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"TextFinderShouldHide" object:self];
            return;
        }
		[field setStringValue:@""];
		typedStringIsCached = NO;
		
		[notesTableView deselectAll:sender];//thiss
		[notationController filterNotesFromString:@""];
		hereNowSearchQuery = @"";
		if (mixedList) { [mixedList filterSitesForString:hereNowSearchQuery]; [notesTableView reloadData]; }
		//was here
        [self setDualFieldIsVisible:YES];
        //		[self _expandToolbar];
		
		[field selectText:sender];
		[[field cell] setShowsClearButton:NO];
	}
}



- (BOOL)control:(NSControl *)control textView:(NSTextView *)aTextView doCommandBySelector:(SEL)command {
	if (control == (NSControl*)field) {
		
        self.isEditing=NO;
		//backwards-searching is slow enough as it is, so why not just check this first?
		if (command == @selector(deleteBackward:))
			return NO;
		
		if (command == @selector(moveDown:) || command == @selector(moveUp:) ||
			//catch shift-up/down selection behavior
			command == @selector(moveDownAndModifySelection:) ||
			command == @selector(moveUpAndModifySelection:) ||
			command == @selector(moveToBeginningOfDocumentAndModifySelection:) ||
			command == @selector(moveToEndOfDocumentAndModifySelection:)) {
			
			BOOL singleSelection = ([notesTableView numberOfRows] == 1 && [notesTableView numberOfSelectedRows] == 1);
			[notesTableView keyDown:[window currentEvent]];
			
			NSUInteger strLen = [[aTextView string] length];
			if (!singleSelection && [aTextView selectedRange].length != strLen) {
				[aTextView setSelectedRange:NSMakeRange(0, strLen)];
			}
			
			return YES;
		}
		
		if ((command == @selector(insertTab:) || command == @selector(insertTabIgnoringFieldEditor:))) {
			//[self setEmptyViewState:NO];
			if (![[aTextView string] length]) {
				return YES;
			}
			if (!currentNote && [notationController preferredSelectedNoteIndex] != NSNotFound && [prefsController autoCompleteSearches]) {
				//if the current note is deselected and re-searching would auto-complete this search, then allow tab to trigger it
				[self searchForString:[self fieldSearchString]];
				return YES;
			} else if ([textView isHidden]) {
				return YES;
			}
			
			[window makeFirstResponder:textView];
			
			//don't eat the tab!
			return NO;
		}
		if (command == @selector(moveToBeginningOfDocument:)) {
		    [notesTableView selectRowAndScroll:0];
		    return YES;
		}
		if (command == @selector(moveToEndOfDocument:)) {
		    [notesTableView selectRowAndScroll:[notesTableView numberOfRows]-1];
		    return YES;
		}
		
		if (command == @selector(moveToBeginningOfLine:) || command == @selector(moveToLeftEndOfLine:)) {
			[aTextView moveToBeginningOfDocument:nil];
			return YES;
		}
		if (command == @selector(moveToEndOfLine:) || command == @selector(moveToRightEndOfLine:)) {
			[aTextView moveToEndOfDocument:nil];
			return YES;
		}
		
		if (command == @selector(moveToBeginningOfLineAndModifySelection:) || command == @selector(moveToLeftEndOfLineAndModifySelection:)) {
			
			if ([aTextView respondsToSelector:@selector(moveToBeginningOfDocumentAndModifySelection:)]) {
				[(id)aTextView performSelector:@selector(moveToBeginningOfDocumentAndModifySelection:)];
				return YES;
			}
		}
		if (command == @selector(moveToEndOfLineAndModifySelection:) || command == @selector(moveToRightEndOfLineAndModifySelection:)) {
			if ([aTextView respondsToSelector:@selector(moveToEndOfDocumentAndModifySelection:)]) {
				[(id)aTextView performSelector:@selector(moveToEndOfDocumentAndModifySelection:)];
				return YES;
			}
		}
		
		//we should make these two commands work for linking editor as well
		if (command == @selector(deleteToMark:)) {
			[aTextView deleteWordBackward:nil];
			return YES;
		}
		if (command == NSSelectorFromString(@"noop:")) {
			//control-U is not set to anything by default, so we have to check the event itself for noops
			NSEvent *event = [window currentEvent];
			if ([event modifierFlags] & NSEventModifierFlagControl) {
				if ([event firstCharacterIgnoringModifiers] == 'u') {
					//in 1.1.1 this deleted the entire line, like tcsh. this is more in-line with bash
					[aTextView deleteToBeginningOfLine:nil];
					return YES;
				}
			}
		}
		
	} else if (control == (NSControl*)notesTableView) {
		
		if (command == @selector(insertNewline:)) {
			//hit return in cell
            self.isEditing=NO;
			[window makeFirstResponder:textView];
			return YES;
		}
	} else if (control == [tagEditor tagField]) {
		if ((command == @selector(insertNewline:))||(command == @selector(insertTab:))) {
            if ([aTextView selectedRange].length>0) {
                NSString *fieldStr=[aTextView string];
                NSInteger len=fieldStr.length;
                if ((![fieldStr hasSuffix:@","])&&![fieldStr hasSuffix:@" "]) {
                    [aTextView insertText:@"," replacementRange:NSMakeRange(len, 0)];
                    len++;
                }
                [aTextView setSelectedRange:NSMakeRange(len, 0)];
                return YES;
            }
		}else {
            if ((command == @selector(deleteBackward:))||(command == @selector(deleteForward:))) {
                wasDeleting = YES;
            }
            return NO;
		}
	} else{
        
		NSLog(@"%@/%@ got %@", [control description], [aTextView description], NSStringFromSelector(command));
        self.isEditing=NO;
    }
	
	return NO;
}

- (void)_setCurrentNote:(NoteObject*)aNote {
	if (currentNote != aNote) {
		if (!editorUndoByNote) editorUndoByNote = [NSMapTable weakToStrongObjectsMapTable];
		if (!editorUndoRecentNotes) editorUndoRecentNotes = [NSMutableArray array];
		if (editorUndoNote == currentNote && editorUndoStates) {
			[editorUndoByNote setObject:@{ @"states": editorUndoStates,
											  @"index": [NSNumber numberWithInteger:editorUndoIndex] }
							 forKey:currentNote];
			[editorUndoRecentNotes removeObjectIdenticalTo:currentNote];
			[editorUndoRecentNotes addObject:currentNote];
		}
		while ([editorUndoRecentNotes count] > NVEditorUndoMaxNotes) {
			NoteObject *oldest = [editorUndoRecentNotes objectAtIndex:0];
			[editorUndoByNote removeObjectForKey:oldest];
			[editorUndoRecentNotes removeObjectAtIndex:0];
		}
		NSDictionary *saved = [editorUndoByNote objectForKey:aNote];
		if (saved) {
			[editorUndoRecentNotes removeObjectIdenticalTo:aNote];
			[editorUndoRecentNotes addObject:aNote];
		}
		editorUndoStates = [saved objectForKey:@"states"];
		editorUndoIndex = saved ? [[saved objectForKey:@"index"] integerValue] : 0;
		editorUndoNote = saved ? aNote : nil;
		editorUndoGroupClosed = YES;
		editorUndoNeedsRebuild = NO;
	}
	//save range of old current note
	//we really only want to save the insertion point position if it's currently invisible
	//how do we test that?
	BOOL wasAutomatic = NO;
	NSRange currentRange = [textView selectedRangeWasAutomatic:&wasAutomatic];
	if (!wasAutomatic) [currentNote setSelectedRange:currentRange];
	
	//regenerate content cache before switching to new note
	[currentNote updateContentCacheCStringIfNecessary];
	
	
	currentNote = aNote;
}

- (NoteObject*)selectedNoteObject {
	return currentNote;
}

- (NSString*)fieldSearchString {
	NSString *typed = [self typedString];
	if (typed) return typed;
	
	if (!currentNote) return [field stringValue];
	
	return nil;
}

- (NSString*)typedString {
	if (typedStringIsCached)
		return typedString;
	
	return nil;
}

- (void)cacheTypedStringIfNecessary:(NSString*)aString {
	if (!typedStringIsCached) {
		typedString = [(aString ? aString : [field stringValue]) copy];
		typedStringIsCached = YES;
	}
}

//from fieldeditor
- (void)controlTextDidChange:(NSNotification *)aNotification {
    
	if ([aNotification object] == field) {
		typedStringIsCached = NO;
		isFilteringFromTyping = YES;
		
		NSTextView *fieldEditor = [[aNotification userInfo] objectForKey:@"NSFieldEditor"];
		NSString *fieldString = [fieldEditor string];
		
		BOOL didFilter = [notationController filterNotesFromString:fieldString];
		hereNowSearchQuery = [fieldString copy];
		if (mixedList) { [mixedList filterSitesForString:fieldString]; [notesTableView reloadData]; }
		
		if ([fieldString length] > 0) {
//             [[NSNotificationCenter defaultCenter] postNotificationName:@"TextFindContextShouldReset" object:self];
			[field setSnapbackString:nil];
			
            
			NSUInteger preferredNoteIndex = [notationController preferredSelectedNoteIndex];
			
			//lastLengthReplaced depends on textView:shouldChangeTextInRange:replacementString: being sent before controlTextDidChange: runs
			if ([prefsController autoCompleteSearches] && preferredNoteIndex != NSNotFound && ([field lastLengthReplaced] > 0)) {
				
				[notesTableView selectRowAndScroll:preferredNoteIndex];
				
				if (didFilter) {
					//current selection may be at the same row, but note at that row may have changed
					[self displayContentsForNoteAtIndex:preferredNoteIndex];
				}
				
				NSAssert(currentNote != nil, @"currentNote must not--cannot--be nil!");
				
				NSRange typingRange = [fieldEditor selectedRange];
				
				//fill in the remaining characters of the title and select
				if ([field lastLengthReplaced] > 0 && typingRange.location < [titleOfNote(currentNote) length]) {
					
					[self cacheTypedStringIfNecessary:fieldString];
					
					NSAssert([fieldString isEqualToString:[fieldEditor string]], @"I don't think it makes sense for fieldString to change");
					
					NSString *remainingTitle = [titleOfNote(currentNote) substringFromIndex:typingRange.location];
					typingRange.length = [fieldString length] - typingRange.location;
					typingRange.length = MAX(typingRange.length, 0U);
					
					[fieldEditor replaceCharactersInRange:typingRange withString:remainingTitle];
					typingRange.length = [remainingTitle length];
					[fieldEditor setSelectedRange:typingRange];
				}
				
			} else {
				//auto-complete is off, search string doesn't prefix any title, or part of the search string is being removed
				goto selectNothing;
			}
		} else {
			//selecting nothing; nothing typed
		selectNothing:
			isFilteringFromTyping = NO;
			[notesTableView deselectAll:nil];
			
			//reloadData could have already de-selected us, and hence this notification would not be sent from -deselectAll:
			[self processChangedSelectionForTable:notesTableView];
		}
		
		isFilteringFromTyping = NO;
        
	} else if ([tagEditor isMultitagging]) { //<--for elasticthreads multitagging
        if (!isAutocompleting&&!wasDeleting) {
            isAutocompleting = YES;
            NSTextView *editor = [tagEditor tagFieldEditor];
            NSRange selRange = [editor selectedRange];
            NSString *tagString = [NSString stringWithString:tagEditor.tagFieldString];
            NSString *searchString = tagString;
            if (selRange.length>0) {
                searchString = [searchString substringWithRange:selRange];
            }
            searchString = [[searchString componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]] lastObject];
            selRange = [tagString rangeOfString:searchString options:NSBackwardsSearch];
            NSArray *theTags = [notesTableView labelCompletionsForString:searchString index:0];
            if ((theTags)&&([theTags count]>0)&&(![[theTags objectAtIndex:0] isEqualToString:@""])){
                NSString *useStr;
                for (useStr in theTags) {
                    if ([tagString rangeOfString:useStr].location==NSNotFound) {
                        break;
                    }
                }
                if (useStr) {
                    tagString = [tagString substringToIndex:selRange.location];
                    tagString = [tagString stringByAppendingString:useStr];
                    selRange = NSMakeRange(selRange.location + selRange.length, useStr.length - searchString.length );
                    [tagEditor setTF:tagString];
                    [editor setSelectedRange:selRange];
                }
            }
            isAutocompleting = NO;
            //            [tagString release];
        }
        wasDeleting = NO;
    }
}

- (void)tableViewSelectionIsChanging:(NSNotification *)aNotification {
	
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TextFindContextShouldReset" object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
    
	BOOL allowMultipleSelection = NO;
	NSEvent *event = [window currentEvent];
    
	NSEventType type = [event type];
	//do not allow drag-selections unless a modifier is pressed
	if (type == NSEventTypeLeftMouseDragged || type == NSEventTypeLeftMouseDown) {
		NSUInteger flags = [event modifierFlags];
		if ((flags & NSEventModifierFlagShift) || (flags & NSEventModifierFlagCommand)) {
			allowMultipleSelection = YES;
		}
	}
	
	if (allowMultipleSelection != [notesTableView allowsMultipleSelection]) {
		//we may need to hack some hidden NSTableView instance variables to improve mid-drag flags-changing
		//NSLog(@"set allows mult: %d", allowMultipleSelection);
		
		[notesTableView setAllowsMultipleSelection:allowMultipleSelection];
		
		//we need this because dragging a selection back to the same note will nto trigger a selectionDidChange notification
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}
    
	if ([window firstResponder] != notesTableView) {
		//occasionally changing multiple selection ability in-between selecting multiple items causes total deselection
		[window makeFirstResponder:notesTableView];
	}
	
	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)setTableAllowsMultipleSelection {
	[notesTableView setAllowsMultipleSelection:YES];
	//NSLog(@"allow mult: %d", [notesTableView allowsMultipleSelection]);
	//[textView setNeedsDisplay:YES];
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TextFindContextShouldUpdate" object:self];
    self.isEditing = NO;
	NSEventType type = [[window currentEvent] type];
	if (type != NSEventTypeKeyDown && type != NSEventTypeKeyUp) {
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}
	
	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)processChangedSelectionForTable:(NSTableView*)table {
	NSInteger selectedRow = [table selectedRow];
	NSInteger numberSelected = [table numberOfSelectedRows];
	
	NSTextView *fieldEditor = (NSTextView*)[field currentEditor];
	
	if (table == (NSTableView*)notesTableView) {
		if ([self selectionContainsHereNowSite]) {
			[self _setCurrentNote:nil];
			[textView setString:@""];
			[self setEmptyViewState:YES];
			NVHereNowSite *site = [mixedList siteAtRow:selectedRow];
			[window setTitle:site ? [NSString stringWithFormat:@"%@ — here.now (read-only)%@", site.title, hereNowSites.stale ? @" — saved" : @""] : @"here.now Sites (read-only)"];
			return;
		}
		
		if (selectedRow > -1 && numberSelected == 1) {
			//if it is uncached, cache the typed string only if we are selecting a note
			
			[self cacheTypedStringIfNecessary:[fieldEditor string]];
			
			//add snapback-button here?
			if (!isFilteringFromTyping && !isCreatingANote)
				[field setSnapbackString:typedString];
			
			if ([self displayContentsForNoteAtIndex:(NSUInteger)selectedRow]) {
				
				[[field cell] setShowsClearButton:YES];
				
				//there doesn't seem to be any situation in which a note will be selected
				//while the user is typing and auto-completion is disabled, so should be OK
                
				if (!isFilteringFromTyping) {
                    //	if ([toolbar isVisible]) {
                    if ([self dualFieldIsVisible]) {
						if (fieldEditor) {
							//the field editor has focus--select text, too
							[fieldEditor setString:titleOfNote(currentNote)];
							NSUInteger strLen = [titleOfNote(currentNote) length];
							if (strLen != [fieldEditor selectedRange].length)
								[fieldEditor setSelectedRange:NSMakeRange(0, strLen)];
						} else {
							//this could be faster
							[field setStringValue:titleOfNote(currentNote)];
						}
					} else {
						[window setTitle:titleOfNote(currentNote)];
					}
				}
			}
			return;
		}
	} else { //tags
#if 0
		if (numberSelected == 1)
			[notationController filterNotesFromLabelAtIndex:selectedRow];
		else if (numberSelected > 1)
			[notationController filterNotesFromLabelIndexSet:[table selectedRowIndexes]];
#endif
	}
	
	if (!isFilteringFromTyping) {
		if (currentNote) {
			//selected nothing and something is currently selected
			
			[self _setCurrentNote:nil];
			[field setShowsDocumentIcon:NO];
			
			if (typedStringIsCached) {
				//restore the un-selected state, but only if something had been first selected to cause that state to be saved
				[field setStringValue:typedString];
			}
			[textView setString:@""];
		}
		//[self _expandToolbar];
        [self setDualFieldIsVisible:YES];
        [mainView setNeedsDisplay:YES];
		if (!currentNote) {
			if (selectedRow == -1 && (!fieldEditor || [window firstResponder] != fieldEditor)) {
				//don't select the field if we're already there
				[window makeFirstResponder:field];
				fieldEditor = (NSTextView*)[field currentEditor];
			}
			if (fieldEditor && [fieldEditor selectedRange].length)
				[fieldEditor setSelectedRange:NSMakeRange([[fieldEditor string] length], 0)];
			
			
			//remove snapback-button from dual field here?
			[field setSnapbackString:nil];
			
			if (!numberSelected && savedSelectedNotes) {
				//savedSelectedNotes needs to be empty after de-selecting all notes,
				//to ensure that any delayed list-resorting does not re-select savedSelectedNotes
                
				savedSelectedNotes = nil;
			}
		}
	}
	[self setEmptyViewState:currentNote == nil];
	[field setShowsDocumentIcon:currentNote != nil];
	[[field cell] setShowsClearButton:currentNote != nil || [[field stringValue] length]];
}


- (BOOL)setNoteIfNecessary{
    if (currentNote==nil) {
        [notesTableView selectRowAndScroll:0];
        return (currentNote!=nil);
    }
    return YES;
}

- (void)setEmptyViewState:(BOOL)state {
    //return;
	
	//int numberSelected = [notesTableView numberOfSelectedRows];
	//BOOL enable = /*numberSelected != 1;*/ state;
    
	[self postTextUpdate];
    [self updateWordCount:![prefsController showWordCount]];
	[textView setHidden:state];
	[editorStatusView setHidden:!state];
	[editorStatusView setShowsSignIn:state && [notesTableView numberOfRows] == 0 &&
		[accountSession status] == NVSyncStatusSignedOut];
	
	if (state) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TextFinderShouldHide" object:self];
		[editorStatusView setLabelStatus:[notesTableView numberOfSelectedRows]];
        if ([self notesListIsCollapsed]) {
            [self toggleCollapse:self];
        }
	}
}

- (BOOL)displayContentsForNoteAtIndex:(NSUInteger)noteIndex {
	NoteObject *note = [notationController noteObjectAtFilteredIndex:noteIndex];
	if (note != currentNote) {
		[self setEmptyViewState:NO];
		[field setShowsDocumentIcon:YES];
		
		//actually load the new note
		[self _setCurrentNote:note];
		
		NSRange firstFoundTermRange = NSMakeRange(NSNotFound,0);
		NSRange noteSelectionRange = [currentNote lastSelectedRange];
		
		if (noteSelectionRange.location == NSNotFound ||
			NSMaxRange(noteSelectionRange) > [[note contentString] length]) {
			//revert to the top; selection is invalid
			noteSelectionRange = NSMakeRange(0,0);
		}
		
		//[textView beginInhibitingUpdates];
		//scroll to the top first in the old note body if necessary, because the text will (or really ought to) have already been laid-out
		//if ([textView visibleRect].origin.y > 0)
		//	[textView scrollRangeToVisible:NSMakeRange(0,0)];
		
		if (![textView didRenderFully]) {
			//NSLog(@"redisplay because last note was too long to finish before we switched");
			[textView setNeedsDisplayInRect:[textView visibleRect] avoidAdditionalLayout:YES];
		}
		
		//restore string
		[[textView textStorage] setAttributedString:[note contentString]];
		[self postTextUpdate];
		[self updateWordCount:(![prefsController showWordCount])];
		//[textView setAutomaticallySelectedRange:NSMakeRange(0,0)];
		
		//highlight terms--delay this, too
		if ((unsigned)noteIndex != [notationController preferredSelectedNoteIndex])
			firstFoundTermRange = [textView highlightTermsTemporarilyReturningFirstRange:typedString avoidHighlight:
								   ![prefsController highlightSearchTerms]];
		
		//if there was nothing selected, select the first found range
		if (!noteSelectionRange.length && firstFoundTermRange.location != NSNotFound)
			noteSelectionRange = firstFoundTermRange;
		
		//select and scroll
		[textView setAutomaticallySelectedRange:noteSelectionRange];
		[textView scrollRangeToVisible:noteSelectionRange];
		
		//NSString *words = noteIndex != [notationController preferredSelectedNoteIndex] ? typedString : nil;
		//[textView setFutureSelectionRange:noteSelectionRange highlightingWords:words];
		
        [self updateRTL];
        
		return YES;
	}
	
	return NO;
}

//from linkingeditor
- (void)_editorUndoGroupDidClose:(NSNotification *)notification {
	if ([notification object] == [currentNote undoManager]) {
		editorUndoGroupClosed = YES;
		if (editorUndoNeedsRebuild && !rebuildingEditorUndoActions &&
			[[notification object] groupingLevel] == 0)
			[self _rebuildSelectedEditorUndoActions];
	}
}

- (void)_rebuildSelectedEditorUndoActions {
	if (!editorUndoNeedsRebuild || rebuildingEditorUndoActions || !currentNote) return;
	NSUndoManager *manager = [currentNote undoManager];
	if ([manager groupingLevel] != 0) return;
	rebuildingEditorUndoActions = YES;
	[manager removeAllActions];
	BOOL groupedByEvent = [manager groupsByEvent];
	[manager setGroupsByEvent:NO];
	for (NSInteger i = 0; i < editorUndoIndex; i++) {
		[manager beginUndoGrouping];
		[manager registerUndoWithTarget:self selector:@selector(_applyRebasedEditorUndoState:)
							 object:[NSNumber numberWithInteger:i]];
		[manager endUndoGrouping];
	}
	[manager setGroupsByEvent:groupedByEvent];
	rebuildingEditorUndoActions = NO;
	editorUndoNeedsRebuild = NO;
}

- (void)textDidChange:(NSNotification *)aNotification {
	id textObject = [aNotification object];
    //[self resetModTimers];
	if (textObject == textView) {
		if (applyingRemoteOrRebasedText) return;
		NSUndoManager *manager = [currentNote undoManager];
		NSString *before = [[[currentNote contentString] string] copy];
		NSString *after = [[textView string] copy];
		if (currentNote && ![before isEqualToString:after]) {
			if (!observingEditorUndoGroups) {
				[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_editorUndoGroupDidClose:)
									 name:NSUndoManagerDidCloseUndoGroupNotification object:nil];
				observingEditorUndoGroups = YES;
			}
			if (editorUndoNote != currentNote || !editorUndoStates) {
				editorUndoNote = currentNote;
				editorUndoStates = [NSMutableArray arrayWithObject:before];
				editorUndoIndex = 0;
				editorUndoGroupClosed = YES;
			}
			if ([manager isUndoing]) {
				BOOL found = NO;
				for (NSInteger i = editorUndoIndex - 1; i >= 0; i--) {
					if ([[editorUndoStates objectAtIndex:i] isEqualToString:after]) {
						editorUndoIndex = i;
						found = YES;
						break;
					}
				}
				if (!found) {
					editorUndoStates = [NSMutableArray arrayWithObject:after];
					editorUndoIndex = 0;
				}
			} else if ([manager isRedoing]) {
				BOOL found = NO;
				for (NSInteger i = editorUndoIndex + 1; i < (NSInteger)[editorUndoStates count]; i++) {
					if ([[editorUndoStates objectAtIndex:i] isEqualToString:after]) {
						editorUndoIndex = i;
						found = YES;
						break;
					}
				}
				if (!found) {
					editorUndoStates = [NSMutableArray arrayWithObject:after];
					editorUndoIndex = 0;
				}
			} else {
				while ([editorUndoStates count] > editorUndoIndex + 1) [editorUndoStates removeLastObject];
				if (editorUndoGroupClosed || editorUndoIndex == 0) {
					[editorUndoStates addObject:after];
					editorUndoIndex++;
				} else {
					[editorUndoStates replaceObjectAtIndex:editorUndoIndex withObject:after];
				}
				editorUndoGroupClosed = NO;
				NSUInteger bytes = 0;
				for (NSString *state in editorUndoStates) bytes += [state length] * sizeof(unichar);
				while ([editorUndoStates count] > 2 &&
						([editorUndoStates count] > NVEditorUndoMaxStates || bytes > NVEditorUndoMaxBytes)) {
					bytes -= [[editorUndoStates objectAtIndex:0] length] * sizeof(unichar);
					[editorUndoStates removeObjectAtIndex:0];
					editorUndoIndex--;
					editorUndoNeedsRebuild = YES;
				}
				if (editorUndoNeedsRebuild)
					[self performSelector:@selector(_rebuildSelectedEditorUndoActions) withObject:nil afterDelay:0];
			}
		}
		[currentNote setContentString:[textView textStorage]];
		[self postTextUpdate];
		[self updateWordCount:(![prefsController showWordCount])];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TextFindContextShouldUpdate" object:self];
	}
    
    
}

//The text system keeps replacement ranges in its undo actions. Once a remote edit
//moves those ranges, replace the actions with whole-state transitions rebased over
//the new text. An overlapping remote line wins when a local step is undone.
- (void)_applyRebasedEditorUndoState:(NSNumber *)targetIndex {
	if (editorUndoNote != currentNote || !editorUndoStates) return;
	NSInteger target = [targetIndex integerValue];
	if (target < 0 || target >= (NSInteger)[editorUndoStates count]) return;
	NSUndoManager *manager = [currentNote undoManager];
	[manager registerUndoWithTarget:self selector:@selector(_applyRebasedEditorUndoState:)
							 object:[NSNumber numberWithInteger:editorUndoIndex]];
	NSString *body = [editorUndoStates objectAtIndex:target];
	NSAttributedString *content = [[NSAttributedString alloc] initWithString:body
											 attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	applyingRemoteOrRebasedText = YES;
	NSArray *moved = [NVTextMerge updateStorage:[textView textStorage] toContent:content
									 selectedRanges:[textView selectedRanges]];
	[textView setSelectedRanges:moved];
	[textView breakUndoCoalescing];
	applyingRemoteOrRebasedText = NO;
	editorUndoIndex = target;
	[currentNote setContentString:[textView textStorage]];
	[self postTextUpdate];
	[self updateWordCount:(![prefsController showWordCount])];
}

- (void)textDidBeginEditing:(NSNotification *)aNotification {
	if ([aNotification object] == textView) {
		[textView removeHighlightedTerms];
	    [self createNoteIfNecessary];
	}/*else if ([aNotification object] == notesTableView) {
      NSLog(@"ntv tdbe2");
      }*/
}

- (BOOL)textShouldBeginEditing:(NSText *)aTextObject {
    if (aTextObject==textView) {
        [[NSNotificationCenter defaultCenter]postNotificationName:@"TextFindContextShouldNoteChanges" object:nil];
        
    }else{
        
        NSLog(@"not textview should begin with to:%@",[aTextObject description]);
    }
    return YES;
    
}

/*
 - (void)controlTextDidBeginEditing:(NSNotification *)aNotification{
 NSLog(@"controltextdidbegin");
 }
*/
- (void)textDidEndEditing:(NSNotification *)aNotification {
	if ([aNotification object] == textView) {
		//save last selection range for currentNote?
		//[currentNote setSelectedRange:[textView selectedRange]];
		
		//we need to set this here as we could return to searching before changing notes
		//and the next time the note would change would be when searching had triggered it
		//which would be too late
		[currentNote updateContentCacheCStringIfNecessary];
	}
}

- (NSMenu *)textView:(NSTextView *)view menu:(NSMenu *)menu forEvent:(NSEvent *)event atIndex:(NSUInteger)charIndex {
    //    NSLog(@"textview menu for event");
	NSInteger idx;
	if ((idx = [menu indexOfItemWithTarget:nil andAction:NSSelectorFromString(@"_removeLinkFromMenu:")]) > -1)
		[menu removeItemAtIndex:idx];
	if ((idx = [menu indexOfItemWithTarget:nil andAction:@selector(orderFrontLinkPanel:)]) > -1)
		[menu removeItemAtIndex:idx];
	return menu;
}

- (NSArray *)textView:(NSTextView *)aTextView completions:(NSArray *)words
  forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)anIndex {
	NSArray *noteTitles = [notationController noteTitlesPrefixedByString:[[aTextView string] substringWithRange:charRange] indexOfSelectedItem:anIndex];
	return noteTitles;
}


- (IBAction)fieldAction:(id)sender {
	
	[self createNoteIfNecessary];
	[window makeFirstResponder:textView];
	
}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)sender {
	
	if ([sender firstResponder] == textView) {
		if (currentNote) {
			NSLog(@"windowWillReturnUndoManager should not be called when textView is first responder on Tiger or higher");
		}
		
		NSUndoManager *undoMan = [self undoManagerForTextView:textView];
		if (undoMan)
			return undoMan;
	}
	return windowUndoManager;
}

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)aTextView {
    if (aTextView == textView && currentNote)
		return [currentNote undoManager];
    
    return nil;
}

- (NoteObject*)createNoteIfNecessary {
    
    if (!currentNote) {
		//this assertion not yet valid until labels list changes notes list
		NSAssert([notesTableView numberOfSelectedRows] != 1, @"cannot create a note when one is already selected");
		
		[textView setTypingAttributes:[prefsController noteBodyAttributes]];
		[textView setFont:[prefsController noteBodyFont]];
		
		isCreatingANote = YES;
		//the search field's text then anything already in the editor is the new note's content, split into
		//title and body as the Notes store splits it: a long name wraps into the body, leading spaces drop
		NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:[field stringValue] attributes:[prefsController noteBodyAttributes]];
		if ([[textView textStorage] length]) {
			if ([text length]) [[text mutableString] appendString:@"\n"];
			[text appendAttributedString:[textView textStorage]];
		}
		NVNoteContent *content = [text trimLeadingTitle];
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:text content:content delegate:notationController labels:nil];
		//typing continues after whatever of the name wrapped into the body
		if ([text length]) [note setSelectedRange:NSMakeRange([text length], 0)];
		[notationController addNewNote:note];
		
		isCreatingANote = NO;
		return note;
    }
    
    return currentNote;
}


- (void)restoreListStateUsingPreferences {
	//to be invoked after loading a notationcontroller
	
	NSString *searchString = [prefsController lastSearchString];
	if ([searchString length]) {
		[self searchForString:searchString];
	} else {
		[field setStringValue:@""];
		[notationController refilterNotes];
	}
    
	CFUUIDBytes bytes = [prefsController UUIDBytesOfLastSelectedNote];
	NSUInteger idx = [self revealNote:[notationController noteForUUIDBytes:&bytes] options:NVDoNotChangeScrollPosition];
	//scroll using saved scrollbar position
	[notesTableView scrollRowToVisible:NSNotFound == idx ? 0 : idx withVerticalOffset:[prefsController scrollOffsetOfLastSelectedNote]];
}

- (NSUInteger)revealNote:(NoteObject*)note options:(NSUInteger)opts {
	if (note) {
		NSUInteger selectedNoteIndex = [notationController indexInFilteredListForNoteIdenticalTo:note];
		
		if (selectedNoteIndex == NSNotFound) {
			NSLog(@"Note was not visible--showing all notes and trying again");
			[self cancelOperation:nil];
			
			selectedNoteIndex = [notationController indexInFilteredListForNoteIdenticalTo:note];
		}
		
		if (selectedNoteIndex != NSNotFound) {
			if (opts & NVDoNotChangeScrollPosition) { //select the note only
				[notesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedNoteIndex] byExtendingSelection:NO];
			} else {
				[notesTableView selectRowAndScroll:selectedNoteIndex];
			}
		}
		
		if (opts & NVEditNoteToReveal) {
			[window makeFirstResponder:textView];
		}
		if (opts & NVOrderFrontWindow) {
			//for external url-handling, often the app will already have been brought to the foreground
			if (![NSApp isActive]) {
//                CurrentContextForWindowNumber([window windowNumber], &spaceSwitchCtx);
				[NSApp activateIgnoringOtherApps:YES];
			}
			if (![window isKeyWindow])
				[window makeKeyAndOrderFront:nil];
		}
		return selectedNoteIndex;
	} else {
		[notesTableView deselectAll:self];
		return NSNotFound;
	}
}

- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note options:(NSUInteger)opts {
	[self revealNote:note options:opts];
}

- (void)notation:(NotationController*)notation revealNotes:(NSArray*)notes {
	
	NSIndexSet *indexes = [notation indexesOfNotes:notes];
	if ([notes count] != [indexes count]) {
		[self cancelOperation:nil];
		
		indexes = [notation indexesOfNotes:notes];
	}
	if ([indexes count]) {
		[notesTableView selectRowIndexes:indexes byExtendingSelection:NO];
		[notesTableView scrollRowToVisible:[indexes firstIndex]];
	}
}

- (void)searchForString:(NSString*)string {
	
	if (string) {
		
        [self setDualFieldIsVisible:YES];
        [mainView setNeedsDisplay:YES];
		[window makeFirstResponder:field];
		NSTextView* fieldEditor = (NSTextView*)[field currentEditor];
		NSRange fullRange = NSMakeRange(0, [[fieldEditor string] length]);
		if (fieldEditor && [fieldEditor shouldChangeTextInRange:fullRange replacementString:string]) {
			//as if typed: controlTextDidChange: filters the list and auto-completes in the field
			[fieldEditor replaceCharactersInRange:fullRange withString:string];
			[fieldEditor didChangeText];
		} else {
			//no field editor, because the field can't be focused (e.g. its window is hidden at launch):
			//set the field's text and filter from that same string, so the two agree (#24)
			[field setStringValue:string];
			[notationController filterNotesFromString:string];
			hereNowSearchQuery = [string copy];
			if (mixedList) { [mixedList filterSitesForString:string]; [notesTableView reloadData]; }
		}
	}
}

- (void)bookmarksController:(BookmarksController*)controller restoreNoteBookmark:(NoteBookmark*)aBookmark inBackground:(BOOL)inBG {
	if (aBookmark) {
		[self searchForString:[aBookmark searchString]];
		[self revealNote:[aBookmark noteObject] options:!inBG ? NVOrderFrontWindow : 0];
	}
}

- (NSSize)windowWillResize:(NSWindow *)window toSize:(NSSize)proposedFrameSize {
	if ([prefsController horizontalLayout]) {
		[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	}
	return proposedFrameSize;
}
/*
 - (void)_expandToolbar {
 if (![toolbar isVisible]) {
 [window setTitle:@"Notation"];
 if (currentNote)
 [field setStringValue:titleOfNote(currentNote)];
 [toolbar setVisible:YES];
 //[window toggleToolbarShown:nil];
 //	if (![splitView isDragging])
 //[[splitView subviewAtPosition:0] setDimension:100.0];
 //[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ToolbarHidden"];
 }
 //if ([[splitView subviewAtPosition:0] isCollapsed])
 //	[[splitView subviewAtPosition:0] expand];
 
 }
 
 - (void)_collapseToolbar {
 if ([toolbar isVisible]) {
 //	if (currentNote)
 //		[window setTitle:titleOfNote(currentNote)];
 //		[window toggleToolbarShown:nil];
 
 [toolbar setVisible:NO];
 //[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ToolbarHidden"];
 }
 }
 */

- (void)tableViewColumnDidResize:(NSNotification *)aNotification {
	NoteAttributeColumn *col = [[aNotification userInfo] objectForKey:@"NSTableColumn"];
	if ([[col identifier] isEqualToString:NoteTitleColumnString]) {
		[notationController regeneratePreviewsForColumn:col visibleFilteredRows:[self visibleNoteRows] forceUpdate:NO];
		
	 	[NSObject cancelPreviousPerformRequestsWithTarget:notesTableView selector:@selector(reloadDataIfNotEditing) object:nil];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0.0];
	}
}


//the notationcontroller must call notationListShouldChange: first
//if it's going to do something that could mess up the tableview's field eidtor
- (BOOL)notationListShouldChange:(NotationController*)someNotation {
	
	if (someNotation == notationController) {
		if ([notesTableView currentEditor])
			return NO;
	}
	
	return YES;
}

- (void)notationListMightChange:(NotationController*)someNotation {
	
	if (!isFilteringFromTyping) {
		if (someNotation == notationController) {
			//deal with one notation at a time
			savedSelectedNotes = nil;
			savedSelectedSiteIdentities = nil;
			if ([notesTableView numberOfSelectedRows] > 0) {
				NSIndexSet *indexSet = [notesTableView selectedRowIndexes];
				NSMutableArray *identities = [NSMutableArray array];
				[indexSet enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
					NVHereNowSite *site = [self->mixedList siteAtRow:(NSInteger)row];
					if (site.identity) [identities addObject:site.identity];
				}];
				savedSelectedSiteIdentities = [identities copy];
				NSMutableIndexSet *noteIndexes = [indexSet mutableCopy];
				if (mixedList) [noteIndexes removeIndexesInRange:NSMakeRange(mixedList.noteRowCount, mixedList.count - mixedList.noteRowCount)];
				if (noteIndexes.count) savedSelectedNotes = [someNotation notesAtIndexes:noteIndexes];
			}
			
			listUpdateViewCtx = [notesTableView viewingLocation];
		}
	}
}

- (void)notationListDidChange:(NotationController*)someNotation {
	
	if (someNotation == notationController) {
		//deal with one notation at a time
		if (mixedList) {
			mixedList.notes = [notationController notesListDataSource];
			[mixedList filterSitesForString:hereNowSearchQuery];
		}
        
		[notesTableView reloadData];
		//[notesTableView noteNumberOfRowsChanged];
		
		if (!isFilteringFromTyping) {
			NSMutableIndexSet *restored = [NSMutableIndexSet indexSet];
			if (savedSelectedNotes) {
				NSIndexSet *indexes = [someNotation indexesOfNotes:savedSelectedNotes];
				savedSelectedNotes = nil;
				[restored addIndexes:indexes];
			}
			for (NSString *identity in savedSelectedSiteIdentities) {
				NSUInteger siteRow = [mixedList rowForSiteIdentity:identity];
				if (siteRow != NSNotFound) [restored addIndex:siteRow];
			}
			savedSelectedSiteIdentities = nil;
			if (restored.count) [notesTableView selectRowIndexes:restored byExtendingSelection:NO];
			
			[notesTableView setViewingLocation:listUpdateViewCtx];
		}
	}
}

- (void)titleUpdatedForNote:(NoteObject*)aNoteObject {
    if (aNoteObject == currentNote) {
        //	if ([toolbar isVisible]) {
        if ([self dualFieldIsVisible]) {
			[field setStringValue:titleOfNote(currentNote)];
		} else {
			[window setTitle:titleOfNote(currentNote)];
		}
    }
	[[prefsController bookmarksController] updateBookmarksUI];
}

- (void)contentsUpdatedForNote:(NoteObject*)aNoteObject {
	if (aNoteObject == currentNote) {
		NSString *oldBody = [[textView string] copy];
		NSString *newBody = [[[aNoteObject contentString] string] copy];
		if (![oldBody isEqualToString:newBody]) {
			NSUndoManager *manager = [aNoteObject undoManager];
			if (editorUndoNote == aNoteObject && editorUndoStates && editorUndoIndex > 0) {
				//States after the current Undo position belong to Redo; discard them
				//because the server applied its update to the currently visible body.
				while ([editorUndoStates count] > editorUndoIndex + 1) [editorUndoStates removeLastObject];
				for (NSUInteger i = 0; i < [editorUndoStates count]; i++) {
					NSString *rebased = [NVTextMerge mergeBase:oldBody ours:newBody
													  theirs:[editorUndoStates objectAtIndex:i]];
					[editorUndoStates replaceObjectAtIndex:i withObject:[rebased copy]];
				}
			} else {
				editorUndoStates = nil;
				editorUndoIndex = 0;
			}
			//End any active typing group before replacing its range-based actions.
			while ([manager groupingLevel] > 0) [manager endUndoGrouping];
			editorUndoNeedsRebuild = YES;
			[self _rebuildSelectedEditorUndoActions];
		}
		//apply only the part that changed (e.g. a line merged in from another device), so the
		//selection stays with the text the user was looking at (ADR 0001 §8)
		applyingRemoteOrRebasedText = YES;
		NSArray *moved = [NVTextMerge updateStorage:[textView textStorage] toContent:[aNoteObject contentString]
								  selectedRanges:[textView selectedRanges]];
		[textView setSelectedRanges:moved];
		[textView breakUndoCoalescing];
		applyingRemoteOrRebasedText = NO;
		[self postTextUpdate];
		[self updateWordCount:(![prefsController showWordCount])];
	} else {
		//NotationController discards stale AppKit actions for a nonselected note.
		[editorUndoByNote removeObjectForKey:aNoteObject];
		[editorUndoRecentNotes removeObjectIdenticalTo:aNoteObject];
	}
}

- (void)rowShouldUpdate:(NSInteger)affectedRow {
	NSRect rowRect = [notesTableView rectOfRow:affectedRow];
	NSRect visibleRect = [notesTableView visibleRect];
	
	if (NSContainsRect(visibleRect, rowRect) || NSIntersectsRect(visibleRect, rowRect)) {
		[notesTableView setNeedsDisplayInRect:rowRect];
	}
}



- (void)windowDidResignKey:(NSNotification *)notification{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];    
}

- (void)windowWillClose:(NSNotification *)aNotification {
    
    //	[self resetModTimers];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
    if ([prefsController quitWhenClosingWindow]){
		[NSApp terminate:nil];
    }
}

//still connected in MainMenu.xib's old sync-wait panel
- (IBAction)syncWaitQuit:(id)sender {
	[NSApp terminate:nil];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
	NSError *writeError = nil;
	if (notationController && ![notationController flushAllNoteChangesReturningError:&writeError]) {
		NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"Notational couldn't save your notes", nil),
			[writeError localizedDescription], nil, nil, nil);
		return NSTerminateCancel;
	}
	return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
	if (notationController) {
		//only save the state if the notation instance has actually loaded; i.e., don't save last-selected-note if we quit from a PW dialog
		BOOL wasAutomatic = NO;
		NSRange currentRange = [textView selectedRangeWasAutomatic:&wasAutomatic];
		if (!wasAutomatic) [currentNote setSelectedRange:currentRange];
		
		[currentNote updateContentCacheCStringIfNecessary];
		
		[prefsController setLastSearchString:[self fieldSearchString] selectedNote:currentNote
					scrollOffsetForTableView:notesTableView sender:self];
		
		[prefsController saveCurrentBookmarksFromSender:self];
	}
	
	[[NSApp windows] makeObjectsPerformSelector:@selector(close)];
	[notationController closeAllResources];
	
    [prefsController synchronize];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter]removeObserver:self];
	[[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
	[self postTextUpdate];
	
}

- (IBAction)showPreferencesWindow:(id)sender {
	[prefsWindowController showWindow:sender];
}


- (IBAction)makeActiveAndShowWindow:(id)sender{
    [self makeActiveAndShowWindowByFocusingControlField:NO andForcingActivation:YES];
}

- (IBAction)bringFocusToControlField:(id)sender {
    //For ElasticThreads' fullscreen mode use this if/else otherwise uncomment the expand toolbar

    [self focusControlField:sender activate:YES];
}

- (void)focusControlField:(id)sender activate:(BOOL)shouldActivate{
    [self makeActiveAndShowWindowByFocusingControlField:YES andForcingActivation:shouldActivate];
}

- (IBAction)toggleNVActivation:(id)sender {

    if ([NSApp isActive] && [window isMainWindow]&&[window isVisible]) {
        [NSApp hide:sender];
        return;
    }
    [self focusControlField:sender activate:YES];
}

- (void)makeActiveAndShowWindowByFocusingControlField:(BOOL)focus andForcingActivation:(BOOL)activate{

    if (focus) {
        if ([self notesListIsCollapsed]) {
            [self toggleCollapse:self];
        }else if (![self dualFieldIsVisible]){
            [self setDualFieldIsVisible:YES];
        }
    }

    CGFloat delay=0.0f;
    if (activate&&![NSApp isActive]) {
        delay=0.03f;
        [NSApp activateIgnoringOtherApps:YES];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (focus) {
            [field selectText:nil];
        }

        [self setEmptyViewState:currentNote == nil];
        self.isEditing = NO;
        if (!window.isMainWindow||!window.isVisible) {
            [window makeKeyAndOrderFront:nil];
        }
    });
}

- (NSWindow*)window {
	return window;
}



#pragma mark SplitView Delegate methods

//when the window resizes, the notes list keeps its size and the editor takes the change
- (BOOL)splitView:(NSSplitView *)sender shouldAdjustSizeOfSubview:(NSView *)subview {
	return subview != notesSubview;
}

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview {
	//only the list collapses, and only once a note is open to take its place
	return subview == notesSubview && (currentNote != nil || splitViewIsRestoring);
}

//a double click on the divider collapses or expands the list instead (see below)
- (BOOL)splitView:(NSSplitView *)sender shouldCollapseSubview:(NSView *)subview forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex {
	return NO;
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)dividerIndex {
	return proposedMin + kNotesListMinDimension;
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)dividerIndex {
	CGFloat editorMin = [prefsController horizontalLayout] ? 100.0 : 1.0;
	return MIN(proposedMax - editorMin, kNotesListMaxDimension);
}

- (BOOL)splitView:(NVSplitView *)sender shouldTrackMouseDown:(NSEvent *)theEvent onDividerAtIndex:(NSInteger)index {
	//if upon the first mousedown, the top selected index is visible, snap to it when resizing
	[notesTableView noteFirstVisibleRow];
	if ([theEvent clickCount]>1) {
        if ((currentNote)||([self notesListIsCollapsed])){
            [self toggleCollapse:sender];
        }
		return NO;
	}
	return YES;
}

//mail.app-like resizing behavior wrt item selections
- (void)splitViewWillResizeSubviews:(NSNotification *)notification {
	//problem: don't do this if the horizontal splitview is being resized; in horizontal layout, only do this when resizing the window
	if (![prefsController horizontalLayout]) {
		[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	}
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
	[self notesListCollapsedStateMayHaveChanged];
}


#pragma mark nvALT methods

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
    if (aTableView==notesTableView) {
        if ([aCell isHighlighted]) {
            if (([window firstResponder]==notesTableView)||(isEditing&&([notesTableView editedRow]==rowIndex))) {//([notesTableView rowHeight]>30.0)||
                [aCell setTextColor:[NSColor whiteColor]];
                return;
            }else if ([[[[NVTheme currentTheme] foregroundColor] colorUsingColorSpace:[NSColorSpace genericGrayColorSpace]] whiteComponent]>0.5) {
                [aCell setTextColor:[NSColor colorWithCalibratedWhite:0.2 alpha:1.0]];
                return;
            }
        }
        [aCell setTextColor:[[NVTheme currentTheme] foregroundColor]];
    }
}

- (NSMenu *)statBarMenu{
	return statBarMenu;
}



#pragma mark multitagging

- (NSArray *)commonLabelsForNotesAtIndexes:(NSIndexSet *)selDexes{
	if (mixedList && [mixedList selectionContainsSite:selDexes]) return @[];
	NSArray *retArray =[NSArray array];
    
	NSEnumerator *noteEnum = [[notationController notesAtIndexes:selDexes] objectEnumerator];
	NoteObject *aNote;
	aNote = [noteEnum nextObject];
	NSString *existTags = labelsOfNote(aNote);
	if (existTags&&(existTags.length>0)) {
        NSMutableSet *commonTags = [NSMutableSet new];
        
        [commonTags addObjectsFromArray:[existTags labelCompatibleWords]];
		while (((aNote = [noteEnum nextObject]))&&([commonTags count]>0)) {
			existTags = labelsOfNote(aNote);
			if (!existTags||(existTags.length==0)) {
				[commonTags removeAllObjects];
				break;
            }else{
				NSArray *tagArray = [existTags labelCompatibleWords];
                if (tagArray&&([tagArray count]>0)) {
                    NSSet *tagsForNote =[NSSet setWithArray:tagArray];
                    if ([commonTags intersectsSet:tagsForNote]) {
                        [commonTags intersectSet:tagsForNote];
                    }else {
                        [commonTags removeAllObjects];
                        break;
                    }
                }else {
                    [commonTags removeAllObjects];
                    break;
                }
			}
		}
		if (commonTags&&([commonTags count]>0)) {
			retArray = [NSArray arrayWithArray:[commonTags allObjects]];
		}
	}
	return retArray;
}

- (IBAction)multiTag:(id)sender {
    if ([self selectionContainsHereNowSite]) return;
	NSString *tagString = [tagEditor.tagFieldString stringByTrimmingCharactersInSet:[NSCharacterSet labelSeparatorCharacterSet]];
	NSArray *newTags;
    if (tagString&&(tagString.length>0)) {
        newTags=[tagString labelCompatibleWords];
    }else{
        newTags=[NSArray array];
    }
    NSArray *commonLabs=tagEditor.commonTags;
    if (![newTags isEqualToArray:commonLabs]) {
        
        NSArray *selNotes = [notationController notesAtIndexes:[notesTableView selectedRowIndexes]];
        if (!selNotes||([selNotes count]==0)) {
            return;
        }
        tagString=nil;
        
        BOOL gotNewLabels=(newTags&&([newTags count]>0));
        BOOL gotCommonLabels=(commonLabs&&([commonLabs count]>0));
        NSPredicate *pred;
        if (gotCommonLabels&&gotNewLabels) {
            pred=[NSPredicate predicateWithFormat:@"NOT %@ CONTAINS[cd] SELF",newTags];
            commonLabs=[commonLabs filteredArrayUsingPredicate:pred];
        }
        NSMutableArray *finalTags = [NSMutableArray new];
        for (NoteObject *aNote in selNotes) {
            NSString *separator=@" ";
            tagString=labelsOfNote(aNote);
            NSArray *filteredTags;
            
            if (tagString&&(tagString.length>0)) {
                if (([tagString rangeOfString:@","].location!=NSNotFound)) {
                    separator=@",";
                }
                filteredTags=[tagString labelCompatibleWords];
                if (gotCommonLabels) {
                    pred=[NSPredicate predicateWithFormat:@"NOT %@ CONTAINS[cd] SELF",commonLabs];
                    filteredTags=[filteredTags filteredArrayUsingPredicate:pred];
                }
                if (filteredTags&&([filteredTags count]>0)) {
                    [finalTags addObjectsFromArray:filteredTags];
                }
            }
            if (gotNewLabels) {
                if (finalTags&&([finalTags count]>0)) {
                    pred=[NSPredicate predicateWithFormat:@"NOT %@ CONTAINS[cd] SELF",finalTags];
                    filteredTags=[newTags filteredArrayUsingPredicate:pred];
                    if (filteredTags&&([filteredTags count]>0)) {
                        [finalTags addObjectsFromArray:filteredTags];
                    }
                }else{
                    [finalTags addObjectsFromArray:newTags];
                }
            }
            if (finalTags&&([finalTags count]>0)) {
                tagString = [finalTags componentsJoinedByString:separator];
            }else{
                tagString=@"";
            }
        
            [aNote setLabelString:tagString];
            [finalTags removeAllObjects];
        }
        
		[notesTableView scrollRowToVisible:[[notesTableView selectedRowIndexes] firstIndex]];
    }
	[tagEditor closeTP:self];
}

- (void)releaseTagEditor:(NSNotification *)note{
    // the tag editor stays referenced by tagEditor (as before, it was never cleared); ARC frees it when the next one replaces it
}

#pragma mark splitview/toolbar management

- (void)setDualFieldInToolbar {
	NSView *dualSV = [field superview];
	[dualFieldView removeFromSuperviewWithoutNeedingDisplay];
	[dualSV removeFromSuperviewWithoutNeedingDisplay];
	dualFieldItem = [[NSToolbarItem alloc] initWithItemIdentifier:@"DualField"];
	[dualFieldItem setView:dualSV];
	//minSize/maxSize are deprecated in favour of sizing the item's view with constraints, but that has not been
	//verified to keep the search field stretching the full width of the expanded toolbar; keep the proven behaviour
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	[dualFieldItem setMaxSize:NSMakeSize(FLT_MAX, [dualSV frame].size.height)];
	[dualFieldItem setMinSize:NSMakeSize(50.0f, [dualSV frame].size.height)];
#pragma clang diagnostic pop
    [dualFieldItem setLabel:NSLocalizedString(@"Search or Create", @"placeholder text in search/create field")];
	
	toolbar = [[NSToolbar alloc] initWithIdentifier:@"NVToolbar"];
	[toolbar setAllowsUserCustomization:NO];
	[toolbar setAutosavesConfiguration:NO];
	[toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
	[toolbar setShowsBaselineSeparator:YES];
    [toolbar setSizeMode:NSToolbarSizeModeSmall];
	[toolbar setDelegate:self];
	[window setToolbar:toolbar];
	//the field gets its own full-width row under a centred title, as before macOS 11; newer SDKs
	//default to a unified title bar that squeezes it in beside the title (#23)
	[window setToolbarStyle:NSWindowToolbarStyleExpanded];
	
	[window setShowsToolbarButton:NO];
	titleBarButton = [[TitlebarButton alloc] initWithFrame:NSMakeRect(0, 0, 19.0, 19.0) pullsDown:YES];
	[titleBarButton addToWindow:window];
	
	[field setDelegate:self];
    [self setDualFieldIsVisible:[self dualFieldIsVisible]];
}

- (void)setDualFieldInView {
	NSView *dualSV = [field superview];
    [dualSV setAutoresizesSubviews:YES];
    [dualSV setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin];
    //	BOOL dfIsVis = [self dualFieldIsVisible];
	[dualSV removeFromSuperviewWithoutNeedingDisplay];
	NSSize wSize = [mainView frame].size;
	wSize.height-=kDualFieldHeight;
	[splitView setFrameSize:wSize];
	NSRect dfViewFrame = [splitView frame];
	dfViewFrame.size.height = kDualFieldHeight;
	dfViewFrame.origin.y = [splitView frame].size.height;
	dualFieldView = [[DFView alloc] initWithFrame:dfViewFrame];
    [dualFieldView setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin];
    [dualFieldView setAutoresizesSubviews:YES];
    [mainView addSubview:dualFieldView positioned:NSWindowAbove relativeTo:splitView];
	NSRect dsvFrame = [dualSV frame];
	dsvFrame.origin.y +=1.0;
    if (![self isInFullScreen]) {
        dsvFrame.origin.y +=4.0;
    }
	dsvFrame.size.width = roundf(wSize.width * 0.99);
	dsvFrame.origin.x =roundf(wSize.width *0.005);
	[dualSV setFrame:dsvFrame];
	[dualFieldView addSubview:dualSV];
    [field setNextKeyView:textView];
    [textView setNextKeyView:field];
    [self setDualFieldIsVisible:[self dualFieldIsVisible]];
}

- (void)setDualFieldIsVisible:(BOOL)isVis{
    if ([self dualFieldIsVisible]!=isVis) {
        [toolbar setVisible:isVis];
    }
    //        [[NSUserDefaults standardUserDefaults] setBool:!isVis forKey:@"ToolbarHidden"];
    if (isVis) {
        [window setTitle:@"Notational"];
        if (currentNote&&(![[field stringValue]isEqualToString:titleOfNote(currentNote)]))
            [field setStringValue:titleOfNote(currentNote)];
        
        
        [window setInitialFirstResponder:field];
        
    }else{
        if (currentNote)
            [window setTitle:titleOfNote(currentNote)];
        
        
        [window setInitialFirstResponder:textView];
    }
    
    if (![[NSArray arrayWithObjects:textView,notesTableView,theFieldEditor, nil] containsObject:[window firstResponder]]) {
        if (isVis) {
            [field selectText:self];
        }else{
            [window makeFirstResponder:textView];
        }
    }
    [[NSUserDefaults standardUserDefaults] setBool:!isVis forKey:@"ToolbarHidden"];
}


- (BOOL)dualFieldIsVisible{
    return [toolbar isVisible];
}

- (IBAction)toggleCollapse:(id)sender{
	if ([self notesListIsCollapsed]) {
        CGFloat dimension = lastNotesDimension;
        if (dimension < kNotesListMinDimension) dimension = [splitView isVertical] ? 200.0 : 150.0;
        [self forceNotesListDimension:dimension];
        [notesSubview setHidden:NO];
	}else {
        lastNotesDimension = [self notesListDimension];
        [notesSubview setHidden:YES];
	}
    [splitView adjustSubviews];
    [self notesListCollapsedStateMayHaveChanged];
}

#pragma mark fullscreen methods


- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)rect{
    
    BOOL autohideTB=NO;
    wasDFVisible=[self dualFieldIsVisible];
    NSUInteger options=NSApplicationPresentationFullScreen | NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock;
    if (autohideTB) {
        return options|NSApplicationPresentationAutoHideToolbar;
    }
    
    return options;
}

- (void)windowWillEnterFullScreen:(NSNotification *)aNotification{
    //   / [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    if (![splitView isVertical]) {
        [self switchViewLayout:self];
        wasVert = NO;
    }else {
        wasVert = YES;
        //[splitView adjustSubviews];
    }
    
}

- (void)windowDidEnterFullScreen:(NSNotification *)aNotification{
    
    [self setDualFieldIsVisible:wasDFVisible];
    
//    [self performSelector:@selector(postToggleToolbar:) withObject:[NSNumber numberWithBool:wasDFVisible] afterDelay:0.0001];
    [textView updateInsetAndForceLayout:YES];
}

- (NSArray *)customWindowsToExitFullScreenForWindow:(NSWindow *)aWindow{
    fieldWasFirstResponder = [[NSArray arrayWithObjects:field,theFieldEditor, nil] containsObject:[aWindow firstResponder]];
    return nil;
}

- (void)windowWillExitFullScreen:(NSNotification *)aNotification{
    wasDFVisible=[self dualFieldIsVisible]&&(![self notesListIsCollapsed]);
    if ((!wasVert)&&([splitView isVertical])) {
        [self switchViewLayout:self];
    }
}
- (void)windowDidExitFullScreen:(NSNotification *)notification{
    //  [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorMoveToActiveSpace];
    
    [self setDualFieldIsVisible:wasDFVisible];
//    [self performSelector:@selector(postToggleToolbar:) withObject:[NSNumber numberWithBool:wasDFVisible] afterDelay:0.0001];
    if (wasDFVisible&&fieldWasFirstResponder) {
        [window makeFirstResponder:field];
    }
    
    [textView updateInsetAndForceLayout:YES];
}

- (void)postToggleToolbar:(NSNumber *)boolNum{
    [self setDualFieldIsVisible:[boolNum boolValue]];
}


- (BOOL)isInFullScreen{
    return (([window styleMask]&NSWindowStyleMaskFullScreen)>0);
}

- (IBAction)switchFullScreen:(id)sender
{
    [window toggleFullScreen:nil];
}

#pragma mark color scheme methods
    
    - (IBAction)setBWColorScheme:(id)sender{
        [[NVTheme currentTheme] setScheme:NVThemeSchemeLight];
    }
    
    - (IBAction)setLCColorScheme:(id)sender{
        [[NVTheme currentTheme] setScheme:NVThemeSchemeLowContrast];
    }
    
    - (IBAction)setUserColorScheme:(id)sender{
        [[NVTheme currentTheme] setScheme:NVThemeSchemeCustom];
    }
    
//the Theme owns the colours (#5); this gives them to the views that don't ask it themselves
- (void)themeDidChange:(NSNotification *)notification{
    NVTheme *theme = [NVTheme currentTheme];
    NSColor *foreground = [theme foregroundColor], *background = [theme backgroundColor];
    [mainView setBackgroundColor:background];
    [NotesTableHeaderCell setTxtColor:foreground];
    
    [notesTableView setGridColor:foreground];
    [notesTableView setBackgroundColor:background];
    NSScrollerKnobStyle knobStyle = [ETScrollView knobStyleForBackgroundColor:background];
    [notesScrollView setScrollerKnobStyle:knobStyle];
    [[textView enclosingScrollView] setScrollerKnobStyle:knobStyle];
    [notationController setForegroundTextColor:foreground];
    
    [textView setBackgroundColor:background];
    [textView updateTextColors];
    [self updateFieldAttributes];
    if (currentNote) {
        [self contentsUpdatedForNote:currentNote];
    }
    [splitView setNeedsDisplay:YES];
    
}

- (void)updateFieldAttributes{
    NVTheme *theme = [NVTheme currentTheme];
    fieldAttributes = [NSDictionary dictionaryWithObject:[textView _selectionColorForForegroundColor:[theme foregroundColor] backgroundColor:[theme backgroundColor]] forKey:NSBackgroundColorAttributeName];
    
    if (self.isEditing) {
        [theFieldEditor setDrawsBackground:NO];
        [theFieldEditor setTextColor:[theme foregroundColor]];
        [theFieldEditor setSelectedTextAttributes:fieldAttributes];
        [theFieldEditor setInsertionPointColor:[theme foregroundColor]];
        
    }
    
}
    
#pragma mark control/opt key hold down to pop word count/preview window
    
    - (void)updateWordCount:(BOOL)doIt{
        if (doIt) {            
            NSUInteger theCount = [[[textView textStorage] words] count];

            if (theCount > 0) {
                [wordCounter setStringValue:[[NSString stringWithFormat:@"%lu", (unsigned long)theCount] stringByAppendingString:@" words"]];
            }else {
                [wordCounter setStringValue:@""];
            }
        }
    }
    
    - (void)popWordCount:(BOOL)showIt{
        NSUInteger curEv=[[NSApp currentEvent] type];
        if ((curEv==NSEventTypeFlagsChanged)||(curEv==NSEventTypeMouseMoved)||(curEv==NSEventTypeMouseEntered)||(curEv==NSEventTypeMouseExited)||(curEv==NSEventTypeScrollWheel)){
            if (showIt) {
                if (([wordCounter isHidden])&&([prefsController showWordCount])) {
                    [self updateWordCount:YES];
                    [wordCounter setHidden:NO];
                    popped=1;
                }
            }else {
                if ((![wordCounter isHidden])&&([prefsController showWordCount])) {
                    [wordCounter setHidden:YES];
                    [wordCounter setStringValue:@""];
                    popped=0;
                }
            }
        }
    }
    
    - (IBAction)toggleWordCount:(id)sender{
        
        
        [prefsController synchronize];
        if ([prefsController showWordCount]) {
            [self updateWordCount:YES];
            [wordCounter setHidden:NO];
            popped=1;
        }else {
            [wordCounter setHidden:YES];
            [wordCounter setStringValue:@""];
            popped=0;
        }
        
        if (![[sender className] isEqualToString:@"NSMenuItem"]) {
            [prefsController setShowWordCount:![prefsController showWordCount]];
        }
        
    }
    
    - (void)flagsChanged:(NSEvent *)theEvent{
        if ((ModFlagger==0)&&(popped==0)) {            
            NSUInteger flags=[theEvent modifierFlags];
            if (((flags&NSEventModifierFlagDeviceIndependentFlagsMask)==(flags&NSEventModifierFlagOption))&&((flags&NSEventModifierFlagDeviceIndependentFlagsMask)>0)) { //only option key down
                ModFlagger = 1;
                modifierTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                                  target:self
                                                                selector:@selector(updateModifier:)
                                                                userInfo:@"option"
                                                                 repeats:NO];
                return;
            }else if (((flags&NSEventModifierFlagDeviceIndependentFlagsMask)==(flags&NSEventModifierFlagControl))&&((flags&NSEventModifierFlagDeviceIndependentFlagsMask)>0)) { //only ctrl key is down
                ModFlagger = 2;
                modifierTimer = [NSTimer scheduledTimerWithTimeInterval:1.2
                                                                  target:self
                                                                selector:@selector(updateModifier:)
                                                                userInfo:@"control"
                                                                 repeats:NO];
                return;
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ModTimersShouldReset" object:nil];
    }
    
    - (void)updateModifier:(NSTimer*)theTimer{
        if ([theTimer isValid]) {
            if((ModFlagger>0)&&(popped==0)){
                if ([[theTimer userInfo] isEqualToString:@"option"]) {
                    [self popWordCount:YES];
                    popped=1;
                }else if ([[theTimer userInfo] isEqualToString:@"control"]) {
                    [self popPreview:YES];
                    popped=2;
                }
            }
            [theTimer invalidate];
        }
    }
    
    - (void)resetModTimers:(NSNotification *)notification{
        
        
        if ((ModFlagger>0)||(popped>0)) {
            ModFlagger = 0;
            if (modifierTimer){
                if ([modifierTimer isValid]) {
                    [modifierTimer invalidate];
                }
                modifierTimer = nil;
            }
            if (popped==1) {
                [self performSelector:@selector(popWordCount:) withObject:nil afterDelay:0.1];
            }else if (popped==2) {
                [self performSelector:@selector(popPreview:) withObject:nil afterDelay:0.1];
            }
            popped=0;
        }
    }
    
    
#pragma mark Preview-related and to be extracted into separate files
    
    - (void)popPreview:(BOOL)showIt{
        NSUInteger curEv=[[NSApp currentEvent] type];
        if((curEv==NSEventTypeFlagsChanged)||(curEv==NSEventTypeMouseMoved)||(curEv==NSEventTypeMouseEntered)||(curEv==NSEventTypeMouseExited)||(curEv==NSEventTypeScrollWheel)){
            if ([previewToggler state]==0) {
                if (showIt) {
                    if (![previewController previewIsVisible]) {
                        [self togglePreview:self];
                    }
                    popped=2;
                }else {
                    if ([previewController previewIsVisible]) {
                        [self togglePreview:self];
                    }
                    popped=0;
                }
            }
        }
    }
    
    
    - (IBAction)togglePreview:(id)sender
    {
        BOOL doIt = (currentNote != nil);
        if ([previewController previewIsVisible]) {
            doIt = YES;
        }
        if ([[sender className] isEqualToString:@"NSMenuItem"]) {
			[sender setState:![sender state]];
        }
        if (doIt) {
            [previewController togglePreview:self];
        }
    }
    
    - (void)ensurePreviewIsVisible
    {
        if (![[previewController window] isVisible]) {
            [previewController togglePreview:self];
        }
    }
    
    - (IBAction)toggleSourceView:(id)sender
    {
        [self ensurePreviewIsVisible];
        [previewController switchTabs:self];
    }
    
    - (IBAction)savePreview:(id)sender
    {
        [self ensurePreviewIsVisible];
        [previewController saveHTML:self];
    }

    - (IBAction)openCustomPreviewFolder:(id)sender
    {
        NVMarkupRenderer *renderer = [NVMarkupRenderer defaultRenderer];
        [renderer installCustomTemplate];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[renderer customTemplateFolder]]];
    }

    - (IBAction)lockPreview:(id)sender
    {
        if (![previewController previewIsVisible])
            return;
        if ([previewController isPreviewSticky]) {
            [previewController makePreviewNotSticky:self];
        } else {
            [previewController makePreviewSticky:self];
        }
    }
    
    - (IBAction)printPreview:(id)sender
    {
        [self ensurePreviewIsVisible];
        [previewController printPreview:self];
    }
    
    - (void)postTextUpdate{
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TextViewHasChangedContents" object:self];
    }
    
    - (IBAction)selectPreviewMode:(id)sender
    {
        NSMenuItem *previewItem = sender;
        currentPreviewMode = [previewItem tag];
        
        // update user defaults
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInteger:currentPreviewMode]
                                                  forKey:@"markupPreviewMode"];
        
        [self postTextUpdate];
    }
    
    - (id)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)client{
        
        if (self.isEditing) {
            
            if (!fieldAttributes) {
                [self updateFieldAttributes];
            }else{
                NSColor *foreground = [[NVTheme currentTheme] foregroundColor];
                [theFieldEditor setDrawsBackground:NO];
                if ([theFieldEditor textColor] != foreground) {
                    [theFieldEditor setTextColor:foreground];
                }
                [theFieldEditor setSelectedTextAttributes:fieldAttributes];
                [theFieldEditor setInsertionPointColor:foreground];
                
                // [notesTableView setNeedsDisplay:YES];
            }
        }else {//if (client==field) {
//            [theFieldEditor setDrawsBackground:NO];
//            [theFieldEditor setSelectedTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor selectedTextBackgroundColor], NSBackgroundColorAttributeName, nil]];
            [theFieldEditor setInsertionPointColor:[NSColor blackColor]];
        }
        // NSLog(@"window first is :%@",[window firstResponder]);
        //NSLog(@"client is :%@",client);
        //}
        
        
        return theFieldEditor;
        //[super windowWillReturnFieldEditor:sender toObject:client];
    }
    
    - (void)updateRTL
    {
        if ([prefsController rtl]) {
            [textView setBaseWritingDirection:NSWritingDirectionRightToLeft range:NSMakeRange(0, [[textView string] length])];
        } else {
            [textView setBaseWritingDirection:NSWritingDirectionLeftToRight range:NSMakeRange(0, [[textView string] length])];
        }
    }
    
    - (void)refreshNotesList
    {
        [notesTableView setNeedsDisplay:YES];
    }
    
    
    
#pragma mark toggleDock
    - (void)togDockIcon:(NSNotification *)notification{
        
        [NSApp hide:self];
        BOOL showIt=[[notification object]boolValue];
        if (showIt) {
            [self performSelectorOnMainThread:@selector(showDockIcon) withObject:nil waitUntilDone:NO];
        }else {
            [self performSelectorOnMainThread:@selector(hideDockIconAfterDelay) withObject:nil waitUntilDone:NO];
            
        }
    }
    
    - (void)showDockIcon{
        ProcessSerialNumber psn = { 0, kCurrentProcess };
        OSStatus returnCode = TransformProcessType(&psn, kProcessTransformToForegroundApplication);
        if( returnCode != 0) {
            NSLog(@"Could not bring the application to front. Error %d", returnCode);
        }

              [self performSelector:@selector(reActivate:) withObject:self afterDelay:0.16];
    }

    - (void)hideDockIcon{
        //    id fullPath = [[NSBundle mainBundle] executablePath];
        //    NSArray *arg = [NSArray arrayWithObjects:nil];
        //    [NSTask launchedTaskWithLaunchPath:fullPath arguments:arg];
        //    [NSApp terminate:sender];
        ProcessSerialNumber psn = { 0, kCurrentProcess };
        OSStatus returnCode = TransformProcessType(&psn, kProcessTransformToUIElementApplication);
        if( returnCode != 0) {
            NSLog(@"Could not bring the application to front. Error %d", returnCode);
        }
        if (!statusItem) {
            [self setUpStatusBarItem];
        }
        
        [self performSelector:@selector(reActivate:) withObject:self afterDelay:0.36];
        
    }
    
    - (void)reActivate:(id)sender{
        [NSApp activateIgnoringOtherApps:YES];
    }
    
    - (void)hideDockIconAfterDelay{
        
        [self performSelector:@selector(hideDockIcon) withObject:nil afterDelay:0.22];
    }



- (IBAction)statusItemAction:(id)sender{

    NSEvent *curEv=[NSApp currentEvent];
    if ((curEv.type==NSEventTypeRightMouseUp)||((NSEventModifierFlagControl&curEv.modifierFlags)!=0)) {
        //show the menu by attaching it for a single click, as popUpStatusItemMenu: did
        statusItem.menu=statBarMenu;
        [statusItem.button performClick:nil];
        statusItem.menu=nil;
        //        NSPoint og=NSMakePoint(statusItem.button.frame.origin.x, 27.f);//NSMaxY(statusItem.button.frame));
        //        [self.statusMenu popUpMenuPositioningItem:nil atLocation:og inView:statusItem.button];
    }else{
        [self toggleNVActivation:sender];
    }
}


- (void)setUpStatusBarItem{

    NSImage *statusIcon=[NSImage imageNamed:@"nvMenuDark"];
    [statusIcon setSize:NSMakeSize(16.0, 16.0)];
    [statusIcon setTemplate:YES];
    statusItem =[[NSStatusBar systemStatusBar] statusItemWithLength:24.f];
    statusItem.button.image=statusIcon;
    statusItem.button.target=self;
    statusItem.button.action=@selector(statusItemAction:);
    [statusItem.button sendActionOn:NSEventMaskLeftMouseUp|NSEventMaskRightMouseUp];

}

    - (void)toggleStatusItem:(NSNotification *)notification{
        if (!statusItem) {
            [self setUpStatusBarItem];
        }else{
            [[NSStatusBar systemStatusBar]removeStatusItem:statusItem];
            statusItem=nil;
        }
    }
    
    
#pragma mark NSPREDICATE TO FIND MARKDOWN REFERENCE LINKS
//    - (IBAction)testThing:(id)sender{
        //    NSString *testString=@"not []http://sdfas as\n\not [][]\n not [](http://)\n     a   [a ref]: http://nytimes.com \n squirels [another ref]: http://google.com    \n http://squarshit \n how's tthat http his lorem ipsum";
        //    
        //    NSArray *foundLinks=[self referenceLinksInString:testString];
        //    if (foundLinks&&([foundLinks count]>0)) {
        //        NSLog(@"found'em:%@",[foundLinks description]);
        //    }else{
        //        NSLog(@"didn't find shit");
        //    }
//    }
    
    - (NSArray *)referenceLinksInString:(NSString *)contentString{    
        NSString *wildString = @"*[*]:*http*"; //This is where you define your match string.    
        NSPredicate *matchPred = [NSPredicate predicateWithFormat:@"SELF LIKE[cd] %@", wildString]; 
        /*
         Breaking it down:
         SELF is the string your testing
         [cd] makes the test case insensitive
         LIKE is one of the predicate search possiblities. It's NOT regex, but lets you use wildcards '?' for one character and '*' for any number of characters
         MATCH (not used) is what you would use for Regex. And you'd set it up similiar to LIKE. I don't really know regex, and I can't quite get it to work. But that might be because I don't know regex. 
         %@ you need to pass in the search string like this, rather than just embedding it in the format string. so DON'T USE something like [NSPredicate predicateWithFormat:@"SELF LIKE[cd] *[*]:*http*"]
         */
        
        NSMutableArray *referenceLinks=[NSMutableArray new];
        
        //enumerateLinesUsing block seems like a good way to go line by line thru the note and test each line for the regex match of a reference link. Downside is that it uses blocks so requires 10.6+. Let's get it to work and then we can figure out a Leopard friendly way of doing this; which I don't think will be a problem (famous last words).
        [contentString enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) { 
            if([matchPred evaluateWithObject:line]){
                //            NSLog(@"%@ matched",line);
                NSString *theRef=line;
                //theRef=[line substring...]  here you want to parse out and get just the name of the reference link we'd want to offer up to the user in the autocomplete
                //and maybe trim out whitespace
                theRef = [theRef stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                //check to make sure its not empty
                if(![theRef isEqualToString:@""]){
                    [referenceLinks addObject:theRef];
                } 		
            }	
        }];
        //create an immutable array safe for returning
        NSArray *returnArray=[NSArray array];
        //see if we found anything
        if(referenceLinks&&([referenceLinks count]>0))
        {
            returnArray=[NSArray arrayWithArray:referenceLinks];
        }
        return returnArray;
    }
    
- (BOOL)selectionContainsHereNowSite {
    return mixedList && [mixedList selectionContainsSite:[notesTableView selectedRowIndexes]];
}

- (BOOL)selectedRowIsHereNowSite {
    return mixedList && [mixedList siteAtRow:[notesTableView selectedRow]] != nil;
}

- (void)installHereNowMenuItems {
    NSMenu *menu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *open = [menu addItemWithTitle:@"Open here.now Site" action:@selector(openSelectedHereNowSite:) keyEquivalent:@""];
    open.target = self;
    NSMenuItem *connect = [menu addItemWithTitle:@"Connect here.now…" action:@selector(connectHereNow:) keyEquivalent:@""];
    connect.target = self;
    NSMenuItem *refresh = [menu addItemWithTitle:@"Refresh here.now Sites" action:@selector(refreshHereNow:) keyEquivalent:@""];
    refresh.target = self;
    NSMenuItem *disconnect = [menu addItemWithTitle:@"Disconnect here.now" action:@selector(disconnectHereNow:) keyEquivalent:@""];
    disconnect.target = self;
    NSMenuItem *status = [menu addItemWithTitle:@"here.now: Not connected" action:NULL keyEquivalent:@""];
    status.tag = 30030; status.enabled = NO;
}

- (void)hereNowSitesChanged:(NSNotification *)notification {
    if (mixedList) {
        NSMutableArray *identities = [NSMutableArray array];
        NSMutableIndexSet *selectedNoteRows = [[notesTableView selectedRowIndexes] mutableCopy];
        [selectedNoteRows removeIndexesInRange:NSMakeRange(mixedList.noteRowCount, mixedList.count - mixedList.noteRowCount)];
        [[notesTableView selectedRowIndexes] enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
            NVHereNowSite *site = [self->mixedList siteAtRow:(NSInteger)row];
            if (site.identity) [identities addObject:site.identity];
        }];
        mixedList.sites = hereNowSites.sites;
        mixedList.stale = hereNowSites.stale;
        [mixedList filterSitesForString:hereNowSearchQuery];
        [notesTableView reloadData];
        if (identities.count) {
            NSMutableIndexSet *rows = selectedNoteRows;
            for (NSString *identity in identities) {
                NSUInteger row = [mixedList rowForSiteIdentity:identity];
                if (row != NSNotFound) [rows addIndex:row];
            }
            if (rows.count) [notesTableView selectRowIndexes:rows byExtendingSelection:NO];
            else [notesTableView deselectAll:self];
        }
    }
    NSMenu *menu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
    [[menu itemWithTag:30030] setTitle:[@"here.now: " stringByAppendingString:hereNowSites.status ?: @"Unknown"]];
}

- (IBAction)connectHereNow:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Connect here.now";
    alert.informativeText = @"Paste a here.now API key. It is stored in Keychain and used only to list Sites.";
    NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"Connect"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [hereNowSites connectWithKey:input.stringValue completion:^(NSError *error) {
        if (error) {
            NSAlert *failure = [NSAlert new];
            failure.messageText = @"here.now connection failed";
            failure.informativeText = error.localizedDescription;
            [failure beginSheetModalForWindow:self->window completionHandler:nil];
        }
    }];
}

- (IBAction)disconnectHereNow:(id)sender { [hereNowSites disconnect]; }
- (IBAction)refreshHereNow:(id)sender { [hereNowSites refresh]; }
- (IBAction)openSelectedHereNowSite:(id)sender {
    if ([notesTableView numberOfSelectedRows] != 1) return;
    NVHereNowSite *site = [mixedList siteAtRow:[notesTableView selectedRow]];
    if (site) [[NSWorkspace sharedWorkspace] openURL:site.URL];
}

    @end
