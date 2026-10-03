//
//  NVSimplenoteAccountWindowController.h
//  Notation
//
//  "Simplenote Account" window: sign in with an emailed code, see sync status,
//  sync now, sign out. Built in code so it needs no localized nibs.
//

#import <Cocoa/Cocoa.h>
#import "NVSyncEngine.h"

@protocol NVSimplenoteAccountDelegate <NSObject>
- (NSString *)simplenoteAccountEmail;
- (NVSyncStatus)simplenoteSyncStatus;
- (NSError *)simplenoteLastError;
- (void)simplenoteAccountDidSignInAs:(NSString *)email token:(NSString *)token completion:(void (^)(BOOL switched, NSError *error))completion;
- (void)simplenoteAccountSignOut;
- (void)simplenoteSyncNow;
@end

//one line for the account's sync state, e.g. "Up to date."
NSString *NVSyncStatusDescription(NVSyncStatus status, NSError *error);

@interface NVSimplenoteAccountWindowController : NSWindowController

@property (nonatomic, weak) id<NVSimplenoteAccountDelegate> accountDelegate;

//re-read the delegate's state and show the matching step
- (void)refresh;

@end
