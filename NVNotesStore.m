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
}
- (id)initWithPath:(NSString *)aPath;
- (BOOL)openReturningError:(NSError **)error;
@end

@interface NVNotesStoreTransactionImpl : NSObject <NVNotesStoreTransaction> {
@public
	NVNotesStore *store;
}
@end

@interface NVNotesStore (QueueOnly)
- (NVNoteRecord *)_recordWithID:(NSString *)noteID;
- (BOOL)_writeRecord:(NVNoteRecord *)record;
- (void)_deleteRecordWithID:(NSString *)noteID;
- (NSArray *)_recordsWhere:(const char *)where;
@end

@implementation NVNotesStoreTransactionImpl
- (NVNoteRecord *)noteWithID:(NSString *)noteID { return [store _recordWithID:noteID]; }
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
	return [[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease];
}

static NSString *JSONString(id object) {
	if (!object) return nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
	return data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
}

static id JSONObject(NSString *string) {
	if (![string length]) return nil;
	return [NSJSONSerialization JSONObjectWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

static const char *NoteColumns = "id, content, tags, deleted, created, modified, server_data, confirmed_version, pending, revision";

static NVNoteRecord *RecordFromRow(sqlite3_stmt *stmt) {
	NVNoteRecord *record = [[[NVNoteRecord alloc] init] autorelease];
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

- (NSArray *)_recordsWhere:(const char *)where {
	NSMutableArray *records = [NSMutableArray array];
	if (!db) return records;
	NSString *sql = [NSString stringWithFormat:@"SELECT %s FROM notes%s%s", NoteColumns, where ? " WHERE " : "", where ? where : ""];
	sqlite3_stmt *stmt = NULL;
	if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) != SQLITE_OK) {
		NSLog(@"NVNotesStore: %@", SQLiteError(db, 0, @"select"));
		return records;
	}
	while (sqlite3_step(stmt) == SQLITE_ROW) [records addObject:RecordFromRow(stmt)];
	sqlite3_finalize(stmt);
	return records;
}

- (NVNoteRecord *)_recordWithID:(NSString *)noteID {
	if (!db) return nil;
	sqlite3_stmt *stmt = NULL;
	NSString *sql = [NSString stringWithFormat:@"SELECT %s FROM notes WHERE id = ?", NoteColumns];
	if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) != SQLITE_OK) return nil;
	BindText(stmt, 1, noteID);
	NVNoteRecord *record = sqlite3_step(stmt) == SQLITE_ROW ? RecordFromRow(stmt) : nil;
	sqlite3_finalize(stmt);
	return record;
}

- (BOOL)_writeRecord:(NVNoteRecord *)record {
	if (!db || ![record noteID]) return NO;
	static const char *sql = "INSERT OR REPLACE INTO notes (id, content, tags, deleted, created, modified, server_data, "
		"confirmed_version, pending, revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
	sqlite3_stmt *stmt = NULL;
	if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
		NSLog(@"NVNotesStore: %@", SQLiteError(db, 0, @"prepare write"));
		return NO;
	}
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
	sqlite3_finalize(stmt);
	if (result != SQLITE_DONE) {
		NSLog(@"NVNotesStore: %@", SQLiteError(db, result, @"write note"));
		return NO;
	}
	return YES;
}

- (NSString *)_metadataValueForKey:(NSString *)key {
	if (!db) return nil;
	sqlite3_stmt *stmt = NULL;
	if (sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key = ?", -1, &stmt, NULL) != SQLITE_OK) return nil;
	BindText(stmt, 1, key);
	NSString *value = sqlite3_step(stmt) == SQLITE_ROW ? ColumnText(stmt, 0) : nil;
	sqlite3_finalize(stmt);
	return value;
}

- (void)_setMetadataValue:(NSString *)value forKey:(NSString *)key {
	if (!db) return;
	sqlite3_stmt *stmt = NULL;
	const char *sql = value ? "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)" : "DELETE FROM metadata WHERE key = ?";
	if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) return;
	BindText(stmt, 1, key);
	if (value) BindText(stmt, 2, value);
	if (sqlite3_step(stmt) != SQLITE_DONE) NSLog(@"NVNotesStore: %@", SQLiteError(db, 0, @"write metadata"));
	sqlite3_finalize(stmt);
}

#pragma mark Opening

+ (NVNotesStore *)storeAtPath:(NSString *)aPath error:(NSError **)error {
	NVNotesStore *store = [[[NVNotesStore alloc] initWithPath:aPath] autorelease];
	return [store openReturningError:error] ? store : nil;
}

- (id)initWithPath:(NSString *)aPath {
	if ((self = [super init])) {
		path = [aPath copy];
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
		failure = [SQLiteError(db, 0, @"open store") retain];
		sqlite3_close(db);
		db = NULL;
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
			NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
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
					[failure release];
					failure = nil;
					return;
				}
			}
		}
	});
	if (!opened && error) *error = [failure autorelease];
	else [failure release];
	return opened;
}

