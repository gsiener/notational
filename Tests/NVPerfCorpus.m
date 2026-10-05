//
//  NVPerfCorpus.m
//  NotationTests
//

#import "NVPerfCorpus.h"
#import "NVNoteRecord.h"
#import "NVNotesStore.h"
#include <math.h>

NSString *const NVPerfRareTerm = @"zyzzogeton";
NSString *const NVPerfMissingTerm = @"qwxjvbnotfound";
NSString *const NVPerfCommonTerm = @"the";
NSString *const NVPerfHugeNoteTitle = @"Very long note";

//splitmix64: small, fast and the same on every machine
typedef struct { uint64_t state; } NVPerfRandom;

static uint64_t NextRandom(NVPerfRandom *r) {
	uint64_t z = (r->state += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

static double UnitRandom(NVPerfRandom *r) {
	return (double)(NextRandom(r) >> 11) / (double)(1ULL << 53);
}

static NSUInteger RandomBelow(NVPerfRandom *r, NSUInteger n) {
	return n ? (NSUInteger)(NextRandom(r) % n) : 0;
}

static double NormalRandom(NVPerfRandom *r) {
	double u = UnitRandom(r), v = UnitRandom(r);
	return sqrt(-2.0 * log(u > 0 ? u : 1e-12)) * cos(2.0 * M_PI * v);
}

#pragma mark Vocabulary

//common English first, so frequency falls off as in real text; made-up words fill the long tail
static NSArray *Vocabulary(void) {
	static NSArray *words;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableArray *list = [[@"the and to of a in is that for it with on as this be at by from or have not are was "
								 "meeting notes project idea call todo email follow up review plan draft next week team "
								 "customer design price list book recipe travel home work garden car doctor read watch "
								 "chicago london budget launch release bug fix test server deploy backup photo music "
								 "coffee dinner lunch weekend morning question answer decision agenda summary link"
								 componentsSeparatedByString:@" "] mutableCopy];
		NSArray *syllables = [@"ka lo mi ne ru sa ti vo be da fe gi ho ju ly mo pa qui re so tu va we xi yo ze an el in or us"
							  componentsSeparatedByString:@" "];
		NVPerfRandom r = { 7 };
		NSMutableSet *seen = [NSMutableSet setWithArray:list];
		while ([list count] < 3000) {
			NSMutableString *word = [NSMutableString string];
			NSUInteger parts = 2 + RandomBelow(&r, 3);
			for (NSUInteger i = 0; i < parts; i++) [word appendString:syllables[RandomBelow(&r, [syllables count])]];
			if (![seen containsObject:word] && ![word isEqualToString:NVPerfRareTerm]) {
				[seen addObject:word];
				[list addObject:word];
			}
		}
		words = list;
	});
	return words;
}

//Zipf-like: word i is drawn with weight 1/(i+1)
static NSString *RandomWord(NVPerfRandom *r) {
	static double *cumulative;
	static NSUInteger count;
	static dispatch_once_t once;
	NSArray *words = Vocabulary();
	dispatch_once(&once, ^{
		count = [words count];
		cumulative = malloc(sizeof(double) * count);
		double sum = 0;
		for (NSUInteger i = 0; i < count; i++) cumulative[i] = (sum += 1.0 / (double)(i + 1));
	});
	double target = UnitRandom(r) * cumulative[count - 1];
	NSUInteger lo = 0, hi = count - 1;
	while (lo < hi) {
		NSUInteger mid = (lo + hi) / 2;
		if (cumulative[mid] < target) lo = mid + 1; else hi = mid;
	}
	return words[lo];
}

static NSArray *Tags(void) {
	static NSArray *tags;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		tags = [@"work home ideas recipes travel finance health reading projects archive meetings personal "
				"family garden car music writing todo someday reference journal shopping kids school taxes "
				"code design hiring books film" componentsSeparatedByString:@" "];
	});
	return tags;
}

//non-ASCII text as notes have it: typographic punctuation, accents, other scripts, emoji
static NSArray *NonASCIIFragments(void) {
	return @[@"“quoted”", @"it’s", @"café", @"naïve", @"résumé", @"—", @"…", @"Zürich", @"São Paulo",
			 @"日本語のメモ", @"Привет", @"→", @"✓", @"🙂", @"½ cup", @"€20"];
}

