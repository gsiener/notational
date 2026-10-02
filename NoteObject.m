//
//  NoteObject.m
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


#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "AttributedPlainText.h"
#import "NSString_CustomTruncation.h"
#import "NSFileManager_NV.h"
#include "BufferUtils.h"
#import "NoteObject_NVRecord.h"
#import "NSData_transformations.h"
#import "NSCollection_utils.h"
#import "NotesTableView.h"
#import "UnifiedCell.h"
#import "LabelColumnCell.h"
#import "ODBEditor.h"

#if __LP64__
// Needed for compatability with data created by 32bit app
typedef struct NSRange32 {
    unsigned int location;
    unsigned int length;
} NSRange32;
#else
typedef NSRange NSRange32;
#endif

@implementation NoteObject

- (id)init {
    if (self=[super init]) {
	
		selectedRange = NSMakeRange(NSNotFound, 0);
		
		//other instance variables initialized on demand
        return self;
    }
	return nil;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	if (cTitle)
		free(cTitle);
	if (cContents)
		free(cContents);
	if (cLabels)
	    free(cLabels);
}

- (id<NVNoteDelegate>)delegate {
	return delegate;
}

- (void)setDelegate:(id<NVNoteDelegate>)theDelegate {
	
	if (theDelegate) {
		delegate = theDelegate;
		
		//do things that ought to have been done during init, but were not possible due to lack of delegate information
		if (!tableTitleString && !didUnarchive) [self updateTablePreviewString];
		if (!labelSet && !didUnarchive) [self updateLabelConnectionsAfterDecoding];
	}
}

NSInteger compareDateModified(__unsafe_unretained id *a, __unsafe_unretained id *b) {
    return (*(__unsafe_unretained NoteObject**)a)->modifiedDate - (*(__unsafe_unretained NoteObject**)b)->modifiedDate;
}
NSInteger compareDateCreated(__unsafe_unretained id *a, __unsafe_unretained id *b) {
    return (*(__unsafe_unretained NoteObject**)a)->createdDate - (*(__unsafe_unretained NoteObject**)b)->createdDate;
}
NSInteger compareLabelString(__unsafe_unretained id *a, __unsafe_unretained id *b) {    
    return (NSInteger)CFStringCompare((__bridge CFStringRef)(labelsOfNote(*(__unsafe_unretained NoteObject **)a)), 
								(__bridge CFStringRef)(labelsOfNote(*(__unsafe_unretained NoteObject **)b)), kCFCompareCaseInsensitive);
}
NSInteger compareTitleString(__unsafe_unretained id *a, __unsafe_unretained id *b) {
	//add kCFCompareNumerically to options for natural order sort
    CFComparisonResult stringResult = CFStringCompare((__bridge CFStringRef)(titleOfNote(*(__unsafe_unretained NoteObject**)a)), 
													  (__bridge CFStringRef)(titleOfNote(*(__unsafe_unretained NoteObject**)b)), 
													  kCFCompareCaseInsensitive);
	if (stringResult == kCFCompareEqualTo) {
		
		NSInteger dateResult = compareDateCreated(a, b);
		if (!dateResult)
			return compareUniqueNoteIDBytes(a, b);
		
		return dateResult;
	}
	
	return (NSInteger)stringResult;
}
NSInteger compareUniqueNoteIDBytes(__unsafe_unretained id *a, __unsafe_unretained id *b) {
	return memcmp((&(*(__unsafe_unretained NoteObject**)a)->uniqueNoteIDBytes), (&(*(__unsafe_unretained NoteObject**)b)->uniqueNoteIDBytes), sizeof(CFUUIDBytes));
}


NSInteger compareDateModifiedReverse(__unsafe_unretained id *a, __unsafe_unretained id *b) {
    return (*(__unsafe_unretained NoteObject**)b)->modifiedDate - (*(__unsafe_unretained NoteObject**)a)->modifiedDate;
}
NSInteger compareDateCreatedReverse(__unsafe_unretained id *a, __unsafe_unretained id *b) {
    return (*(__unsafe_unretained NoteObject**)b)->createdDate - (*(__unsafe_unretained NoteObject**)a)->createdDate;
}
NSInteger compareLabelStringReverse(__unsafe_unretained id *a, __unsafe_unretained id *b) {    
    return (NSInteger)CFStringCompare((__bridge CFStringRef)(labelsOfNote(*(__unsafe_unretained NoteObject **)b)), 
								(__bridge CFStringRef)(labelsOfNote(*(__unsafe_unretained NoteObject **)a)), kCFCompareCaseInsensitive);
}
NSInteger compareTitleStringReverse(__unsafe_unretained id *a, __unsafe_unretained id *b) {
    CFComparisonResult stringResult = CFStringCompare((__bridge CFStringRef)(titleOfNote(*(__unsafe_unretained NoteObject **)b)), 
													  (__bridge CFStringRef)(titleOfNote(*(__unsafe_unretained NoteObject **)a)), 
													  kCFCompareCaseInsensitive);
	
	if (stringResult == kCFCompareEqualTo) {
		NSInteger dateResult = compareDateCreatedReverse(a, b);
		if (!dateResult)
			return compareUniqueNoteIDBytes(b, a);
		
		return dateResult;
	}
	return (NSInteger)stringResult;	
}

#include "SynchronizedNoteMixIns.h"

//syncing w/ server and from journal;

DefModelAttrAccessor(titleOfNote, titleString)
DefModelAttrAccessor(labelsOfNote, labelString)
DefModelAttrAccessor(modifiedDateOfNote, modifiedDate)
DefModelAttrAccessor(createdDateOfNote, createdDate)
DefModelAttrAccessor(prefixParentsOfNote, prefixParentNotes)

