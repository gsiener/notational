//
//  NoteObject_NVRecord.m
//  Notation
//

#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"
#import "NVNoteContent.h"
#import "NotationPrefs.h"
#import "GlobalPrefs.h"
#import "AttributedPlainText.h"
#import <objc/runtime.h>

static char RecordIDKey, ContentSplitKey;

static NSString *LabelStringFromTags(NSArray *tags) {
	return [tags count] ? [tags componentsJoinedByString:@" "] : @"";
}

static NSArray *TagsFromLabelString(NSString *labels) {
	NSMutableArray *tags = [NSMutableArray array];
	for (NSString *label in [labels componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ,"]])
		if ([label length] && ![tags containsObject:label]) [tags addObject:label];
	return tags;
}

@implementation NoteObject (NVRecord)

- (id)initWithNoteRecord:(NVNoteRecord *)record delegate:(id)aDelegate {
	NVNoteContent *split = [NVNoteContent contentWithString:[record content]];
	NSMutableAttributedString *body = [[[NSMutableAttributedString alloc] initWithString:[split body]
																			 attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]] autorelease];
	[body addLinkAttributesForRange:NSMakeRange(0, [body length])];
	[body addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [body length])];
	if ((self = [self initWithNoteBody:body title:[split title] delegate:aDelegate format:SingleDatabaseFormat
								labels:LabelStringFromTags([record tags])])) {
		objc_setAssociatedObject(self, &RecordIDKey, [record noteID], OBJC_ASSOCIATION_COPY);
		objc_setAssociatedObject(self, &ContentSplitKey, split, OBJC_ASSOCIATION_RETAIN);
		if ([record creationDate] > 0) [self setDateAdded:[record creationDate] - kCFAbsoluteTimeIntervalSince1970];
		if ([record modificationDate] > 0) [self setDateModified:[record modificationDate] - kCFAbsoluteTimeIntervalSince1970];
	}
	return self;
}

- (NSString *)noteRecordID {
	NSString *recordID = objc_getAssociatedObject(self, &RecordIDKey);
	if (!recordID) {
		recordID = [NVNoteRecord newNoteID];
		objc_setAssociatedObject(self, &RecordIDKey, recordID, OBJC_ASSOCIATION_COPY);
	}
	return recordID;
}

- (NVNoteRecord *)noteRecordRepresentation {
	NVNoteContent *split = objc_getAssociatedObject(self, &ContentSplitKey);
	if (!split) split = [NVNoteContent contentWithString:@""];
	NVNoteRecord *record = [[[NVNoteRecord alloc] init] autorelease];
	[record setNoteID:[self noteRecordID]];
	[record setContent:[split stringWithTitle:titleOfNote(self) body:[[self contentString] string]]];
	[record setTags:TagsFromLabelString(labelsOfNote(self))];
	[record setCreationDate:createdDateOfNote(self) + kCFAbsoluteTimeIntervalSince1970];
	[record setModificationDate:modifiedDateOfNote(self) + kCFAbsoluteTimeIntervalSince1970];
	return record;
}

- (BOOL)applyNoteRecord:(NVNoteRecord *)record {
	NVNoteContent *split = [NVNoteContent contentWithString:[record content]];
	NVNoteContent *previous = objc_getAssociatedObject(self, &ContentSplitKey);
	objc_setAssociatedObject(self, &ContentSplitKey, split, OBJC_ASSOCIATION_RETAIN);

	BOOL changed = NO;
	if (![[split title] isEqualToString:titleOfNote(self)] || ![[split body] isEqualToString:[[self contentString] string]]) {
		[self updateWithSyncBody:[split body] andTitle:[split title]];
		changed = YES;
	} else if (previous && ![[previous string] isEqualToString:[split string]]) {
		//same title and body, different layout (e.g. separator): nothing visible changed
	}
	NSString *labels = LabelStringFromTags([record tags]);
	if (![labels isEqualToString:labelsOfNote(self)]) {
		[self setLabelString:labels];
		changed = YES;
	}
	if ([record modificationDate] > 0) [self setDateModified:[record modificationDate] - kCFAbsoluteTimeIntervalSince1970];
	return changed;
}

@end
