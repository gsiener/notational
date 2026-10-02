//
//  NVLegacyImporter.h
//  Notation
//
//  One-time migration from the old nvALT storage (ADR 0001 §10). Reads the old
//  "Notes & Settings" database and any leftover journal, read-only, and finds the
//  notes that never reached Simplenote or have edits Simplenote never got. Those are
//  returned as new notes tagged nvalt-recovered, so they can't silently merge into a
//  newer copy. Also extracts the old per-database settings worth keeping.
//
//  Never writes to or deletes the old files.
//

#import <Cocoa/Cocoa.h>

@class NVNoteRecord;

extern NSString *const NVRecoveredNoteTag;

typedef enum {
	NVLegacyImportNothingFound = 0,   //no old database
	NVLegacyImportRead,               //database read; see recoveredNotes
	NVLegacyImportEncrypted,          //database is encrypted; the old app must export it
	NVLegacyImportUnreadable          //file exists but couldn't be read
} NVLegacyImportResult;

@interface NVLegacyImporter : NSObject

//default locations used by the old app
+ (NSString *)defaultDatabasePath;
+ (NSString *)defaultJournalDirectory;

- (id)initWithDatabasePath:(NSString *)databasePath journalDirectory:(NSString *)journalDirectory;

- (NVLegacyImportResult)read;

//after -read: notes to import (new ids, tagged nvalt-recovered)
@property (nonatomic, readonly) NSArray *recoveredNotes;
//after -read: counts for logging and the migration message
@property (nonatomic, readonly) NSUInteger totalNotes, syncedNotes, journalRecords;
//after -read: old settings, nil when absent
@property (nonatomic, readonly) NSFont *bodyFont;
@property (nonatomic, readonly) NSColor *textColor;
@property (nonatomic, readonly) BOOL confirmsDeletion;

@end
