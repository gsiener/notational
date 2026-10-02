//
//  NotationController.m
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import "NotationController.h"
#import "NVNotesStore.h"
#import "NVSyncEngine.h"
#import "NVNoteRecord.h"
#import "NoteObject_NVRecord.h"
#import "NSCollection_utils.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "BufferUtils.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NVArchiving.h"
#import "NoteAttributeColumn.h"
#import "FrozenNotation.h"
#import "AlienNoteImporter.h"
#import "ODBEditor.h"
#import "BookmarksController.h"
#import "nvaDevConfig.h"
#import "NVTheme.h"

@implementation NotationController

- (id)init {
    if (self=[super init]) {
		notesChanged = NO;
		
		allNotes = [[NSMutableArray alloc] init]; //<--the authoritative list of all memory-accessible notes
		deletedNotes = [[NSMutableSet alloc] init];
		labelsListController = [[LabelsListController alloc] init];
		prefsController = [GlobalPrefs defaultPrefs];
		notesListDataSource = [[FastListDataSource alloc] init];
		
		allNotesBuffer = NULL;
		allNotesBufferSize = 0;
		manglingString = currentFilterStr = NULL;
		lastWordInFilterStr = 0;
		selectedNoteIndex = NSNotFound;
		
		lastLayoutStyleGenerated = -1;
		lastCheckedDateInHours = hoursFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
		
		unwrittenNotes = [[NSMutableSet alloc] init];
    }
    return self;
}


#pragma mark Simplenote-backed storage

- (id)initWithNotesStore:(NVNotesStore *)store {
	if ((self = [self init])) {
		notesStore = store;
		
		//per-database settings (fonts, colours, deletion confirmation) live in the store's metadata;
		//encryption and per-file storage no longer apply
		NotationPrefs *prefs = nil;
		NSString *archived = [store metadataValueForKey:@"notationSettings"];
		if (archived) {
			prefs = NVUnarchiveKeyedObject([[NSData alloc] initWithBase64EncodedString:archived options:0]);
		}
		notationPrefs = ([prefs isKindOfClass:[NotationPrefs class]]) ? prefs : [[NotationPrefs alloc] init];
		[notationPrefs setNotesStorageFormat:SingleDatabaseFormat];
		[notationPrefs setDelegate:self];
		
		allNotes = [[NSMutableArray alloc] init];
		deletedNotes = [[NSMutableSet alloc] init];
		applyingRemoteChanges = YES;
		for (NVNoteRecord *record in [store allNotes]) {
			if ([record deleted]) continue;
			NoteObject *note = [[NoteObject alloc] initWithNoteRecord:record delegate:self];
			if (note) [allNotes addObject:note];
		}
		applyingRemoteChanges = NO;
		
		[prefsController setNotationPrefs:notationPrefs sender:self];
		[self makeForegroundTextColorMatchGlobalPrefs];
		[self updateTitlePrefixConnections];
	}
	return self;
}

- (NVNotesStore *)notesStore {
	return notesStore;
}

- (void)setSyncEngine:(NVSyncEngine *)engine {
	if (engine == syncEngine) return;
	[syncEngine setDelegate:nil];
	[syncEngine stop];
	syncEngine = engine;
	[syncEngine setDelegate:(id<NVSyncEngineDelegate>)self];
}

- (NVSyncEngine *)syncEngine {
	return syncEngine;
}

- (NoteObject *)noteForRecordID:(NSString *)recordID {
	for (NoteObject *note in allNotes)
		if ([[note noteRecordID] isEqualToString:recordID]) return note;
	return nil;
}

- (void)syncEngine:(NVSyncEngine *)engine didChangeStatus:(NVSyncStatus)status {
	[[NSNotificationCenter defaultCenter] postNotificationName:@"NVSyncStatusDidChangeNotification" object:self
													  userInfo:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:status] forKey:@"status"]];
}