//DefColAttrAccessor(wordCountOfNote, wordCountString)
DefColAttrAccessor(titleOfNote2, titleString)
DefColAttrAccessor(dateCreatedStringOfNote, dateCreatedString)
DefColAttrAccessor(dateModifiedStringOfNote, dateModifiedString)

force_inline id tableTitleOfNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	if (note->tableTitleString) return note->tableTitleString;
	return titleOfNote(note);
}
force_inline id properlyHighlightingTableTitleOfNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	if (note->tableTitleString) {
		if ([tv isRowSelected:row]) {
			return [note->tableTitleString string];
		}
		return note->tableTitleString;
	}	
	return titleOfNote(note);
}

force_inline id labelColumnCellForNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	
	LabelColumnCell *cell = [[tv tableColumnWithIdentifier:NoteLabelsColumnString] dataCellForRow:row];
	[cell setNoteObject:note];
	
	return labelsOfNote(note);
}

force_inline id unifiedCellSingleLineForNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	
	id obj = note->tableTitleString ? (id)note->tableTitleString : (id)titleOfNote(note);
	
	UnifiedCell *cell = [[[tv tableColumns] objectAtIndex:0] dataCellForRow:row];
	[cell setNoteObject:note];
	[cell setPreviewIsHidden:YES];
	
	return obj;
}

force_inline id unifiedCellForNote(NotesTableView *tv, NoteObject *note, NSInteger row) {
	//snow leopard is stricter about applying the default highlight-attributes (e.g., no shadow unless no paragraph formatting)
	//so add the shadow here for snow leopard on selected rows
	
	UnifiedCell *cell = [[[tv tableColumns] objectAtIndex:0] dataCellForRow:row];
	[cell setNoteObject:note];
	[cell setPreviewIsHidden:NO];

	BOOL rowSelected = [tv isRowSelected:row];
	BOOL drawShadow = YES;
	
	id obj = note->tableTitleString ? (rowSelected ? (id)AttributedStringForSelection(note->tableTitleString, drawShadow) : 
									   (id)note->tableTitleString) : (id)titleOfNote(note);
	
	
	return obj;
}

//make notationcontroller should send setDelegate: and setLabelString: (if necessary) to each note when unarchiving this way

//there is no measurable difference in speed when using decodeValuesOfObjCTypes, oddly enough
//the overhead of the _decodeObject* C functions must be significantly greater than the objc_msgSend and argument passing overhead
#define DECODE_INDIVIDUALLY 1

- (id)initWithCoder:(NSCoder*)decoder {
	if (self=[self init]) {
		
		if ([decoder allowsKeyedCoding]) {
			//(hopefully?) no versioning necessary here
			
			//for knowing when to delay certain initializations during launch (e.g., preview generation)
			didUnarchive = YES;
			
			modifiedDate = [decoder decodeDoubleForKey:VAR_STR(modifiedDate)];
			createdDate = [decoder decodeDoubleForKey:VAR_STR(createdDate)];
			selectedRange.location = [decoder decodeInt32ForKey:@"selectionRangeLocation"];
			selectedRange.length = [decoder decodeInt32ForKey:@"selectionRangeLength"];
			contentsWere7Bit = [decoder decodeBoolForKey:VAR_STR(contentsWere7Bit)];
			
			logSequenceNumber = [decoder decodeInt32ForKey:VAR_STR(logSequenceNumber)];

			//the per-file storage keys (filename, fileEncoding, currentFormatID, logicalSize, fileModifiedDate, perDiskInfoGroups) are no longer read

			NSUInteger decodedUUIDByteCount = 0;
			const uint8_t *decodedUUIDBytes = [decoder decodeBytesForKey:VAR_STR(uniqueNoteIDBytes) returnedLength:&decodedUUIDByteCount];
			if (decodedUUIDBytes) memcpy(&uniqueNoteIDBytes, decodedUUIDBytes, MIN(decodedUUIDByteCount, sizeof(CFUUIDBytes)));
			
			syncServicesMD = [decoder decodeObjectForKey:VAR_STR(syncServicesMD)];
			
			titleString = [decoder decodeObjectForKey:VAR_STR(titleString)];
			labelString = [decoder decodeObjectForKey:VAR_STR(labelString)];
			contentString = [[NSMutableAttributedString alloc] initWithAttributedString: [decoder decodeObjectForKey:VAR_STR(contentString)]];
			
		} else {
            NSRange32 range32;
			unsigned int serverModifiedTime = 0;
			float scrolledProportion = 0.0;
            #if __LP64__
            unsigned long longTemp;
            #endif
			//per-file storage values that are read only to advance past them
			int legacyFormatID = 0;
			NSString *legacyFilename = nil;
			UInt32 legacyNodeID = 0;
			UTCDateTime legacyFileModifiedDate = {0, 0, 0};
			NSStringEncoding legacyFileEncoding = 0;
#if DECODE_INDIVIDUALLY
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modifiedDate];
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&createdDate];
            #if __LP64__
			[decoder decodeValueOfObjCType:"{_NSRange=II}" at:&range32];
            #else
            [decoder decodeValueOfObjCType:@encode(NSRange) at:&range32];
            #endif
			[decoder decodeValueOfObjCType:@encode(float) at:&scrolledProportion];
			
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
			
			[decoder decodeValueOfObjCType:@encode(int) at:&legacyFormatID];
            #if __LP64__
            [decoder decodeValueOfObjCType:"L" at:&longTemp];
            legacyNodeID = (UInt32)longTemp;
            #else
			[decoder decodeValueOfObjCType:@encode(UInt32) at:&legacyNodeID];
            #endif
			[decoder decodeValueOfObjCType:@encode(UInt16) at:&legacyFileModifiedDate.highSeconds];
            #if __LP64__
			[decoder decodeValueOfObjCType:"L" at:&longTemp];
            legacyFileModifiedDate.lowSeconds = (UInt32)longTemp;
            #else
            [decoder decodeValueOfObjCType:@encode(UInt32) at:&legacyFileModifiedDate.lowSeconds];
            #endif
			[decoder decodeValueOfObjCType:@encode(UInt16) at:&legacyFileModifiedDate.fraction];	
            
            #if __LP64__
            [decoder decodeValueOfObjCType:"I" at:&legacyFileEncoding];
            #else
            [decoder decodeValueOfObjCType:@encode(NSStringEncoding) at:&legacyFileEncoding];
            #endif
			
			[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
			
			titleString = [decoder decodeObject];
			labelString = [decoder decodeObject];
			contentString = [[decoder decodeObject] mutableCopy];
			legacyFilename = [decoder decodeObject];
#else 
			[decoder decodeValuesOfObjCTypes: "dd{NSRange=ii}fIiI{UTCDateTime=SIS}I[16C]I@@@@", &modifiedDate, &createdDate, &range32, 
				&scrolledProportion, &logSequenceNumber, &legacyFormatID, &legacyNodeID, &legacyFileModifiedDate, &legacyFileEncoding, &uniqueNoteIDBytes, 
				&serverModifiedTime, &titleString, &labelString, &contentString, &legacyFilename];
#endif
            selectedRange.location = range32.location;
            selectedRange.length = range32.length;
			contentsWere7Bit = (*(unsigned int*)&scrolledProportion) != 0; //hacko wacko
		}
	
		//re-created at runtime to save space
		[self initContentCacheCString];
		cTitleFoundPtr = cTitle = titleString ? strdup([titleString lowercaseUTF8String]) : NULL;
		cLabelsFoundPtr = cLabels = labelString ? strdup([labelString lowercaseUTF8String]) : NULL;
		
		dateCreatedString = [NSString relativeDateStringWithAbsoluteTime:createdDate];
		dateModifiedString = [NSString relativeDateStringWithAbsoluteTime:modifiedDate];
		
		if (!titleString && !contentString && !labelString) return nil;
        return self;
	}
    return nil;
}

