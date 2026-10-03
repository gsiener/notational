//
//  NVNotesStore.h
//  Notation
//
//  The Notes store: a SQLite replica of the user's Simplenote account, plus local
//  notes not yet pushed. See docs/adr/0001-simplenote-backed-storage.md.
//
//  All SQLite access happens on the store's own serial queue. Writes return after
//  commit or rollback; records passed in and out are copies.
//

#import <Foundation/Foundation.h>

@class NVNoteRecord;

//Operations available inside -performTransaction:. Valid only during the block.
@protocol NVNotesStoreTransaction <NSObject>
- (NVNoteRecord *)noteWithID:(NSString *)noteID;
//the note's sync state alone (see -syncStatesOfNotesWithIDs:); nil if there's no such note
- (NVNoteRecord *)syncStateOfNoteWithID:(NSString *)noteID;
//ids of the notes the server has confirmed (confirmed version > 0)
- (NSArray *)confirmedNoteIDs;
- (void)putNote:(NVNoteRecord *)record;
- (void)removeNoteWithID:(NSString *)noteID;
- (NSArray *)allNotes;
@end

extern NSString *const NVNotesStoreErrorDomain;

@interface NVNotesStore : NSObject

//Opens or creates the store. A file that isn't a readable store is moved aside
//(…corrupt-<timestamp>) and replaced by an empty one; the replica can be re-synced.
+ (NVNotesStore *)storeAtPath:(NSString *)path error:(NSError **)error;

//path of a file moved aside on open because it was unreadable, if any
@property (nonatomic, readonly) NSString *movedAsideCorruptFile;

#pragma mark Reading

- (NSArray *)allNotes;
//every note with an empty serverData: what the notes list needs, without the second full copy
//of each note the server data holds. Not for anything that pushes or writes records back.
- (NSArray *)allNotesWithoutServerData;
- (NVNoteRecord *)noteWithID:(NSString *)noteID;
- (NSArray *)pendingNotes;
//Sync states of those of the notes that are in the store, by id: records holding only noteID,
//confirmedVersion, pending and localRevision, without content, tags, dates or server data.
- (NSDictionary *)syncStatesOfNotesWithIDs:(NSArray *)noteIDs;
- (NSUInteger)noteCount;

#pragma mark Local edits

//Stores the record's content, tags, trash flag and dates as a local edit: marks it
//pending and bumps its local revision. Keeps the stored server data and confirmed version.
- (void)saveLocalEdit:(NVNoteRecord *)record;
//the same for each record, committed together
- (void)saveLocalEdits:(NSArray *)records;
//Returns only after the whole batch commits or rolls back.
- (BOOL)saveLocalEdits:(NSArray *)records error:(NSError **)error;
//Imports edits and metadata (including an import marker) as one durable batch.
- (BOOL)saveLocalEdits:(NSArray *)records metadata:(NSDictionary *)metadata error:(NSError **)error;

#pragma mark Sync

//Runs block on the store's queue inside one SQLite transaction, blocking the caller.
//Everything the block does commits together; other store operations wait.
//Use the error variant when the caller must distinguish rollback from commit.
- (void)performTransaction:(void (^)(id<NVNotesStoreTransaction> transaction))block;
- (BOOL)performTransaction:(void (^)(id<NVNotesStoreTransaction> transaction))block error:(NSError **)error;

- (void)removeAllNotes;
- (BOOL)removeAllNotesReturningError:(NSError **)error;
//Clears the replica and changes its owner in one commit during account switching.
- (BOOL)resetForAccount:(NSString *)account error:(NSError **)error;

//the account change version the replica is up to date with; nil before the first full sync
@property (nonatomic, copy) NSString *syncPoint;

- (NSString *)metadataValueForKey:(NSString *)key;
- (void)setMetadataValue:(NSString *)value forKey:(NSString *)key;
- (BOOL)setMetadataValue:(NSString *)value forKey:(NSString *)key error:(NSError **)error;

#pragma mark Lifecycle

//Waits for earlier queued work. Writes already return after commit or rollback.
- (void)waitUntilWritten;
- (BOOL)closeReturningError:(NSError **)error;
- (void)close;

@end