//NVSyncEngineDelegate, on the main thread
- (void)syncEngine:(NVSyncEngine *)engine didUpdateNotes:(NSArray *)records removedNoteIDs:(NSArray *)noteIDs {
	NSMutableDictionary *byID = [NSMutableDictionary dictionaryWithCapacity:[allNotes count]];
	for (NoteObject *note in allNotes) [byID setObject:note forKey:[note noteRecordID]];
	
	BOOL listChanged = NO;
	NSMutableArray *removed = [NSMutableArray array];
	applyingRemoteChanges = YES;
	for (NVNoteRecord *record in records) {
		NoteObject *note = [byID objectForKey:[record noteID]];
		if (note && [unwrittenNotes containsObject:note]) {
			//edited here since the last save; that save will be pushed and merged by the server
			continue;
		}
		if ([record deleted]) {
			if (note) [removed addObject:note];
			continue;
		}
		if (note) {
			if ([note applyNoteRecord:record]) {
				listChanged = YES;
				if ([delegate respondsToSelector:@selector(contentsUpdatedForNote:)])
					[delegate performSelector:@selector(contentsUpdatedForNote:) withObject:note];
			}
		} else {
			NoteObject *added = [[NoteObject alloc] initWithNoteRecord:record delegate:self];
			if (added) {
				[allNotes addObject:added];
				listChanged = YES;
			}
		}
	}
	applyingRemoteChanges = NO;
	
	for (NSString *recordID in noteIDs) {
		NoteObject *note = [byID objectForKey:recordID];
		if (note) [removed addObject:note];
	}
	for (NoteObject *note in removed) {
		[note disconnectLabels];
		[note abortEditingInExternalEditor];
		[allNotes removeObjectIdenticalTo:note];
		[[prefsController bookmarksController] removeBookmarkForNote:note];
		listChanged = YES;
	}
	
	if (listChanged) {
		[self updateTitlePrefixConnections];
		[self resortAllNotes];
		[self refilterNotes];
	}
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)theDelegate {
	
	delegate = theDelegate;

}

//used to ensure a newly-written Notes & Settings file is valid before finalizing the save
//read the file back from disk, deserialize it, decrypt and decompress it, and compare the notes roughly to our current notes
//stick the newest unique recovered notes into allNotes
- (void)flushEverything {
	[self flushAllNoteChanges];
}

- (BOOL)flushAllNoteChanges {
	[self synchronizeNoteChanges:changeWritingTimer];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNoteChanges:) object:nil];
	if ([notationPrefs preferencesChanged]) {
		[notesStore setMetadataValue:[NVKeyedArchivedData(notationPrefs) base64EncodedStringWithOptions:0]
							  forKey:@"notationSettings"];
		[notationPrefs setPreferencesAreStored];
	}
	[notesStore waitUntilWritten];
	notesChanged = NO;
	return YES;
}

//notation prefs delegate method
- (void)databaseEncryptionSettingsChanged {
	//encryption no longer applies: notes live in Simplenote (ADR 0001)
}

//notation prefs delegate method
- (void)databaseSettingsChangedFromOldFormat:(NSInteger)oldFormat {
	//storage formats no longer apply: notes live in Simplenote (ADR 0001)
}

- (void)synchronizeNoteChanges:(NSTimer*)timer {
	if ([unwrittenNotes count] > 0) {
		for (NoteObject *note in unwrittenNotes)
			[notesStore saveLocalEdit:[note noteRecordRepresentation]];
		[unwrittenNotes removeAllObjects];
		[syncEngine syncNow];
		[self scheduleUpdateListForAttribute:NoteDateModifiedColumnString];
	}
	if (changeWritingTimer) {
		[changeWritingTimer invalidate];
		changeWritingTimer = nil;
	}
}

- (void)closeAllResources {
	[allNotes makeObjectsPerformSelector:@selector(abortEditingInExternalEditor)];
	[self flushAllNoteChanges];
	[syncEngine stop];
	[allNotes makeObjectsPerformSelector:@selector(disconnectLabels)];
}

