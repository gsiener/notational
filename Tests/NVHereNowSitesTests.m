#import <XCTest/XCTest.h>
#import "NVHereNowSites.h"
#import "AppController.h"

@interface FakeHereNowTransport : NSObject <NVHereNowPageTransport>
@property(copy) NSDictionary<NSString *, NSDictionary *> *answers;
@property(strong) NSMutableArray<NSString *> *paths;
@end
@implementation FakeHereNowTransport
- (instancetype)init { if ((self = [super init])) _paths = [NSMutableArray array]; return self; }
- (void)getPath:(NSString *)path token:(NSString *)token completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    [_paths addObject:path];
    NSDictionary *answer = _answers[path];
    NSInteger status = [answer[@"status"] integerValue] ?: 200;
    NSData *body = [answer[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://here.now/api/v1/publishes"] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
    completion(body, response, answer[@"error"]);
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
    NSObject *note = [NSObject new];
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
    [mixed filterSitesForString:@"missing"];
    XCTAssertEqual(mixed.count, (NSUInteger)1);
    XCTAssertNil([mixed siteAtRow:1]);
    XCTAssertEqual(notes.count, (NSUInteger)1);
}
- (void)testSelectedSiteDisablesAndBlocksNoteDeletion {
    FastListDataSource *notes = [FastListDataSource new];
    [notes fillArrayFromArray:@[[NSObject new]]];
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
@end
