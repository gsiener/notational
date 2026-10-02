//
//  NVSyncEngine.h
//  Notation
//
//  The Sync engine keeps the Notes store and Simplenote in step: first sync from the
//  account index, catch-up from the sync point, pushing pending notes at their
//  confirmed version and adopting the server-merged result, trash, re-index when the
//  sync point is forgotten, and retry with backoff. See ADR 0001.
//
//  Runs on its own serial queue and calls the Simplenote port synchronously from it; fetches and
//  pushes of several notes go out a few at a time, and never while the store is held.
//  A note with local edits is never overwritten by a remote change: the next push
//  sends it at its confirmed version and the server merges both sides.
//

#import <Foundation/Foundation.h>
#import "NVSimplenoteService.h"

@class NVNotesStore, NVSyncEngine;

typedef enum {
	NVSyncStatusIdle = 0,       //up to date as of the last cycle
	NVSyncStatusSyncing,
	NVSyncStatusSignedOut,      //no valid token: user must sign in again
	NVSyncStatusOffline,        //network or server trouble; retrying with backoff
} NVSyncStatus;

//posted (object: the notes controller or nil) whenever the sync status changes; userInfo carries
//the NVSyncStatus as an NSNumber under NVSyncStatusKey
extern NSString *const NVSyncStatusDidChangeNotification;
extern NSString *const NVSyncStatusKey;

@protocol NVSyncEngineDelegate <NSObject>
//Notes whose stored content changed because of the server: added, changed remotely,
//merged by the server, or rebased after a push. Delivered once per cycle on the delegate queue.
- (void)syncEngine:(NVSyncEngine *)engine didUpdateNotes:(NSArray *)records removedNoteIDs:(NSArray *)noteIDs;
@optional
- (void)syncEngine:(NVSyncEngine *)engine didChangeStatus:(NVSyncStatus)status;
@end

@interface NVSyncEngine : NSObject

- (id)initWithStore:(NVNotesStore *)store service:(id<NVSimplenoteService>)service;

@property (nonatomic, weak) id<NVSyncEngineDelegate> delegate;
//queue delegate callbacks are delivered on; main queue by default
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
//seconds between automatic cycles while started; default 30
@property (nonatomic, assign) NSTimeInterval pollInterval;
//index page size for full syncs; default 100
@property (nonatomic, assign) NSUInteger indexPageSize;

@property (nonatomic, readonly) NVSyncStatus status;
@property (nonatomic, readonly) NSError *lastError;

//begin periodic syncing (a cycle runs immediately); stop cancels future cycles
- (void)start;
- (void)stop;

//request a cycle soon, e.g. after a local edit; coalesced, subject to backoff, ignored unless started
- (void)syncNow;

//run one full cycle on the engine queue and wait for it; ignores backoff. For tests and quit.
- (BOOL)syncOnceReturningError:(NSError **)error;

@end
