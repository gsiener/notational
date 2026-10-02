//
//  NVSyncEngine.m
//  Notation
//

#import "NVSyncEngine.h"
#import "NVNotesStore.h"
#import "NVNoteRecord.h"
#import "NVTextMerge.h"

//pushes repeated in one cycle while notes keep changing under us
#define MAX_PUSH_ROUNDS 3
//backoff ceiling after repeated failures
#define MAX_BACKOFF 900.0
//requests to Simplenote in flight at once when fetching or pushing several notes
#define MAX_CONCURRENT_REQUESTS 4

//what pushing one note got from the server
@interface NVPushOutcome : NSObject
@property (nonatomic, copy) NSDictionary *sent;      //the data posted (rebased, if it had to be)
@property (nonatomic, copy) NSDictionary *result;    //the server's copy afterwards; nil on failure
@property (nonatomic, assign) NSInteger version;
@property (nonatomic, strong) NSError *error;
@end

@implementation NVPushOutcome
@synthesize sent, result, version, error;
@end

@interface NVSyncEngine () {
	NVNotesStore *store;
	id<NVSimplenoteService> service;
	dispatch_queue_t queue;
	dispatch_source_t timer;
	NVSyncStatus status;
	NSError *lastError;
	BOOL cycleRequested;
	BOOL running;
	NSUInteger consecutiveFailures;
	NSDate *nextAllowedAttempt;

	//accumulated during a cycle, delivered at its end
	NSMutableDictionary *updatedNotes;
	NSMutableSet *removedNoteIDs;
}
@end

NSString *const NVSyncStatusDidChangeNotification = @"NVSyncStatusDidChangeNotification";
NSString *const NVSyncStatusKey = @"status";

static BOOL IsSimplenoteError(NSError *e, NSInteger code) {
	return [[e domain] isEqualToString:NVSimplenoteErrorDomain] && [e code] == code;
}

//Calls work for each index from 0 to count - 1, at most MAX_CONCURRENT_REQUESTS at a time on other
//threads, and returns once every call has finished. After a call returns NO, no more are started.
static void PerformConcurrently(NSUInteger count, BOOL (^work)(NSUInteger index)) {
	dispatch_semaphore_t slots = dispatch_semaphore_create(MAX_CONCURRENT_REQUESTS);
	dispatch_group_t group = dispatch_group_create();
	dispatch_queue_t workers = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	NSLock *lock = [[NSLock alloc] init];
	__block BOOL stopped = NO;
	NSUInteger i;
	for (i = 0; i < count; i++) {
		dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
		[lock lock];
		BOOL stop = stopped;
		[lock unlock];
		if (stop) {
			dispatch_semaphore_signal(slots);
			break;
		}
		NSUInteger index = i;
		dispatch_group_async(group, workers, ^{
			if (!work(index)) {
				[lock lock];
				stopped = YES;
				[lock unlock];
			}
			dispatch_semaphore_signal(slots);
		});
	}
	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

@implementation NVSyncEngine

@synthesize delegate, delegateQueue, pollInterval, indexPageSize;

- (id)initWithStore:(NVNotesStore *)aStore service:(id<NVSimplenoteService>)aService {
	if ((self = [super init])) {
		store = aStore;
		service = aService;
		queue = dispatch_queue_create("net.elasticthreads.nv.sync-engine", DISPATCH_QUEUE_SERIAL);
		delegateQueue = dispatch_get_main_queue();
		pollInterval = 30.0;
		indexPageSize = 100;
		updatedNotes = [[NSMutableDictionary alloc] init];
		removedNoteIDs = [[NSMutableSet alloc] init];
	}
	return self;
}

- (void)dealloc {
	//the last reference may be released by a block running on our own queue, so never
	//dispatch_sync onto it from here; nothing else can reach this object any more
	if (timer) {
		dispatch_source_cancel(timer);
		timer = nil;
	}
}

- (NVSyncStatus)status {
	__block NVSyncStatus current;
	dispatch_sync(queue, ^{ current = status; });
	return current;
}

- (NSError *)lastError {
	__block NSError *error = nil;
	dispatch_sync(queue, ^{ error = lastError; });
	return error;
}

#pragma mark Scheduling

- (void)start {
	dispatch_async(queue, ^{
		running = YES;
		if (timer) return;
		timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
		__weak NVSyncEngine *weakSelf = self;
		uint64_t interval = (uint64_t)(pollInterval * NSEC_PER_SEC);
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
		dispatch_source_set_event_handler(timer, ^{ [weakSelf _runScheduledCycle]; });
		dispatch_resume(timer);
	});
}

- (void)stop {
	dispatch_sync(queue, ^{
		running = NO;
		if (timer) {
			dispatch_source_cancel(timer);
			timer = nil;
		}
	});
}

- (void)syncNow {
	dispatch_async(queue, ^{
		if (cycleRequested) return;
		cycleRequested = YES;
		//let a burst of edits settle into one cycle
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), queue, ^{
			cycleRequested = NO;
			[self _runScheduledCycle];
		});
	});
}