- (void)encodeWithCoder:(NSCoder *)coder {
		
	if ([coder allowsKeyedCoding]) {
		
		[coder encodeDouble:modifiedDate forKey:VAR_STR(modifiedDate)];
		[coder encodeDouble:createdDate forKey:VAR_STR(createdDate)];
		[coder encodeInt32:(unsigned int)selectedRange.location forKey:@"selectionRangeLocation"];
		[coder encodeInt32:(unsigned int)selectedRange.length forKey:@"selectionRangeLength"];
		[coder encodeBool:contentsWere7Bit forKey:VAR_STR(contentsWere7Bit)];
		
		[coder encodeInt32:logSequenceNumber forKey:VAR_STR(logSequenceNumber)];
		
		//the per-file storage keys are no longer written; nothing reads them
		
		[coder encodeBytes:(const uint8_t *)&uniqueNoteIDBytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uniqueNoteIDBytes)];
		[coder encodeObject:syncServicesMD forKey:VAR_STR(syncServicesMD)];
		
		[coder encodeObject:titleString forKey:VAR_STR(titleString)];
		[coder encodeObject:labelString forKey:VAR_STR(labelString)];
		[coder encodeObject:contentString forKey:VAR_STR(contentString)];
	}
}

- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle delegate:(id<NVNoteDelegate>)aDelegate labels:(NSString*)aLabelString {
	//delegate optional here
    if (self=[self init]) {
		
		if (!bodyText || !aNoteTitle) {
			return nil;
		}
		delegate = aDelegate;

		contentString = [[NSMutableAttributedString alloc] initWithAttributedString:bodyText];
		[self initContentCacheCString];
		if (!cContents) {
			NSLog(@"couldn't get UTF8 string from contents?!?");
			return nil;
		}

		if (![self _setTitleString:aNoteTitle])
		    titleString = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		
		if (![self _setLabelString:aLabelString]) {
			labelString = @"";
			cLabelsFoundPtr = cLabels = strdup("");
		}
		
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		createdDate = modifiedDate = CFAbsoluteTimeGetCurrent();
		dateCreatedString = dateModifiedString = [NSString relativeDateStringWithAbsoluteTime:modifiedDate];
		
		if (delegate)
			[self updateTablePreviewString];
        
        
        return self;
    }
    return nil;
}

//assume any changes have been synchronized with undomanager
- (void)setContentString:(NSAttributedString*)attributedString {
	[self setContentString:attributedString updateTime:YES];
}

- (void)setContentString:(NSAttributedString*)attributedString updateTime:(BOOL)updateTime {
	if (attributedString) {
		[contentString setAttributedString:attributedString];
		
		[self updateTablePreviewString];
		contentCacheNeedsUpdate = YES;
		//[self updateContentCacheCStringIfNecessary];
		
		[delegate note:self attributeChanged:NotePreviewString];
	
		[self makeNoteDirtyUpdateTime:updateTime updateFile:YES];
	}
}
- (NSAttributedString*)contentString {
	return contentString;
}

- (void)updateContentCacheCStringIfNecessary {
	if (contentCacheNeedsUpdate) {
		//NSLog(@"updating ccache strs");
		cContentsFoundPtr = cContents = replaceString(cContents, [[contentString string] lowercaseUTF8String]);
		contentCacheNeedsUpdate = NO;
		
		unsigned long len = strlen(cContents);
		contentsWere7Bit = !(ContainsHighAscii(cContents, len));
		
		//could cache dumbwordcount here for faster launch, but string creation takes more time, anyway
		//if (wordCountString) CFRelease((CFStringRef*)wordCountString); //this is CFString, so bridge will just call back to CFRelease, anyway
		//wordCountString = (NSString*)CFStringFromBase10Integer(DumbWordCount(cContents, len));
	}
}

