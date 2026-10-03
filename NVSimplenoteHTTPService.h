//
//  NVSimplenoteHTTPService.h
//  Notation
//
//  Production adapter for the Simplenote port: the Simperium HTTP API used by
//  Simplenote (app chalk-bump-f49, bucket "note"), plus the key-less email-code
//  sign-in and Keychain storage for the resulting token.
//  See docs/research/simplenote-sync.md and docs/adr/0001-simplenote-backed-storage.md.
//

#import <Foundation/Foundation.h>
#import "NVSimplenoteService.h"
#import "NVAccountSession.h"

@interface NVSimplenoteHTTPService : NSObject <NVSimplenoteService>

//clientID identifies this installation in change records; keep it stable per install
- (id)initWithToken:(NSString *)token clientID:(NSString *)clientID;
- (id)initWithToken:(NSString *)token clientID:(NSString *)clientID
	  configuration:(NSURLSessionConfiguration *)configuration baseURL:(NSURL *)baseURL;

@end

@interface NVSimplenoteAuthenticator : NSObject

//identity sent as request_source; nvALT identifies itself honestly
+ (NSString *)requestSource;

- (id)init;
- (id)initWithConfiguration:(NSURLSessionConfiguration *)configuration baseURL:(NSURL *)baseURL;

//asks Simplenote to email a sign-in code
- (BOOL)requestCodeForEmail:(NSString *)email error:(NSError **)error;
//exchanges the emailed code for a sync token
- (NSString *)tokenForEmail:(NSString *)email code:(NSString *)code error:(NSError **)error;

@end

//Keychain storage for the sync token (generic password, one per account email)
@interface NVSimplenoteCredentials : NSObject <NVAccountCredentials>

- (id)initWithService:(NSString *)service;
+ (NVSimplenoteCredentials *)defaultCredentials;

- (NSString *)tokenForAccount:(NSString *)email;
- (BOOL)setToken:(NSString *)token forAccount:(NSString *)email;
- (void)removeTokenForAccount:(NSString *)email;

@end
