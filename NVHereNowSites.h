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
// The list API's `contentUpdatedAt` (falling back to `updatedAt`); nil in caches written before dates were kept.
@property(strong) NSDate *modifiedDate;
// The list API offers no creation time, so this stays nil until it does; nil sorts after every dated row.
@property(strong) NSDate *createdDate;
@end

//what the Settings pane (NVHereNowPrefsViewController) needs from the here.now Sites service (NVHereNowSites); tests pass a fake,
//since connecting with a real key writes to Keychain
@protocol NVHereNowSettingsSource <NSObject>
@property(readonly, copy) NSString *status;
@property(readonly) BOOL connected;
- (void)connectWithKey:(NSString *)key completion:(void (^)(NSError *))completion;
- (void)disconnect;
- (void)refresh;
@end

@interface NVHereNowSites : NSObject <NVHereNowSettingsSource>
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

// The Notes list's rows: the visible Notes in their own order, with the visible Sites interleaved
// by the Notes list's sort (sortKey is a Notes column identifier). Rows are a snapshot taken at the
// last rebuild; a Site row can sit anywhere, so map rows only through the methods below.
@interface NVHereNowMixedList : FastListDataSource <NSTableViewDataSource>
@property(strong) FastListDataSource *notes;
@property(copy) NSArray<NVHereNowSite *> *sites;
@property(assign) BOOL stale;
@property(readonly, copy) NSString *sortKey;
@property(readonly) BOOL reverseSort;
@property(readonly) NSUInteger noteRowCount;   //how many rows are Notes
- (void)filterSitesForString:(NSString *)search;
// nil or an unknown key lists the Sites after the Notes.
- (void)setSortKey:(NSString *)sortKey reversed:(BOOL)reversed;
// All of the above in one rebuild.
- (void)setNotes:(FastListDataSource *)notes sortKey:(NSString *)sortKey reversed:(BOOL)reversed search:(NSString *)search;
- (BOOL)selectionContainsSite:(NSIndexSet *)indexes;
- (NVHereNowSite *)siteAtRow:(NSInteger)row;
- (NSUInteger)rowForSiteIdentity:(NSString *)identity;
- (id)noteAtRow:(NSInteger)row;                       //nil for a Site row or a row out of range
- (NSUInteger)rowForNote:(id)note;                    //NSNotFound unless the Note is listed
- (NSUInteger)rowForNoteIndex:(NSUInteger)noteIndex;  //an index into `notes` as of the last rebuild
- (NSUInteger)noteIndexForRow:(NSInteger)row;         //NSNotFound for a Site row
- (NSArray *)notesAtRows:(NSIndexSet *)rows;          //the Notes among rows, skipping Sites
- (NSIndexSet *)rowsForNotes:(NSArray *)notes;
@end

@interface NVHereNowHTTPTransport : NSObject <NVHereNowPageTransport>
@end