- (void)updateTitlePrefixConnections {
	//used to auto-complete titles to the first, shortest title of the same prefix--
	//to prevent auto-completing "Chicago Brauhaus" before "Chicago" when search string is "Chi", for example.
	//builds a tree-overlay in the list of notes, to find, for any given note, 
	//all other notes whose complete titles are a prefix of it
	
	//***
	//*** this method must run after any note is added, deleted, or retitled **
	//***
	
	if (![prefsController autoCompleteSearches] || ![allNotes count])
		return;
	
	//sort alphabetically to find shorter prefixes first
	NSMutableArray *allNotesAlpha = [allNotes mutableCopy];
	[allNotesAlpha sortStableUsingFunction:compareTitleString usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
	[allNotes makeObjectsPerformSelector:@selector(removeAllPrefixParentNotes)];

	NSUInteger j, i = 0, count = [allNotesAlpha count];
	for (i=0; i<count - 1; i++) {
		NoteObject *shorterNote = [allNotesAlpha objectAtIndex:i];
		BOOL isAPrefix = NO;
		//scan all notes sorted beneath this one for matching prefixes
		j = i + 1;
		do {
			NoteObject *longerNote = [allNotesAlpha objectAtIndex:j];
			if ((isAPrefix = noteTitleIsAPrefixOfOtherNoteTitle(longerNote, shorterNote))) {
				[longerNote addPrefixParentNote:shorterNote];
			}
		} while (isAPrefix && ++j<count);
	}

}

- (void)addNewNote:(NoteObject*)note {
    [self _addNote:note];
	
	//clear aNoteObject's syncServicesMD to facilitate sync recreation upon undoing of deletion
	//new notes should not have any sync MD; if they do, they should be added using -addNotesFromSync:
	//problem is that note could very likely still be in the process of syncing, in which case these dicts will be accessed
	//for simplenote is is necessary only once the iPhone app has fully deleted the note off the server; otherwise a regular update will recreate it
	//[note removeAllSyncServiceMD];
    
	[note makeNoteDirtyUpdateTime:YES updateFile:YES];
	
	[self updateTitlePrefixConnections];
	
	//force immediate update
	[self synchronizeNoteChanges:nil];
	
	if ([[self undoManager] isUndoing]) {
		//prohibit undoing of creation--only redoing of deletion
		//NSLog(@"registering %s", _cmd);
		[undoManager registerUndoWithTarget:self selector:@selector(removeNote:) object:note];
		if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
			[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Create Note quotemark%@quotemark",@"undo action name for creating a single note"), titleOfNote(note)]];
	}
    
	[self resortAllNotes];
    [self refilterNotes];
    
    [delegate notation:self revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];	
}

//do not update the view here (why not?)
- (void)addNotes:(NSArray*)noteArray {
	
	if (![noteArray count]) return; 
	
	unsigned int i;
	
	if ([[self undoManager] isUndoing]) [undoManager beginUndoGrouping];
	for (i=0; i<[noteArray count]; i++) {
		NoteObject * note = [noteArray objectAtIndex:i];
		
		[self _addNote:note];
		
		[note makeNoteDirtyUpdateTime:YES updateFile:YES];
	}
	if ([[self undoManager] isUndoing]) [undoManager endUndoGrouping];
	
	[self updateTitlePrefixConnections];
	
	[self synchronizeNoteChanges:nil];
	
	if ([[self undoManager] isUndoing]) {
		//prohibit undoing of creation--only redoing of deletion
		//NSLog(@"registering %s", _cmd);
		[undoManager registerUndoWithTarget:self selector:@selector(removeNotes:) object:noteArray];		
		if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
			[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Add %lu Notes", @"undo action name for creating multiple notes"), (unsigned long)[noteArray count]]];	
	}
	[self resortAllNotes];
	[self refilterNotes];
	
	if ([noteArray count] > 1)
		[delegate notation:self revealNotes:noteArray];
	else
		[delegate notation:self revealNote:[noteArray lastObject] options:NVOrderFrontWindow];
}

- (void)note:(NoteObject*)note attributeChanged:(NSString*)attribute {
	
	if ([attribute isEqualToString:NotePreviewString]) {
		if ([prefsController tableColumnsShowPreview]) {
			NSUInteger idx = [notesListDataSource indexOfObjectIdenticalTo:note];
			if (NSNotFound != idx) {
				[delegate rowShouldUpdate:idx];
			}
		}
		//this attribute is not displayed as a column
		return;
	}
	
	//[self scheduleUpdateListForAttribute:attribute];
	[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:0.0];

	//special case for title requires this method, as app controller needs to know a few note-specific things
	if ([attribute isEqualToString:NoteTitleColumnString]) {
		[delegate titleUpdatedForNote:note];
		
		//also update notationcontroller's psuedo-prefix tree for autocompletion
		[self updateTitlePrefixConnections];
		//should perhaps instead trigger a coalesced notification that also updates wiki-link-titles
	}
}

- (BOOL)openFiles:(NSArray*)filenames {
	//reveal notes that already exist with any of these filenames
	//for paths left over that weren't in the notes-folder/database, import those files as new notes
	
	if (![filenames count]) return NO;
	
	NSArray *unknownPaths = filenames; //(this is not a requirement for -notesWithFilenames:unknownFiles:)
	
	//NSLog(@"paths not found in DB: %@", unknownPaths);
	NSArray *createdNotes = [[[AlienNoteImporter alloc] initWithStoragePaths:unknownPaths] importedNotes];
	if (!createdNotes) return NO;
	
	[self addNotes:createdNotes];
	
	return YES;
}



- (void)scheduleUpdateListForAttribute:(NSString*)attribute {
	
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(scheduleUpdateListForAttribute:) object:attribute];
	
	if ([[sortColumn identifier] isEqualToString:attribute]) {
		
		if ([delegate notationListShouldChange:self]) {
			[self sortAndRedisplayNotes];
		} else {
			[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:1.5];
		}
	} else {
		//catch col updates even if they aren't the sort key
		
		NSEnumerator *enumerator = [[prefsController visibleTableColumns] objectEnumerator];
		NSString *colIdentifier = nil;
		
		//check to see if appropriate col is visible
		while ((colIdentifier = [enumerator nextObject])) {
			if ([colIdentifier isEqualToString:attribute]) {
				if ([delegate notationListShouldChange:self]) {
					[delegate notationListMightChange:self];
					[delegate notationListDidChange:self];
				} else {
					[self performSelector:@selector(scheduleUpdateListForAttribute:) withObject:attribute afterDelay:1.5];
				}
				break;
			}
		}
	}
}

- (void)scheduleWriteForNote:(NoteObject*)note {
	//applying a change that came from Simplenote is not a local edit
	if (applyingRemoteChanges) return;

	if ([allNotes containsObject:note]) {
	
		BOOL immediately = NO;
		notesChanged = YES;
		
		[unwrittenNotes addObject:note];
		
		//always synchronize absolutely no matter what 15 seconds after any change
		if (!changeWritingTimer)
			changeWritingTimer = [NSTimer scheduledTimerWithTimeInterval:(immediately ? 0.0 : 15.0) target:self 
									 selector:@selector(synchronizeNoteChanges:)
									 userInfo:nil repeats:NO];
		
		//next user change always invalidates queued write from performSelector, but not queued write from timer
		//this avoids excessive writing and any potential and unnecessary disk access while user types
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(synchronizeNoteChanges:) object:nil];
		
		if (walWriter) {
			//perhaps a more general user interface activity timer would be better for this? update process syncs every 30 secs, anyway...
			[NSObject cancelPreviousPerformRequestsWithTarget:walWriter selector:@selector(synchronize) object:nil];
			//fsyncing WAL to disk can cause noticeable interruption when run from main thread
			[walWriter performSelector:@selector(synchronize) withObject:nil afterDelay:15.0];
		}
		
		if (!immediately) {
			//timer is already scheduled if immediately is true
			//queue to write 2.7 seconds after last user change; 
			[self performSelector:@selector(synchronizeNoteChanges:) withObject:nil afterDelay:2.7];
		}
	} else {
		NSLog(@"not writing note %@ because it is not controlled by NoteController", note);
	}
}

//the gatekeepers!
- (void)_addNote:(NoteObject*)aNoteObject {
    [aNoteObject setDelegate:self];	
	
    [allNotes addObject:aNoteObject];
	[deletedNotes removeObject:aNoteObject];
    
    notesChanged = YES;
}


- (void)removeNotesAtIndexes:(NSIndexSet *)indexes{
    //just delete the notes outright
    if (!indexes||([indexes count]==0)) {
        return;
    }else if ([indexes count]>1) {
        [self removeNotes:[self notesAtIndexes:indexes]];
    }else{
        [self removeNote:[self noteObjectAtFilteredIndex:[indexes firstIndex]]];
    }
}

//the gateway methods must always show warnings, or else flash overlay window if show-warnings-pref is off
- (void)removeNotes:(NSArray*)noteArray {
	NSEnumerator *enumerator = [noteArray objectEnumerator];
	NoteObject* note;
	
	[undoManager beginUndoGrouping];
	while ((note = [enumerator nextObject])) {
		[self removeNote:note];
	}
	[undoManager endUndoGrouping];
	if (! [[self undoManager] isUndoing] && ! [[self undoManager] isRedoing])
		[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete %lu Notes",@"undo action name for deleting notes"), (unsigned long)[noteArray count]]];
	
}

- (void)removeNote:(NoteObject*)aNoteObject {
    //reset linking labels and their notes
    
	[aNoteObject disconnectLabels];
	[aNoteObject abortEditingInExternalEditor];
	
    [allNotes removeObjectIdenticalTo:aNoteObject];
	[unwrittenNotes removeObject:aNoteObject];
	if (notesStore) {
		//deleting moves the note to Simplenote's trash; undo restores it with the next save
		NVNoteRecord *trashed = [aNoteObject noteRecordRepresentation];
		[trashed setDeleted:YES];
		[trashed setModificationDate:[[NSDate date] timeIntervalSince1970]];
		[notesStore saveLocalEdit:trashed];
		[syncEngine syncNow];
	}
	if (!notesStore) [self _addDeletedNote:aNoteObject];
	
    
    notesChanged = YES;
	
	//force-write any cached note changes to make sure that their LSNs are smaller than this deleted note's LSN
	[self synchronizeNoteChanges:nil];
    
	//add journal removal event
	if (walWriter && ![walWriter writeRemovalForNote:aNoteObject]) {
		NSLog(@"Couldn't log note removal");
	}
	
    
	[self _registerDeletionUndoForNote:aNoteObject];
		
	//delete note from bookmarks, too
	[[prefsController bookmarksController] removeBookmarkForNote:aNoteObject];
	
	//rebuild the prefix tree, as this note may have been a prefix of another, or vise versa
	[self updateTitlePrefixConnections];
    
    [self refilterNotes];
}

- (void)_purgeAlreadyDistributedDeletedNotes {
	//purge deletedNotes of objects without any more syncMD entries;
	//once a note has been deleted from all services, there's no need to keep it around anymore

	NSUInteger i = 0;
	NSArray *dnArray = [deletedNotes allObjects];
	for (i = 0; i<[dnArray count]; i++) {
		DeletedNoteObject *dnObj = [dnArray objectAtIndex:i];
		if (![[dnObj syncServicesMD] count]) {
			[deletedNotes removeObject:dnObj];
			notesChanged = YES;
		}
	}
	//NSLog(@"%s: deleted notes left: %@", _cmd, deletedNotes);
}

- (DeletedNoteObject*)_addDeletedNote:(id<SynchronizedNote>)aNote {
	//currently coupled to -[allNotes removeObjectIdenticalTo:]
	//don't need to remember this deleted note unless it was already synced with some service
	//furthermore, after that deleted note has been remotely-removed from all services with which it was previously synced,
	//can it be purged from this database once and for all?
	//e.g., each successful syncservice deletion would also remove that service's entry from syncServicesMD
	//when syncServicesMD was empty, it would be removed from the set
	//but what about synchronization systems without explicit delete APIs?
	
	if ([[aNote syncServicesMD] count]) {
		//it is important to use the actual deleted note if one is passed
		DeletedNoteObject *deletedNote = [aNote isKindOfClass:[DeletedNoteObject class]] ? aNote : [DeletedNoteObject deletedNoteWithNote:aNote];
		[deletedNotes addObject:deletedNote];
		notesChanged = YES;
		return deletedNote;
	}
	return nil;
}

- (void)_registerDeletionUndoForNote:(NoteObject*)aNote {	
	[undoManager registerUndoWithTarget:self selector:@selector(addNewNote:) object:aNote];			
	if (![undoManager isUndoing] && ![undoManager isRedoing])
		[undoManager setActionName:[NSString stringWithFormat:NSLocalizedString(@"Delete quotemark%@quotemark",@"undo action name for deleting a single note"), titleOfNote(aNote)]];				
}			


- (void)setUndoManager:(NSUndoManager*)anUndoManager {
    undoManager = anUndoManager;
}

- (NSUndoManager*)undoManager {
    return undoManager;
}

- (void)updateDateStringsIfNecessary {
	
	unsigned int currentHours = hoursFromAbsoluteTime(CFAbsoluteTimeGetCurrent());
	BOOL isHorizontalLayout = [prefsController horizontalLayout];
	
	if (currentHours != lastCheckedDateInHours || isHorizontalLayout != lastLayoutStyleGenerated) {
		lastCheckedDateInHours = currentHours;
		lastLayoutStyleGenerated = (int)isHorizontalLayout;
		
		[delegate notationListMightChange:self];
		resetCurrentDayTime();
		[allNotes makeObjectsPerformSelector:@selector(updateDateStrings)];
		[delegate notationListDidChange:self];
	}
}

- (void)makeForegroundTextColorMatchGlobalPrefs {
	NSColor *prefsFGColor = [notationPrefs foregroundColor];
	if (prefsFGColor) {
		NSColor *fgColor = [[NVTheme currentTheme] foregroundColor];
		[self setForegroundTextColor:fgColor];
		//NSColor *fgColor = [prefsController foregroundTextColor];
		
		//if (!ColorsEqualWith8BitChannels(prefsFGColor, fgColor)) {			
		//	[self setForegroundTextColor:fgColor];
		//}
	}
}

- (void)setForegroundTextColor:(NSColor*)fgColor {
	//do not update the notes in any other way, nor the database, other than also setting this color in notationPrefs
	//foreground color is archived only for practicality, and should be for display only
	NSAssert(fgColor != nil, @"foreground color cannot be nil");

	[allNotes makeObjectsPerformSelector:@selector(setForegroundTextColorOnly:) withObject:fgColor];
	
	[notationPrefs setForegroundTextColor:fgColor];
}

- (void)restyleAllNotes {
	NSFont *baseFont = [notationPrefs baseBodyFont];
	NSAssert(baseFont != nil, @"base body font from notation prefs should ALWAYS be valid!");
	
	[allNotes makeObjectsPerformSelector:@selector(updateUnstyledTextWithBaseFont:) withObject:baseFont];
	
	[notationPrefs setBaseBodyFont:[prefsController noteBodyFont]];
}

//used by BookmarksController

- (NoteObject*)noteForUUIDBytes:(CFUUIDBytes*)bytes {
	NSUInteger noteIndex = [allNotes indexOfNoteWithUUIDBytes:bytes];
	if (noteIndex != NSNotFound) return [allNotes objectAtIndex:noteIndex];
	return nil;	
}

- (void)updateLabelConnectionsAfterDecoding {
	[allNotes makeObjectsPerformSelector:@selector(updateLabelConnectionsAfterDecoding)];
}

//re-searching for all notes each time a label is added or removed is unnecessary, I think
- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet {
	[labelsListController addLabelSet:labelSet toNote:note];
        
    //this can only happen while the note is visible
	
	//[self refilterNotes];
}

- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet {
	[labelsListController removeLabelSet:labelSet fromNote:note];
        
	//[self refilterNotes];
}

- (void)filterNotesFromLabelAtIndex:(int)labelIndex {
	NSArray *notes = [[labelsListController notesAtFilteredIndex:labelIndex] allObjects];
	
	[delegate notationListMightChange:self];
	[notesListDataSource fillArrayFromArray:notes];
	
	[delegate notationListDidChange:self];	
}

- (void)filterNotesFromLabelIndexSet:(NSIndexSet*)indexSet {
	NSArray *notes = [[labelsListController notesAtFilteredIndexes:indexSet] allObjects];
	
	[delegate notationListMightChange:self];
	[notesListDataSource fillArrayFromArray:notes];
	
	[delegate notationListDidChange:self];
}

- (BOOL)filterNotesFromString:(NSString*)string {
	
	[delegate notationListMightChange:self];
	if ([self filterNotesFromUTF8String:[string lowercaseUTF8String] forceUncached:NO]) {
		[delegate notationListDidChange:self];
		
		return YES;
	}
	
	return NO;
}

- (void)refilterNotes {
	
    [delegate notationListMightChange:self];
    [self filterNotesFromUTF8String:(currentFilterStr ? currentFilterStr : "") forceUncached:YES];
    [delegate notationListDidChange:self];
}

- (BOOL)filterNotesFromUTF8String:(const char*)searchString forceUncached:(BOOL)forceUncached {
    BOOL stringHasExistingPrefix = YES;
    BOOL didFilterNotes = NO;
    size_t oldLen = 0, newLen = 0;
	NSUInteger i, initialCount = [notesListDataSource count];
    
	NSAssert(searchString != NULL, @"filterNotesFromUTF8String requires a non-NULL argument");
	
	newLen = strlen(searchString);
    
	//PHASE 1: determine whether notes can be searched from where they are--if not, start on all the notes
    if (!currentFilterStr || forceUncached || ((oldLen = strlen(currentFilterStr)) > newLen) ||
		strncmp(currentFilterStr, searchString, oldLen)) {
		
		//the search must be re-initialized; our strings don't have the same prefix
		
		[notesListDataSource fillArrayFromArray:allNotes];
		//[labelsListController unfilterLabels];
		
		stringHasExistingPrefix = NO;
		lastWordInFilterStr = 0;
		didFilterNotes = YES;
		
		//		NSLog(@"filter: scanning all notes");
    }
    
	
	//PHASE 2: actually search for notes
	NoteFilterContext filterContext;
	
	//if there is a quote character in the string, use that as a delimiter, as we will search by phrase
	//perhaps we could add some additional delimiters like punctuation marks here
    char *token, *separators = (strchr(searchString, '"') ? "\"" : " :\t\r\n");
    manglingString = replaceString(manglingString, searchString);
    
    BOOL touchedNotes = NO;
    
    if (!didFilterNotes || newLen > 0) {
		//only bother searching each note if we're actually searching for something
		//otherwise, filtered notes already reflect all-notes-state
		
		char *preMangler = manglingString + lastWordInFilterStr;
		while ((token = strsep(&preMangler, separators))) {
			
			if (*token != '\0') {
				//if this is the same token that we had scanned previously
				filterContext.useCachedPositions = stringHasExistingPrefix && (token == manglingString + lastWordInFilterStr);
				filterContext.needle = token;
				
				touchedNotes = YES;
				
				if ([notesListDataSource filterArrayUsingFunction:(BOOL (*)(id, void*))noteContainsUTF8String context:&filterContext])
					didFilterNotes = YES;
								
				lastWordInFilterStr = token - manglingString;
			}
		}
    }
    
	//PHASE 3: reset found pointers in case have been cleared
	NSUInteger filteredNoteCount = [notesListDataSource count];
	__unsafe_unretained NoteObject **notesBuffer = (__unsafe_unretained NoteObject **)[notesListDataSource immutableObjects];
	
    if (didFilterNotes) {
		
		if (!touchedNotes) {
			//I can't think of any situation where notes were filtered and not touched--EXCEPT WHEN REMOVING A NOTE (>= vs. ==)
			NSAssert(filteredNoteCount >= [allNotes count], @"filtered notes were claimed to be filtered but were not");
			
			//reset found-ptr values; the search string was effectively blank and so no notes were examined
			for (i=0; i<filteredNoteCount; i++)
				resetFoundPtrsForNote(notesBuffer[i]);
		}
		
		//we have to re-create the array at each iteration while searching notes, but not here, so we can wait until the end
		//[labelsListController recomputeListFromFilteredSet];
    }
    
	//PHASE 4: autocomplete based on results
	//even if the controller didn't filter, the search string could have changed its representation wrt spacing
	//which will still influence note title prefixes 
	selectedNoteIndex = NSNotFound;
	
    if (newLen && [prefsController autoCompleteSearches]) {

		for (i=0; i<filteredNoteCount; i++) {			
			//because we already searched word-by-word up there, this is just way simpler
			if (noteTitleHasPrefixOfUTF8String(notesBuffer[i], searchString, newLen)) {
				selectedNoteIndex = i;
				//this note matches, but what if there are other note-titles that are prefixes of both this one and the search string?
				//find the first prefix-parent of which searchString is also a prefix
				NSUInteger j = 0, prefixParentIndex = NSNotFound;
				NSArray *prefixParents = prefixParentsOfNote(notesBuffer[i]);
				
				for (j=0; j<[prefixParents count]; j++) {
					NoteObject *obj = [prefixParents objectAtIndex:j];
					
					if (noteTitleHasPrefixOfUTF8String(obj, searchString, newLen) &&
						(prefixParentIndex = [notesListDataSource indexOfObjectIdenticalTo:obj]) != NSNotFound) {
						//figure out where this prefix parent actually is in the list--if it actually is in the list, that is
						//otherwise look at the next prefix parent, etc.
						//the prefix parents array should always be alpha-sorted, so the shorter prefixes will always be first
						selectedNoteIndex = prefixParentIndex;
						break;
					}
				}
				break;
			}
		}
    }
    
    currentFilterStr = replaceString(currentFilterStr, searchString);
	
	if (!initialCount && initialCount == filteredNoteCount)
		return NO;
    
    return didFilterNotes;
}

- (NSUInteger)preferredSelectedNoteIndex {
    return selectedNoteIndex;
}

- (NSArray*)noteTitlesPrefixedByString:(NSString*)prefixString indexOfSelectedItem:(NSInteger *)anIndex {
	NSMutableArray *objs = [NSMutableArray arrayWithCapacity:[allNotes count]];
	const char *searchString = [prefixString lowercaseUTF8String];
	NSUInteger i, titleLen, strLen = strlen(searchString), j = 0, shortestTitleLen = UINT_MAX;

	for (i=0; i<[allNotes count]; i++) {
		NoteObject *thisNote = [allNotes objectAtIndex:i];
		if (noteTitleHasPrefixOfUTF8String(thisNote, searchString, strLen)) {
			[objs addObject:titleOfNote(thisNote)];
			if (anIndex && (titleLen = CFStringGetLength((__bridge CFStringRef)titleOfNote(thisNote))) < shortestTitleLen) {
				*anIndex = j;
				shortestTitleLen = titleLen;
			}
			j++;
		}
	}
	return objs;
}

- (NoteObject*)noteObjectAtFilteredIndex:(NSUInteger)noteIndex {
	unsigned int theIndex = (unsigned int)noteIndex;
	
	if (theIndex < [notesListDataSource count])
		return [notesListDataSource immutableObjects][theIndex];
	
	return nil;
}

- (NSArray*)notesAtIndexes:(NSIndexSet*)indexSet {
	return [notesListDataSource objectsAtFilteredIndexes:indexSet];
}

//O(n^2) at best, but at least we're dealing with C arrays

- (NSIndexSet*)indexesOfNotes:(NSArray*)noteArray {
	NSMutableIndexSet *noteIndexes = [[NSMutableIndexSet alloc] init];
	
	NSUInteger i, noteCount = [noteArray count];
	
	__unsafe_unretained id *notes = (__unsafe_unretained id*)malloc(noteCount * sizeof(id));
	[noteArray getObjects:notes range:NSMakeRange(0, noteCount)];
	
	for (i=0; i<noteCount; i++) {
		NSUInteger noteIndex = [notesListDataSource indexOfObjectIdenticalTo:notes[i]];
		
		if (noteIndex != NSNotFound)
			[noteIndexes addIndex:noteIndex];
	}
	
	free(notes);
	
	return noteIndexes;
}

- (NSUInteger)indexInFilteredListForNoteIdenticalTo:(NoteObject*)note {
	return [notesListDataSource indexOfObjectIdenticalTo:note];
}

- (NSUInteger)totalNoteCount {
	return [allNotes count];
}

- (NoteAttributeColumn*)sortColumn {
	return sortColumn;
}

- (void)setSortColumn:(NoteAttributeColumn*)col { 
	
	sortColumn = col;
	
	[self sortAndRedisplayNotes];
}

//re-sort without refiltering, to avoid removing notes currently being edited
- (void)sortAndRedisplayNotes {
	
	[delegate notationListMightChange:self];

	NoteAttributeColumn *col = sortColumn;
	if (col) {
		BOOL reversed = [prefsController tableIsReverseSorted];
		NSInteger (*sortFunction) (__unsafe_unretained id *, __unsafe_unretained id *) = (reversed ? [col reverseSortFunction] : [col sortFunction]);
		NSInteger (*stringSortFunction) (__unsafe_unretained id *, __unsafe_unretained id *) = (reversed ? compareTitleStringReverse : compareTitleString);
		
		[allNotes sortStableUsingFunction:stringSortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		if (sortFunction != stringSortFunction)
			[allNotes sortStableUsingFunction:sortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		
		
		if ([notesListDataSource count] != [allNotes count]) {
				
			[notesListDataSource sortStableUsingFunction:stringSortFunction];	
		    if (sortFunction != stringSortFunction)
				[notesListDataSource sortStableUsingFunction:sortFunction];
			
		} else {
		    //mirror from allNotes; notesListDataSource is not filtered
		    [notesListDataSource fillArrayFromArray:allNotes];
		}
		
		[delegate notationListDidChange:self];
	}
}

- (void)resortAllNotes {
	
	NoteAttributeColumn *col = sortColumn;
	
	if (col) {
		BOOL reversed = [prefsController tableIsReverseSorted];
	
		NSInteger (*sortFunction) (__unsafe_unretained id *, __unsafe_unretained id *) = (reversed ? [col reverseSortFunction] : [col sortFunction]);
		NSInteger (*stringSortFunction) (__unsafe_unretained id *, __unsafe_unretained id *) = (reversed ? compareTitleStringReverse : compareTitleString);

		[allNotes sortStableUsingFunction:stringSortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
		if (sortFunction != stringSortFunction)
			[allNotes sortStableUsingFunction:sortFunction usingBuffer:&allNotesBuffer ofSize:&allNotesBufferSize];
	}
}

- (float)titleColumnWidth {
	return titleColumnWidth;
}

- (void)regeneratePreviewsForColumn:(NSTableColumn*)col visibleFilteredRows:(NSRange)rows forceUpdate:(BOOL)force {
    float width = [col width];
    width -= [NSScroller scrollerWidthForControlSize:NSControlSizeRegular scrollerStyle:[NSScroller preferredScrollerStyle]];
	
	if (force || roundf(width) != roundf(titleColumnWidth)) {
		titleColumnWidth = width;
		
		//regenerate previews for visible rows immediately and post a delayed message to regenerate previews for all rows
		if (rows.length > 0) {
			CFArrayRef visibleNotes = CFArrayCreate(NULL, (const void **)(void *)([notesListDataSource immutableObjects] + rows.location), rows.length, NULL);
			[(__bridge NSArray*)visibleNotes makeObjectsPerformSelector:@selector(updateTablePreviewString)];
			CFRelease(visibleNotes);
		}
		
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(regenerateAllPreviews) object:nil];
		[self performSelector:@selector(regenerateAllPreviews) withObject:nil afterDelay:0.0];
	}
}

- (void)regenerateAllPreviews {
	[allNotes makeObjectsPerformSelector:@selector(updateTablePreviewString)];
}

- (NotationPrefs*)notationPrefs {
	return notationPrefs;
}

//NVNoteDelegate: notes ask their controller, not the views or the app behind it
- (void)noteContentsDidChange:(NoteObject *)note {
	if ([delegate respondsToSelector:@selector(contentsUpdatedForNote:)]) [delegate contentsUpdatedForNote:note];
}

- (NSImage *)labelImageForWord:(NSString *)word highlighted:(BOOL)highlighted {
	return [labelsListController cachedLabelImageForWord:word highlighted:highlighted];
}

- (id)labelsListDataSource {
    return labelsListController;
}

- (id)notesListDataSource {
    return notesListDataSource;
}


- (void)dealloc {
 
	[walWriter setDelegate:nil];
	[notationPrefs setDelegate:nil];
	[allNotes makeObjectsPerformSelector:@selector(setDelegate:) withObject:nil];

    if (allNotesBuffer)
		free(allNotesBuffer);
	free(currentFilterStr);
	free(manglingString);
	
	[syncEngine setDelegate:nil];
}

#pragma mark nvALT stuff
- (NSString *)createCachesFolder{
    NSString *path = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if ([paths count])    {
        path = [[paths objectAtIndex:0] stringByAppendingPathComponent:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"]];
        NSError *theError=nil;
        if ((path!=nil)&&([[NSFileManager defaultManager]createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&theError])) {
//           NSLog(@"cache folder :>%@<",path);
            return path;
        }else{
            NSLog(@"error creating cache folder:");
            if (theError) {
                NSLog(@"%@",[theError description]);
            }
        }
    }else{
        NSLog(@"Unable to find or create cache folder:\n%@", path);
    }
    return nil;
}

@end


