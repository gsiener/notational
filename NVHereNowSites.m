#import "NVHereNowSites.h"
#import "NoteAttributeColumn.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "UnifiedCell.h"
#import "LabelColumnCell.h"
#import "NSString_NV.h"
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
// here.now sends RFC 3339 times, with or without fractional seconds.
static NSDate *SiteDate(id value) {
    if (![value isKindOfClass:[NSString class]] || ![value length]) return nil;
    static NSISO8601DateFormatter *plain, *fractional;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plain = [NSISO8601DateFormatter new];
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [fractional dateFromString:value] ?: [plain dateFromString:value];
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
        // contentUpdatedAt moves only when the live content changes, like a Note's modification date;
        // updatedAt also moves on settings changes, so it is only a fallback. The list has no creation time.
        site.modifiedDate = SiteDate(row[@"contentUpdatedAt"]) ?: SiteDate(row[@"updatedAt"]);
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
        if (!owner || generation != owner->_generation) { page = nil; return; }
        NSString *path = @"/api/v1/publishes?scope=all&limit=100";
        if (cursor) {
            NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
            path = [path stringByAppendingFormat:@"&cursor=%@", [cursor stringByAddingPercentEncodingWithAllowedCharacters:unreserved]];
        }
        [owner->_transport getPath:path token:token completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || generation != strongSelf->_generation) { page = nil; return; }
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

typedef NS_ENUM(NSInteger, NVMixedSortKind) { NVMixedSortNone, NVMixedSortTitle, NVMixedSortLabels, NVMixedSortModified, NVMixedSortCreated };

static NVMixedSortKind SortKindForKey(NSString *key) {
    if ([key isEqualToString:NoteDateModifiedColumnString]) return NVMixedSortModified;
    if ([key isEqualToString:NoteDateCreatedColumnString]) return NVMixedSortCreated;
    if ([key isEqualToString:NoteTitleColumnString]) return NVMixedSortTitle;
    if ([key isEqualToString:NoteLabelsColumnString]) return NVMixedSortLabels;
    return NVMixedSortNone;
}
//as compareTitleString and compareLabelString compare
static NSInteger CompareCaseInsensitive(NSString *a, NSString *b) {
    return (NSInteger)CFStringCompare((__bridge CFStringRef)(a ?: @""), (__bridge CFStringRef)(b ?: @""), kCFCompareCaseInsensitive);
}
static BOOL SiteSortTime(NVHereNowSite *site, NVMixedSortKind kind, CFAbsoluteTime *time) {
    NSDate *date = kind == NVMixedSortModified ? site.modifiedDate : kind == NVMixedSortCreated ? site.createdDate : nil;
    if (date) *time = [date timeIntervalSinceReferenceDate];
    return date != nil;
}
// Negative when the Site is listed before the Note. It mirrors the Notes' sort: the column's comparator
// (dates truncated to whole seconds, as compareDateModified does), then the title, both flipped when
// reversed. A Site with no date for a date sort, and any tie, lists after the Note.
static NSInteger CompareSiteToNote(NVHereNowSite *site, NoteObject *note, NVMixedSortKind kind, BOOL reversed) {
    NSInteger result = 0;
    switch (kind) {
        case NVMixedSortNone: return 1;
        case NVMixedSortModified:
        case NVMixedSortCreated: {
            CFAbsoluteTime time;
            if (!SiteSortTime(site, kind, &time)) return 1;
            result = (NSInteger)(time - (kind == NVMixedSortModified ? modifiedDateOfNote(note) : createdDateOfNote(note)));
            break;
        }
        case NVMixedSortLabels: result = CompareCaseInsensitive(@"", labelsOfNote(note)); break;   //Sites have no tags
        case NVMixedSortTitle: break;
    }
    if (!result) result = CompareCaseInsensitive(site.title, titleOfNote(note));
    if (!result) return 1;
    return reversed ? -result : result;
}
// Sites among themselves, by the same rules; undated Sites list last in either direction, otherwise ties keep API order.
static NSComparisonResult CompareSites(NVHereNowSite *a, NVHereNowSite *b, NVMixedSortKind kind, BOOL reversed) {
    if (kind == NVMixedSortNone) return NSOrderedSame;
    NSInteger result = 0;
    if (kind == NVMixedSortModified || kind == NVMixedSortCreated) {
        CFAbsoluteTime timeA = 0, timeB = 0;
        BOOL datedA = SiteSortTime(a, kind, &timeA), datedB = SiteSortTime(b, kind, &timeB);
        if (datedA != datedB) return datedA ? NSOrderedAscending : NSOrderedDescending;
        if (datedA) result = (NSInteger)(timeA - timeB);
    }
    if (!result) result = CompareCaseInsensitive(a.title, b.title);
    if (reversed) result = -result;
    return result < 0 ? NSOrderedAscending : result > 0 ? NSOrderedDescending : NSOrderedSame;
}
static NSString *SiteDateString(NSDate *date) {
    return date ? [NSString relativeDateStringWithAbsoluteTime:[date timeIntervalSinceReferenceDate]] : @"";
}

@implementation NVHereNowMixedList {
    NSArray *_rows;               //Notes and Sites; also keeps alive what FastListDataSource borrows
    NSString *_search;
    NSUInteger _noteRowCount;
    NSMutableData *_noteIndexForRow, *_rowForNoteIndex;
}
- (void)setNotes:(FastListDataSource *)notes { _notes = notes; [self rebuild]; }
- (void)setSites:(NSArray *)sites { _sites = [sites copy]; [self rebuild]; }
- (void)filterSitesForString:(NSString *)search { _search = [search copy]; [self rebuild]; }
- (void)setSortKey:(NSString *)sortKey reversed:(BOOL)reversed { _sortKey = [sortKey copy]; _reverseSort = reversed; [self rebuild]; }
- (void)setNotes:(FastListDataSource *)notes sortKey:(NSString *)sortKey reversed:(BOOL)reversed search:(NSString *)search {
    _notes = notes; _sortKey = [sortKey copy]; _reverseSort = reversed; _search = [search copy];
    [self rebuild];
}
- (void)rebuild {
    NSMutableArray *visible = [NSMutableArray array];
    for (NVHereNowSite *site in _sites) if (!_search.length || [site.searchText localizedCaseInsensitiveContainsString:_search]) [visible addObject:site];
    NVMixedSortKind kind = SortKindForKey(_sortKey);
    BOOL reversed = _reverseSort;
    NSArray *sites = [visible sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) { return CompareSites(a, b, kind, reversed); }];

    const __unsafe_unretained id *notes = [_notes immutableObjects];
    NSUInteger noteCount = [_notes count], rowCount = noteCount + sites.count, site = 0;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:rowCount];
    _noteIndexForRow = [NSMutableData dataWithLength:rowCount * sizeof(NSUInteger)];
    _rowForNoteIndex = [NSMutableData dataWithLength:noteCount * sizeof(NSUInteger)];
    NSUInteger *noteIndexForRow = _noteIndexForRow.mutableBytes, *rowForNoteIndex = _rowForNoteIndex.mutableBytes;
    for (NSUInteger i = 0; i <= noteCount; ++i) {
        //each Site goes before the first Note it sorts ahead of; the rest follow the last Note
        while (site < sites.count && (i == noteCount || CompareSiteToNote(sites[site], notes[i], kind, reversed) < 0)) {
            noteIndexForRow[rows.count] = NSNotFound;
            [rows addObject:sites[site++]];
        }
        if (i == noteCount) break;
        rowForNoteIndex[i] = rows.count;
        noteIndexForRow[rows.count] = i;
        [rows addObject:notes[i]];
    }
    _noteRowCount = noteCount;
    _rows = rows; // FastListDataSource keeps unsafe pointers.
    [self fillArrayFromArray:rows];
}
- (NSUInteger)noteRowCount { return _noteRowCount; }
- (BOOL)rowInRange:(NSInteger)row { return row >= 0 && (NSUInteger)row < _rows.count; }
- (NVHereNowSite *)siteAtRow:(NSInteger)row {
    if (![self rowInRange:row]) return nil;
    id object = _rows[(NSUInteger)row];
    return [object isKindOfClass:[NVHereNowSite class]] ? object : nil;
}
- (id)noteAtRow:(NSInteger)row { return [self noteIndexForRow:row] == NSNotFound ? nil : _rows[(NSUInteger)row]; }
- (NSUInteger)noteIndexForRow:(NSInteger)row {
    return [self rowInRange:row] ? ((const NSUInteger *)_noteIndexForRow.bytes)[row] : NSNotFound;
}
- (NSUInteger)rowForNoteIndex:(NSUInteger)noteIndex {
    return noteIndex < _noteRowCount ? ((const NSUInteger *)_rowForNoteIndex.bytes)[noteIndex] : NSNotFound;
}
- (NSUInteger)rowForNote:(id)note {
    if (!note) return NSNotFound;
    NSUInteger row = [self indexOfObjectIdenticalTo:note];
    return row != NSNotFound && [self noteIndexForRow:(NSInteger)row] != NSNotFound ? row : NSNotFound;
}
- (NSArray *)notesAtRows:(NSIndexSet *)rows {
    NSMutableArray *notes = [NSMutableArray arrayWithCapacity:rows.count];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        id note = [self noteAtRow:(NSInteger)row];
        if (note) [notes addObject:note];
    }];
    return notes;
}
- (NSIndexSet *)rowsForNotes:(NSArray *)notes {
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (id note in notes) {
        NSUInteger row = [self rowForNote:note];
        if (row != NSNotFound) [rows addIndex:row];
    }
    return rows;
}
//callers that treat the list as a FastListDataSource of Notes never receive a Site
- (NSArray *)objectsAtFilteredIndexes:(NSIndexSet *)indexSet { return [self notesAtRows:indexSet]; }
- (NSUInteger)rowForSiteIdentity:(NSString *)identity {
    if (!identity.length) return NSNotFound;
    for (NSUInteger row = 0; row < _rows.count; ++row) {
        NVHereNowSite *site = _rows[row];
        if ([site isKindOfClass:[NVHereNowSite class]] && [site.identity isEqualToString:identity]) return row;
    }
    return NSNotFound;
}
- (BOOL)selectionContainsSite:(NSIndexSet *)indexes {
    return [indexes indexPassingTest:^BOOL(NSUInteger row, BOOL *stop) { return [self siteAtRow:(NSInteger)row] != nil; }] != NSNotFound;
}
- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NVHereNowSite *site = [self siteAtRow:row];
    if (!site) return [self rowInRange:row] ? [super tableView:table objectValueForTableColumn:column row:row] : nil;
    //the shared cells still hold the last Note drawn; clear it so a Site row draws no Note's date or tags
    id cell = [column dataCellForRow:row];
    if ([cell isKindOfClass:[UnifiedCell class]]) {
        [cell setNoteObject:nil];
        [cell setFallbackDateModifiedString:SiteDateString(site.modifiedDate) createdString:SiteDateString(site.createdDate)];
    } else if ([cell isKindOfClass:[LabelColumnCell class]]) {
        [cell setNoteObject:nil];
    }
    NSString *identifier = [column identifier];
    if ([identifier isEqual:NoteTitleColumnString]) return [NSString stringWithFormat:@"◈ %@  (here.now · %@ · read-only%@)", site.title, site.scopeLabel ?: @"Personal", self.stale ? @" · saved" : @""];
    if ([identifier isEqual:NoteDateModifiedColumnString]) return SiteDateString(site.modifiedDate);
    if ([identifier isEqual:NoteDateCreatedColumnString]) return SiteDateString(site.createdDate);
    return @"";
}
- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if ([self noteAtRow:row]) [super tableView:table setObjectValue:value forTableColumn:column row:row];
}
@end
