//
//  NVSimplenoteService.m
//  Notation
//

#import "NVSimplenoteService.h"

NSString *const NVSimplenoteErrorDomain = @"NVSimplenoteErrorDomain";

@implementation NVRemoteNote

@synthesize noteID, version, data;

+ (NVRemoteNote *)noteWithID:(NSString *)anID version:(NSInteger)aVersion data:(NSDictionary *)someData {
	NVRemoteNote *note = [[[NVRemoteNote alloc] init] autorelease];
	[note setNoteID:anID];
	[note setVersion:aVersion];
	[note setData:someData];
	return note;
}

- (void)dealloc {
	[noteID release];
	[data release];
	[super dealloc];
}

@end

@implementation NVRemoteChange

@synthesize noteID, changeVersion, version, data, removed;

- (void)dealloc {
	[noteID release];
	[changeVersion release];
	[data release];
	[super dealloc];
}

@end

@implementation NVIndexPage

@synthesize notes, nextMark, changeVersion;

- (void)dealloc {
	[notes release];
	[nextMark release];
	[changeVersion release];
	[super dealloc];
}

@end
