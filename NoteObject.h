//
//  NoteObject.h
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


#import <Cocoa/Cocoa.h>
#import "NotationController.h"
#import "NVNoteDelegate.h"
#import "BufferUtils.h"
#import "SynchronizedNoteProtocol.h"

@class LabelObject;
@class NotesTableView;
@class ExternalEditor;
@class NVNoteContent;

typedef struct _NoteFilterContext {
	char* needle;
	BOOL useCachedPositions;
} NoteFilterContext;

@interface NoteObject : NSObject <NSCoding, SynchronizedNote> {
	NSAttributedString *tableTitleString;
	NSMutableAttributedString *contentString;
	
	//caching/searching purposes only -- created at runtime
	char *cTitle, *cContents, *cLabels, *cTitleFoundPtr, *cContentsFoundPtr, *cLabelsFoundPtr;
	NSMutableSet *labelSet;
	BOOL contentsWere7Bit, contentCacheNeedsUpdate;
	//if this note's title is "Chicken Shack menu listing", its prefix parent might have the title "Chicken Shack"
	
//	NSString *wordCountString;
	NSString *dateModifiedString, *dateCreatedString;
	
	__weak id<NVNoteDelegate> delegate; //the notes controller
	
	BOOL didUnarchive;
	
	//for storing in write-ahead-log
	unsigned int logSequenceNumber;
	
	//the first for syncing w/ NV server, as the ID cannot be encrypted
	CFUUIDBytes uniqueNoteIDBytes;
	
	NSMutableDictionary *syncServicesMD;
	
	//the Simplenote id, and how the stored content split into title and body (NoteObject_NVRecord);
	//not archived: both come from the Notes store
	NSString *recordID;
	NVNoteContent *recordContent;
	
	//more metadata
	NSRange selectedRange;
	
	//each note has its own undo manager--isn't that nice?
	NSUndoManager *undoManager;
@public
	NSMutableArray *prefixParentNotes;
	NSString *titleString, *labelString;
	CFAbsoluteTime modifiedDate, createdDate;
}