- (void)dealloc {
	//may run on our own queue (a queued block held the last reference), so close directly
	if (db) {
		sqlite3_close(db);
		db = NULL;
	}
	dispatch_release(queue);
	[path release];
	[movedAsideCorruptFile release];
	[super dealloc];
}

- (void)close {
	dispatch_sync(queue, ^{
		if (db) {
			sqlite3_close(db);
			db = NULL;
		}
	});
}

- (void)waitUntilWritten {
	dispatch_sync(queue, ^{});
}

#pragma mark Reading

- (NSArray *)allNotes {
	__block NSArray *records = nil;
	dispatch_sync(queue, ^{ records = [[self _recordsWhere:NULL] retain]; });
	return [records autorelease];
}

- (NSArray *)pendingNotes {
	__block NSArray *records = nil;
	dispatch_sync(queue, ^{ records = [[self _recordsWhere:"pending != 0"] retain]; });
	return [records autorelease];
}

- (NVNoteRecord *)noteWithID:(NSString *)noteID {
	__block NVNoteRecord *record = nil;
	dispatch_sync(queue, ^{ record = [[self _recordWithID:noteID] retain]; });
	return [record autorelease];
}

- (NSUInteger)noteCount {
	__block NSUInteger count = 0;
	dispatch_sync(queue, ^{
		if (!db) return;
		sqlite3_stmt *stmt = NULL;
		if (sqlite3_prepare_v2(db, "SELECT count(*) FROM notes", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW)
			count = (NSUInteger)sqlite3_column_int64(stmt, 0);
		sqlite3_finalize(stmt);
	});
	return count;
}

#pragma mark Writing

- (void)saveLocalEdit:(NVNoteRecord *)record {
	NVNoteRecord *edit = [[record copy] autorelease];
	dispatch_async(queue, ^{
		NVNoteRecord *stored = [self _recordWithID:[edit noteID]];
		NVNoteRecord *updated = stored ? stored : edit;
		[updated setContent:[edit content]];
		[updated setTags:[edit tags]];
		[updated setDeleted:[edit deleted]];
		[updated setCreationDate:[edit creationDate]];
		[updated setModificationDate:[edit modificationDate]];
		[updated setPending:YES];
		[updated setLocalRevision:(stored ? [stored localRevision] : [edit localRevision]) + 1];
		[self _writeRecord:updated];
	});
}

- (void)updateNoteWithID:(NSString *)noteID usingBlock:(BOOL (^)(NVNoteRecord *record))block {
	dispatch_sync(queue, ^{
		NVNoteRecord *record = [self _recordWithID:noteID];
		if (block(record) && record) [self _writeRecord:record];
	});
}

- (void)putNote:(NVNoteRecord *)record {
	NVNoteRecord *copy = [[record copy] autorelease];
	dispatch_async(queue, ^{ [self _writeRecord:copy]; });
}

- (void)_deleteRecordWithID:(NSString *)noteID {
	if (!db) return;
	sqlite3_stmt *stmt = NULL;
	if (sqlite3_prepare_v2(db, "DELETE FROM notes WHERE id = ?", -1, &stmt, NULL) != SQLITE_OK) return;
	BindText(stmt, 1, noteID);
	sqlite3_step(stmt);
	sqlite3_finalize(stmt);
}

- (void)removeNoteWithID:(NSString *)noteID {
	NSString *anID = [[noteID copy] autorelease];
	dispatch_async(queue, ^{ [self _deleteRecordWithID:anID]; });
}

- (void)performTransaction:(void (^)(id<NVNotesStoreTransaction> transaction))block {
	dispatch_sync(queue, ^{
		NVNotesStoreTransactionImpl *transaction = [[NVNotesStoreTransactionImpl alloc] init];
		transaction->store = self;
		if (!db) return;
		BOOL began = Exec(db, "BEGIN IMMEDIATE");
		@try {
			block(transaction);
		} @finally {
			if (began) Exec(db, "COMMIT");
			transaction->store = nil;
			[transaction release];
		}
	});
}

- (void)removeAllNotes {
	dispatch_async(queue, ^{ if (db) Exec(db, "DELETE FROM notes"); });
}

- (NSString *)syncPoint {
	return [self metadataValueForKey:SyncPointKey];
}

- (void)setSyncPoint:(NSString *)syncPoint {
	[self setMetadataValue:syncPoint forKey:SyncPointKey];
}

- (NSString *)metadataValueForKey:(NSString *)key {
	__block NSString *value = nil;
	dispatch_sync(queue, ^{ value = [[self _metadataValueForKey:key] retain]; });
	return [value autorelease];
}

- (void)setMetadataValue:(NSString *)value forKey:(NSString *)key {
	NSString *v = [[value copy] autorelease], *k = [[key copy] autorelease];
	dispatch_async(queue, ^{ [self _setMetadataValue:v forKey:k]; });
}

@end