- (void)_runScheduledCycle {
	if (!running || status == NVSyncStatusSignedOut) return;
	if (nextAllowedAttempt && [nextAllowedAttempt timeIntervalSinceNow] > 0) return;
	[self _runCycleReturningError:NULL];
}

- (BOOL)syncOnceReturningError:(NSError **)error {
	__block BOOL ok = NO;
	__block NSError *failure = nil;
	dispatch_sync(queue, ^{
		NSError *e = nil;
		ok = [self _runCycleReturningError:&e];
		failure = e;
	});
	if (error) *error = failure;
	return ok;
}

#pragma mark Status and delivery

- (void)_setStatus:(NVSyncStatus)newStatus {
	if (status == newStatus) return;
	status = newStatus;
	id<NVSyncEngineDelegate> target = delegate;
	if ([target respondsToSelector:@selector(syncEngine:didChangeStatus:)]) {
		dispatch_async(delegateQueue, ^{ [target syncEngine:self didChangeStatus:newStatus]; });
	}
}

- (void)_noteUpdated:(NVNoteRecord *)record {
	[removedNoteIDs removeObject:[record noteID]];
	[updatedNotes setObject:[record copy] forKey:[record noteID]];
}

- (void)_noteRemoved:(NSString *)noteID {
	[updatedNotes removeObjectForKey:noteID];
	[removedNoteIDs addObject:noteID];
}

- (void)_deliverChanges {
	if (![updatedNotes count] && ![removedNoteIDs count]) return;
	NSArray *records = [updatedNotes allValues];
	NSArray *removed = [removedNoteIDs allObjects];
	[updatedNotes removeAllObjects];
	[removedNoteIDs removeAllObjects];
	id<NVSyncEngineDelegate> target = delegate;
	dispatch_async(delegateQueue, ^{
		[target syncEngine:self didUpdateNotes:records removedNoteIDs:removed];
	});
}

#pragma mark Cycle

- (BOOL)_runCycleReturningError:(NSError **)error {
	[self _setStatus:NVSyncStatusSyncing];
	NSError *failure = nil;
	BOOL ok = [self _pullReturningError:&failure] && [self _pushReturningError:&failure];
	[self _deliverChanges];

	lastError = failure;
	if (ok) {
		consecutiveFailures = 0;
		nextAllowedAttempt = nil;
		[self _setStatus:NVSyncStatusIdle];
	} else if (IsSimplenoteError(failure, NVSimplenoteErrorUnauthorized)) {
		[self _setStatus:NVSyncStatusSignedOut];
	} else {
		consecutiveFailures++;
		NSTimeInterval delay = MIN(MAX_BACKOFF, pollInterval * pow(2.0, (double)MIN(consecutiveFailures, (NSUInteger)10)));
		nextAllowedAttempt = [NSDate dateWithTimeIntervalSinceNow:delay];
		[self _setStatus:NVSyncStatusOffline];
	}
	if (error) *error = failure;
	return ok;
}

#pragma mark Pull