- (void)initContentCacheCString {

	if (contentsWere7Bit) {
		if (!(cContentsFoundPtr = cContents = [[contentString string] copyLowercaseASCIIString]))
			contentsWere7Bit = NO;
	}
	
	size_t len = -1;
	
	if (!contentsWere7Bit) {
		const char *cStringData = [[contentString string] lowercaseUTF8String];
		cContentsFoundPtr = cContents = cStringData ? strdup(cStringData) : NULL;
		
		contentsWere7Bit = cContents ? !(ContainsHighAscii(cContents, (len = strlen(cContents)))) : NO;
	}
	
	//if (len < 0) len = strlen(cContents);
	//wordCountString = (NSString*)CFStringFromBase10Integer(DumbWordCount(cContents, len));
	
	contentCacheNeedsUpdate = NO;
}

- (BOOL)contentsWere7Bit {
	return contentsWere7Bit;
}

- (NSString*)description {
	return syncServicesMD ? [NSString stringWithFormat:@"%@ / %@", titleString, syncServicesMD] : titleString;
}

- (NSString*)combinedContentWithContextSeparator:(NSString*)sepWContext {
	//combine title and body based on separator data usually generated by -syntheticTitleAndSeparatorWithContext:bodyLoc:
	//if separator does not exist or chars do not match trailing and leading chars of title and body, respectively,
	//then just delimit with a double-newline
	
	NSString *content = [contentString string];
	
	BOOL defaultJoin = NO;
	if (![sepWContext length] || ![content length] || ![titleString length] || 
		[titleString characterAtIndex:[titleString length] - 1] != [sepWContext characterAtIndex:0] ||
		[content characterAtIndex:0] != [sepWContext characterAtIndex:[sepWContext length] - 1]) {
		defaultJoin = YES;
	}
	
	NSString *separator = @"\n\n";
	
	//if the separator lacks any actual separating characters, then concatenate with an empty string
	if (!defaultJoin) {
		separator = [sepWContext length] > 2 ? [sepWContext substringWithRange:NSMakeRange(1, [sepWContext length] - 2)] : @"";
	}
	
	NSMutableString *combined = [[NSMutableString alloc] initWithCapacity:[content length] + [titleString length] + [separator length]];
	
	[combined appendString:titleString];
	[combined appendString:separator];
	[combined appendString:content];
	
	return combined;
}


- (NSAttributedString*)printableStringRelativeToBodyFont:(NSFont*)bodyFont {
	NSFont *titleFont = [NSFont fontWithName:[bodyFont fontName] size:[bodyFont pointSize] + 6.0f];
	
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:titleFont, NSFontAttributeName, nil];
	
	NSMutableAttributedString *largeAttributedTitleString = [[NSMutableAttributedString alloc] initWithString:titleString attributes:dict];
	
	NSAttributedString *noAttrBreak = [[NSAttributedString alloc] initWithString:@"\n\n\n" attributes:nil];
	[largeAttributedTitleString appendAttributedString:noAttrBreak];

	//other header things here, too? like date created/mod/printed? tags?
	NSMutableAttributedString *contentMinusColor = [[self contentString] mutableCopy];
	[contentMinusColor removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentMinusColor length])];
	
	[largeAttributedTitleString appendAttributedString:contentMinusColor];
	
	return largeAttributedTitleString;
}

- (void)updateTablePreviewString {
	//delegate required for this method
	GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];

	if ([prefs tableColumnsShowPreview]) {
		if ([prefs horizontalLayout]) {
			//is called for visible notes at launch and resize only, generation of images for invisible notes is delayed until after launch
			
			NSSize labelBlockSize = ColumnIsSet(NoteLabelsColumn, [prefs tableColumnsBitmap]) ? [self sizeOfLabelBlocks] : NSZeroSize;
			tableTitleString = [titleString attributedMultiLinePreviewFromBodyText:contentString upToWidth:[delegate titleColumnWidth] 
																	 intrusionWidth:labelBlockSize.width];
		} else {
			tableTitleString = [titleString attributedSingleLinePreviewFromBodyText:contentString upToWidth:[delegate titleColumnWidth]];
		}
	} else {
		if ([prefs horizontalLayout]) {
			tableTitleString = [titleString attributedSingleLineTitle];
		} else {
			tableTitleString = nil;
		}
	}
}

- (void)setTitleString:(NSString*)aNewTitle {
	
    if ([self _setTitleString:aNewTitle]) {
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		
		[self updateTablePreviewString];
		
		/*NSUndoManager *undoMan = [delegate undoManager];
		[undoMan registerUndoWithTarget:self selector:@selector(setTitleString:) object:oldTitle];
		if (![undoMan isUndoing] && ![undoMan isRedoing])
			[undoMan setActionName:[NSString stringWithFormat:@"Rename Note \"%@\"", titleString]];
		*/
		
		[delegate note:self attributeChanged:NoteTitleColumnString];
    }
}

- (BOOL)_setTitleString:(NSString*)aNewTitle {
    if (!aNewTitle || ![aNewTitle length] || (titleString && [aNewTitle isEqualToString:titleString]))
	return NO;

    titleString = [aNewTitle copy];
    
    cTitleFoundPtr = cTitle = replaceString(cTitle, [titleString lowercaseUTF8String]);
    
    return YES;
}

