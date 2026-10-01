//
//  NVSimplenoteHTTPServiceTests.m
//  NotationTests
//
//  The HTTP adapter against a stub URL protocol: request shapes and response mapping.
//  No network access.
//

#import <XCTest/XCTest.h>
#import "NVSimplenoteHTTPService.h"

typedef NSDictionary *(^NVStubHandler)(NSURLRequest *request, NSData *body);

static NVStubHandler stubHandler = nil;
static NSMutableArray *stubRequests = nil;

//response dictionary keys: @"status" (NSNumber), @"headers" (NSDictionary), @"body" (id: JSON object or NSData)
@interface NVStubURLProtocol : NSURLProtocol
@end

@implementation NVStubURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

static NSData *BodyOf(NSURLRequest *request) {
	if ([request HTTPBody]) return [request HTTPBody];
	NSInputStream *stream = [request HTTPBodyStream];
	if (!stream) return nil;
	NSMutableData *data = [NSMutableData data];
	uint8_t buffer[4096];
	[stream open];
	NSInteger read;
	while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:read];
	[stream close];
	return data;
}

- (void)startLoading {
	NSData *body = BodyOf([self request]);
	@synchronized([NVStubURLProtocol class]) {
		[stubRequests addObject:[NSDictionary dictionaryWithObjectsAndKeys:[self request], @"request", body ? body : [NSData data], @"body", nil]];
	}
	NSDictionary *reply = stubHandler ? stubHandler([self request], body) : nil;
	NSInteger status = reply ? [[reply objectForKey:@"status"] integerValue] : 500;
	id payload = [reply objectForKey:@"body"];
	NSData *data = [payload isKindOfClass:[NSData class]] ? payload :
		(payload ? [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL] : [NSData data]);
	NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[[self request] URL] statusCode:status
															  HTTPVersion:@"HTTP/1.1" headerFields:[reply objectForKey:@"headers"]] autorelease];
	[[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
	[[self client] URLProtocol:self didLoadData:data];
	[[self client] URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

static NSDictionary *Reply(NSInteger status, id body, NSDictionary *headers) {
	return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:status], @"status",
			body ? body : [NSData data], @"body", headers ? headers : [NSDictionary dictionary], @"headers", nil];
}

@interface NVSimplenoteHTTPServiceTests : XCTestCase {
	NVSimplenoteHTTPService *service;
	NVSimplenoteAuthenticator *authenticator;
}
@end

@implementation NVSimplenoteHTTPServiceTests

- (NSURLSessionConfiguration *)stubConfiguration {
	NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	[config setProtocolClasses:[NSArray arrayWithObject:[NVStubURLProtocol class]]];
	return config;
}

- (void)setUp {
	[super setUp];
	stubRequests = [[NSMutableArray alloc] init];
	service = [[NVSimplenoteHTTPService alloc] initWithToken:@"TOKEN" clientID:@"nvalt-test"
											   configuration:[self stubConfiguration] baseURL:nil];
	authenticator = [[NVSimplenoteAuthenticator alloc] initWithConfiguration:[self stubConfiguration] baseURL:nil];
}

- (void)tearDown {
	[service release];
	[authenticator release];
	[stubHandler release];
	stubHandler = nil;
	[stubRequests release];
	stubRequests = nil;
	[super tearDown];
}

- (void)stub:(NVStubHandler)handler {
	[stubHandler release];
	stubHandler = [handler copy];
}

- (NSURLRequest *)lastRequest { return [[stubRequests lastObject] objectForKey:@"request"]; }
- (id)lastJSONBody { return [NSJSONSerialization JSONObjectWithData:[[stubRequests lastObject] objectForKey:@"body"] options:0 error:NULL]; }

static NSDictionary *QueryOf(NSURL *url) {
	NSMutableDictionary *query = [NSMutableDictionary dictionary];
	for (NSURLQueryItem *item in [[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES] queryItems])
		[query setObject:[item value] ? [item value] : @"" forKey:[item name]];
	return query;
}

#pragma mark Data API

- (void)testIndexRequestAndParsing {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionaryWithObjectsAndKeys:
						   [NSArray arrayWithObjects:
							[NSDictionary dictionaryWithObjectsAndKeys:@"a1", @"id", [NSNumber numberWithInt:3], @"v",
							 [NSDictionary dictionaryWithObject:@"hello" forKey:@"content"], @"d", nil],
							[NSDictionary dictionaryWithObjectsAndKeys:@"b2", @"id", [NSNumber numberWithInt:9], @"v", nil], nil], @"index",
						   @"MARK2", @"mark", @"cvXYZ", @"current", nil], nil);
	}];
	NSError *error = nil;
	NVIndexPage *page = [service indexPageAfterMark:@"MARK1" limit:100 includeData:YES error:&error];
	XCTAssertNotNil(page, @"%@", error);

	NSURLRequest *request = [self lastRequest];
	XCTAssertEqualObjects([[request URL] path], @"/1/chalk-bump-f49/note/index");
	XCTAssertEqualObjects(QueryOf([request URL]), ([NSDictionary dictionaryWithObjectsAndKeys:@"100", @"limit", @"MARK1", @"mark", @"1", @"data", nil]));
	XCTAssertEqualObjects([request valueForHTTPHeaderField:@"X-Simperium-Token"], @"TOKEN");
	XCTAssertEqualObjects([[request URL] host], @"api.simperium.com");

	XCTAssertEqual([[page notes] count], (NSUInteger)2);
	XCTAssertEqualObjects([[[[page notes] objectAtIndex:0] data] objectForKey:@"content"], @"hello");
	XCTAssertEqual([[[page notes] objectAtIndex:1] version], (NSInteger)9);
	XCTAssertNil([[[page notes] objectAtIndex:1] data]);
	XCTAssertEqualObjects([page nextMark], @"MARK2");
	XCTAssertEqualObjects([page changeVersion], @"cvXYZ");
}

