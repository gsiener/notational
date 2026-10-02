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

static NSString *LabelStringFromTags(NSArray *tags) {
	return [tags count] ? [tags componentsJoinedByString:@" "] : @"";
}

//notes keep CFAbsoluteTime (seconds since 2001); records use Simplenote's seconds since 1970
static CFAbsoluteTime AbsoluteTimeFromRecordDate(NSTimeInterval date) {
	return date - kCFAbsoluteTimeIntervalSince1970;
}

static NSTimeInterval RecordDateFromAbsoluteTime(CFAbsoluteTime time) {
	return time + kCFAbsoluteTimeIntervalSince1970;
}

@implementation NoteObject (NVRecord)

- (id)initWithNoteRecord:(NVNoteRecord *)record delegate:(id)aDelegate {
	NVNoteContent *split = [NVNoteContent contentWithString:[record content]];
	NSMutableAttributedString *body = [[NSMutableAttributedString alloc] initWithString:[split body]
																			 attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
	[body addStrikethroughNearDoneTagsForRange:NSMakeRange(0, [body length])];
	if ((self = [self initWithNoteBody:body title:[split title] delegate:aDelegate labels:LabelStringFromTags([record tags])])) {
		//link detection is the costly part of loading thousands of notes; it waits until the body is shown
		linksNeedDetecting = YES;
		recordID = [[record noteID] copy];
		recordContent = split;
		if ([record creationDate] > 0) [self setDateAdded:AbsoluteTimeFromRecordDate([record creationDate])];
		if ([record modificationDate] > 0) [self setDateModified:AbsoluteTimeFromRecordDate([record modificationDate])];
	}
	return self;
}

- (NSString *)noteRecordID {
	if (!recordID) recordID = [NVNoteRecord newNoteID];
	return recordID;
}

- (NVNoteRecord *)noteRecordRepresentation {
	NVNoteContent *split = recordContent ? recordContent : [NVNoteContent contentWithString:@""];
	NVNoteRecord *record = [[NVNoteRecord alloc] init];
	[record setNoteID:[self noteRecordID]];
	[record setContent:[split stringWithTitle:titleOfNote(self) body:[contentString string]]];
	//split the labels as the tag UI does
	NSArray *tags = [self orderedLabelTitles];
	[record setTags:tags ? tags : [NSArray array]];
	[record setCreationDate:RecordDateFromAbsoluteTime(createdDateOfNote(self))];
	[record setModificationDate:RecordDateFromAbsoluteTime(modifiedDateOfNote(self))];
	return record;
}

- (BOOL)applyNoteRecord:(NVNoteRecord *)record {
	NVNoteContent *split = [NVNoteContent contentWithString:[record content]];
	recordContent = split;

	BOOL changed = NO;
	if (![[split title] isEqualToString:titleOfNote(self)] || ![[split body] isEqualToString:[contentString string]]) {
		[self updateWithSyncBody:[split body] andTitle:[split title]];
		changed = YES;
	}
	NSString *labels = LabelStringFromTags([record tags]);
	if (![labels isEqualToString:labelsOfNote(self)]) {
		[self updateWithSyncLabels:labels];
		changed = YES;
	}
	if ([record modificationDate] > 0) [self setDateModified:AbsoluteTimeFromRecordDate([record modificationDate])];
	return changed;
}

@end
