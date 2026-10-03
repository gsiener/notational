#import "NVHereNowSites.h"
#import "NoteAttributeColumn.h"
#import <Security/Security.h>

NSString *const NVHereNowSitesDidChangeNotification = @"NVHereNowSitesDidChange";
static NSString *const KeychainService = @"org.notationalvelocity.here-now.read-only";

@implementation NVHereNowSite
@end

@implementation NVHereNowHTTPTransport {
    NSURLSession *_session;
}
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 20;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}
- (void)getPath:(NSString *)path token:(NSString *)token completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:[@"https://here.now" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"codex/notational-read" forHTTPHeaderField:@"X-HereNow-Client"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        completion(data, (NSHTTPURLResponse *)response, error);
    }] resume];
}
@end

static NSDictionary *KeyQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: KeychainService,
             (__bridge id)kSecAttrAccount: @"current"};
}
static NSString *ReadKey(void) {
    NSMutableDictionary *query = [KeyQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(result) encoding:NSUTF8StringEncoding];
}
static BOOL SaveKey(NSString *key) {
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)KeyQuery(), (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [KeyQuery() mutableCopy];
        item[(__bridge id)kSecValueData] = data;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return status == errSecSuccess;
}
static NSError *SiteError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NVHereNowSites" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation NVHereNowSites {
    id<NVHereNowPageTransport> _transport;
    NSURL *_cacheURL;
    NSString *_accountID;
    NSUInteger _generation;
    NSArray<NVHereNowSite *> *_sites;
    NSString *_status;
    BOOL _stale;
}
- (instancetype)initWithTransport:(id<NVHereNowPageTransport>)transport cacheURL:(NSURL *)cacheURL {
    if ((self = [super init])) { _transport = transport; _cacheURL = cacheURL; _sites = @[]; _status = @"Not connected"; }
    return self;
}
- (NSArray *)sites { return _sites; }
- (NSString *)status { return _status; }
- (BOOL)stale { return _stale; }
- (BOOL)connected { return ReadKey() != nil; }
- (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:NVHereNowSitesDidChangeNotification object:self]; }
- (void)restore {
    if (![self connected]) return;
    NSData *cacheData = [NSData dataWithContentsOfURL:_cacheURL];
    id decoded = cacheData ? [NSJSONSerialization JSONObjectWithData:cacheData options:0 error:nil] : nil;
    NSDictionary *cache = [decoded isKindOfClass:[NSDictionary class]] ? decoded : nil;
    _accountID = cache[@"accountID"];
    if (![_accountID isKindOfClass:[NSString class]] || !_accountID.length) _accountID = [[NSUUID UUID] UUIDString];
    _sites = [self sitesFromRows:cache[@"rows"] accountID:_accountID];
    _stale = YES;
    _status = @"Showing saved Sites; refresh pending";
    [self changed];
    [self refresh];
}
- (void)connectWithKey:(NSString *)key completion:(void (^)(NSError *))completion {
    if (!key.length) { completion(SiteError(0, @"Enter a here.now API key.")); return; }
    // A local identity scopes cached rows; replacing the key always starts a fresh identity.
    if (!SaveKey(key)) { completion(SiteError(0, @"The here.now API key could not be saved in Keychain.")); return; }
    [[NSFileManager defaultManager] removeItemAtURL:_cacheURL error:nil];
    _accountID = [[NSUUID UUID] UUIDString];
    _sites = @[]; _stale = NO; _status = @"Connected; loading Sites";
    [self changed]; [self refresh]; completion(nil);
}
- (void)disconnect {
    ++_generation;
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)KeyQuery());
    if (status != errSecSuccess && status != errSecItemNotFound) {
        _status = @"Could not remove here.now key from Keychain"; [self changed]; return;
    }
    [[NSFileManager defaultManager] removeItemAtURL:_cacheURL error:nil];
    _accountID = nil; _sites = @[]; _stale = NO; _status = @"Not connected";
    [self changed];
}
- (void)refresh { NSString *token = ReadKey(); if (token) [self refreshWithToken:token completion:nil]; }
- (NSArray *)sitesFromRows:(NSArray *)rows accountID:(NSString *)accountID {
    if (![rows isKindOfClass:[NSArray class]] || !accountID.length) return @[];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]] || ![row[@"status"] isEqual:@"active"]) continue;
        NSString *slug = row[@"slug"], *ownership = row[@"ownership"];
        if (![slug isKindOfClass:[NSString class]] || !slug.length || ![ownership isKindOfClass:[NSString class]]) continue;
        NSString *rawURL = [row[@"primaryUrl"] isKindOfClass:[NSString class]] ? row[@"primaryUrl"] : row[@"siteUrl"];
        NSURL *url = [rawURL isKindOfClass:[NSString class]] ? [NSURL URLWithString:rawURL] : nil;
        if (![[url scheme] isEqual:@"https"] || ![url host]) continue;
        NSDictionary *workspace = row[@"workspace"];
        NSString *scope = [workspace isKindOfClass:[NSDictionary class]] && [workspace[@"subdomain"] isKindOfClass:[NSString class]] ? workspace[@"subdomain"] : nil;
        if (!scope.length) scope = ownership;
        NSString *identity = [NSString stringWithFormat:@"%@:%@:%@", accountID, scope, slug];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        NVHereNowSite *site = [NVHereNowSite new];
        site.identity = identity;
        NSString *title = row[@"displayName"];
        site.title = [title isKindOfClass:[NSString class]] && title.length ? title : slug;
        NSString *workspaceName = [workspace isKindOfClass:[NSDictionary class]] && [workspace[@"displayName"] isKindOfClass:[NSString class]] ? workspace[@"displayName"] : nil;
        site.scopeLabel = workspaceName.length ? workspaceName : ([ownership isEqual:@"shared"] ? @"Shared" : @"Personal");
        site.URL = url;
        site.searchText = [[@[site.title, slug, rawURL, site.scopeLabel] componentsJoinedByString:@" "] lowercaseString];
        [result addObject:site];
    }
    return result;
}
- (void)refreshWithToken:(NSString *)token completion:(void (^)(NSError *))completion {
    NSUInteger generation = ++_generation;
    _status = @"Refreshing Sites"; [self changed];
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *cursors = [NSMutableSet set];
    __weak typeof(self) weakSelf = self;
    __block void (^page)(NSString *);
    page = ^(NSString *cursor) {
        typeof(self) owner = weakSelf;
        if (!owner) return;
        NSString *path = @"/api/v1/publishes?scope=all&limit=100";
        if (cursor) {
            NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
            path = [path stringByAppendingFormat:@"&cursor=%@", [cursor stringByAddingPercentEncodingWithAllowedCharacters:unreserved]];
        }
        [owner->_transport getPath:path token:token completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || generation != strongSelf->_generation) return;
                NSError *failure = error;
                if (!failure && response.statusCode != 200) {
                    NSString *message = response.statusCode == 401 ? @"here.now key expired; reconnect to refresh Sites" :
                        response.statusCode == 403 ? @"here.now access denied; saved Sites may be outdated" :
                        response.statusCode == 429 ? @"here.now rate limit; retry refresh later" : @"here.now unavailable; showing saved Sites";
                    failure = SiteError(response.statusCode, message);
                }
                NSDictionary *json = !failure && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&failure] : nil;
                NSArray *batch = [json isKindOfClass:[NSDictionary class]] ? json[@"publishes"] : nil;
                if (!failure && ![batch isKindOfClass:[NSArray class]]) failure = SiteError(0, @"Invalid here.now list response");
                NSString *next = [json isKindOfClass:[NSDictionary class]] ? json[@"nextCursor"] : nil;
                if (!failure && next && next != (id)[NSNull null] && (![next isKindOfClass:[NSString class]] || [cursors containsObject:next])) failure = SiteError(0, @"Invalid here.now page cursor");
                if (failure) {
                    strongSelf->_stale = YES; strongSelf->_status = [failure localizedDescription]; [strongSelf changed];
                    if (completion) completion(failure);
                    page = nil; return;
                }
                [rows addObjectsFromArray:batch];
                if ([next isKindOfClass:[NSString class]] && next.length) { [cursors addObject:next]; page(next); return; }
                strongSelf->_sites = [strongSelf sitesFromRows:rows accountID:strongSelf->_accountID];
                strongSelf->_stale = NO; strongSelf->_status = [NSString stringWithFormat:@"%lu Sites", (unsigned long)strongSelf->_sites.count];
                if (strongSelf->_cacheURL && strongSelf->_accountID) {
                    [[NSFileManager defaultManager] createDirectoryAtURL:[strongSelf->_cacheURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
                    NSData *cache = [NSJSONSerialization dataWithJSONObject:@{@"accountID": strongSelf->_accountID, @"rows": rows} options:0 error:nil];
                    [cache writeToURL:strongSelf->_cacheURL atomically:YES];
                }
                [strongSelf changed]; if (completion) completion(nil); page = nil;
            });
        }];
    };
    page(nil);
}
@end

