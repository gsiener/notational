//
//  NVNoteRecord.m
//  Notation
//

#import "NVNoteRecord.h"

@implementation NVNoteRecord

@synthesize noteID, content, tags, deleted, creationDate, modificationDate;
@synthesize serverData, confirmedVersion, pending, localRevision;

+ (NSString *)newNoteID {
	//Simplenote's own clients use dashless lowercase UUIDs
	return [[[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
}

+ (NVNoteRecord *)recordWithNoteID:(NSString *)anID serverData:(NSDictionary *)data version:(NSInteger)version {
	NVNoteRecord *record = [[[NVNoteRecord alloc] init] autorelease];
	[record setNoteID:anID];
	[record setServerData:data];
	[record setConfirmedVersion:version];
	[record takeFieldsFromServerData:data];
	return record;
}

- (id)init {
	if ((self = [super init])) {
		content = @"";
		tags = [[NSArray alloc] init];
		serverData = [[NSDictionary alloc] init];
	}
	return self;
}

- (void)dealloc {
	[noteID release];
	[content release];
	[tags release];
	[serverData release];
	[super dealloc];
}

- (id)copyWithZone:(NSZone *)zone {
	NVNoteRecord *copy = [[NVNoteRecord allocWithZone:zone] init];
	[copy setNoteID:noteID];
	[copy setContent:content];
	[copy setTags:tags];
	[copy setDeleted:deleted];
	[copy setCreationDate:creationDate];
	[copy setModificationDate:modificationDate];
	[copy setServerData:serverData];
	[copy setConfirmedVersion:confirmedVersion];
	[copy setPending:pending];
	[copy setLocalRevision:localRevision];
	return copy;
}

static NSArray *StringArray(id value) {
	NSMutableArray *strings = [NSMutableArray array];
	if ([value isKindOfClass:[NSArray class]]) {
		for (id item in value)
			if ([item isKindOfClass:[NSString class]]) [strings addObject:item];
	}
	return strings;
}

- (void)takeFieldsFromServerData:(NSDictionary *)data {
	id value = [data objectForKey:@"content"];
	[self setContent:[value isKindOfClass:[NSString class]] ? value : @""];
	[self setTags:StringArray([data objectForKey:@"tags"])];
	[self setDeleted:[[data objectForKey:@"deleted"] boolValue]];
	[self setCreationDate:[[data objectForKey:@"creationDate"] doubleValue]];
	[self setModificationDate:[[data objectForKey:@"modificationDate"] doubleValue]];
}

- (NSDictionary *)dataForPush {
	NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:serverData ? serverData : [NSDictionary dictionary]];
	[data setObject:content ? content : @"" forKey:@"content"];
	[data setObject:tags ? tags : [NSArray array] forKey:@"tags"];
	[data setObject:[NSNumber numberWithBool:deleted] forKey:@"deleted"];
	[data setObject:[NSNumber numberWithDouble:creationDate] forKey:@"creationDate"];
	[data setObject:[NSNumber numberWithDouble:modificationDate] forKey:@"modificationDate"];
	//fields a new note must carry so other Simplenote clients accept it
	if (![data objectForKey:@"systemTags"]) [data setObject:[NSArray array] forKey:@"systemTags"];
	if (![data objectForKey:@"shareURL"]) [data setObject:@"" forKey:@"shareURL"];
	if (![data objectForKey:@"publishURL"]) [data setObject:@"" forKey:@"publishURL"];
	return data;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@ %@ v%ld%@%@ rev%ld>", [self class], noteID, (long)confirmedVersion,
			pending ? @" pending" : @"", deleted ? @" trashed" : @"", (long)localRevision];
}

@end