//Apply a server copy of a note unless it is older than what we have or we hold local edits.
- (void)_applyRemoteNote:(NSString *)noteID data:(NSDictionary *)data version:(NSInteger)version
			 transaction:(id<NVNotesStoreTransaction>)t {
	if (!noteID || ![data isKindOfClass:[NSDictionary class]]) return;
	NVNoteRecord *state = [t syncStateOfNoteWithID:noteID];
	if (state && (version <= [state confirmedVersion] || [state pending])) {
		//an echo of something we already have, or local edits the next push will merge
		return;
	}
	//the server's copy replaces every stored field but the local revision
	NVNoteRecord *record = [NVNoteRecord recordWithNoteID:noteID serverData:data version:version];
	if (state) [record setLocalRevision:[state localRevision]];
	[t putNote:record];
	[self _noteUpdated:record];
}

- (void)_applyRemoteRemovalOfNote:(NSString *)noteID transaction:(id<NVNotesStoreTransaction>)t {
	NVNoteRecord *record = [t noteWithID:noteID];
	if (!record) return;
	if ([record pending]) {
		//purged elsewhere while edited here: keep the edits and recreate the note on the next push
		[record setConfirmedVersion:0];
		[t putNote:record];
		return;
	}
	[t removeNoteWithID:noteID];
	[self _noteRemoved:noteID];
}

- (BOOL)_pullReturningError:(NSError **)error {
	NSString *syncPoint = [store syncPoint];
	if (!syncPoint) return [self _fullSyncReturningError:error];

	NSError *failure = nil;
	NSArray *changes = [service changesSince:syncPoint error:&failure];
	if (!changes) {
		if (IsSimplenoteError(failure, NVSimplenoteErrorUnknownChangeVersion)) {
			NSLog(@"NVSyncEngine: sync point no longer known to the server; re-indexing");
			[store setSyncPoint:nil];
			return [self _fullSyncReturningError:error];
		}
		if (error) *error = failure;
		return NO;
	}
	if (![changes count]) return YES;
	
	//only the last change per note matters; the HTTP feed carries versions, not data,
	//so fetch each changed note once (skipping our own echoes) before touching the store
	NSMutableDictionary *latest = [NSMutableDictionary dictionary];
	NSMutableArray *order = [NSMutableArray array];
	for (NVRemoteChange *change in changes) {
		if (![change noteID]) continue;
		if (![latest objectForKey:[change noteID]]) [order addObject:[change noteID]];
		[latest setObject:change forKey:[change noteID]];
	}
	NSMutableArray *bare = [NSMutableArray array];
	for (NSString *noteID in order) {
		NVRemoteChange *change = [latest objectForKey:noteID];
		if (![change removed] && ![change data]) [bare addObject:noteID];
	}
	NSDictionary *local = [store syncStatesOfNotesWithIDs:bare];
	NSMutableArray *wanted = [NSMutableArray array];
	for (NSString *noteID in bare) {
		NVNoteRecord *state = [local objectForKey:noteID];
		NVRemoteChange *change = [latest objectForKey:noteID];
		if (state && ([state pending] || [change version] <= [state confirmedVersion])) continue;
		[wanted addObject:noteID];
	}
	NSMutableDictionary *fetched = [NSMutableDictionary dictionary];
	NSError *fetchFailure = [self _fetchNotes:wanted into:fetched ignoringFailures:NO];
	if (fetchFailure) {
		if (error) *error = fetchFailure;
		return NO;
	}
	
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		for (NSString *noteID in order) {
			NVRemoteChange *change = [latest objectForKey:noteID];
			if ([change removed]) {
				[self _applyRemoteRemovalOfNote:noteID transaction:t];
			} else if ([change data]) {
				[self _applyRemoteNote:noteID data:[change data] version:[change version] transaction:t];
			} else {
				NVRemoteNote *note = [fetched objectForKey:noteID];
				if (note) [self _applyRemoteNote:noteID data:[note data] version:[note version] transaction:t];
			}
		}
	}];
	[store setSyncPoint:[[changes lastObject] changeVersion]];
	return YES;
}

