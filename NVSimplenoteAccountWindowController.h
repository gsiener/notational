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
//return NO to cancel (e.g. the user declined switching accounts)
- (BOOL)simplenoteAccountWillSignInAs:(NSString *)email;
- (void)simplenoteAccountDidSignInAs:(NSString *)email token:(NSString *)token;
- (void)simplenoteAccountSignOut;
- (void)simplenoteSyncNow;
@end

//one line for the account's sync state, e.g. "Up to date."
NSString *NVSyncStatusDescription(NVSyncStatus status, NSError *error);

@interface NVSimplenoteAccountWindowController : NSWindowController

@property (nonatomic, assign) id<NVSimplenoteAccountDelegate> accountDelegate;

//re-read the delegate's state and show the matching step
- (void)refresh;

@end