#pragma mark Notes

static void AppendSentence(NSMutableString *text, NVPerfRandom *r, BOOL nonASCII) {
	NSUInteger words = 6 + RandomBelow(r, 12);
	for (NSUInteger i = 0; i < words; i++) {
		NSString *word = RandomWord(r);
		if (i == 0) word = [word capitalizedString];
		[text appendString:word];
		if (nonASCII && RandomBelow(r, 25) == 0) {
			[text appendString:@" "];
			[text appendString:NonASCIIFragments()[RandomBelow(r, [NonASCIIFragments() count])]];
		}
		[text appendString:i + 1 < words ? @" " : @". "];
	}
}

//one Markdown-ish block: paragraph, list, heading, task list, link line or quote
static void AppendBlock(NSMutableString *text, NVPerfRandom *r, BOOL nonASCII, BOOL links) {
	NSUInteger kind = RandomBelow(r, 10);
	if (kind <= 3) {
		NSUInteger sentences = 1 + RandomBelow(r, 4);
		for (NSUInteger i = 0; i < sentences; i++) AppendSentence(text, r, nonASCII);
	} else if (kind <= 5) {
		NSUInteger items = 2 + RandomBelow(r, 5);
		for (NSUInteger i = 0; i < items; i++) {
			[text appendString:@"- "];
			AppendSentence(text, r, nonASCII);
			if (i + 1 < items) [text appendString:@"\n"];
		}
	} else if (kind == 6) {
		[text appendFormat:@"## %@ %@", [RandomWord(r) capitalizedString], RandomWord(r)];
	} else if (kind == 7) {
		//TaskPaper-style project with tasks, some done
		[text appendFormat:@"%@:\n", [RandomWord(r) capitalizedString]];
		NSUInteger tasks = 2 + RandomBelow(r, 4);
		for (NSUInteger i = 0; i < tasks; i++) {
			[text appendFormat:@"\t- %@ %@ %@", RandomWord(r), RandomWord(r), RandomWord(r)];
			if (RandomBelow(r, 3) == 0) [text appendString:@" @done"];
			if (i + 1 < tasks) [text appendString:@"\n"];
		}
	} else if (kind == 8 && links) {
		[text appendFormat:@"See https://example.com/%@/%@ and [%@](https://%@.example.org/) or [[%@]].",
		 RandomWord(r), RandomWord(r), RandomWord(r), RandomWord(r), [RandomWord(r) capitalizedString]];
	} else {
		[text appendString:@"> "];
		AppendSentence(text, r, nonASCII);
	}
	[text appendString:@"\n\n"];
}

static NSString *Body(NVPerfRandom *r, NSUInteger length, BOOL nonASCII, BOOL links) {
	NSMutableString *body = [NSMutableString stringWithCapacity:length + 400];
	while ([body length] < length) AppendBlock(body, r, nonASCII, links);
	return body;
}

//titles: dated meeting notes (many sharing a prefix), short topic titles that prefix longer ones
//("Chicago", "Chicago trip"), and free phrases
static NSString *Title(NVPerfRandom *r, NSUInteger index, NSTimeInterval created) {
	NSUInteger kind = RandomBelow(r, 10);
	if (kind <= 2) {
		static NSCalendar *calendar;
		if (!calendar) {
			calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
			[calendar setTimeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]];
		}
		NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate dateWithTimeIntervalSince1970:created]];
		return [NSString stringWithFormat:@"Meeting notes %04ld-%02ld-%02ld", (long)c.year, (long)c.month, (long)c.day];
	}
	if (kind <= 4) {
		NSString *topic = [Vocabulary()[20 + RandomBelow(r, 60)] capitalizedString];
		return RandomBelow(r, 3) == 0 ? topic : [NSString stringWithFormat:@"%@ %@", topic, RandomWord(r)];
	}
	return [NSString stringWithFormat:@"%@ %@ %@ %lu", [RandomWord(r) capitalizedString], RandomWord(r), RandomWord(r), (unsigned long)index];
}

