//
//  NVTextMerge.m
//  Notation
//

#import "NVTextMerge.h"

//a replacement of base lines [start, end) by some lines
typedef struct {
	NSUInteger start, end;
	NSRange replacement; //range in the other side's line array
} NVLineHunk;

//largest middle section (after trimming common lines) diffed with LCS; beyond it the
//middle is treated as one changed block, which only makes merges coarser
#define MAX_LCS_CELLS 4000000

static NSArray *LinesOf(NSString *text) {
	NSMutableArray *lines = [NSMutableArray array];
	NSUInteger length = [text length], start = 0;
	while (start < length) {
		NSRange newline = [text rangeOfString:@"\n" options:NSLiteralSearch range:NSMakeRange(start, length - start)];
		NSUInteger end = newline.location == NSNotFound ? length : NSMaxRange(newline);
		[lines addObject:[text substringWithRange:NSMakeRange(start, end - start)]];
		start = end;
	}
	return lines;
}

//hunks turning base into other, in base order
static NSUInteger DiffLines(NSArray *base, NSArray *other, NVLineHunk **outHunks) {
	NSUInteger n = [base count], m = [other count];
	NSUInteger prefix = 0, suffix = 0;
	while (prefix < n && prefix < m && [[base objectAtIndex:prefix] isEqualToString:[other objectAtIndex:prefix]]) prefix++;
	while (suffix < n - prefix && suffix < m - prefix &&
		   [[base objectAtIndex:n - 1 - suffix] isEqualToString:[other objectAtIndex:m - 1 - suffix]]) suffix++;

	NSUInteger bn = n - prefix - suffix, om = m - prefix - suffix;
	NVLineHunk *hunks = malloc(sizeof(NVLineHunk) * (bn + om + 1));
	NSUInteger count = 0;

	if (bn == 0 && om == 0) {
		*outHunks = hunks;
		return 0;
	}
	if (bn == 0 || om == 0 || (bn + 1) * (om + 1) > MAX_LCS_CELLS) {
		hunks[count].start = prefix; hunks[count].end = prefix + bn;
		hunks[count].replacement = NSMakeRange(prefix, om);
		*outHunks = hunks;
		return 1;
	}

	//LCS lengths over the middle section, from the end
	unsigned int *lcs = calloc((bn + 1) * (om + 1), sizeof(unsigned int));
#define LCS(i, j) lcs[(i) * (om + 1) + (j)]
	NSInteger i, j;
	for (i = (NSInteger)bn - 1; i >= 0; i--) {
		for (j = (NSInteger)om - 1; j >= 0; j--) {
			if ([[base objectAtIndex:prefix + i] isEqualToString:[other objectAtIndex:prefix + j]])
				LCS(i, j) = LCS(i + 1, j + 1) + 1;
			else
				LCS(i, j) = MAX(LCS(i + 1, j), LCS(i, j + 1));
		}
	}

	NSUInteger bi = 0, oj = 0;
	BOOL inHunk = NO;
	while (bi < bn || oj < om) {
		BOOL same = bi < bn && oj < om && [[base objectAtIndex:prefix + bi] isEqualToString:[other objectAtIndex:prefix + oj]];
		if (same) {
			if (inHunk) {
				hunks[count].end = prefix + bi;
				hunks[count].replacement.length = prefix + oj - hunks[count].replacement.location;
				count++;
				inHunk = NO;
			}
			bi++; oj++;
			continue;
		}
		if (!inHunk) {
			hunks[count].start = prefix + bi;
			hunks[count].replacement = NSMakeRange(prefix + oj, 0);
			inHunk = YES;
		}
		if (oj >= om || (bi < bn && LCS(bi + 1, oj) >= LCS(bi, oj + 1)))
			bi++;
		else
			oj++;
	}
	if (inHunk) {
		hunks[count].end = prefix + bi;
		hunks[count].replacement.length = prefix + oj - hunks[count].replacement.location;
		count++;
	}
#undef LCS
	free(lcs);
	*outHunks = hunks;
	return count;
}

static BOOL HunksOverlap(NVLineHunk a, NVLineHunk b) {
	//two insertions at the same point, or intersecting replaced ranges, or an insertion inside a replaced range
	if (a.start == a.end && b.start == b.end) return a.start == b.start;
	if (a.start == a.end) return a.start > b.start && a.start < b.end;
	if (b.start == b.end) return b.start > a.start && b.start < a.end;
	return a.start < b.end && b.start < a.end;
}

static void AppendLines(NSMutableString *out, NSArray *lines, NSRange range) {
	NSUInteger k;
	for (k = range.location; k < NSMaxRange(range); k++) [out appendString:[lines objectAtIndex:k]];
}

@implementation NVTextMerge