- (void)testLastIndexPageHasNoMark {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionaryWithObjectsAndKeys:[NSArray array], @"index", @"cv1", @"current", nil], nil);
	}];
	XCTAssertNil([[service indexPageAfterMark:nil limit:10 includeData:NO error:NULL] nextMark]);
	XCTAssertNil(QueryOf([[self lastRequest] URL])[@"data"]);
}

- (void)testChangesRequestAndParsing {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSArray arrayWithObjects:
						   [NSDictionary dictionaryWithObjectsAndKeys:@"a1", @"id", @"cv2", @"cv", @"M", @"o", [NSNumber numberWithInt:4], @"ev", nil],
						   [NSDictionary dictionaryWithObjectsAndKeys:@"b2", @"id", @"cv3", @"cv", @"-", @"o", nil], nil], nil);
	}];
	NSError *error = nil;
	NSArray *changes = [service changesSince:@"cv1" error:&error];
	XCTAssertEqualObjects([[[self lastRequest] URL] path], @"/1/chalk-bump-f49/note/changes");
	XCTAssertEqualObjects(QueryOf([[self lastRequest] URL]), ([NSDictionary dictionaryWithObjectsAndKeys:@"cv1", @"cv", @"nvalt-test", @"clientid", @"0", @"wait", nil]));
	XCTAssertEqual([changes count], (NSUInteger)2);
	XCTAssertEqual([[changes objectAtIndex:0] version], (NSInteger)4);
	XCTAssertFalse([[changes objectAtIndex:0] removed]);
	XCTAssertNil([[changes objectAtIndex:0] data]);
	XCTAssertTrue([[changes objectAtIndex:1] removed]);
	XCTAssertEqualObjects([[changes lastObject] changeVersion], @"cv3");
}

- (void)testUnknownChangeVersion {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) { return Reply(404, nil, nil); }];
	NSError *error = nil;
	XCTAssertNil([service changesSince:@"cvOLD" error:&error]);
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorUnknownChangeVersion);
}

