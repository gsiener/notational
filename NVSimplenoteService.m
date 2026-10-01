//
//  NVSimplenoteService.m
//  Notation
//

#import "NVSimplenoteService.h"

NSString *const NVSimplenoteErrorDomain = @"NVSimplenoteErrorDomain";

@implementation NVRemoteNote

@synthesize noteID, version, data;

+ (NVRemoteNote *)noteWithID:(NSString *)anID version:(NSInteger)aVersion data:(NSDictionary *)someData {
	NVRemoteNote *note = [[NVRemoteNote alloc] init];
	[note setNoteID:anID];
	[note setVersion:aVersion];
	[note setData:someData];
	return note;
}

@end

@implementation NVRemoteChange

@synthesize noteID, changeVersion, version, data, removed;

@end

@implementation NVIndexPage

@synthesize notes, nextMark, changeVersion;

@end