//body length drawn from a log-normal fitted to the real account's percentiles
static NSUInteger BodyLength(NVPerfRandom *r) {
	double length = 320.0 * exp(1.6 * NormalRandom(r));
	return (NSUInteger)MAX(10.0, MIN(length, 60000.0));
}

@implementation NVPerfCorpus

+ (NSString *)contentWithLength:(NSUInteger)length seed:(uint64_t)seed {
	NVPerfRandom r = { seed };
	NSString *title = [NSString stringWithFormat:@"%@ %@", [RandomWord(&r) capitalizedString], RandomWord(&r)];
	return [NSString stringWithFormat:@"%@\n\n%@", title, Body(&r, length, YES, YES)];
}

+ (NSArray<NVNoteRecord *> *)recordsWithCount:(NSUInteger)count seed:(uint64_t)seed {
	NVPerfRandom r = { seed };
	NSMutableArray *records = [NSMutableArray arrayWithCapacity:count];
	//2011 to 2026, as the real account
	const NSTimeInterval start = 1300000000, end = 1790000000;
	//one note of about 1 MB, and one in a thousand between 100 and 300 KB
	NSUInteger hugeIndex = count / 2;
	NSUInteger rareIndexes[3] = { count / 7, count / 3, (count * 5) / 6 };
	NSArray *tags = Tags();
	for (NSUInteger i = 0; i < count; i++) {
		NSTimeInterval created = start + UnitRandom(&r) * (end - start);
		NSTimeInterval modified = created + UnitRandom(&r) * (end - created);
		BOOL nonASCII = UnitRandom(&r) < 0.45, links = UnitRandom(&r) < 0.15;
		NSUInteger length = BodyLength(&r);
		NSString *title = Title(&r, i, created);
		if (i == hugeIndex) {
			title = NVPerfHugeNoteTitle;
			length = 1000000;
		} else if (RandomBelow(&r, 1000) == 0) {
			length = 100000 + RandomBelow(&r, 200000);
		}
		//the huge note is the same in every corpus, so measurements on it compare across sizes
		NVPerfRandom hugeRandom = { 1000000 };
		NSMutableString *body = [(i == hugeIndex ? Body(&hugeRandom, length, YES, YES) : Body(&r, length, nonASCII, links)) mutableCopy];
		for (NSUInteger k = 0; k < 3; k++)
			if (rareIndexes[k] == i) [body appendFormat:@"Remember the %@.\n", NVPerfRareTerm];
		NSMutableArray *noteTags = [NSMutableArray array];
		if (UnitRandom(&r) < 0.3) {
			NSUInteger tagCount = 1 + RandomBelow(&r, 3);
			for (NSUInteger k = 0; k < tagCount; k++) {
				NSString *tag = tags[RandomBelow(&r, [tags count])];
				if (![noteTags containsObject:tag]) [noteTags addObject:tag];
			}
		}
		NSString *content = [NSString stringWithFormat:@"%@\n\n%@", title, body];
		NSDictionary *data = @{ @"content": content, @"tags": noteTags, @"deleted": @NO,
								@"creationDate": @(created), @"modificationDate": @(modified),
								@"systemTags": @[], @"shareURL": @"", @"publishURL": @"" };
		NSString *noteID = [NSString stringWithFormat:@"perf%016llx%08lx", seed, (unsigned long)i];
		[records addObject:[NVNoteRecord recordWithNoteID:noteID serverData:data version:1]];
	}
	return records;
}

+ (NVNotesStore *)storeAtPath:(NSString *)path count:(NSUInteger)count seed:(uint64_t)seed {
	NVNotesStore *store = [NVNotesStore storeAtPath:path error:NULL];
	if (!store) return nil;
	NSArray *records = [self recordsWithCount:count seed:seed];
	BOOL written = [store performTransaction:^(id<NVNotesStoreTransaction> transaction) {
		for (NVNoteRecord *record in records) [transaction putNote:record];
	} error:NULL];
	if (!written) {
		[store close];
		return nil;
	}
	[store setSyncPoint:@"perf-corpus"];
	return store;
}

@end
