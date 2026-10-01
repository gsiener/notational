//
//  NVFakeSimplenoteService.h
//  NotationTests
//
//  In-memory adapter for the Simplenote port. Mirrors the server behaviour the Sync
//  engine relies on: per-note versions, an account change feed, and server-side merging
//  of posts made against an older version. Text merging uses NVTextMerge (line-based)
//  where the real server uses diff-match-patch; tests shouldn't depend on character-level
//  merge results.
//
//  The "remote..." methods act as another Simplenote client editing the account.
//

#import <Foundation/Foundation.h>
#import "NVSimplenoteService.h"

@interface NVFakeSimplenoteService : NSObject <NVSimplenoteService>

//requests served, by kind: @"index", @"changes", @"get", @"post"
@property (nonatomic, readonly) NSCountedSet *requestCounts;

//runs after a post has been applied and before it returns, i.e. while the push is "in flight"
@property (nonatomic, copy) void (^afterPostApplied)(NSString *noteID);

//the next requests fail with these NVSimplenoteErrorDomain codes, in order
- (void)failNextRequestsWithCodes:(NSArray *)codes;

//another client's actions
- (NSString *)remoteCreateNoteWithContent:(NSString *)content tags:(NSArray *)tags;
- (void)remoteSetContent:(NSString *)content ofNote:(NSString *)noteID;
- (void)remoteSetData:(NSDictionary *)data ofNote:(NSString *)noteID;
- (void)remoteTrashNote:(NSString *)noteID;
- (void)remotePurgeNote:(NSString *)noteID;

//make every existing version of a note except the latest unavailable, as if pruned
- (void)pruneHistoryOfNote:(NSString *)noteID;

//make every change version issued so far unknown, as if the server pruned its history
- (void)forgetChangeHistory;

//inspection
- (NSDictionary *)currentDataOfNote:(NSString *)noteID;
- (NSInteger)currentVersionOfNote:(NSString *)noteID;
- (NSUInteger)noteCount;
- (NSString *)currentChangeVersion;

@end