NSInteger compareDateModified(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareDateCreated(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareLabelString(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareTitleString(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareUniqueNoteIDBytes(__unsafe_unretained id *a, __unsafe_unretained id *b);


NSInteger compareDateModifiedReverse(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareDateCreatedReverse(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareLabelStringReverse(__unsafe_unretained id *a, __unsafe_unretained id *b);
NSInteger compareTitleStringReverse(__unsafe_unretained id *a, __unsafe_unretained id *b);

//syncing w/ server and from journal
- (CFUUIDBytes *)uniqueNoteIDBytes;
- (NSDictionary*)syncServicesMD;
- (unsigned int)logSequenceNumber;
- (void)incrementLSN;

- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj;

	CFAbsoluteTime modifiedDateOfNote(NoteObject *note);
	CFAbsoluteTime createdDateOfNote(NoteObject *note);
	
	NSString* titleOfNote(NoteObject *note);
	NSString* labelsOfNote(NoteObject *note);

	NSMutableArray* prefixParentsOfNote(NoteObject *note);

#define DefColAttrAccessor(__FName, __IVar) force_inline id __FName(NotesTableView *tv, NoteObject *note, NSInteger row) { return note->__IVar; }
#define DefModelAttrAccessor(__FName, __IVar) force_inline typeof (((NoteObject *)0)->__IVar) __FName(NoteObject *note) { return note->__IVar; }

	//return types are NSString or NSAttributedString, satisifying NSTableDataSource protocol otherwise
	id titleOfNote2(NotesTableView *tv, NoteObject *note, NSInteger row);
	id tableTitleOfNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id properlyHighlightingTableTitleOfNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id unifiedCellSingleLineForNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id unifiedCellForNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id labelColumnCellForNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id dateCreatedStringOfNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id dateModifiedStringOfNote(NotesTableView *tv, NoteObject *note, NSInteger row);
	id wordCountOfNote(NotesTableView *tv, NoteObject *note, NSInteger row);

	void resetFoundPtrsForNote(NoteObject *note);
	BOOL noteContainsUTF8String(NoteObject *note, NoteFilterContext *context);
	BOOL noteTitleHasPrefixOfUTF8String(NoteObject *note, const char* fullString, size_t stringLen);
	BOOL noteTitleIsAPrefixOfOtherNoteTitle(NoteObject *longerNote, NoteObject *shorterNote);

- (id<NVNoteDelegate>)delegate;
- (void)setDelegate:(id<NVNoteDelegate>)theDelegate;
- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle 
			  delegate:(id<NVNoteDelegate>)aDelegate labels:(NSString*)aLabelString;

- (NSSet*)labelSet;
- (void)replaceMatchingLabelSet:(NSSet*)aLabelSet;
- (void)replaceMatchingLabel:(LabelObject*)label;
- (void)updateLabelConnectionsAfterDecoding;
- (void)updateLabelConnections;
- (void)disconnectLabels;
- (BOOL)_setLabelString:(NSString*)newLabelString;
- (void)setLabelString:(NSString*)newLabels;
- (NSMutableSet*)labelSetFromCurrentString;
- (NSArray*)orderedLabelTitles;
- (NSSize)sizeOfLabelBlocks;
- (void)_drawLabelBlocksInRect:(NSRect)aRect rightAlign:(BOOL)onRight highlighted:(BOOL)isHighlighted getSizeOnly:(NSSize*)reqSize;
- (void)drawLabelBlocksInRect:(NSRect)aRect rightAlign:(BOOL)onRight highlighted:(BOOL)isHighlighted;

- (void)setSyncObjectAndKeyMD:(NSDictionary*)aDict forService:(NSString*)serviceName;
- (void)removeAllSyncMDForService:(NSString*)serviceName;
//- (void)removeKey:(NSString*)aKey forService:(NSString*)serviceName;
- (void)updateWithSyncBody:(NSString*)newBody andTitle:(NSString*)newTitle;
- (void)registerModificationWithOwnedServices;

- (BOOL)updateFromPlainTextData:(NSMutableData*)data;

- (NSURL*)uniqueNoteLink;
- (NSString*)titleAsFilename;
- (NSString*)temporaryTextFilePath;

- (void)makeNoteDirtyUpdateTime:(BOOL)updateTime updateFile:(BOOL)updateFile;

- (OSStatus)exportToDirectoryURL:(NSURL*)directoryURL withFilename:(NSString*)userFilename usingFormat:(int)storageFormat overwrite:(BOOL)overwrite;
- (NSRange)nextRangeForWords:(NSArray*)words options:(unsigned)opts range:(NSRange)inRange;
- (void)editExternallyUsingEditor:(ExternalEditor*)ed;
- (void)abortEditingInExternalEditor;

- (BOOL)_setTitleString:(NSString*)aNewTitle;
- (void)setTitleString:(NSString*)aNewTitle;
- (void)updateTablePreviewString;
- (void)initContentCacheCString;
- (void)updateContentCacheCStringIfNecessary;
- (void)setContentString:(NSAttributedString*)attributedString;
- (NSAttributedString*)contentString;
- (NSAttributedString*)printableStringRelativeToBodyFont:(NSFont*)bodyFont;
- (NSString*)combinedContentWithContextSeparator:(NSString*)sepWContext;
- (void)setForegroundTextColorOnly:(NSColor*)aColor;
- (void)_resanitizeContent;
- (void)updateUnstyledTextWithBaseFont:(NSFont*)baseFont;
- (void)updateDateStrings;
- (void)setDateModified:(CFAbsoluteTime)newTime;
- (void)setDateAdded:(CFAbsoluteTime)newTime;
- (void)setSelectedRange:(NSRange)newRange;
- (NSRange)lastSelectedRange;
- (BOOL)contentsWere7Bit;
- (void)addPrefixParentNote:(NoteObject*)aNote;
- (void)removeAllPrefixParentNotes;
- (void)previewUsingMarked;

- (NSUndoManager*)undoManager;
- (void)_undoManagerDidChange:(NSNotification *)notification;

@end

@interface NSObject (NoteObjectDelegate)
- (void)note:(NoteObject*)note didAddLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note didRemoveLabelSet:(NSSet*)labelSet;
- (void)note:(NoteObject*)note attributeChanged:(NSString*)attribute;
@end

