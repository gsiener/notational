//
//  NVFakeSimplenoteService.m
//  NotationTests
//

#import "NVFakeSimplenoteService.h"
#import "NVTextMerge.h"
#import "NVNoteRecord.h"

@interface NVFakeSimplenoteService () {
	NSMutableDictionary *versions;     //note id -> NSMutableArray of data dictionaries; index = version - 1
	NSMutableArray *changeLog;         //NVRemoteChange, oldest first
	NSUInteger changeCounter;
	NSUInteger forgottenThrough;       //change counters below this are unknown
	NSMutableArray *failureCodes;
	NSCountedSet *requestCounts;
	NSMutableDictionary *oldestAvailableVersion; //note id -> NSNumber
}
@end

@implementation NVFakeSimplenoteService

@synthesize requestCounts, afterPostApplied, changesOmitData;

- (id)init {
	if ((self = [super init])) {
		versions = [[NSMutableDictionary alloc] init];
		changeLog = [[NSMutableArray alloc] init];
		failureCodes = [[NSMutableArray alloc] init];
		requestCounts = [[NSCountedSet alloc] init];
		oldestAvailableVersion = [[NSMutableDictionary alloc] init];
	}
	return self;
}

#pragma mark Helpers

static NSString *ChangeVersionString(NSUInteger counter) {
	return [NSString stringWithFormat:@"cv%08lu", (unsigned long)counter];
}

static NSUInteger ChangeCounterOf(NSString *changeVersion) {
	if (![changeVersion hasPrefix:@"cv"]) return NSNotFound;
	return (NSUInteger)[[changeVersion substringFromIndex:2] integerValue];
}

- (BOOL)failIfScheduled:(NSString *)kind error:(NSError **)error {
	[requestCounts addObject:kind];
	if (![failureCodes count]) return NO;
	NSInteger code = [[failureCodes objectAtIndex:0] integerValue];
	[failureCodes removeObjectAtIndex:0];
	if (error) *error = [NSError errorWithDomain:NVSimplenoteErrorDomain code:code userInfo:nil];
	return YES;
}

- (void)recordChangeOfNote:(NSString *)noteID removed:(BOOL)removed {
	NVRemoteChange *change = [[NVRemoteChange alloc] init];
	[change setNoteID:noteID];
	[change setChangeVersion:ChangeVersionString(++changeCounter)];
	[change setRemoved:removed];
	if (!removed) {
		NSArray *history = [versions objectForKey:noteID];
		[change setVersion:[history count]];
		[change setData:[history lastObject]];
	}
	[changeLog addObject:change];
}

- (void)appendVersion:(NSDictionary *)data toNote:(NSString *)noteID {
	NSMutableArray *history = [versions objectForKey:noteID];
	if (!history) {
		history = [NSMutableArray array];
		[versions setObject:history forKey:noteID];
	}
	[history addObject:[data copy]];
	[self recordChangeOfNote:noteID removed:NO];
}

#pragma mark NVSimplenoteService

- (NVIndexPage *)indexPageAfterMark:(NSString *)mark limit:(NSUInteger)limit includeData:(BOOL)includeData error:(NSError **)error {
	@synchronized(self) {
		if ([self failIfScheduled:@"index" error:error]) return nil;
		NSArray *ids = [[versions allKeys] sortedArrayUsingSelector:@selector(compare:)];
		NSUInteger start = mark ? (NSUInteger)[mark integerValue] : 0;
		NSUInteger end = MIN([ids count], start + MAX(limit, (NSUInteger)1));
		NSMutableArray *notes = [NSMutableArray array];
		NSUInteger i;
		for (i = start; i < end; i++) {
			NSString *noteID = [ids objectAtIndex:i];
			NSArray *history = [versions objectForKey:noteID];
			[notes addObject:[NVRemoteNote noteWithID:noteID version:[history count] data:includeData ? [history lastObject] : nil]];
		}
		NVIndexPage *page = [[NVIndexPage alloc] init];
		[page setNotes:notes];
		[page setNextMark:end < [ids count] ? [NSString stringWithFormat:@"%lu", (unsigned long)end] : nil];
		[page setChangeVersion:ChangeVersionString(changeCounter)];
		return page;
	}
}

- (NSArray *)changesSince:(NSString *)changeVersion error:(NSError **)error {
	@synchronized(self) {
		if ([self failIfScheduled:@"changes" error:error]) return nil;
		NSUInteger since = ChangeCounterOf(changeVersion);
		if (since == NSNotFound || since > changeCounter || (since < forgottenThrough)) {
			if (error) *error = [NSError errorWithDomain:NVSimplenoteErrorDomain code:NVSimplenoteErrorUnknownChangeVersion userInfo:nil];
			return nil;
		}
		NSMutableArray *changes = [NSMutableArray array];
		for (__strong NVRemoteChange *change in changeLog) {
			if (ChangeCounterOf([change changeVersion]) <= since) continue;
			if (changesOmitData && [change data]) {
				NVRemoteChange *bare = [[NVRemoteChange alloc] init];
				[bare setNoteID:[change noteID]];
				[bare setChangeVersion:[change changeVersion]];
				[bare setVersion:[change version]];
				change = bare;
			}
			[changes addObject:change];
		}
		return changes;
	}
}

