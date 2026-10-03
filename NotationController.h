//
//  NotationController.h
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.

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


#import <Cocoa/Cocoa.h>
#import "NVNoteDelegate.h"
#import "FastListDataSource.h"
#import "LabelsListController.h"

#import <CoreServices/CoreServices.h>

//enum { kUISearch, kUINewNote, kUIDeleteNote, kUIRenameNote, kUILabelOperation };

@class NoteObject;
@class NotationPrefs;
@class NoteAttributeColumn;
@class NoteBookmark;
@class GlobalPrefs;

@class NVNotesStore, NVSyncEngine;

@interface NotationController : NSObject <NVNoteDelegate> {
    BOOL resourcesClosed;
    NSMutableArray *allNotes;
	//the same notes by Simplenote id; kept in step wherever allNotes gains or loses a note
	NSMutableDictionary *notesByRecordID;
    FastListDataSource *notesListDataSource;
    LabelsListController *labelsListController;
	GlobalPrefs *prefsController;
	__weak id delegate;
	
	float titleColumnWidth;
	NoteAttributeColumn* sortColumn;
	
    __unsafe_unretained NoteObject **allNotesBuffer;
	unsigned int allNotesBufferSize;
    
    NSUInteger selectedNoteIndex;
    char *currentFilterStr, *manglingString;
    NSInteger lastWordInFilterStr;
    
    NotationPrefs *notationPrefs;
	
	unsigned int lastCheckedDateInHours;
	int lastLayoutStyleGenerated;
    
    NSMutableSet *unwrittenNotes;
	NSMutableDictionary *failedTrashEdits;
	NSTimer *changeWritingTimer;
	NSUndoManager *undoManager;
	
	//Simplenote-backed storage (ADR 0001); when set, the notes database, journal and
	//notes-folder code paths are bypassed
	NVNotesStore *notesStore;
	NVSyncEngine *syncEngine;
}

- (id)initWithNotesStore:(NVNotesStore *)store;
- (NVNotesStore *)notesStore;
- (void)setSyncEngine:(NVSyncEngine *)engine;
- (NVSyncEngine *)syncEngine;
- (NoteObject *)noteForRecordID:(NSString *)recordID;

- (id)init;
- (void)flushAllNoteChanges;
- (BOOL)flushAllNoteChangesReturningError:(NSError **)error;
- (BOOL)closeAllResourcesReturningError:(NSError **)error;
- (BOOL)prepareForAccountResetReturningError:(NSError **)error;
- (void)retireAfterAccountReset;
- (void)flushEverything;



- (id)delegate;
- (void)setDelegate:(id)theDelegate;

- (void)synchronizeNoteChanges:(NSTimer*)timer;

- (void)updateDateStringsIfNecessary;
- (void)makeForegroundTextColorMatchGlobalPrefs;
- (void)setForegroundTextColor:(NSColor*)aColor;
- (void)restyleAllNotes;
- (void)setUndoManager:(NSUndoManager*)anUndoManager;
- (NSUndoManager*)undoManager;
- (void)scheduleWriteForNote:(NoteObject*)note;
- (void)closeAllResources;
- (void)updateTitlePrefixConnections;
- (void)addNotes:(NSArray*)noteArray;
- (void)addNewNote:(NoteObject*)aNoteObject;
- (void)_addNote:(NoteObject*)aNoteObject;
- (void)removeNote:(NoteObject*)aNoteObject;
- (void)removeNotes:(NSArray*)noteArray;
- (void)_registerDeletionUndoForNote:(NoteObject*)aNote;

- (BOOL)openFiles:(NSArray*)filenames;

- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet;

- (void)filterNotesFromLabelAtIndex:(int)labelIndex;
- (void)filterNotesFromLabelIndexSet:(NSIndexSet*)indexSet;
- (void)updateLabelConnectionsAfterDecoding;

- (void)refilterNotes;
- (BOOL)filterNotesFromString:(NSString*)string;
- (BOOL)filterNotesFromUTF8String:(const char*)searchString forceUncached:(BOOL)forceUncached;
- (NSUInteger)preferredSelectedNoteIndex;
- (NSArray*)noteTitlesPrefixedByString:(NSString*)prefixString indexOfSelectedItem:(NSInteger *)anIndex;
- (NoteObject*)noteObjectAtFilteredIndex:(NSUInteger)noteIndex;
- (NSArray*)notesAtIndexes:(NSIndexSet*)indexSet;
- (NSIndexSet*)indexesOfNotes:(NSArray*)noteSet;
- (NSUInteger)indexInFilteredListForNoteIdenticalTo:(NoteObject*)note;

- (void)scheduleUpdateListForAttribute:(NSString*)attribute;
- (NoteAttributeColumn*)sortColumn;
- (void)setSortColumn:(NoteAttributeColumn*)col;
- (void)resortAllNotes;
- (void)sortAndRedisplayNotes;

- (float)titleColumnWidth;
- (void)regeneratePreviewsForColumn:(NSTableColumn*)col visibleFilteredRows:(NSRange)rows forceUpdate:(BOOL)force;
- (void)regenerateAllPreviews;

//for setting up the nstableviews
- (id)labelsListDataSource;
- (id)notesListDataSource;

- (NotationPrefs*)notationPrefs;

#pragma mark nvALT stuff

- (void)removeNotesAtIndexes:(NSIndexSet *)indexes;

@end


enum { NVDefaultReveal = 0, NVDoNotChangeScrollPosition = 1, NVOrderFrontWindow = 2, NVEditNoteToReveal = 4 };

@interface NSObject (NotationControllerDelegate)
- (BOOL)notationListShouldChange:(NotationController*)someNotation;
- (void)notationListMightChange:(NotationController*)someNotation;
- (void)notationListDidChange:(NotationController*)someNotation;
- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note options:(NSUInteger)opts;
- (void)notation:(NotationController*)notation revealNotes:(NSArray*)notes;

- (void)contentsUpdatedForNote:(NoteObject*)aNoteObject;
- (void)titleUpdatedForNote:(NoteObject*)aNoteObject;
- (void)rowShouldUpdate:(NSInteger)affectedRow;

@end