- (void)setForegroundTextColorOnly:(NSColor*)aColor {
	//called when notationPrefs font doesn't match globalprefs font, or user changes the font
	[contentString removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentString length])];
	if (aColor) {
		[contentString addAttribute:NSForegroundColorAttributeName value:aColor range:NSMakeRange(0, [contentString length])];
	}
}

- (void)_resanitizeContent {
	[contentString santizeForeignStylesForImporting];
	
	//renormalize the title, in case it is still somehow derived from decomposed HFS+ filenames
	NSMutableString *normalizedString = [titleString mutableCopy];
	CFStringNormalize((__bridge CFMutableStringRef)normalizedString, kCFStringNormalizationFormC);
	
	[self _setTitleString:normalizedString];
}

//how do we write a thousand RTF files at once, repeatedly? 

- (void)updateUnstyledTextWithBaseFont:(NSFont*)baseFont {

	if ([contentString restyleTextToFont:[[GlobalPrefs defaultPrefs] noteBodyFont] usingBaseFont:baseFont] > 0) {
		[undoManager removeAllActions];
	}
}

- (void)updateDateStrings {
	dateCreatedString = [NSString relativeDateStringWithAbsoluteTime:createdDate];
	dateModifiedString = [NSString relativeDateStringWithAbsoluteTime:modifiedDate];
}

- (void)setDateModified:(CFAbsoluteTime)newTime {
	modifiedDate = newTime;
	
	dateModifiedString = [NSString relativeDateStringWithAbsoluteTime:modifiedDate];
}

- (void)setDateAdded:(CFAbsoluteTime)newTime {
	createdDate = newTime;
	
	dateCreatedString = [NSString relativeDateStringWithAbsoluteTime:createdDate];
}


- (void)setSelectedRange:(NSRange)newRange {
	//if (!newRange.length) newRange = NSMakeRange(0,0);
	
	//don't save the range if it's invalid, it's equal to the current range, or the entire note is selected
	if ((newRange.location != NSNotFound) && !NSEqualRanges(newRange, selectedRange) && 
		!NSEqualRanges(newRange, NSMakeRange(0, [contentString length]))) {
	//	NSLog(@"saving: old range: %@, new range: %@", NSStringFromRange(selectedRange), NSStringFromRange(newRange));
		selectedRange = newRange;
		[self makeNoteDirtyUpdateTime:NO updateFile:NO];
	}
}

- (NSRange)lastSelectedRange {
	return selectedRange;
}

//these two methods let us get the actual label objects in use by other notes
//they assume that the label string already contains the title of the label object(s); that there is only replacement and not addition
- (void)replaceMatchingLabelSet:(NSSet*)aLabelSet {
    [labelSet minusSet:aLabelSet];
    [labelSet unionSet:aLabelSet];
}

- (void)replaceMatchingLabel:(LabelObject*)aLabel {
    //remove the old label and add the new one; if this is the same one, well, too bad
    [labelSet removeObject:aLabel];
    [labelSet addObject:aLabel];
}

- (void)updateLabelConnectionsAfterDecoding {
	if ([labelString length] > 0) {
		[self updateLabelConnections];
	}
}

- (void)updateLabelConnections {
	//find differences between previous labels and new ones	
	if (delegate) {
		NSMutableSet *oldLabelSet = labelSet;
		NSMutableSet *newLabelSet = [self labelSetFromCurrentString];
		
		if (!oldLabelSet) {
			oldLabelSet = labelSet = [[NSMutableSet alloc] initWithCapacity:[newLabelSet count]];
		}
		
		//what's left-over
		NSMutableSet *oldLabels = [oldLabelSet mutableCopy];
		[oldLabels minusSet:newLabelSet];
		
		//what wasn't there last time
		NSMutableSet *newLabels = newLabelSet;
		[newLabels minusSet:oldLabelSet];
		
		//update the currently known labels
		[labelSet minusSet:oldLabels];
		[labelSet unionSet:newLabels];
		
		//update our status within the list of all labels, adding or removing from the list and updating the labels where appropriate
		//these end up calling replaceMatchingLabel*
		[delegate note:self didRemoveLabelSet:oldLabels];
		[delegate note:self didAddLabelSet:newLabels];
	}
}

- (void)disconnectLabels {
	//when removing this note from NotationController, other LabelObjects as well as LabelsListController should know not to list it
	if (delegate) {
		[delegate note:self didRemoveLabelSet:labelSet];
		labelSet = nil;
	} else {
		NSLog(@"not disconnecting labels because no delegate exists");
	}
}

- (BOOL)_setLabelString:(NSString*)newLabelString {
	if (newLabelString && ![newLabelString isEqualToString:labelString]) {
		
		labelString = [newLabelString copy];
		
		cLabelsFoundPtr = cLabels = replaceString(cLabels, [labelString lowercaseUTF8String]);
		
		[self updateLabelConnections];
		return YES;
	}
	return NO;
}

- (void)setLabelString:(NSString*)newLabelString {
	
	if ([self _setLabelString:newLabelString]) {
	
		if ([[GlobalPrefs defaultPrefs] horizontalLayout]) {
			[self updateTablePreviewString];
		}
		
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		//[self registerModificationWithOwnedServices];
		
		[delegate note:self attributeChanged:NoteLabelsColumnString];
	}
}

- (NSMutableSet*)labelSetFromCurrentString {
	
	NSArray *words = [self orderedLabelTitles];
	NSMutableSet *newLabelSet = [NSMutableSet setWithCapacity:[words count]];
	
	unsigned int i;
	for (i=0; i<[words count]; i++) {
		NSString *aWord = [words objectAtIndex:i];
		
		if ([aWord length] > 0) {
			LabelObject *aLabel = [[LabelObject alloc] initWithTitle:aWord];
			[aLabel addNote:self];
			
			[newLabelSet addObject:aLabel];
		}
	}
	
	return newLabelSet; 
}