- (NSDictionary *)noteWithID:(NSString *)noteID version:(NSInteger *)version error:(NSError **)error {
	@synchronized(self) {
		if ([self failIfScheduled:@"get" error:error]) return nil;
		NSArray *history = [versions objectForKey:noteID];
		if (!history) {
			if (error) *error = [NSError errorWithDomain:NVSimplenoteErrorDomain code:NVSimplenoteErrorNotFound userInfo:nil];
			return nil;
		}
		if (version) *version = [history count];
		return [[history lastObject] copy];
	}
}

- (NSDictionary *)postNoteWithID:(NSString *)noteID data:(NSDictionary *)data baseVersion:(NSInteger)baseVersion
						 version:(NSInteger *)newVersion error:(NSError **)error {
	@synchronized(self) {
		if ([self failIfScheduled:@"post" error:error]) return nil;
		NSArray *history = [versions objectForKey:noteID];
		NSInteger current = [history count];

		if (!history || baseVersion == 0) {
			//create, or overwrite when the client has no base version
			[self appendVersion:data toNote:noteID];
		} else if (baseVersion > current || baseVersion < MAX(1, [[oldestAvailableVersion objectForKey:noteID] integerValue])) {
			if (error) *error = [NSError errorWithDomain:NVSimplenoteErrorDomain code:NVSimplenoteErrorNotFound userInfo:nil];
			return nil;
		} else if ([data isEqualToDictionary:[history lastObject]]) {
			//nothing changed: no new version
		} else if (baseVersion == current) {
			[self appendVersion:data toNote:noteID];
		} else {
			//stale base: merge text edits made since baseVersion, as the server does
			NSDictionary *baseData = [history objectAtIndex:baseVersion - 1];
			NSDictionary *latest = [history lastObject];
			NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:latest];
			for (NSString *key in data) {
				if ([key isEqualToString:@"content"]) continue;
				//fields the poster changed relative to its base win; others keep the latest value
				id posted = [data objectForKey:key];
				if (![posted isEqual:[baseData objectForKey:key]]) [merged setObject:posted forKey:key];
			}
			[merged setObject:[NVTextMerge mergeBase:[baseData objectForKey:@"content"]
												ours:[data objectForKey:@"content"]
											  theirs:[latest objectForKey:@"content"]] forKey:@"content"];
			[self appendVersion:merged toNote:noteID];
		}
		history = [versions objectForKey:noteID];
		if (newVersion) *newVersion = [history count];
		NSDictionary *result = [[history lastObject] copy];
		if (afterPostApplied) afterPostApplied(noteID);
		return result;
	}
}

#pragma mark Another client

- (void)failNextRequestsWithCodes:(NSArray *)codes {
	@synchronized(self) {
		[failureCodes addObjectsFromArray:codes];
	}
}

- (NSString *)remoteCreateNoteWithContent:(NSString *)content tags:(NSArray *)tags {
	@synchronized(self) {
		NSString *noteID = [NVNoteRecord newNoteID];
		NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
		NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:
							  content, @"content", tags ? tags : [NSArray array], @"tags",
							  [NSNumber numberWithBool:NO], @"deleted", [NSArray array], @"systemTags",
							  [NSNumber numberWithDouble:now], @"creationDate", [NSNumber numberWithDouble:now], @"modificationDate",
							  @"", @"shareURL", @"", @"publishURL", nil];
		[self appendVersion:data toNote:noteID];
		return noteID;
	}
}

- (void)remoteSetData:(NSDictionary *)data ofNote:(NSString *)noteID {
	@synchronized(self) {
		[self appendVersion:data toNote:noteID];
	}
}

- (void)remoteUpdateNote:(NSString *)noteID key:(NSString *)key value:(id)value {
	@synchronized(self) {
		NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:[[versions objectForKey:noteID] lastObject]];
		[data setObject:value forKey:key];
		[data setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] forKey:@"modificationDate"];
		[self appendVersion:data toNote:noteID];
	}
}

- (void)remoteSetContent:(NSString *)content ofNote:(NSString *)noteID {
	[self remoteUpdateNote:noteID key:@"content" value:content];
}

- (void)remoteTrashNote:(NSString *)noteID {
	[self remoteUpdateNote:noteID key:@"deleted" value:[NSNumber numberWithBool:YES]];
}

- (void)remotePurgeNote:(NSString *)noteID {
	@synchronized(self) {
		[versions removeObjectForKey:noteID];
		[self recordChangeOfNote:noteID removed:YES];
	}
}

- (void)pruneHistoryOfNote:(NSString *)noteID {
	@synchronized(self) {
		[oldestAvailableVersion setObject:[NSNumber numberWithInteger:[[versions objectForKey:noteID] count]] forKey:noteID];
	}
}

- (void)forgetChangeHistory {
	@synchronized(self) {
		//everything older than the current change version becomes unknown
		forgottenThrough = changeCounter;
	}
}

#pragma mark Inspection

- (NSDictionary *)currentDataOfNote:(NSString *)noteID {
	@synchronized(self) {
		return [[versions objectForKey:noteID] lastObject];
	}
}

- (NSInteger)currentVersionOfNote:(NSString *)noteID {
	@synchronized(self) {
		return [[versions objectForKey:noteID] count];
	}
}

- (NSUInteger)noteCount {
	@synchronized(self) {
		return [versions count];
	}
}

- (NSString *)currentChangeVersion {
	@synchronized(self) {
		return ChangeVersionString(changeCounter);
	}
}

@end