- (void)testGetNoteReadsVersionHeader {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionaryWithObject:@"text" forKey:@"content"],
					 [NSDictionary dictionaryWithObject:@"12" forKey:@"X-Simperium-Version"]);
	}];
	NSInteger version = 0;
	NSDictionary *note = [service noteWithID:@"a1" version:&version error:NULL];
	XCTAssertEqualObjects([[[self lastRequest] URL] path], @"/1/chalk-bump-f49/note/i/a1");
	XCTAssertEqualObjects([note objectForKey:@"content"], @"text");
	XCTAssertEqual(version, (NSInteger)12);
}

- (void)testPostAtBaseVersionSendsFullNoteAndReturnsMergedResult {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionaryWithObject:@"merged" forKey:@"content"],
					 [NSDictionary dictionaryWithObject:@"8" forKey:@"X-Simperium-Version"]);
	}];
	NSDictionary *note = [NSDictionary dictionaryWithObjectsAndKeys:@"mine", @"content", [NSArray arrayWithObject:@"pinned"], @"systemTags", nil];
	NSInteger version = 0;
	NSDictionary *result = [service postNoteWithID:@"a1" data:note baseVersion:6 version:&version error:NULL];

	NSURLRequest *request = [self lastRequest];
	XCTAssertEqualObjects([request HTTPMethod], @"POST");
	XCTAssertEqualObjects([[request URL] path], @"/1/chalk-bump-f49/note/i/a1/v/6");
	NSDictionary *query = QueryOf([request URL]);
	XCTAssertEqualObjects([query objectForKey:@"clientid"], @"nvalt-test");
	XCTAssertEqualObjects([query objectForKey:@"response"], @"1");
	XCTAssertEqual([[query objectForKey:@"ccid"] length], (NSUInteger)36);
	XCTAssertEqualObjects([self lastJSONBody], note);
	XCTAssertEqualObjects([result objectForKey:@"content"], @"merged");
	XCTAssertEqual(version, (NSInteger)8);
}

- (void)testCreateHasNoVersionInPath {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionaryWithObject:@"new" forKey:@"content"], [NSDictionary dictionaryWithObject:@"1" forKey:@"X-Simperium-Version"]);
	}];
	[service postNoteWithID:@"new1" data:[NSDictionary dictionaryWithObject:@"new" forKey:@"content"] baseVersion:0 version:NULL error:NULL];
	XCTAssertEqualObjects([[[self lastRequest] URL] path], @"/1/chalk-bump-f49/note/i/new1");
}

- (void)testEmptyChangeReadsBackCurrentNote {
	__block NSUInteger calls = 0;
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		if (++calls == 1) return Reply(412, nil, nil);
		return Reply(200, [NSDictionary dictionaryWithObject:@"same" forKey:@"content"], [NSDictionary dictionaryWithObject:@"5" forKey:@"X-Simperium-Version"]);
	}];
	NSInteger version = 0;
	NSDictionary *result = [service postNoteWithID:@"a1" data:[NSDictionary dictionaryWithObject:@"same" forKey:@"content"] baseVersion:5 version:&version error:NULL];
	XCTAssertEqualObjects([result objectForKey:@"content"], @"same");
	XCTAssertEqual(version, (NSInteger)5);
	XCTAssertEqualObjects([[self lastRequest] HTTPMethod], @"GET");
}

- (void)testStatusMapping {
	NSDictionary *expected = [NSDictionary dictionaryWithObjectsAndKeys:
							  [NSNumber numberWithInteger:NVSimplenoteErrorUnauthorized], [NSNumber numberWithInt:401],
							  [NSNumber numberWithInteger:NVSimplenoteErrorNotFound], [NSNumber numberWithInt:404],
							  [NSNumber numberWithInteger:NVSimplenoteErrorTooLarge], [NSNumber numberWithInt:413],
							  [NSNumber numberWithInteger:NVSimplenoteErrorServer], [NSNumber numberWithInt:503], nil];
	for (NSNumber *status in expected) {
		[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) { return Reply([status integerValue], nil, nil); }];
		NSError *error = nil;
		XCTAssertNil([service postNoteWithID:@"a1" data:[NSDictionary dictionary] baseVersion:1 version:NULL error:&error]);
		XCTAssertEqual([error code], [[expected objectForKey:status] integerValue], @"HTTP %@", status);
	}
}

