//
//  NVNotesStore.m
//  Notation
//

#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#include <sqlite3.h>

NSString *const NVNotesStoreErrorDomain = @"NVNotesStoreErrorDomain";

#define SCHEMA_VERSION 1

static NSString *const SyncPointKey = @"syncPoint";

@interface NVNotesStore () {
	sqlite3 *db;
	dispatch_queue_t queue;
	NSString *path;
	NSString *movedAsideCorruptFile;
	//prepared statements by SQL, kept until the database closes
	NSMutableDictionary *statements;
	NSError *transactionError;
	BOOL failNextCommitForTesting;
}
- (id)initWithPath:(NSString *)aPath;
- (BOOL)openReturningError:(NSError **)error;
@end

@interface NVNotesStoreTransactionImpl : NSObject <NVNotesStoreTransaction> {
@public
	__weak NVNotesStore *store;
}
@end

@interface NVNotesStore (QueueOnly)
- (NVNoteRecord *)_recordWithID:(NSString *)noteID;
- (BOOL)_writeRecord:(NVNoteRecord *)record;
- (void)_deleteRecordWithID:(NSString *)noteID;
- (BOOL)_saveLocalEdit:(NVNoteRecord *)edit;
- (NSArray *)_recordsWhere:(const char *)where;
- (NSArray *)_recordsWithColumns:(const char *)columns where:(const char *)where;
- (NVNoteRecord *)_syncStateWithID:(NSString *)noteID;
- (NSArray *)_confirmedNoteIDs;
@end

@implementation NVNotesStoreTransactionImpl
- (NVNoteRecord *)noteWithID:(NSString *)noteID { return [store _recordWithID:noteID]; }
- (NVNoteRecord *)syncStateOfNoteWithID:(NSString *)noteID { return [store _syncStateWithID:noteID]; }
- (NSArray *)confirmedNoteIDs { return [store _confirmedNoteIDs]; }
- (void)putNote:(NVNoteRecord *)record { [store _writeRecord:record]; }
- (void)removeNoteWithID:(NSString *)noteID { [store _deleteRecordWithID:noteID]; }
- (NSArray *)allNotes { return [store _recordsWhere:NULL]; }
@end

@implementation NVNotesStore

@synthesize movedAsideCorruptFile;

#pragma mark SQLite helpers (store queue only)

static NSError *SQLiteError(sqlite3 *handle, int code, NSString *what) {
	NSString *message = handle ? [NSString stringWithUTF8String:sqlite3_errmsg(handle)] : @"";
	return [NSError errorWithDomain:NVNotesStoreErrorDomain code:code
						   userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@: %@", what, message]
																forKey:NSLocalizedDescriptionKey]];
}

static BOOL Exec(sqlite3 *handle, const char *sql) {
	char *message = NULL;
	if (sqlite3_exec(handle, sql, NULL, NULL, &message) != SQLITE_OK) {
		NSLog(@"NVNotesStore: %s failed: %s", sql, message ? message : "");
		sqlite3_free(message);
		return NO;
	}
	return YES;
}

static void BindText(sqlite3_stmt *stmt, int index, NSString *text) {
	if (!text) {
		sqlite3_bind_null(stmt, index);
		return;
	}
	//explicit byte length keeps embedded NULs and exact bytes
	NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
	sqlite3_bind_text(stmt, index, [utf8 bytes], (int)[utf8 length], SQLITE_TRANSIENT);
}

static NSString *ColumnText(sqlite3_stmt *stmt, int column) {
	const unsigned char *bytes = sqlite3_column_text(stmt, column);
	if (!bytes) return nil;
	int length = sqlite3_column_bytes(stmt, column);
	return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
}