- (NSArray*)orderedLabelTitles {
	return [labelString labelCompatibleWords];
}

- (NSSize)sizeOfLabelBlocks {
	NSSize size = NSZeroSize;
	[self _drawLabelBlocksInRect:NSZeroRect rightAlign:NO highlighted:NO getSizeOnly:&size];
	return size;
}

- (void)drawLabelBlocksInRect:(NSRect)aRect rightAlign:(BOOL)onRight highlighted:(BOOL)isHighlighted {
	return [self _drawLabelBlocksInRect:aRect rightAlign:onRight highlighted:isHighlighted getSizeOnly:NULL];
}

- (void)_drawLabelBlocksInRect:(NSRect)aRect rightAlign:(BOOL)onRight highlighted:(BOOL)isHighlighted getSizeOnly:(NSSize*)reqSize {
	//used primarily by UnifiedCell, but also by LabelColumnCell, as well as to determine the width of all label-block-images for this note
	//iterate over words in orderedLabelTitles, retrieving images via -[LabelsListController cachedLabelImageForWord:highlighted:]
	//if right-align is enabled, then the label-images are queued on the first pass and drawn in reverse on the second
	
	CGFloat totalWidth = 0.0, height = 0.0;
	
	//(a do-while rather than goto: ARC does not allow jumping past initialized object variables)
	do {
	if (![labelString length]) break;
	
	NSArray *words = [self orderedLabelTitles];
	if (![words count]) break;
	
	NSPoint nextBoxPoint = onRight ? NSMakePoint(NSMaxX(aRect), aRect.origin.y) : aRect.origin;
	NSMutableArray *images = reqSize || !onRight ? nil : [NSMutableArray arrayWithCapacity:[words count]];
    CGFloat tableFontSize = [[GlobalPrefs defaultPrefs] tableFontSize] - 1.0f;
    nextBoxPoint.y-=round(tableFontSize * 1.3f);
    NSRect dRect=NSZeroRect;
	NSInteger i;
	
	for (i=0; i<(NSInteger)[words count]; i++) {
		NSString *word = [words objectAtIndex:i];
		if ([word length]) {
			NSImage *img = [delegate labelImageForWord:word highlighted:isHighlighted];
			
            dRect.origin=nextBoxPoint;
            dRect.size=[img size];
			if (!reqSize) {
				if (onRight) {
					[images addObject:img];
				} else {
                    [img drawInRect:dRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0f respectFlipped:YES hints:nil];
					nextBoxPoint.x += [img size].width + 4.0;
				}
			} else {
				totalWidth += [img size].width + 4.0;
				height = MAX(height, [img size].height);
			}
		}
	}
	
	if (!reqSize && onRight) {
		{
			//draw images in reverse instead
			for (i = [images count] - 1; i>=0; i--) {
				NSImage *img = [images objectAtIndex:i];
				nextBoxPoint.x -= [img size].width + 4.0;
                dRect.origin=nextBoxPoint;
                dRect.size=[img size];
              [img drawInRect:dRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0f respectFlipped:YES hints:nil];
			}
		}
	}
	} while (0);
	
	if (reqSize) *reqSize = NSMakeSize(totalWidth, height);
}


- (NSURL*)uniqueNoteLink {
		
	//the Simplenote id is stable across launches and machines (and matches links made by older versions)
	NSMutableDictionary *idsDict = [NSMutableDictionary dictionaryWithObject:[self noteRecordID] forKey:@"SN"];
	[idsDict setObject:[[NSData dataWithBytes:&uniqueNoteIDBytes length:16] encodeBase64WithNewlines:NO] forKey:@"NV"];
	
	return [NSURL URLWithString:[@"notational://find/" stringByAppendingFormat:@"%@/?%@", [titleString stringWithPercentEscapes], 
								 [idsDict URLEncodedString]]];
}

- (NSString*)titleAsFilename {
	//the title made safe for use as a file name; no extension
	NSMutableString *name = [titleString mutableCopy];
	[name replaceOccurrencesOfString:@":" withString:@"-" options:0 range:NSMakeRange(0, [name length])];
	[name replaceOccurrencesOfString:@"/" withString:@"-" options:0 range:NSMakeRange(0, [name length])];
	if ([name hasPrefix:@"."]) [name replaceCharactersInRange:NSMakeRange(0, 1) withString:@"_"];
	//leave room for an extension and a uniquing suffix
	return [name filenameExpectingAdditionalCharCount:8];
}