+ (NSString *)mergeBase:(NSString *)base ours:(NSString *)ours theirs:(NSString *)theirs {
	if (!base) base = @"";
	if (!ours) ours = @"";
	if (!theirs) theirs = @"";
	if ([ours isEqualToString:theirs] || [theirs isEqualToString:base]) return ours;
	if ([ours isEqualToString:base]) return theirs;

	//compare with a trailing newline on every side so a change to an unterminated last line
	//is still a whole-line change
	BOOL addedNewline = ![base hasSuffix:@"\n"] || ![ours hasSuffix:@"\n"] || ![theirs hasSuffix:@"\n"];
	NSArray *b = LinesOf(addedNewline ? [base stringByAppendingString:@"\n"] : base);
	NSArray *o = LinesOf(addedNewline ? [ours stringByAppendingString:@"\n"] : ours);
	NSArray *t = LinesOf(addedNewline ? [theirs stringByAppendingString:@"\n"] : theirs);

	NVLineHunk *oursHunks = NULL, *theirsHunks = NULL;
	NSUInteger oc = DiffLines(b, o, &oursHunks), tc = DiffLines(b, t, &theirsHunks);

	NSMutableString *merged = [NSMutableString string];
	NSUInteger pos = 0, oi = 0, ti = 0;
	while (oi < oc || ti < tc) {
		//a group starts at the earliest remaining hunk and absorbs every hunk overlapping it
		NSUInteger groupStart, groupEnd, oLast = oi, tLast = ti;
		if (ti >= tc || (oi < oc && oursHunks[oi].start <= theirsHunks[ti].start)) {
			groupStart = oursHunks[oi].start; groupEnd = oursHunks[oi].end; oLast = oi + 1;
		} else {
			groupStart = theirsHunks[ti].start; groupEnd = theirsHunks[ti].end; tLast = ti + 1;
		}
		BOOL grew = YES;
		while (grew) {
			grew = NO;
			NVLineHunk group = {groupStart, groupEnd, {0, 0}};
			if (oLast < oc && HunksOverlap(group, oursHunks[oLast])) {
				groupStart = MIN(groupStart, oursHunks[oLast].start); groupEnd = MAX(groupEnd, oursHunks[oLast].end);
				oLast++; grew = YES;
				group.start = groupStart; group.end = groupEnd;
			}
			if (tLast < tc && HunksOverlap(group, theirsHunks[tLast])) {
				groupStart = MIN(groupStart, theirsHunks[tLast].start); groupEnd = MAX(groupEnd, theirsHunks[tLast].end);
				tLast++; grew = YES;
			}
		}
		
		//replay one side's hunks across the group; ours wins when both sides changed it
		BOOL useOurs = oLast > oi;
		NVLineHunk *side = useOurs ? oursHunks : theirsHunks;
		NSArray *sideLines = useOurs ? o : t;
		NSUInteger k = useOurs ? oi : ti, kEnd = useOurs ? oLast : tLast, cursor = groupStart;
		AppendLines(merged, b, NSMakeRange(pos, groupStart - pos));
		for (; k < kEnd; k++) {
			AppendLines(merged, b, NSMakeRange(cursor, side[k].start - cursor));
			AppendLines(merged, sideLines, side[k].replacement);
			cursor = side[k].end;
		}
		AppendLines(merged, b, NSMakeRange(cursor, groupEnd - cursor));
		
		pos = groupEnd;
		oi = oLast; ti = tLast;
	}
	AppendLines(merged, b, NSMakeRange(pos, [b count] - pos));
	free(oursHunks);
	free(theirsHunks);

	if (addedNewline && [merged hasSuffix:@"\n"])
		[merged deleteCharactersInRange:NSMakeRange([merged length] - 1, 1)];
	return merged;
}

+ (BOOL)changeFrom:(NSString *)oldText to:(NSString *)newText range:(NSRange *)range replacement:(NSString **)replacement {
	if (!oldText) oldText = @"";
	if (!newText) newText = @"";
	if ([oldText isEqualToString:newText]) return NO;

	NSUInteger oldLength = [oldText length], newLength = [newText length];
	NSUInteger prefix = [[oldText commonPrefixWithString:newText options:NSLiteralSearch] length];
	//don't split a surrogate pair or composed character sequence
	if (prefix > 0 && prefix < oldLength) prefix = [oldText rangeOfComposedCharacterSequenceAtIndex:prefix].location;

	NSUInteger suffix = 0, maxSuffix = MIN(oldLength, newLength) - prefix;
	while (suffix < maxSuffix && [oldText characterAtIndex:oldLength - 1 - suffix] == [newText characterAtIndex:newLength - 1 - suffix])
		suffix++;
	if (suffix > 0 && suffix < oldLength - prefix) {
		NSUInteger boundary = oldLength - suffix;
		NSRange composed = [oldText rangeOfComposedCharacterSequenceAtIndex:boundary];
		if (composed.location < boundary) suffix = oldLength - NSMaxRange(composed);
	}

	if (range) *range = NSMakeRange(prefix, oldLength - prefix - suffix);
	if (replacement) *replacement = [newText substringWithRange:NSMakeRange(prefix, newLength - prefix - suffix)];
	return YES;
}

+ (NSRange)selection:(NSRange)selection afterChangeFrom:(NSString *)oldText to:(NSString *)newText {
	NSRange changed;
	NSString *replacement = nil;
	if (![self changeFrom:oldText to:newText range:&changed replacement:&replacement]) return selection;

	NSInteger delta = (NSInteger)[replacement length] - (NSInteger)changed.length;
	NSUInteger start = selection.location, end = NSMaxRange(selection);
	//positions after the change shift with it; positions inside it move to its end
	if (start >= NSMaxRange(changed)) start += delta;
	else if (start > changed.location) start = changed.location + [replacement length];
	if (end >= NSMaxRange(changed)) end += delta;
	else if (end > changed.location) end = changed.location + [replacement length];
	if (end < start) end = start;
	return NSMakeRange(start, end - start);
}

@end