- (BOOL)_fullSyncReturningError:(NSError **)error {
	NSString *mark = nil, *startingChangeVersion = nil;
	NSMutableSet *seen = [NSMutableSet set];
	do {
		NSError *failure = nil;
		NVIndexPage *page = [service indexPageAfterMark:mark limit:indexPageSize includeData:YES error:&failure];
		if (!page) {
			if (error) *error = failure;
			return NO;
		}
		//the change version from the first page is the safe resume point: anything that
		//changes during the scan is replayed by the next catch-up
		if (!startingChangeVersion) startingChangeVersion = [page changeVersion];
		//notes listed without data are fetched first, so the store isn't held while we wait on the network
		NSMutableArray *bare = [NSMutableArray array];
		for (NVRemoteNote *note in [page notes])
			if (![note data] && [note noteID]) [bare addObject:[note noteID]];
		NSMutableDictionary *fetched = [NSMutableDictionary dictionary];
		[self _fetchNotes:bare into:fetched ignoringFailures:YES];
		[store performTransaction:^(id<NVNotesStoreTransaction> t) {
			for (NVRemoteNote *note in [page notes]) {
				[seen addObject:[note noteID]];
				NSDictionary *data = [note data];
				NSInteger version = [note version];
				if (!data) {
					//one that couldn't be fetched is left as it is
					NVRemoteNote *fetchedNote = [fetched objectForKey:[note noteID]];
					data = [fetchedNote data];
					version = fetchedNote ? [fetchedNote version] : 0;
				}
				[self _applyRemoteNote:[note noteID] data:data version:version transaction:t];
			}
		}];
		mark = [page nextMark];
	} while (mark);

	//notes the server no longer has (purged while we weren't looking)
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		for (NSString *noteID in [t confirmedNoteIDs]) {
			if (![seen containsObject:noteID]) [self _applyRemoteRemovalOfNote:noteID transaction:t];
		}
	}];
	[store setSyncPoint:startingChangeVersion];
	return YES;
}

//Fetches the notes' current copies from the server, several at a time, into fetched (id -> NVRemoteNote).
//A note the server no longer has is left out. Any other failure stops further fetches and is returned
//(the first in noteIDs' order), unless ignoringFailures, when that note is just left out too.
- (NSError *)_fetchNotes:(NSArray *)noteIDs into:(NSMutableDictionary *)fetched ignoringFailures:(BOOL)ignoreFailures {
	NSUInteger count = [noteIDs count];
	if (!count) return nil;
	NSMutableArray *outcomes = [NSMutableArray arrayWithCapacity:count];
	NSUInteger i;
	for (i = 0; i < count; i++) [outcomes addObject:[NSNull null]];
	PerformConcurrently(count, ^BOOL(NSUInteger index) {
		NSString *noteID = [noteIDs objectAtIndex:index];
		NSInteger version = 0;
		NSError *fetchError = nil;
		NSDictionary *data = [service noteWithID:noteID version:&version error:&fetchError];
		id outcome = data ? (id)[NVRemoteNote noteWithID:noteID version:version data:data] : (id)fetchError;
		@synchronized(outcomes) {
			if (outcome) [outcomes replaceObjectAtIndex:index withObject:outcome];
		}
		//gone again since it was listed; the feed (or the purge pass) will say so
		return data || ignoreFailures || IsSimplenoteError(fetchError, NVSimplenoteErrorNotFound);
	});
	for (i = 0; i < count; i++) {
		id outcome = [outcomes objectAtIndex:i];
		if ([outcome isKindOfClass:[NVRemoteNote class]]) {
			[fetched setObject:outcome forKey:[outcome noteID]];
		} else if ([outcome isKindOfClass:[NSError class]] && !ignoreFailures && !IsSimplenoteError(outcome, NVSimplenoteErrorNotFound)) {
			return outcome;
		}
	}
	return nil;
}

#pragma mark Push