static NSString *JSONString(id object) {
	if (!object) return nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static id JSONObject(NSString *string) {
	if (![string length]) return nil;
	return [NSJSONSerialization JSONObjectWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

static const char *NoteColumns = "id, content, tags, deleted, created, modified, server_data, confirmed_version, pending, revision";
//the same without server_data, the second full copy of each note; only the Sync engine needs it
static const char *ListColumns = "id, content, tags, deleted, created, modified, NULL, confirmed_version, pending, revision";

static NVNoteRecord *RecordFromRow(sqlite3_stmt *stmt) {
	NVNoteRecord *record = [[NVNoteRecord alloc] init];
	[record setNoteID:ColumnText(stmt, 0)];
	NSString *content = ColumnText(stmt, 1);
	[record setContent:content ? content : @""];
	id tags = JSONObject(ColumnText(stmt, 2));
	[record setTags:[tags isKindOfClass:[NSArray class]] ? tags : [NSArray array]];
	[record setDeleted:sqlite3_column_int(stmt, 3) != 0];
	[record setCreationDate:sqlite3_column_double(stmt, 4)];
	[record setModificationDate:sqlite3_column_double(stmt, 5)];
	id serverData = JSONObject(ColumnText(stmt, 6));
	[record setServerData:[serverData isKindOfClass:[NSDictionary class]] ? serverData : [NSDictionary dictionary]];
	[record setConfirmedVersion:(NSInteger)sqlite3_column_int64(stmt, 7)];
	[record setPending:sqlite3_column_int(stmt, 8) != 0];
	[record setLocalRevision:(NSInteger)sqlite3_column_int64(stmt, 9)];
	return record;
}

//a statement ready to bind and step, prepared once and kept for reuse; hand it back with Done()
- (sqlite3_stmt *)_statement:(const char *)sql {
	if (!db) return NULL;
	NSString *key = [NSString stringWithUTF8String:sql];
	sqlite3_stmt *stmt = [[statements objectForKey:key] pointerValue];
	if (!stmt) {
		if (sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &stmt, NULL) != SQLITE_OK) {
			NSLog(@"NVNotesStore: %@", SQLiteError(db, 0, [NSString stringWithFormat:@"prepare %s", sql]));
			return NULL;
		}
		[statements setObject:[NSValue valueWithPointer:stmt] forKey:key];
	}
	return stmt;
}

//ends a statement's use: its read or write is over and its bindings released
static void Done(sqlite3_stmt *stmt) {
	sqlite3_reset(stmt);
	sqlite3_clear_bindings(stmt);
}

- (void)_closeDatabase {
	for (NSValue *stmt in [statements allValues]) sqlite3_finalize([stmt pointerValue]);
	[statements removeAllObjects];
	if (db) {
		if (sqlite3_close(db) != SQLITE_OK) NSLog(@"NVNotesStore: %@", SQLiteError(db, 0, @"close"));
		db = NULL;
	}
}

- (NSArray *)_recordsWhere:(const char *)where {
	return [self _recordsWithColumns:NoteColumns where:where];
}

- (NSArray *)_recordsWithColumns:(const char *)columns where:(const char *)where {
	NSMutableArray *records = [NSMutableArray array];
	if (!db) return records;
	NSString *sql = [NSString stringWithFormat:@"SELECT %s FROM notes%s%s", columns, where ? " WHERE " : "", where ? where : ""];
	sqlite3_stmt *stmt = [self _statement:[sql UTF8String]];
	if (!stmt) return records;
	while (sqlite3_step(stmt) == SQLITE_ROW) [records addObject:RecordFromRow(stmt)];
	Done(stmt);
	return records;
}

- (NVNoteRecord *)_recordWithID:(NSString *)noteID {
	if (!db) return nil;
	NSString *sql = [NSString stringWithFormat:@"SELECT %s FROM notes WHERE id = ?", NoteColumns];
	sqlite3_stmt *stmt = [self _statement:[sql UTF8String]];
	if (!stmt) return nil;
	BindText(stmt, 1, noteID);
	NVNoteRecord *record = sqlite3_step(stmt) == SQLITE_ROW ? RecordFromRow(stmt) : nil;
	Done(stmt);
	return record;
}

- (NVNoteRecord *)_syncStateWithID:(NSString *)noteID {
	if (!db) return nil;
	sqlite3_stmt *stmt = [self _statement:"SELECT confirmed_version, pending, revision FROM notes WHERE id = ?"];
	if (!stmt) return nil;
	BindText(stmt, 1, noteID);
	NVNoteRecord *state = nil;
	if (sqlite3_step(stmt) == SQLITE_ROW) {
		state = [[NVNoteRecord alloc] init];
		[state setNoteID:noteID];
		[state setConfirmedVersion:(NSInteger)sqlite3_column_int64(stmt, 0)];
		[state setPending:sqlite3_column_int(stmt, 1) != 0];
		[state setLocalRevision:(NSInteger)sqlite3_column_int64(stmt, 2)];
	}
	Done(stmt);
	return state;
}

- (NSArray *)_confirmedNoteIDs {
	NSMutableArray *noteIDs = [NSMutableArray array];
	if (!db) return noteIDs;
	sqlite3_stmt *stmt = [self _statement:"SELECT id FROM notes WHERE confirmed_version > 0"];
	if (!stmt) return noteIDs;
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		NSString *noteID = ColumnText(stmt, 0);
		if (noteID) [noteIDs addObject:noteID];
	}
	Done(stmt);
	return noteIDs;
}

- (BOOL)_writeRecord:(NVNoteRecord *)record {
	if (!db || ![record noteID]) { transactionError = SQLiteError(db, SQLITE_MISUSE, @"write note"); return NO; }
	sqlite3_stmt *stmt = [self _statement:"INSERT OR REPLACE INTO notes (id, content, tags, deleted, created, modified, server_data, "
						  "confirmed_version, pending, revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"];
	if (!stmt) { transactionError = SQLiteError(db, sqlite3_errcode(db), @"prepare write note"); return NO; }
	BindText(stmt, 1, [record noteID]);
	BindText(stmt, 2, [record content] ? [record content] : @"");
	BindText(stmt, 3, JSONString([record tags] ? [record tags] : [NSArray array]));
	sqlite3_bind_int(stmt, 4, [record deleted] ? 1 : 0);
	sqlite3_bind_double(stmt, 5, [record creationDate]);
	sqlite3_bind_double(stmt, 6, [record modificationDate]);
	BindText(stmt, 7, JSONString([record serverData] ? [record serverData] : [NSDictionary dictionary]));
	sqlite3_bind_int64(stmt, 8, [record confirmedVersion]);
	sqlite3_bind_int(stmt, 9, [record pending] ? 1 : 0);
	sqlite3_bind_int64(stmt, 10, [record localRevision]);
	int result = sqlite3_step(stmt);
	Done(stmt);
	if (result != SQLITE_DONE) {
		transactionError = SQLiteError(db, result, @"write note");
		return NO;
	}
	return YES;
}

- (NSString *)_metadataValueForKey:(NSString *)key {
	if (!db) return nil;
	sqlite3_stmt *stmt = [self _statement:"SELECT value FROM metadata WHERE key = ?"];
	if (!stmt) return nil;
	BindText(stmt, 1, key);
	NSString *value = sqlite3_step(stmt) == SQLITE_ROW ? ColumnText(stmt, 0) : nil;
	Done(stmt);
	return value;
}

- (BOOL)_setMetadataValue:(NSString *)value forKey:(NSString *)key {
	if (!db) { transactionError = SQLiteError(db, SQLITE_MISUSE, @"write metadata"); return NO; }
	sqlite3_stmt *stmt = [self _statement:value ? "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)" : "DELETE FROM metadata WHERE key = ?"];
	if (!stmt) { transactionError = SQLiteError(db, sqlite3_errcode(db), @"prepare metadata"); return NO; }
	BindText(stmt, 1, key);
	if (value) BindText(stmt, 2, value);
	int result = sqlite3_step(stmt);
	if (result != SQLITE_DONE) transactionError = SQLiteError(db, result, @"write metadata");
	Done(stmt);
	return result == SQLITE_DONE;
}

#pragma mark Opening

+ (NVNotesStore *)storeAtPath:(NSString *)aPath error:(NSError **)error {
	NVNotesStore *store = [[NVNotesStore alloc] initWithPath:aPath];
	return [store openReturningError:error] ? store : nil;
}

- (id)initWithPath:(NSString *)aPath {
	if ((self = [super init])) {
		path = [aPath copy];
		statements = [[NSMutableDictionary alloc] init];
		queue = dispatch_queue_create("net.elasticthreads.nv.notes-store", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (BOOL)_openAndMigrate {
	if (sqlite3_open_v2([path fileSystemRepresentation], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK)
		return NO;
	//WAL with FULL sync: a committed write survives a crash or power loss
	if (!Exec(db, "PRAGMA journal_mode = WAL") || !Exec(db, "PRAGMA synchronous = FULL")) return NO;

	sqlite3_stmt *stmt = NULL;
	int version = -1;
	if (sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
		version = sqlite3_column_int(stmt, 0);
	sqlite3_finalize(stmt);
	if (version < 0) return NO;

	if (version == 0) {
		return Exec(db, "BEGIN") &&
		Exec(db, "CREATE TABLE notes ("
			 "id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, tags TEXT NOT NULL, deleted INTEGER NOT NULL, "
			 "created REAL NOT NULL, modified REAL NOT NULL, server_data TEXT NOT NULL, "
			 "confirmed_version INTEGER NOT NULL, pending INTEGER NOT NULL, revision INTEGER NOT NULL)") &&
		Exec(db, "CREATE INDEX notes_pending ON notes (pending) WHERE pending != 0") &&
		Exec(db, "CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT)") &&
		Exec(db, "PRAGMA user_version = 1") &&
		Exec(db, "COMMIT");
	}
	if (version > SCHEMA_VERSION) {
		NSLog(@"NVNotesStore: %@ has schema %d, newer than this build understands (%d)", path, version, SCHEMA_VERSION);
		return NO;
	}
	//a quick check that the file really is a usable store
	BOOL usable = sqlite3_prepare_v2(db, "SELECT count(*) FROM notes", -1, &stmt, NULL) == SQLITE_OK &&
		sqlite3_step(stmt) == SQLITE_ROW;
	sqlite3_finalize(stmt);
	return usable;
}

- (BOOL)openReturningError:(NSError **)error {
	__block BOOL opened = NO;
	__block NSError *failure = nil;
	dispatch_sync(queue, ^{
		[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
								  withIntermediateDirectories:YES attributes:nil error:NULL];
		if ([self _openAndMigrate]) {
			opened = YES;
			return;
		}
		//not a usable store: move it aside rather than deleting anything, then start empty
		failure = SQLiteError(db, 0, @"open store");
		sqlite3_close(db);
		db = NULL;
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
			NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
			[formatter setDateFormat:@"yyyyMMdd-HHmmss"];
			NSString *aside = [path stringByAppendingFormat:@".corrupt-%@", [formatter stringFromDate:[NSDate date]]];
			if ([[NSFileManager defaultManager] moveItemAtPath:path toPath:aside error:NULL]) {
				movedAsideCorruptFile = [aside copy];
				NSString *suffix;
				for (suffix in [NSArray arrayWithObjects:@"-wal", @"-shm", nil])
					[[NSFileManager defaultManager] moveItemAtPath:[path stringByAppendingString:suffix]
															toPath:[aside stringByAppendingString:suffix] error:NULL];
				NSLog(@"NVNotesStore: moved unreadable store aside to %@", aside);
				if ([self _openAndMigrate]) {
					opened = YES;
					failure = nil;
					return;
				}
			}
		}
	});
	if (!opened && error) *error = failure;
	return opened;
}

- (void)dealloc {
	//may run on our own queue (a queued block held the last reference), so close directly
	[self _closeDatabase];
}

- (void)close {
	[self closeReturningError:NULL];
}

- (BOOL)closeReturningError:(NSError **)error {
	__block NSError *failure = nil;
	dispatch_sync(queue, ^{
		if (db && sqlite3_get_autocommit(db) == 0) failure = SQLiteError(db, SQLITE_BUSY, @"close with open transaction");
		[self _closeDatabase];
	});
	if (error) *error = failure;
	return failure == nil;
}

- (void)waitUntilWritten {
	dispatch_sync(queue, ^{});
}

#pragma mark Reading

- (NSArray *)allNotes {
	__block NSArray *records = nil;
	dispatch_sync(queue, ^{ records = [self _recordsWhere:NULL]; });
	return records;
}

- (NSArray *)allNotesWithoutServerData {
	__block NSArray *records = nil;
	dispatch_sync(queue, ^{ records = [self _recordsWithColumns:ListColumns where:NULL]; });
	return records;
}

- (NSArray *)pendingNotes {
	__block NSArray *records = nil;
	dispatch_sync(queue, ^{ records = [self _recordsWhere:"pending != 0"]; });
	return records;
}

- (NSDictionary *)syncStatesOfNotesWithIDs:(NSArray *)noteIDs {
	NSArray *requested = [noteIDs copy];
	NSMutableDictionary *states = [NSMutableDictionary dictionary];
	dispatch_sync(queue, ^{
		for (NSString *noteID in requested) {
			NVNoteRecord *state = [self _syncStateWithID:noteID];
			if (state) [states setObject:state forKey:noteID];
		}
	});
	return states;
}

- (NVNoteRecord *)noteWithID:(NSString *)noteID {
	__block NVNoteRecord *record = nil;
	dispatch_sync(queue, ^{ record = [self _recordWithID:noteID]; });
	return record;
}

- (NSUInteger)noteCount {
	__block NSUInteger count = 0;
	dispatch_sync(queue, ^{
		sqlite3_stmt *stmt = [self _statement:"SELECT count(*) FROM notes"];
		if (!stmt) return;
		if (sqlite3_step(stmt) == SQLITE_ROW) count = (NSUInteger)sqlite3_column_int64(stmt, 0);
		Done(stmt);
	});
	return count;
}

#pragma mark Writing

- (void)saveLocalEdit:(NVNoteRecord *)record {
	if (record) [self saveLocalEdits:[NSArray arrayWithObject:record]];
}

- (void)saveLocalEdits:(NSArray *)records {
	NSError *error = nil;
	if (![self saveLocalEdits:records error:&error]) NSLog(@"NVNotesStore: %@", error);
}

- (BOOL)saveLocalEdits:(NSArray *)records error:(NSError **)error {
	return [self saveLocalEdits:records metadata:nil error:error];
}

- (BOOL)saveLocalEdits:(NSArray *)records metadata:(NSDictionary *)metadata error:(NSError **)error {
	NSMutableArray *edits = [NSMutableArray arrayWithCapacity:[records count]];
	for (NVNoteRecord *record in records) [edits addObject:[record copy]];
	NSDictionary *values = [metadata copy];
	if (![edits count] && ![values count]) return YES;
	return [self performTransaction:^(id<NVNotesStoreTransaction> transaction) {
		for (NVNoteRecord *edit in edits) {
			if (transactionError) break;
			[self _saveLocalEdit:edit];
		}
		if (!transactionError) for (NSString *key in values) {
			if (![self _setMetadataValue:[values objectForKey:key] forKey:key]) break;
		}
	} error:error];
}

- (BOOL)_saveLocalEdit:(NVNoteRecord *)edit {
	if (!db || ![edit noteID]) { transactionError = SQLiteError(db, SQLITE_MISUSE, @"save local edit"); return NO; }
	//a stored note keeps its server data and confirmed version; only the edited fields change
	sqlite3_stmt *stmt = [self _statement:"UPDATE notes SET content = ?, tags = ?, deleted = ?, created = ?, modified = ?, "
						  "pending = 1, revision = revision + 1 WHERE id = ?"];
	if (!stmt) { transactionError = SQLiteError(db, sqlite3_errcode(db), @"prepare local edit"); return NO; }
	BindText(stmt, 1, [edit content] ? [edit content] : @"");
	BindText(stmt, 2, JSONString([edit tags] ? [edit tags] : [NSArray array]));
	sqlite3_bind_int(stmt, 3, [edit deleted] ? 1 : 0);
	sqlite3_bind_double(stmt, 4, [edit creationDate]);
	sqlite3_bind_double(stmt, 5, [edit modificationDate]);
	BindText(stmt, 6, [edit noteID]);
	int result = sqlite3_step(stmt);
	int changed = result == SQLITE_DONE ? sqlite3_changes(db) : 0;
	Done(stmt);
	if (result != SQLITE_DONE) {
		transactionError = SQLiteError(db, result, @"save local edit");
		return NO;
	}
	if (changed > 0) return YES;

	//new to the store: the record as given, pending, one revision on
	[edit setPending:YES];
	[edit setLocalRevision:[edit localRevision] + 1];
	return [self _writeRecord:edit];
}

- (void)_deleteRecordWithID:(NSString *)noteID {
	sqlite3_stmt *stmt = [self _statement:"DELETE FROM notes WHERE id = ?"];
	if (!stmt) { transactionError = SQLiteError(db, sqlite3_errcode(db), @"prepare delete note"); return; }
	BindText(stmt, 1, noteID);
	int result = sqlite3_step(stmt);
	if (result != SQLITE_DONE) transactionError = SQLiteError(db, result, @"delete note");
	Done(stmt);
}

- (void)performTransaction:(void (^)(id<NVNotesStoreTransaction> transaction))block {
	NSError *error = nil;
	if (![self performTransaction:block error:&error]) NSLog(@"NVNotesStore: %@", error);
}

- (BOOL)performTransaction:(void (^)(id<NVNotesStoreTransaction> transaction))block error:(NSError **)error {
	__block NSError *failure = nil;
	dispatch_sync(queue, ^{
		NVNotesStoreTransactionImpl *transaction = [[NVNotesStoreTransactionImpl alloc] init];
		transaction->store = self;
		if (!db) { failure = SQLiteError(db, SQLITE_MISUSE, @"store closed"); return; }
		int result = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
		if (result != SQLITE_OK) { failure = SQLiteError(db, result, @"begin transaction"); return; }
		transactionError = nil;
		@try {
			block(transaction);
		} @catch (NSException *exception) {
			transactionError = [NSError errorWithDomain:NVNotesStoreErrorDomain code:SQLITE_ABORT
				userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"transaction aborted: %@", [exception reason] ?: [exception name]]}];
		} @finally {
			failure = transactionError;
			if (!failure) {
				if (failNextCommitForTesting) { failNextCommitForTesting = NO; failure = SQLiteError(db, SQLITE_IOERR, @"commit transaction"); }
				else {
					result = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
					if (result != SQLITE_OK) failure = SQLiteError(db, result, @"commit transaction");
				}
			}
			if (failure) sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
			transactionError = nil;
			transaction->store = nil;
		}
	});
	if (error) *error = failure;
	return failure == nil;
}

- (void)failNextCommitForTesting {
	dispatch_sync(queue, ^{ failNextCommitForTesting = YES; });
}

- (void)removeAllNotes {
	NSError *error = nil;
	if (![self removeAllNotesReturningError:&error]) NSLog(@"NVNotesStore: %@", error);
}

- (BOOL)removeAllNotesReturningError:(NSError **)error {
	return [self performTransaction:^(id<NVNotesStoreTransaction> transaction) {
		int result = sqlite3_exec(db, "DELETE FROM notes", NULL, NULL, NULL);
		if (result != SQLITE_OK) transactionError = SQLiteError(db, result, @"remove all notes");
	} error:error];
}

- (BOOL)resetForAccount:(NSString *)account error:(NSError **)error {
	NSString *newAccount = [account copy];
	return [self performTransaction:^(id<NVNotesStoreTransaction> transaction) {
		int result = sqlite3_exec(db, "DELETE FROM notes", NULL, NULL, NULL);
		if (result != SQLITE_OK) { transactionError = SQLiteError(db, result, @"clear account notes"); return; }
		if (![self _setMetadataValue:nil forKey:SyncPointKey]) return;
		[self _setMetadataValue:newAccount forKey:@"simplenoteAccount"];
	} error:error];
}

- (NSString *)syncPoint {
	return [self metadataValueForKey:SyncPointKey];
}

- (void)setSyncPoint:(NSString *)syncPoint {
	[self setMetadataValue:syncPoint forKey:SyncPointKey];
}

- (NSString *)metadataValueForKey:(NSString *)key {
	__block NSString *value = nil;
	dispatch_sync(queue, ^{ value = [self _metadataValueForKey:key]; });
	return value;
}

- (void)setMetadataValue:(NSString *)value forKey:(NSString *)key {
	NSError *error = nil;
	if (![self setMetadataValue:value forKey:key error:&error]) NSLog(@"NVNotesStore: %@", error);
}

- (BOOL)setMetadataValue:(NSString *)value forKey:(NSString *)key error:(NSError **)error {
	NSString *v = [value copy], *k = [key copy];
	return [self performTransaction:^(id<NVNotesStoreTransaction> transaction) {
		[self _setMetadataValue:v forKey:k];
	} error:error];
}

@end
