#import <XCTest/XCTest.h>
#import "NVHereNowSites.h"
#import "AppController.h"
#import "NotationController.h"
#import "NotesTableView.h"

@interface AppController (HereNowSelectionTests)
- (void)notationListMightChange:(NotationController *)notation;
- (void)notationListDidChange:(NotationController *)notation;
- (void)hereNowSitesChanged:(NSNotification *)notification;
@end

@interface FakeMixedTable : NSTableView
@end
@implementation FakeMixedTable
- (ViewLocationContext)viewingLocation { ViewLocationContext location = {0}; return location; }
- (void)setViewingLocation:(ViewLocationContext)location { (void)location; }
@end

@interface FakeHereNowTransport : NSObject <NVHereNowPageTransport>
@property(copy) NSDictionary<NSString *, NSDictionary *> *answers;
@property(strong) NSMutableArray<NSString *> *paths;
@property(strong) NSMutableArray *pending;
@property(assign) BOOL holdsReplies;
- (void)respondNextWithBody:(NSString *)body;
@end
@implementation FakeHereNowTransport
- (instancetype)init { if ((self = [super init])) { _paths = [NSMutableArray array]; _pending = [NSMutableArray array]; } return self; }
- (void)getPath:(NSString *)path token:(NSString *)token completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    [_paths addObject:path];
    if (_holdsReplies) { [_pending addObject:[completion copy]]; return; }
    NSDictionary *answer = _answers[path];
    NSInteger status = [answer[@"status"] integerValue] ?: 200;
    NSData *body = [answer[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://here.now/api/v1/publishes"] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
    completion(body, response, answer[@"error"]);
}
- (void)respondNextWithBody:(NSString *)body {
    void (^reply)(NSData *, NSHTTPURLResponse *, NSError *) = [_pending firstObject];
    [_pending removeObjectAtIndex:0];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://here.now/api/v1/publishes"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    reply([body dataUsingEncoding:NSUTF8StringEncoding], response, nil);
}
@end

@interface NVHereNowSitesTests : XCTestCase
@end
@implementation NVHereNowSitesTests
- (NVHereNowSites *)serviceWithTransport:(FakeHereNowTransport *)fake {
    NVHereNowSites *service = [[NVHereNowSites alloc] initWithTransport:fake cacheURL:nil];
    [service setValue:@"separate-account" forKey:@"accountID"];
    return service;
}
- (NSError *)refresh:(NVHereNowSites *)service {
    XCTestExpectation *done = [self expectationWithDescription:@"refresh"];
    __block NSError *outError;
    [service refreshWithToken:@"fake-token" completion:^(NSError *error) { outError = error; [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:2];
    return outError;
}
- (void)testCompletePaginationAndFailureKeepsLastSnapshot {
    FakeHereNowTransport *fake = [FakeHereNowTransport new];
    NSString *first = @"/api/v1/publishes?scope=all&limit=100";
    NSString *second = [first stringByAppendingString:@"&cursor=a%26b%3Dc"];
    fake.answers = @{first: @{ @"body": @"{\"publishes\":[{\"slug\":\"one\",\"displayName\":\"First\",\"status\":\"active\",\"ownership\":\"owned\",\"siteUrl\":\"https://one.here.now/\"}],\"nextCursor\":\"a&b=c\"}" },
                     second: @{ @"body": @"{\"publishes\":[{\"slug\":\"two\",\"status\":\"active\",\"ownership\":\"workspace\",\"workspace\":{\"subdomain\":\"team\"},\"siteUrl\":\"https://two.here.now/\",\"primaryUrl\":\"https://example.com/\"}],\"nextCursor\":null}" }};
    NVHereNowSites *service = [self serviceWithTransport:fake];
    XCTAssertNil([self refresh:service]);
    XCTAssertEqual(service.sites.count, (NSUInteger)2);
    XCTAssertEqualObjects(fake.paths.lastObject, second);
    XCTAssertEqualObjects(service.sites[1].identity, @"separate-account:team:two");
    XCTAssertEqualObjects(service.sites[1].URL.absoluteString, @"https://example.com/");
    fake.answers = @{first: fake.answers[first], second: @{ @"status": @401, @"body": @"{}" }};
    XCTAssertNotNil([self refresh:service]);
    XCTAssertTrue(service.stale);
    XCTAssertEqual(service.sites.count, (NSUInteger)2);
    XCTAssertTrue([service.status containsString:@"reconnect"]);
    NSError *offline = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    fake.answers = @{first: @{ @"error": offline }};
    XCTAssertNotNil([self refresh:service]);
    XCTAssertEqual(service.sites.count, (NSUInteger)2);
    fake.answers = @{first: @{ @"status": @403, @"body": @"{}" }};
    XCTAssertNotNil([self refresh:service]);
    XCTAssertTrue([service.status containsString:@"access denied"]);
    XCTAssertEqual(service.sites.count, (NSUInteger)2);
    fake.answers = @{first: @{ @"body": @"{\"publishes\":{}}" }};
    XCTAssertNotNil([self refresh:service]);
    XCTAssertEqual(service.sites.count, (NSUInteger)2);
    fake.answers = @{first: @{ @"body": @"{\"publishes\":[],\"nextCursor\":null}" }};
    XCTAssertNil([self refresh:service]);
    XCTAssertFalse(service.stale);
    XCTAssertEqual(service.sites.count, (NSUInteger)0);
}
- (void)testMixedRowsStaySeparateAndSelectionGateCoversAllSelectedRows {
    FastListDataSource *notes = [FastListDataSource new];
    __attribute__((objc_precise_lifetime)) NSObject *note = [NSObject new];
    [notes fillArrayFromArray:@[note]];
    NVHereNowSite *site = [NVHereNowSite new];
    site.identity = @"account:owned:one"; site.title = @"First";
    site.searchText = @"first one"; site.URL = [NSURL URLWithString:@"https://one.here.now/"];
    NVHereNowMixedList *mixed = [NVHereNowMixedList new];
    mixed.notes = notes; mixed.sites = @[site];
    XCTAssertEqual(mixed.count, (NSUInteger)2);
    XCTAssertEqual([mixed immutableObjects][0], note);
    XCTAssertEqual([mixed siteAtRow:1], site);
    XCTAssertTrue([mixed selectionContainsSite:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]]);
    XCTAssertFalse([mixed selectionContainsSite:[NSIndexSet indexSetWithIndex:0]]);
    NSString *selectedIdentity = [mixed siteAtRow:1].identity;
    __attribute__((objc_precise_lifetime)) NSObject *insertedNote = [NSObject new]; // FastListDataSource borrows its objects.
    [notes fillArrayFromArray:@[note, insertedNote]];
    // The source can change before the table snapshot is rebuilt.
    XCTAssertEqual(mixed.noteRowCount, (NSUInteger)1);
    XCTAssertEqual([mixed siteAtRow:1], site);
    XCTAssertEqual([mixed rowForSiteIdentity:selectedIdentity], (NSUInteger)1);
    XCTAssertTrue([mixed selectionContainsSite:[NSIndexSet indexSetWithIndex:1]]);
    mixed.notes = notes;
    XCTAssertEqual([mixed rowForSiteIdentity:selectedIdentity], (NSUInteger)2);
    [notes fillArrayFromArray:@[note]];
    mixed.notes = notes;
    XCTAssertEqual([mixed rowForSiteIdentity:selectedIdentity], (NSUInteger)1);
    NVHereNowSite *refreshed = [NVHereNowSite new];
    refreshed.identity = site.identity; refreshed.title = site.title; refreshed.searchText = site.searchText; refreshed.URL = site.URL;
    mixed.sites = @[refreshed];
    XCTAssertEqual([mixed rowForSiteIdentity:selectedIdentity], (NSUInteger)1);
    [mixed filterSitesForString:@"missing"];
    XCTAssertEqual(mixed.count, (NSUInteger)1);
    XCTAssertNil([mixed siteAtRow:1]);
    XCTAssertEqual(notes.count, (NSUInteger)1);
}
- (void)testOldRefreshCannotReplaceNewSnapshot {
    FakeHereNowTransport *fake = [FakeHereNowTransport new];
    fake.holdsReplies = YES;
    NVHereNowSites *service = [self serviceWithTransport:fake];
    [service refreshWithToken:@"old" completion:nil];
    XCTestExpectation *done = [self expectationWithDescription:@"new refresh"];
    [service refreshWithToken:@"new" completion:^(NSError *error) { XCTAssertNil(error); [done fulfill]; }];
    NSString *oldPage = @"{\"publishes\":[{\"slug\":\"old\",\"status\":\"active\",\"ownership\":\"owned\",\"siteUrl\":\"https://old.here.now/\"}],\"nextCursor\":null}";
    NSString *newPage = @"{\"publishes\":[{\"slug\":\"new\",\"status\":\"active\",\"ownership\":\"owned\",\"siteUrl\":\"https://new.here.now/\"}],\"nextCursor\":null}";
    [fake respondNextWithBody:oldPage];
    [fake respondNextWithBody:newPage];
    [self waitForExpectations:@[done] timeout:2];
    XCTAssertEqual(service.sites.count, (NSUInteger)1);
    XCTAssertEqualObjects(service.sites.firstObject.title, @"new");
}
- (void)testSelectedSiteDisablesAndBlocksNoteDeletion {
    FastListDataSource *notes = [FastListDataSource new];
    __attribute__((objc_precise_lifetime)) NSObject *note = [NSObject new];
    [notes fillArrayFromArray:@[note]];
    NVHereNowSite *site = [NVHereNowSite new];
    site.title = @"Report"; site.searchText = @"report";
    site.URL = [NSURL URLWithString:@"https://report.here.now/"];
    NVHereNowMixedList *mixed = [NVHereNowMixedList new];
    mixed.notes = notes; mixed.sites = @[site];
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"Title"]];
    [table setDataSource:mixed];
    [table reloadData];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    AppController *app = [AppController alloc];
    static NSMutableArray *kept;
    if (!kept) kept = [NSMutableArray array];
    [kept addObject:app];
    [app setValue:mixed forKey:@"mixedList"];
    [app setValue:table forKey:@"notesTableView"];
    XCTAssertTrue([app selectedRowIsHereNowSite]);
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Delete" action:@selector(deleteNote:) keyEquivalent:@""];
    XCTAssertFalse([(id<NSMenuItemValidation>)app validateMenuItem:item]);
    [app deleteNote:nil]; // must return before touching the Note store
    XCTAssertEqual(notes.count, (NSUInteger)1);
}
- (void)testSelectedSiteSurvivesNoteListAndSiteRefresh {
    NotationController *notation = [[NotationController alloc] init];
    FastListDataSource *notes = [notation notesListDataSource];
    __attribute__((objc_precise_lifetime)) NSObject *note = [NSObject new];
    [notes fillArrayFromArray:@[note]];
    NVHereNowSite *site = [NVHereNowSite new];
    site.identity = @"account:owned:report"; site.title = @"Report"; site.searchText = @"report";
    site.URL = [NSURL URLWithString:@"https://report.here.now/"];
    NVHereNowSite *other = [NVHereNowSite new];
    other.identity = @"account:owned:other"; other.title = @"Other"; other.searchText = @"other";
    other.URL = [NSURL URLWithString:@"https://other.here.now/"];
    NVHereNowMixedList *mixed = [NVHereNowMixedList new]; mixed.notes = notes; mixed.sites = @[site, other];
    FakeMixedTable *table = [[FakeMixedTable alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"Title"]];
    table.allowsMultipleSelection = YES;
    table.dataSource = mixed; [table reloadData];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)] byExtendingSelection:NO];
    XCTAssertTrue(table.allowsMultipleSelection);
    XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]);
    AppController *app = [AppController alloc];
    static NSMutableArray *keptSelections;
    if (!keptSelections) keptSelections = [NSMutableArray array];
    [keptSelections addObject:app];
    [app setValue:notation forKey:@"notationController"];
    [app setValue:mixed forKey:@"mixedList"];
    [app setValue:table forKey:@"notesTableView"];
    // setNotationController: rebuilds the note source; establish the fixture after it.
    [notes fillArrayFromArray:@[note]];
    mixed.notes = notes;
    [table reloadData];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)] byExtendingSelection:NO];
    XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]);
    [app notationListMightChange:notation];
    XCTAssertEqual([[app valueForKey:@"savedSelectedSiteIdentities"] count], (NSUInteger)2);
    __attribute__((objc_precise_lifetime)) NSObject *insertedNote = [NSObject new];
    [notes fillArrayFromArray:@[note, insertedNote]];
    [app notationListDidChange:notation];
    XCTAssertEqual([mixed rowForSiteIdentity:site.identity], (NSUInteger)2);
    XCTAssertEqual([mixed rowForSiteIdentity:other.identity], (NSUInteger)3);
    XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 2)]);
    [app notationListMightChange:notation];
    [notes fillArrayFromArray:@[note]];
    [app notationListDidChange:notation];
    XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]);
    NVHereNowSite *replacement = [NVHereNowSite new];
    replacement.identity = site.identity; replacement.title = @"Renamed report";
    replacement.searchText = @"renamed report"; replacement.URL = site.URL;
    NVHereNowSites *service = [self serviceWithTransport:[FakeHereNowTransport new]];
    [service setValue:@[other, replacement] forKey:@"sites"];
    [app setValue:service forKey:@"hereNowSites"];
    [app hereNowSitesChanged:nil];
    XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]);
    XCTAssertEqual([mixed siteAtRow:2], replacement);
}
@end