- (void)testMalformedJSONIsAServerError {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [@"<html>oops</html>" dataUsingEncoding:NSUTF8StringEncoding], nil);
	}];
	NSError *error = nil;
	XCTAssertNil([service indexPageAfterMark:nil limit:1 includeData:NO error:&error]);
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorServer);
}

- (void)testNoteIDsAreEscapedInPaths {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionary], [NSDictionary dictionaryWithObject:@"1" forKey:@"X-Simperium-Version"]);
	}];
	[service noteWithID:@"weird id?x" version:NULL error:NULL];
	XCTAssertEqualObjects([[[self lastRequest] URL] path], @"/1/chalk-bump-f49/note/i/weird id?x");
	XCTAssertNil([[[self lastRequest] URL] query]);
}

#pragma mark Sign-in

- (void)testRequestCodeIdentifiesAsNvALT {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) { return Reply(200, nil, nil); }];
	NSError *error = nil;
	XCTAssertTrue([authenticator requestCodeForEmail:@"me@example.com" error:&error]);
	NSURLRequest *request = [self lastRequest];
	XCTAssertEqualObjects([[request URL] absoluteString], @"https://app.simplenote.com/account/request-login");
	XCTAssertEqualObjects([self lastJSONBody], ([NSDictionary dictionaryWithObjectsAndKeys:@"me@example.com", @"username", @"nvalt", @"request_source", nil]));
	XCTAssertNil([request valueForHTTPHeaderField:@"X-Simperium-API-Key"]);
}

- (void)testCompleteLoginReturnsSyncToken {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) {
		return Reply(200, [NSDictionary dictionaryWithObjectsAndKeys:@"tok123", @"sync_token", @"me@example.com", @"username", nil], nil);
	}];
	NSString *token = [authenticator tokenForEmail:@"me@example.com" code:@" abc123\n" error:NULL];
	XCTAssertEqualObjects(token, @"tok123");
	XCTAssertEqualObjects([[[self lastRequest] URL] absoluteString], @"https://app.simplenote.com/account/complete-login");
	XCTAssertEqualObjects([self lastJSONBody], ([NSDictionary dictionaryWithObjectsAndKeys:@"me@example.com", @"username", @"ABC123", @"auth_code", nil]));
}

- (void)testBadCodeAndRateLimitErrors {
	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) { return Reply(400, [NSDictionary dictionary], nil); }];
	NSError *error = nil;
	XCTAssertNil([authenticator tokenForEmail:@"me@example.com" code:@"WRONG" error:&error]);
	XCTAssertEqual([error code], (NSInteger)NVSimplenoteErrorUnauthorized);

	[self stub:^NSDictionary *(NSURLRequest *request, NSData *body) { return Reply(429, nil, nil); }];
	XCTAssertFalse([authenticator requestCodeForEmail:@"me@example.com" error:&error]);
	XCTAssertTrue([[error localizedDescription] rangeOfString:@"Too many"].location != NSNotFound);
}

#pragma mark Keychain

- (void)testCredentialsRoundTrip {
	NSString *serviceName = [NSString stringWithFormat:@"nvALT tests %@", [[NSProcessInfo processInfo] globallyUniqueString]];
	NVSimplenoteCredentials *credentials = [[[NVSimplenoteCredentials alloc] initWithService:serviceName] autorelease];
	XCTAssertNil([credentials tokenForAccount:@"me@example.com"]);
	XCTAssertTrue([credentials setToken:@"first" forAccount:@"me@example.com"]);
	XCTAssertTrue([credentials setToken:@"second" forAccount:@"me@example.com"]);
	XCTAssertEqualObjects([credentials tokenForAccount:@"me@example.com"], @"second");
	[credentials removeTokenForAccount:@"me@example.com"];
	XCTAssertNil([credentials tokenForAccount:@"me@example.com"]);
}

@end