- (BOOL)_pushReturningError:(NSError **)error {
	NSUInteger round;
	for (round = 0; round < MAX_PUSH_ROUNDS; round++) {
		NSArray *pending = [store pendingNotes];
		if (![pending count]) return YES;

		//each note is posted on its own and its result applied on its own, so they can go out together
		NSUInteger count = [pending count], i;
		NSMutableArray *outcomes = [NSMutableArray arrayWithCapacity:count];
		for (i = 0; i < count; i++) [outcomes addObject:[NSNull null]];
		PerformConcurrently(count, ^BOOL(NSUInteger index) {
			NVPushOutcome *outcome = [self _sendNote:[pending objectAtIndex:index]];
			@synchronized(outcomes) {
				[outcomes replaceObjectAtIndex:index withObject:outcome];
			}
			//a note too large for Simplenote stays pending; nothing else we can do until the user shortens it
			return [outcome result] || IsSimplenoteError([outcome error], NVSimplenoteErrorTooLarge);
		});

		BOOL pushedAny = NO;
		NSError *failure = nil;
		for (i = 0; i < count; i++) {
			NVPushOutcome *outcome = [outcomes objectAtIndex:i];
			if (![outcome isKindOfClass:[NVPushOutcome class]]) continue; //not sent: an earlier one failed
			NVNoteRecord *record = [pending objectAtIndex:i];
			if ([outcome result]) {
				[self _applyPushOf:record outcome:outcome];
				pushedAny = YES;
			} else if (IsSimplenoteError([outcome error], NVSimplenoteErrorTooLarge)) {
				NSLog(@"NVSyncEngine: note %@ is too large for Simplenote", [record noteID]);
			} else if (!failure) {
				failure = [outcome error];
			}
		}
		if (failure) {
			if (error) *error = failure;
			return NO;
		}
		if (!pushedAny) return YES;
	}
	return YES;
}

//posts the note; called from several threads at once, so it only talks to the server
- (NVPushOutcome *)_sendNote:(NVNoteRecord *)pushed {
	NSDictionary *data = [pushed dataForPush];
	NSInteger baseVersion = [pushed confirmedVersion], newVersion = 0;
	NSError *failure = nil;
	NSDictionary *result = [service postNoteWithID:[pushed noteID] data:data baseVersion:baseVersion version:&newVersion error:&failure];

	if (!result && IsSimplenoteError(failure, NVSimplenoteErrorNotFound) && baseVersion > 0) {
		//the server no longer has our base version (or the note): merge against its current copy ourselves
		NSInteger currentVersion = 0;
		NSError *getError = nil;
		NSDictionary *current = [service noteWithID:[pushed noteID] version:&currentVersion error:&getError];
		NSMutableDictionary *rebased = [NSMutableDictionary dictionaryWithDictionary:data];
		if (current) {
			[rebased setObject:[NVTextMerge mergeBase:[[pushed serverData] objectForKey:@"content"]
												 ours:[pushed content]
											   theirs:[current objectForKey:@"content"]] forKey:@"content"];
		} else {
			currentVersion = 0; //gone entirely: recreate it
		}
		failure = nil;
		result = [service postNoteWithID:[pushed noteID] data:rebased baseVersion:currentVersion version:&newVersion error:&failure];
		data = rebased;
	}
	NVPushOutcome *outcome = [[NVPushOutcome alloc] init];
	[outcome setSent:data];
	[outcome setResult:result];
	[outcome setVersion:newVersion];
	[outcome setError:result ? nil : failure];
	return outcome;
}

- (void)_applyPushOf:(NVNoteRecord *)pushed outcome:(NVPushOutcome *)outcome {
	NSDictionary *result = [outcome result];
	NSInteger newVersion = [outcome version];
	NSString *pushedContent = [[outcome sent] objectForKey:@"content"];
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		NVNoteRecord *record = [t noteWithID:[pushed noteID]];
		if (!record) return;
		[record setServerData:result];
		[record setConfirmedVersion:newVersion];

		if ([record localRevision] == [pushed localRevision]) {
			//nothing changed locally while the push was in flight: adopt the server's result
			BOOL serverChangedIt = ![[result objectForKey:@"content"] isEqual:[record content]] ||
				![[result objectForKey:@"tags"] isEqual:[record tags]] ||
				[[result objectForKey:@"deleted"] boolValue] != [record deleted];
			[record takeFieldsFromServerData:result];
			[record setPending:NO];
			[t putNote:record];
			if (serverChangedIt) [self _noteUpdated:record];
			return;
		}

		//edited while in flight: keep the newer local text, carrying over anything the
		//server merged in, and push again from the new base
		NSString *serverContent = [result objectForKey:@"content"];
		if (![serverContent isEqualToString:pushedContent]) {
			[record setContent:[NVTextMerge mergeBase:pushedContent ours:[record content] theirs:serverContent]];
			[self _noteUpdated:record];
		}
		[record setPending:YES];
		[t putNote:record];
	}];
}

@end
