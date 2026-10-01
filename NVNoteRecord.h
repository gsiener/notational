//
//  NVNoteRecord.h
//  Notation
//
//  One note as the Notes store keeps it: Simplenote's fields plus the sync
//  bookkeeping needed to push local edits and adopt server versions.
//  See docs/adr/0001-simplenote-backed-storage.md.
//

#import <Foundation/Foundation.h>

@interface NVNoteRecord : NSObject <NSCopying>

//Simplenote object id; assigned locally for notes created in nvALT
@property (nonatomic, copy) NSString *noteID;

//verbatim Simplenote content: title is the first line, body the rest
@property (nonatomic, copy) NSString *content;
@property (nonatomic, copy) NSArray *tags;
//Simplenote trash
@property (nonatomic, assign) BOOL deleted;
//seconds since 1970, as Simplenote stores them
@property (nonatomic, assign) NSTimeInterval creationDate;
@property (nonatomic, assign) NSTimeInterval modificationDate;

//the full object as the server last confirmed it, including fields nvALT doesn't use
@property (nonatomic, copy) NSDictionary *serverData;
//server version serverData corresponds to; 0 if the server has never confirmed this note
@property (nonatomic, assign) NSInteger confirmedVersion;
//local edits not yet confirmed by the server
@property (nonatomic, assign) BOOL pending;
//incremented on every local edit, so a push can tell whether the note changed while in flight
@property (nonatomic, assign) NSInteger localRevision;

//Returns an autoreleased (+0) string despite the "new" prefix, as it always has; callers must not release it.
+ (NSString *)newNoteID NS_RETURNS_NOT_RETAINED;

//record for a note as the server sent it
+ (NVNoteRecord *)recordWithNoteID:(NSString *)noteID serverData:(NSDictionary *)data version:(NSInteger)version;

//replace the Simplenote-owned fields with those in data (content, tags, deleted, dates)
- (void)takeFieldsFromServerData:(NSDictionary *)data;

//serverData with nvALT-owned fields replaced by this record's values; what a push sends
- (NSDictionary *)dataForPush;

@end
