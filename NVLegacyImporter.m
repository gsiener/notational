//
//  NVLegacyImporter.m
//  Notation
//

#import "NVLegacyImporter.h"
#import "NVNoteRecord.h"
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NVArchiving.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "WALController.h"

NSString *const NVRecoveredNoteTag = @"nvalt-recovered";

//keys the old Simplenote sync code stored in each note's metadata
static NSString *const LegacySimplenoteService = @"SN";
static NSString *const LegacySeparatorKey = @"SepStr";

@interface NVLegacyImporter () {
	NSString *databasePath, *journalDirectory;
	NSMutableArray *recoveredNotes;
	NSUInteger totalNotes, syncedNotes, journalRecords;
	NSFont *bodyFont;
	NSColor *textColor;
	BOOL confirmsDeletion, securesTextEntry;
}
@end

@implementation NVLegacyImporter

@synthesize recoveredNotes, totalNotes, syncedNotes, journalRecords, bodyFont, textColor, confirmsDeletion, securesTextEntry;

+ (NSString *)defaultDatabasePath {
	return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Notational Data"]
			stringByAppendingPathComponent:@"Notes & Settings"];
}

+ (NSString *)defaultJournalDirectory {
	return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/net.elasticthreads.nv"];
}

- (id)initWithDatabasePath:(NSString *)aDatabasePath journalDirectory:(NSString *)aJournalDirectory {
	if ((self = [super init])) {
		databasePath = [aDatabasePath copy];
		journalDirectory = [aJournalDirectory copy];
		recoveredNotes = [[NSMutableArray alloc] init];
		confirmsDeletion = YES;
	}
	return self;
}

static NSData *UUIDKey(id note) {
	return [NSData dataWithBytes:[note uniqueNoteIDBytes] length:sizeof(CFUUIDBytes)];
}

//a note Simplenote doesn't fully have: never synced, or changed locally since its last sync
static BOOL NeedsRecovery(NoteObject *note) {
	NSDictionary *sn = [[note syncServicesMD] objectForKey:LegacySimplenoteService];
	return ![sn objectForKey:@"key"] || [[sn objectForKey:@"dirty"] boolValue];
}

- (NVNoteRecord *)recordForNote:(NoteObject *)note {
	NSDictionary *sn = [[note syncServicesMD] objectForKey:LegacySimplenoteService];
	NVNoteRecord *record = [[NVNoteRecord alloc] init];
	//a new id: the recovered copy sits beside whatever Simplenote has, never on top of it
	[record setNoteID:[NVNoteRecord newNoteID]];
	[record setContent:[note combinedContentWithContextSeparator:[sn objectForKey:LegacySeparatorKey]]];

	NSMutableArray *tags = [NSMutableArray array];
	for (NSString *label in [labelsOfNote(note) componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ,"]])
		if ([label length] && ![tags containsObject:label]) [tags addObject:label];
	[tags addObject:NVRecoveredNoteTag];
	[record setTags:tags];

	//old dates are CFAbsoluteTime (since 2001); Simplenote uses seconds since 1970
	[record setCreationDate:createdDateOfNote(note) + kCFAbsoluteTimeIntervalSince1970];
	[record setModificationDate:modifiedDateOfNote(note) + kCFAbsoluteTimeIntervalSince1970];
	return record;
}

- (NVLegacyImportResult)read {
	[recoveredNotes removeAllObjects];
	totalNotes = syncedNotes = journalRecords = 0;

	NSData *bytes = [NSData dataWithContentsOfFile:databasePath options:NSDataReadingUncached error:NULL];
	if (!bytes) return [[NSFileManager defaultManager] fileExistsAtPath:databasePath] ? NVLegacyImportUnreadable : NVLegacyImportNothingFound;

	FrozenNotation *frozen = nil;
	frozen = NVUnarchiveKeyedObject(bytes);
	if (![frozen isKindOfClass:[FrozenNotation class]]) return NVLegacyImportUnreadable;

	NotationPrefs *prefs = [frozen notationPrefs];
	bodyFont = [prefs baseBodyFont];
	textColor = [prefs foregroundColor];
	confirmsDeletion = [prefs confirmFileDeletion];
	securesTextEntry = [prefs secureTextEntry];
	if ([prefs doesEncryption]) return NVLegacyImportEncrypted;

	OSStatus err = noErr;
	NSArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&err];
	if (!notes || err != noErr) return NVLegacyImportUnreadable;

	//newest copy of each note: the database, overridden by newer journal records
	NSMutableDictionary *byUUID = [NSMutableDictionary dictionary];
	for (NoteObject *note in notes) {
		if ([note isKindOfClass:[NoteObject class]]) [byUUID setObject:note forKey:UUIDKey(note)];
	}
	if ([journalDirectory length] && [[NSFileManager defaultManager] fileExistsAtPath:
									  [journalDirectory stringByAppendingPathComponent:@"Interim Note-Changes"]]) {
		WALRecoveryController *recovery = [[WALRecoveryController alloc] initWithParentFSRep:[journalDirectory fileSystemRepresentation]
																			 encryptionKey:[prefs WALSessionKey]];
		for (id record in [[recovery recoveredNotes] allValues]) {
			journalRecords++;
			NSData *key = UUIDKey(record);
			id existing = [byUUID objectForKey:key];
			if (existing && [existing logSequenceNumber] > [record logSequenceNumber]) continue;
			if ([record isKindOfClass:[DeletedNoteObject class]]) [byUUID removeObjectForKey:key];
			else if ([record isKindOfClass:[NoteObject class]]) [byUUID setObject:record forKey:key];
		}
	}

	for (NoteObject *note in [byUUID allValues]) {
		totalNotes++;
		if (NeedsRecovery(note)) [recoveredNotes addObject:[self recordForNote:note]];
		else syncedNotes++;
	}
	[recoveredNotes sortUsingDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:YES]]];
	return NVLegacyImportRead;
}

@end
