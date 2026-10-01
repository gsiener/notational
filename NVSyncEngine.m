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

@interface NVSyncEngine () {
	NVNotesStore *store;
	id<NVSimplenoteService> service;
	dispatch_queue_t queue;
	dispatch_source_t timer;
	NVSyncStatus status;
	NSError *lastError;
	BOOL cycleRequested;
	NSUInteger consecutiveFailures;
	NSDate *nextAllowedAttempt;

	//accumulated during a cycle, delivered at its end
	NSMutableDictionary *updatedNotes;
	NSMutableSet *removedNoteIDs;
}
@end

@implementation NVSyncEngine

@synthesize delegate, delegateQueue, pollInterval, indexPageSize;

- (id)initWithStore:(NVNotesStore *)aStore service:(id<NVSimplenoteService>)aService {
	if ((self = [super init])) {
		store = [aStore retain];
		service = [aService retain];
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
	[self stop];
	dispatch_release(queue);
	[store release];
	[service release];
	[lastError release];
	[nextAllowedAttempt release];
	[updatedNotes release];
	[removedNoteIDs release];
	[super dealloc];
}

- (NVSyncStatus)status {
	__block NVSyncStatus current;
	dispatch_sync(queue, ^{ current = status; });
	return current;
}

- (NSError *)lastError {
	__block NSError *error = nil;
	dispatch_sync(queue, ^{ error = [lastError retain]; });
	return [error autorelease];
}

#pragma mark Scheduling

- (void)start {
	dispatch_async(queue, ^{
		if (timer) return;
		timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
		uint64_t interval = (uint64_t)(pollInterval * NSEC_PER_SEC);
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
		dispatch_source_set_event_handler(timer, ^{ [self _runScheduledCycle]; });
		dispatch_resume(timer);
	});
}

- (void)stop {
	dispatch_sync(queue, ^{
		if (timer) {
			dispatch_source_cancel(timer);
			dispatch_release(timer);
			timer = NULL;
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
	if (status == NVSyncStatusSignedOut) return;
	if (nextAllowedAttempt && [nextAllowedAttempt timeIntervalSinceNow] > 0) return;
	[self _runCycleReturningError:NULL];
}

- (BOOL)syncOnceReturningError:(NSError **)error {
	__block BOOL ok = NO;
	__block NSError *failure = nil;
	dispatch_sync(queue, ^{
		NSError *e = nil;
		ok = [self _runCycleReturningError:&e];
		failure = [e retain];
	});
	if (error) *error = [failure autorelease];
	else [failure release];
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
	[updatedNotes setObject:[[record copy] autorelease] forKey:[record noteID]];
}

- (void)_noteRemoved:(NSString *)noteID {
	[updatedNotes removeObjectForKey:noteID];
	[removedNoteIDs addObject:noteID];
}

- (void)_deliverChanges {
	if (![updatedNotes count] && ![removedNoteIDs count]) return;
	NSArray *records = [[updatedNotes allValues] retain];
	NSArray *removed = [[removedNoteIDs allObjects] retain];
	[updatedNotes removeAllObjects];
	[removedNoteIDs removeAllObjects];
	id<NVSyncEngineDelegate> target = delegate;
	dispatch_async(delegateQueue, ^{
		[target syncEngine:self didUpdateNotes:records removedNoteIDs:removed];
		[records release];
		[removed release];
	});
}

#pragma mark Cycle

- (BOOL)_runCycleReturningError:(NSError **)error {
	[self _setStatus:NVSyncStatusSyncing];
	NSError *failure = nil;
	BOOL ok = [self _pullReturningError:&failure] && [self _pushReturningError:&failure];
	[self _deliverChanges];

	[lastError release];
	lastError = [failure retain];
	if (ok) {
		consecutiveFailures = 0;
		[nextAllowedAttempt release];
		nextAllowedAttempt = nil;
		[self _setStatus:NVSyncStatusIdle];
	} else if ([[failure domain] isEqualToString:NVSimplenoteErrorDomain] && [failure code] == NVSimplenoteErrorUnauthorized) {
		[self _setStatus:NVSyncStatusSignedOut];
	} else {
		consecutiveFailures++;
		NSTimeInterval delay = MIN(MAX_BACKOFF, pollInterval * pow(2.0, (double)MIN(consecutiveFailures, (NSUInteger)10)));
		[nextAllowedAttempt release];
		nextAllowedAttempt = [[NSDate dateWithTimeIntervalSinceNow:delay] retain];
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
	NVNoteRecord *record = [t noteWithID:noteID];
	if (!record) {
		record = [NVNoteRecord recordWithNoteID:noteID serverData:data version:version];
	} else if (version <= [record confirmedVersion] || [record pending]) {
		//an echo of something we already have, or local edits the next push will merge
		return;
	} else {
		[record setServerData:data];
		[record setConfirmedVersion:version];
		[record takeFieldsFromServerData:data];
	}
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
		if ([[failure domain] isEqualToString:NVSimplenoteErrorDomain] && [failure code] == NVSimplenoteErrorUnknownChangeVersion) {
			NSLog(@"NVSyncEngine: sync point no longer known to the server; re-indexing");
			[store setSyncPoint:nil];
			return [self _fullSyncReturningError:error];
		}
		if (error) *error = failure;
		return NO;
	}
	if (![changes count]) return YES;

	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		for (NVRemoteChange *change in changes) {
			if ([change removed]) [self _applyRemoteRemovalOfNote:[change noteID] transaction:t];
			else [self _applyRemoteNote:[change noteID] data:[change data] version:[change version] transaction:t];
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
		[store performTransaction:^(id<NVNotesStoreTransaction> t) {
			for (NVRemoteNote *note in [page notes]) {
				[seen addObject:[note noteID]];
				NSDictionary *data = [note data];
				NSInteger version = [note version];
				if (!data) {
					NSError *getError = nil;
					data = [service noteWithID:[note noteID] version:&version error:&getError];
				}
				[self _applyRemoteNote:[note noteID] data:data version:version transaction:t];
			}
		}];
		mark = [page nextMark];
	} while (mark);

	//notes the server no longer has (purged while we weren't looking)
	[store performTransaction:^(id<NVNotesStoreTransaction> t) {
		for (NVNoteRecord *record in [t allNotes]) {
			if ([record confirmedVersion] > 0 && ![seen containsObject:[record noteID]])
				[self _applyRemoteRemovalOfNote:[record noteID] transaction:t];
		}
	}];
	[store setSyncPoint:startingChangeVersion];
	return YES;
}

#pragma mark Push

- (BOOL)_pushReturningError:(NSError **)error {
	NSUInteger round;
	for (round = 0; round < MAX_PUSH_ROUNDS; round++) {
		NSArray *pending = [store pendingNotes];
		if (![pending count]) return YES;
		BOOL pushedAny = NO;
		for (NVNoteRecord *record in pending) {
			NSError *failure = nil;
			BOOL pushed = [self _pushNote:record error:&failure];
			if (pushed) {
				pushedAny = YES;
				continue;
			}
			if ([[failure domain] isEqualToString:NVSimplenoteErrorDomain] && [failure code] == NVSimplenoteErrorTooLarge) {
				//leave it pending; nothing else we can do until the user shortens it
				NSLog(@"NVSyncEngine: note %@ is too large for Simplenote", [record noteID]);
				continue;
			}
			if (error) *error = failure;
			return NO;
		}
		if (!pushedAny) return YES;
	}
	return YES;
}

- (BOOL)_pushNote:(NVNoteRecord *)pushed error:(NSError **)error {
	NSDictionary *data = [pushed dataForPush];
	NSInteger baseVersion = [pushed confirmedVersion], newVersion = 0;
	NSError *failure = nil;
	NSDictionary *result = [service postNoteWithID:[pushed noteID] data:data baseVersion:baseVersion version:&newVersion error:&failure];

	if (!result && [[failure domain] isEqualToString:NVSimplenoteErrorDomain] && [failure code] == NVSimplenoteErrorNotFound && baseVersion > 0) {
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
	if (!result) {
		if (error) *error = failure;
		return NO;
	}

	NSString *pushedContent = [data objectForKey:@"content"];
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
	return YES;
}

@end