@implementation NVHereNowMixedList {
    NSArray *_visibleSites;
    NSArray *_retainedRows;
    NSString *_search;
}
- (void)setNotes:(FastListDataSource *)notes { _notes = notes; [self rebuild]; }
- (void)setSites:(NSArray *)sites { _sites = [sites copy]; [self rebuild]; }
- (void)filterSitesForString:(NSString *)search { _search = [search copy]; [self rebuild]; }
- (void)rebuild {
    NSMutableArray *rows = [NSMutableArray array];
    const __unsafe_unretained id *notes = [_notes immutableObjects];
    for (NSUInteger i = 0; i < [_notes count]; ++i) [rows addObject:notes[i]];
    NSMutableArray *visible = [NSMutableArray array];
    for (NVHereNowSite *site in _sites) if (!_search.length || [site.searchText localizedCaseInsensitiveContainsString:_search]) [visible addObject:site];
    _visibleSites = visible;
    [rows addObjectsFromArray:visible];
    _retainedRows = rows; // FastListDataSource keeps unsafe pointers.
    [self fillArrayFromArray:rows];
}
- (NVHereNowSite *)siteAtRow:(NSInteger)row {
    NSInteger offset = row - (NSInteger)[_notes count];
    return offset >= 0 && offset < (NSInteger)_visibleSites.count ? _visibleSites[offset] : nil;
}
- (BOOL)selectionContainsSite:(NSIndexSet *)indexes { return indexes.lastIndex != NSNotFound && indexes.lastIndex >= [_notes count]; }
- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NVHereNowSite *site = [self siteAtRow:row];
    if (!site) return [_notes tableView:table objectValueForTableColumn:column row:row];
    if ([[column identifier] isEqual:@"Title"]) return [NSString stringWithFormat:@"◈ %@  (here.now · %@ · read-only%@)", site.title, site.scopeLabel ?: @"Personal", self.stale ? @" · saved" : @""];
    return @"";
}
- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (![self siteAtRow:row]) [_notes tableView:table setObjectValue:value forTableColumn:column row:row];
}
@end