- (NSString*)temporaryTextFilePath {
	//for Marked and for dragging a note out as a file: write the note's text to a file in the temporary directory
	NSString *directory = [[NSFileManager defaultManager] temporaryNotesDirectory];
	NSString *path = [directory stringByAppendingPathComponent:[[self titleAsFilename] stringByAppendingPathExtension:@"txt"]];
	
	if (!directory || ![[contentString string] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
		NSLog(@"couldn't write a temporary file for note %@", titleString);
		return nil;
	}
	return path;
}

- (BOOL)updateFromPlainTextData:(NSMutableData*)data {
	
	if (!data) {
		NSLog(@"%@: Data is nil!", NSStringFromSelector(_cmd));
		return NO;
	}
	
	NSStringEncoding encoding = NSUTF8StringEncoding;
	NSMutableString *stringFromData = [NSMutableString newShortLivedStringFromData:data ofGuessedEncoding:&encoding withPath:NULL];
	if (!stringFromData) {
		NSLog(@"Couldn't make string out of data for note %@", titleString);
		return NO;
	}
	
	NSMutableAttributedString *attributedStringFromData = [[NSMutableAttributedString alloc] initWithString:stringFromData 
																								  attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	
	contentString = attributedStringFromData;
	[contentString santizeForeignStylesForImporting];
	
	contentCacheNeedsUpdate = YES;
	[self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];
	
	[self updateTablePreviewString];
	
	//don't update the date modified here, as this could be old data
	return YES;
}

- (void)updateWithSyncBody:(NSString*)newBody andTitle:(NSString*)newTitle {
	
	NSMutableAttributedString *attributedBodyString = [[NSMutableAttributedString alloc] initWithString:newBody attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	[attributedBodyString addLinkAttributesForRange:NSMakeRange(0, [attributedBodyString length])];
	[attributedBodyString addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [attributedBodyString length])];
	
	//should eventually sync changes back to disk:
	[self setContentString:attributedBodyString updateTime:NO];

	//actions that user-editing via AppDelegate would have handled for us:
    [self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];

	[self setTitleString:newTitle];
}

- (void)registerModificationWithOwnedServices {
	//mirror this note's current mod date to services with which it is already synced
	//there is no point calling this method unless the modification time is 
}

- (void)removeAllSyncServiceMD {
	//potentially dangerous
	[syncServicesMD removeAllObjects];
}


- (void)makeNoteDirtyUpdateTime:(BOOL)updateTime updateFile:(BOOL)updateFile {
	
	if (updateTime) {
		[self setDateModified:CFAbsoluteTimeGetCurrent()];
	}
	if (updateFile && updateTime) {
		//if this is a change that affects the actual content of a note such that we would need to updateFile
		//and the modification time was actually updated, then dirty the note with the sync services, too
		[self registerModificationWithOwnedServices];
	}
	
	//queue note to be written
    [delegate scheduleWriteForNote:self];	
	
	//tell delegate that the date modified changed
	//[delegate note:self attributeChanged:NoteDateModifiedColumnString];
	//except we don't want this here, as it will cause unnecessary (potential) re-sorting and updating of list view while typing
	//so expect the delegate to know to schedule the same update itself
}

- (OSStatus)exportToDirectoryURL:(NSURL*)directoryURL withFilename:(NSString*)userFilename usingFormat:(int)storageFormat overwrite:(BOOL)overwrite {
	
	NSData *formattedData = nil;
	NSError *error = nil;
	
	NSMutableAttributedString *contentMinusColor = [contentString mutableCopy];
	[contentMinusColor removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, [contentMinusColor length])];

	
	switch (storageFormat) {
		case SingleDatabaseFormat:
			NSAssert(NO, @"Warning! Tried to export data in single-db format!?");
		case PlainTextFormat:
			formattedData = [[contentMinusColor string] dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
			break;
		case RTFTextFormat:
			formattedData = [contentMinusColor RTFFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:[NSDictionary dictionary]];
			break;
		case HTMLFormat:
			formattedData = [contentMinusColor dataFromRange:NSMakeRange(0, [contentMinusColor length])
									  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																					 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			break;
		case WordDocFormat:
			formattedData = [contentMinusColor docFormatFromRange:NSMakeRange(0, [contentMinusColor length]) documentAttributes:[NSDictionary dictionary]];
			break;
		case WordXMLFormat:
			formattedData = [contentMinusColor dataFromRange:NSMakeRange(0, [contentMinusColor length]) 
									  documentAttributes:[NSDictionary dictionaryWithObject:NSWordMLTextDocumentType 
																					 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			break;
		default:
			NSLog(@"Attempted to export using unknown format ID: %d", storageFormat);
    }
	if (!formattedData)
		return kDataFormattingErr;
		
	//notes with the same title get the same file name and cause an overwrite prompt
	NSString *newextension = [NotationPrefs pathExtensionForFormat:storageFormat];
	NSString *newfilename = userFilename ? userFilename : [[self titleAsFilename] stringByAppendingPathExtension:newextension];
	//one last replacing, though if the unique file-naming method worked this should be unnecessary
	newfilename = [newfilename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
	
	NSURL *fileURL = [directoryURL URLByAppendingPathComponent:newfilename isDirectory:NO];
	if (!fileURL) return paramErr;
	
	if (!overwrite && [[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
		NSLog(@"File already existed!");
		return dupFNErr;
	}
	NSError *writeError = nil;
	if (![formattedData writeToURL:fileURL options:0 error:&writeError]) {
		NSLog(@"error exporting note: %@", writeError);
		return [[writeError domain] isEqualToString:NSCocoaErrorDomain] && [writeError code] == NSFileWriteNoPermissionError ? permErr : ioErr;
	}
	NSFileManager *fileMan = [NSFileManager defaultManager];
	if (PlainTextFormat == storageFormat) {
		[fileMan setTextEncodingAttribute:NSUTF8StringEncoding atFSPath:[fileURL fileSystemRepresentation]];
	}
	[fileMan setTags:[self orderedLabelTitles] atFSPath:[fileURL fileSystemRepresentation]];
	
	//also export the note's modification and creation dates
	[fileURL setResourceValues:@{ NSURLCreationDateKey: [NSDate dateWithTimeIntervalSinceReferenceDate:createdDate],
								  NSURLContentModificationDateKey: [NSDate dateWithTimeIntervalSinceReferenceDate:modifiedDate] } error:NULL];
			
	return noErr;
}

- (void)editExternallyUsingEditor:(ExternalEditor*)ed {
	[[ODBEditor sharedODBEditor] editNote:self inEditor:ed context:nil];
}

- (void)previewUsingMarked {
	NSWorkspace * ws = [NSWorkspace sharedWorkspace];
	NSURL *markedURL = nil;
	NSString *identifiers[] = { @"com.brettterpstra.marked2", @"com.brettterpstra.marked-setapp", @"com.brettterpstra.marked2.beta", @"com.brettterpstra.marky" };
	int i;
	for (i = 0; i < 4 && !markedURL; i++) {
		NSURL *url = [ws URLForApplicationWithBundleIdentifier:identifiers[i]];
		if ([url isFileURL]) markedURL = url;
	}
	
	NSString *path = markedURL ? [self temporaryTextFilePath] : nil;
	if (markedURL && path) {
		NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
		configuration.activates = NO; //andDeactivate:NO
		[ws openURLs:[NSArray arrayWithObject:[NSURL fileURLWithPath:path]] withApplicationAtURL:markedURL configuration:configuration completionHandler:nil];
	}
}

- (void)abortEditingInExternalEditor {
	[[ODBEditor sharedODBEditor] abortAllEditingSessionsForClient:self];
}

-(void)odbEditor:(ODBEditor *)editor didModifyFile:(NSString *)path newFileLocation:(NSString *)newPath  context:(NSDictionary *)context {

	//read path/newPath into NSData and update note contents
	
	if ([self updateFromPlainTextData:[NSMutableData dataWithContentsOfFile:path options:NSUncachedRead error:NULL]]) {
		//reflect the temp file's changes directly back to the notes store and Simplenote
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		
		[delegate note:self attributeChanged:NotePreviewString];
		[delegate noteContentsDidChange:self];
	} else {
		NSBeep();
		NSLog(@"odbEditor:didModifyFile: unable to get data from %@", path);
	}	
}
-(void)odbEditor:(ODBEditor *)editor didClosefile:(NSString *)path context:(NSDictionary *)context {
	//remove the temp file	
	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

}

- (NSRange)nextRangeForWords:(NSArray*)words options:(unsigned)opts range:(NSRange)inRange {
	//opts indicate forwards or backwards, inRange allows us to continue from where we left off
	//return location of NSNotFound and length 0 if none of the words could be found inRange
	
	//an optimization would be to fall back on cached cString if contentsWere7Bit is true, but then we have to handle opts ourselves
	unsigned int i;
	NSString *haystack = [contentString string];
	NSRange nextRange = NSMakeRange(NSNotFound, 0);
	for (i=0; i<[words count]; i++) {
		NSString *word = [words objectAtIndex:i];
		if ([word length] > 0) {
			nextRange = [haystack rangeOfString:word options:opts range:inRange];
			if (nextRange.location != NSNotFound && nextRange.length)
				break;
		}
	}

	return nextRange;
}

force_inline void resetFoundPtrsForNote(NoteObject *note) {
	note->cTitleFoundPtr = note->cTitle;
	note->cContentsFoundPtr = note->cContents;
	note->cLabelsFoundPtr = note->cLabels;	
}

BOOL noteContainsUTF8String(NoteObject *note, NoteFilterContext *context) {
	
    if (!context->useCachedPositions) {
		resetFoundPtrsForNote(note);
    }
	
	char *needle = context->needle;
    
	/* NOTE: strstr in Darwin is heinously, supernaturally optimized; it blows boyer-moore out of the water. 
	implementations on other OSes will need considerably more code in this function. */
	
    if (note->cTitleFoundPtr)
		note->cTitleFoundPtr = strstr(note->cTitleFoundPtr, needle);
    
    if (note->cContentsFoundPtr)
		note->cContentsFoundPtr = strstr(note->cContentsFoundPtr, needle);
    
    if (note->cLabelsFoundPtr)
		note->cLabelsFoundPtr = strstr(note->cLabelsFoundPtr, needle);
        
    return note->cContentsFoundPtr || note->cTitleFoundPtr || note->cLabelsFoundPtr;
}

BOOL noteTitleHasPrefixOfUTF8String(NoteObject *note, const char* fullString, size_t stringLen) {
	return !strncmp(note->cTitle, fullString, stringLen);
}
BOOL noteTitleIsAPrefixOfOtherNoteTitle(NoteObject *longerNote, NoteObject *shorterNote) {
	return !strncmp(longerNote->cTitle, shorterNote->cTitle, strlen(shorterNote->cTitle));
}

- (void)addPrefixParentNote:(NoteObject*)aNote {
	if (!prefixParentNotes) {
		prefixParentNotes = [[NSMutableArray alloc] initWithCapacity:1];
	}
	[prefixParentNotes addObject:aNote];
}
- (void)removeAllPrefixParentNotes {
	[prefixParentNotes removeAllObjects];
}

- (NSSet*)labelSet {
    return labelSet;
}

/*
- (CFArrayRef)rangesForWords:(NSString*)string inRange:(NSRange)rangeLimit {
	//use cstring caches if note is all 7-bit, as we [REALLY OUGHT TO] be able to assume a 1-to-1 character mapping
	
	if (contentsWere7Bit) {
		char *manglingString = strdup([string UTF8String]);
		char *token, *separators = separatorsForCString(manglingString);
		
		while ((token = strsep(&manglingString, separators))) {
			if (*token != '\0') {
				//find all occurrences of token in cContents and add cfranges to cfmutablearray
			}
		}
	}
}*/

- (NSUndoManager*)undoManager {
    if (!undoManager) {
	undoManager = [[NSUndoManager alloc] init];
	
	id center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(_undoManagerDidChange:)
		       name:NSUndoManagerDidUndoChangeNotification
		     object:undoManager];
	
	[center addObserver:self selector:@selector(_undoManagerDidChange:)
		       name:NSUndoManagerDidRedoChangeNotification
		     object:undoManager];
    }
    
    return undoManager;
}

- (void)_undoManagerDidChange:(NSNotification *)notification {
	[self makeNoteDirtyUpdateTime:YES updateFile:YES];
    //queue note to be synchronized to disk (and network if necessary)
}



@end
