#import <Foundation/Foundation.h>
#import "NVSyncEngine.h"
@class NotationController, NVNotesStore;

@protocol NVAccountCredentials <NSObject>
- (NSString *)tokenForAccount:(NSString *)email;
- (BOOL)setToken:(NSString *)token forAccount:(NSString *)email;
- (void)removeTokenForAccount:(NSString *)email;
@end

typedef NS_ENUM(NSInteger, NVAccountSwitchChoice) {
    NVAccountSwitchCancel, NVAccountSwitchSync, NVAccountSwitchDiscard
};

// Main-thread owner of account transitions. Network work runs off the main thread.
@interface NVAccountSession : NSObject
- (instancetype)initWithNotation:(NotationController *)notation
                    credentials:(id<NVAccountCredentials>)credentials
                  engineFactory:(NVSyncEngine *(^)(NVNotesStore *, NSString *))factory;
@property (nonatomic, readonly) NotationController *notation;
@property (nonatomic, readonly) BOOL loadingCredentials;
@property (nonatomic, readonly) NVSyncStatus status;
extern NSString *const NVAccountCredentialExpiredKey;
- (void)syncEngine:(NVSyncEngine *)engine didChangeStatus:(NVSyncStatus)status;
- (void)restoreSignIn;
- (void)signOut;
// Called only after authentication. The choice is requested only for another account's pending edits.
- (void)signInAs:(NSString *)email token:(NSString *)token
         choose:(NVAccountSwitchChoice (^)(void))choose
     completion:(void (^)(BOOL switched, NSError *error))completion;
@end
