//
//  NVSimplenoteService.h
//  Notation
//
//  The Simplenote port: the seam between the Sync engine and Simplenote.
//  Two adapters: NVSimplenoteHTTPService (production, Simperium HTTP API) and
//  NVFakeSimplenoteService (tests, in memory).
//
//  Calls are synchronous; the Sync engine makes them from its own serial queue.
//  See docs/adr/0001-simplenote-backed-storage.md.
//

#import <Foundation/Foundation.h>

extern NSString *const NVSimplenoteErrorDomain;

enum {
	NVSimplenoteErrorUnauthorized = 401,      //token missing, expired or revoked: sign in again
	NVSimplenoteErrorNotFound = 404,          //no such note, or no such version of it
	NVSimplenoteErrorUnknownChangeVersion = 1001, //sync point no longer known to the server: re-index
	NVSimplenoteErrorNetwork = 1002,          //transport failure; retry later
	NVSimplenoteErrorServer = 1003,           //unexpected status or malformed response; retry later
	NVSimplenoteErrorTooLarge = 413           //note exceeds the server's size limit; keep it pending
};

//one entry of the account index
@interface NVRemoteNote : NSObject
@property (nonatomic, copy) NSString *noteID;
@property (nonatomic, assign) NSInteger version;
//full object; nil when the index was fetched without data
@property (nonatomic, copy) NSDictionary *data;
+ (NVRemoteNote *)noteWithID:(NSString *)anID version:(NSInteger)aVersion data:(NSDictionary *)someData;
@end

//one entry of the changes feed
@interface NVRemoteChange : NSObject
@property (nonatomic, copy) NSString *noteID;
//account change version after this change
@property (nonatomic, copy) NSString *changeVersion;
//note version after this change; 0 for removals
@property (nonatomic, assign) NSInteger version;
//full object after the change; nil when the note was removed permanently
@property (nonatomic, copy) NSDictionary *data;
@property (nonatomic, assign) BOOL removed;
@end

@interface NVIndexPage : NSObject
@property (nonatomic, retain) NSArray *notes;          //NVRemoteNote
@property (nonatomic, copy) NSString *nextMark;        //nil on the last page
@property (nonatomic, copy) NSString *changeVersion;   //account change version when the page was read
@end

@protocol NVSimplenoteService <NSObject>

- (NVIndexPage *)indexPageAfterMark:(NSString *)mark limit:(NSUInteger)limit includeData:(BOOL)includeData error:(NSError **)error;

//changes after changeVersion, oldest first; empty when up to date
- (NSArray *)changesSince:(NSString *)changeVersion error:(NSError **)error;

- (NSDictionary *)noteWithID:(NSString *)noteID version:(NSInteger *)version error:(NSError **)error;

//Create (baseVersion 0) or update a note. When baseVersion is older than the server's
//current version, the server merges concurrent text edits; the result is returned with
//its new version. Returns nil on error.
- (NSDictionary *)postNoteWithID:(NSString *)noteID data:(NSDictionary *)data baseVersion:(NSInteger)baseVersion
						 version:(NSInteger *)newVersion error:(NSError **)error;

@end
