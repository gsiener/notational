#import <Cocoa/Cocoa.h>
#import "FastListDataSource.h"

extern NSString *const NVHereNowSitesDidChangeNotification;

@protocol NVHereNowPageTransport <NSObject>
- (void)getPath:(NSString *)path token:(NSString *)token completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion;
@end

@interface NVHereNowSite : NSObject
@property(copy) NSString *identity;
@property(copy) NSString *title;
@property(copy) NSString *scopeLabel;
@property(copy) NSString *searchText;
@property(strong) NSURL *URL;
@end

@interface NVHereNowSites : NSObject
@property(readonly, copy) NSArray<NVHereNowSite *> *sites;
@property(readonly, copy) NSString *status;
@property(readonly) BOOL connected;
@property(readonly) BOOL stale;
- (instancetype)initWithTransport:(id<NVHereNowPageTransport>)transport cacheURL:(NSURL *)cacheURL;
- (void)restore;
- (void)connectWithKey:(NSString *)key completion:(void (^)(NSError *))completion;
- (void)disconnect;
- (void)refresh;
// The parser is also used by fake-transport tests. It replaces the cache only after the final page.
- (void)refreshWithToken:(NSString *)token completion:(void (^)(NSError *))completion;
@end

@interface NVHereNowMixedList : FastListDataSource <NSTableViewDataSource>
@property(strong) FastListDataSource *notes;
@property(copy) NSArray<NVHereNowSite *> *sites;
@property(assign) BOOL stale;
- (void)filterSitesForString:(NSString *)search;
- (BOOL)selectionContainsSite:(NSIndexSet *)indexes;
- (NVHereNowSite *)siteAtRow:(NSInteger)row;
@end

@interface NVHereNowHTTPTransport : NSObject <NVHereNowPageTransport>
@end
