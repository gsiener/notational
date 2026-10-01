//
//  NVSimplenoteHTTPService.m
//  Notation
//

#import "NVSimplenoteHTTPService.h"
#import <Security/Security.h>

static NSString *const SimperiumAppID = @"chalk-bump-f49";
static NSString *const NoteBucket = @"note";
static NSTimeInterval const RequestTimeout = 60.0;

static NSError *SimplenoteError(NSInteger code, NSString *description) {
	NSDictionary *info = description ? [NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey] : nil;
	return [NSError errorWithDomain:NVSimplenoteErrorDomain code:code userInfo:info];
}

static NSString *UserAgent(void) {
	NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
	return [NSString stringWithFormat:@"Notational/%@", version ? version : @"dev"];
}

static NSString *QueryEscape(NSString *value) {
	NSMutableCharacterSet *allowed = [[[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy] autorelease];
	[allowed removeCharactersInString:@"&=+?/"];
	return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSString *PathEscape(NSString *value) {
	return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
}

//Performs a request synchronously. Returns the response body (possibly empty) or nil on a transport error.
static NSData *PerformRequest(NSURLSession *session, NSURLRequest *request, NSHTTPURLResponse **outResponse, NSError **error) {
	__block NSData *body = nil;
	__block NSHTTPURLResponse *response = nil;
	__block NSError *transportError = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
		body = [data retain];
		response = [(NSHTTPURLResponse *)r retain];
		transportError = [e retain];
		dispatch_semaphore_signal(done);
	}];
	[task resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	dispatch_release(done);
	[body autorelease];
	[response autorelease];
	[transportError autorelease];

	if (outResponse) *outResponse = response;
	if (transportError || !response) {
		if (error) *error = SimplenoteError(NVSimplenoteErrorNetwork, [transportError localizedDescription]);
		return nil;
	}
	return body ? body : [NSData data];
}

static id JSONFromData(NSData *data) {
	if (![data length]) return nil;
	return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

#pragma mark -

@interface NVSimplenoteHTTPService () {
	NSString *token;
	NSString *clientID;
	NSURLSession *session;
	NSURL *baseURL;
}
@end

@implementation NVSimplenoteHTTPService

- (id)initWithToken:(NSString *)aToken clientID:(NSString *)aClientID {
	return [self initWithToken:aToken clientID:aClientID configuration:nil baseURL:nil];
}

- (id)initWithToken:(NSString *)aToken clientID:(NSString *)aClientID
	  configuration:(NSURLSessionConfiguration *)configuration baseURL:(NSURL *)aBaseURL {
	if ((self = [super init])) {
		token = [aToken copy];
		clientID = [aClientID copy];
		NSURLSessionConfiguration *config = configuration ? configuration : [NSURLSessionConfiguration ephemeralSessionConfiguration];
		[config setTimeoutIntervalForRequest:RequestTimeout];
		session = [[NSURLSession sessionWithConfiguration:config] retain];
		baseURL = [(aBaseURL ? aBaseURL : [NSURL URLWithString:[NSString stringWithFormat:@"https://api.simperium.com/1/%@/%@/",
																	SimperiumAppID, NoteBucket]]) retain];
	}
	return self;
}

- (void)dealloc {
	[session invalidateAndCancel];
	[session release];
	[token release];
	[clientID release];
	[baseURL release];
	[super dealloc];
}

- (NSMutableURLRequest *)requestForPath:(NSString *)path query:(NSDictionary *)query {
	NSMutableString *spec = [NSMutableString stringWithString:path];
	if ([query count]) {
		NSMutableArray *pairs = [NSMutableArray array];
		for (NSString *key in [[query allKeys] sortedArrayUsingSelector:@selector(compare:)])
			[pairs addObject:[NSString stringWithFormat:@"%@=%@", key, QueryEscape([[query objectForKey:key] description])]];
		[spec appendFormat:@"?%@", [pairs componentsJoinedByString:@"&"]];
	}
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:spec relativeToURL:baseURL]];
	[request setValue:token forHTTPHeaderField:@"X-Simperium-Token"];
	[request setValue:UserAgent() forHTTPHeaderField:@"User-Agent"];
	return request;
}

//maps an HTTP status to the port's errors; returns YES for success
static BOOL CheckStatus(NSHTTPURLResponse *response, NSError **error) {
	NSInteger status = [response statusCode];
	if (status >= 200 && status < 300) return YES;
	NSInteger code;
	switch (status) {
		case 401: case 403: code = NVSimplenoteErrorUnauthorized; break;
		case 404: code = NVSimplenoteErrorNotFound; break;
		case 413: code = NVSimplenoteErrorTooLarge; break;
		default: code = NVSimplenoteErrorServer; break;
	}
	if (error) *error = SimplenoteError(code, [NSString stringWithFormat:@"Simplenote returned HTTP %ld", (long)status]);
	return NO;
}

- (NVIndexPage *)indexPageAfterMark:(NSString *)mark limit:(NSUInteger)limit includeData:(BOOL)includeData error:(NSError **)error {
	NSMutableDictionary *query = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:limit] forKey:@"limit"];
	if (mark) [query setObject:mark forKey:@"mark"];
	if (includeData) [query setObject:@"1" forKey:@"data"];
	NSHTTPURLResponse *response = nil;
	NSData *body = PerformRequest(session, [self requestForPath:@"index" query:query], &response, error);
	if (!body || !CheckStatus(response, error)) return nil;

	NSDictionary *json = JSONFromData(body);
	if (![json isKindOfClass:[NSDictionary class]] || ![[json objectForKey:@"index"] isKindOfClass:[NSArray class]]) {
		if (error) *error = SimplenoteError(NVSimplenoteErrorServer, @"Malformed index response");
		return nil;
	}
	NSMutableArray *notes = [NSMutableArray array];
	for (NSDictionary *entry in [json objectForKey:@"index"]) {
		if (![entry isKindOfClass:[NSDictionary class]] || ![[entry objectForKey:@"id"] isKindOfClass:[NSString class]]) continue;
		id data = [entry objectForKey:@"d"];
		[notes addObject:[NVRemoteNote noteWithID:[entry objectForKey:@"id"]
										  version:[[entry objectForKey:@"v"] integerValue]
											 data:[data isKindOfClass:[NSDictionary class]] ? data : nil]];
	}
	NVIndexPage *page = [[[NVIndexPage alloc] init] autorelease];
	[page setNotes:notes];
	id nextMark = [json objectForKey:@"mark"];
	[page setNextMark:[nextMark isKindOfClass:[NSString class]] && [nextMark length] ? nextMark : nil];
	id current = [json objectForKey:@"current"];
	[page setChangeVersion:[current isKindOfClass:[NSString class]] ? current : nil];
	return page;
}

- (NSArray *)changesSince:(NSString *)changeVersion error:(NSError **)error {
	NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:changeVersion ? changeVersion : @"", @"cv",
						   clientID, @"clientid", @"0", @"wait", nil];
	NSHTTPURLResponse *response = nil;
	NSData *body = PerformRequest(session, [self requestForPath:@"changes" query:query], &response, error);
	if (!body) return nil;
	NSInteger status = [response statusCode];
	if (status == 400 || status == 404) {
		//the server no longer knows this change version
		if (error) *error = SimplenoteError(NVSimplenoteErrorUnknownChangeVersion, @"Unknown change version");
		return nil;
	}
	if (!CheckStatus(response, error)) return nil;

	id json = JSONFromData(body);
	if (!json && ![body length]) return [NSArray array];
	if (![json isKindOfClass:[NSArray class]]) {
		if (error) *error = SimplenoteError(NVSimplenoteErrorServer, @"Malformed changes response");
		return nil;
	}
	NSMutableArray *changes = [NSMutableArray array];
	for (NSDictionary *entry in json) {
		if (![entry isKindOfClass:[NSDictionary class]] || ![[entry objectForKey:@"id"] isKindOfClass:[NSString class]]) continue;
		NVRemoteChange *change = [[[NVRemoteChange alloc] init] autorelease];
		[change setNoteID:[entry objectForKey:@"id"]];
		[change setChangeVersion:[[entry objectForKey:@"cv"] description]];
		[change setRemoved:[@"-" isEqual:[entry objectForKey:@"o"]]];
		[change setVersion:[[entry objectForKey:@"ev"] integerValue]];
		id data = [entry objectForKey:@"d"];
		if ([data isKindOfClass:[NSDictionary class]]) [change setData:data];
		[changes addObject:change];
	}
	return changes;
}

- (NSDictionary *)noteWithID:(NSString *)noteID version:(NSInteger *)version error:(NSError **)error {
	NSHTTPURLResponse *response = nil;
	NSString *path = [NSString stringWithFormat:@"i/%@", PathEscape(noteID)];
	NSData *body = PerformRequest(session, [self requestForPath:path query:nil], &response, error);
	if (!body || !CheckStatus(response, error)) return nil;
	NSDictionary *json = JSONFromData(body);
	if (![json isKindOfClass:[NSDictionary class]]) {
		if (error) *error = SimplenoteError(NVSimplenoteErrorServer, @"Malformed note response");
		return nil;
	}
	if (version) *version = [[[response allHeaderFields] objectForKey:@"X-Simperium-Version"] integerValue];
	return json;
}

- (NSDictionary *)postNoteWithID:(NSString *)noteID data:(NSDictionary *)data baseVersion:(NSInteger)baseVersion
						 version:(NSInteger *)newVersion error:(NSError **)error {
	NSString *path = baseVersion > 0 ? [NSString stringWithFormat:@"i/%@/v/%ld", PathEscape(noteID), (long)baseVersion]
									 : [NSString stringWithFormat:@"i/%@", PathEscape(noteID)];
	NSString *ccid = [[[NSUUID UUID] UUIDString] lowercaseString];
	NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:clientID, @"clientid", ccid, @"ccid", @"1", @"response", nil];
	NSMutableURLRequest *request = [self requestForPath:path query:query];
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	NSData *payload = [NSJSONSerialization dataWithJSONObject:data options:0 error:NULL];
	if (!payload) {
		if (error) *error = SimplenoteError(NVSimplenoteErrorServer, @"Note could not be encoded");
		return nil;
	}
	[request setHTTPBody:payload];

	NSHTTPURLResponse *response = nil;
	NSData *body = PerformRequest(session, request, &response, error);
	if (!body) return nil;
	NSInteger status = [response statusCode];
	if (status == 412 || status == 409) {
		//412: nothing to change; 409: this change was already applied. Either way, read back the current note.
		return [self noteWithID:noteID version:newVersion error:error];
	}
	if (!CheckStatus(response, error)) return nil;

	NSDictionary *json = JSONFromData(body);
	NSInteger version = [[[response allHeaderFields] objectForKey:@"X-Simperium-Version"] integerValue];
	if (![json isKindOfClass:[NSDictionary class]] || version <= 0) {
		//no echo or version: read the authoritative copy
		return [self noteWithID:noteID version:newVersion error:error];
	}
	if (newVersion) *newVersion = version;
	return json;
}

@end

#pragma mark -

@interface NVSimplenoteAuthenticator () {
	NSURLSession *session;
	NSURL *baseURL;
}
@end

@implementation NVSimplenoteAuthenticator

+ (NSString *)requestSource {
	return @"nvalt";
}

- (id)init {
	return [self initWithConfiguration:nil baseURL:nil];
}

- (id)initWithConfiguration:(NSURLSessionConfiguration *)configuration baseURL:(NSURL *)aBaseURL {
	if ((self = [super init])) {
		NSURLSessionConfiguration *config = configuration ? configuration : [NSURLSessionConfiguration ephemeralSessionConfiguration];
		[config setTimeoutIntervalForRequest:RequestTimeout];
		session = [[NSURLSession sessionWithConfiguration:config] retain];
		baseURL = [(aBaseURL ? aBaseURL : [NSURL URLWithString:@"https://app.simplenote.com/account/"]) retain];
	}
	return self;
}

- (void)dealloc {
	[session invalidateAndCancel];
	[session release];
	[baseURL release];
	[super dealloc];
}

- (NSDictionary *)postJSON:(NSDictionary *)payload toPath:(NSString *)path status:(NSInteger *)status error:(NSError **)error {
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:path relativeToURL:baseURL]];
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	[request setValue:UserAgent() forHTTPHeaderField:@"User-Agent"];
	[request setHTTPBody:[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL]];
	NSHTTPURLResponse *response = nil;
	NSData *body = PerformRequest(session, request, &response, error);
	if (!body) return nil;
	if (status) *status = [response statusCode];
	id json = JSONFromData(body);
	return [json isKindOfClass:[NSDictionary class]] ? json : [NSDictionary dictionary];
}

static NSError *SignInError(NSInteger status) {
	if (status == 429) return SimplenoteError(NVSimplenoteErrorServer, NSLocalizedString(@"Too many sign-in attempts. Wait a few minutes and try again.", nil));
	if (status == 400 || status == 401 || status == 403)
		return SimplenoteError(NVSimplenoteErrorUnauthorized, NSLocalizedString(@"That code didn't work. Check the latest email from Simplenote and try again.", nil));
	return SimplenoteError(NVSimplenoteErrorServer, [NSString stringWithFormat:NSLocalizedString(@"Simplenote returned an error (HTTP %ld).", nil), (long)status]);
}

- (BOOL)requestCodeForEmail:(NSString *)email error:(NSError **)error {
	NSInteger status = 0;
	NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:email, @"username", [[self class] requestSource], @"request_source", nil];
	if (![self postJSON:payload toPath:@"request-login" status:&status error:error]) return NO;
	if (status < 200 || status >= 300) {
		if (error) *error = SignInError(status);
		return NO;
	}
	return YES;
}

- (NSString *)tokenForEmail:(NSString *)email code:(NSString *)code error:(NSError **)error {
	NSString *normalized = [[code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
	NSInteger status = 0;
	NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:email, @"username", normalized, @"auth_code", nil];
	NSDictionary *json = [self postJSON:payload toPath:@"complete-login" status:&status error:error];
	if (!json) return nil;
	NSString *token = [json objectForKey:@"sync_token"];
	if (status < 200 || status >= 300 || ![token isKindOfClass:[NSString class]] || ![token length]) {
		if (error) *error = SignInError(status >= 200 && status < 300 ? 500 : status);
		return nil;
	}
	return token;
}

@end

#pragma mark -

@interface NVSimplenoteCredentials () {
	NSString *service;
}
@end

@implementation NVSimplenoteCredentials

+ (NVSimplenoteCredentials *)defaultCredentials {
	return [[[NVSimplenoteCredentials alloc] initWithService:@"Notational Simplenote sync"] autorelease];
}

- (id)initWithService:(NSString *)aService {
	if ((self = [super init])) {
		service = [aService copy];
	}
	return self;
}

- (void)dealloc {
	[service release];
	[super dealloc];
}

- (NSMutableDictionary *)queryForAccount:(NSString *)email {
	return [NSMutableDictionary dictionaryWithObjectsAndKeys:
			(id)kSecClassGenericPassword, (id)kSecClass,
			service, (id)kSecAttrService,
			email, (id)kSecAttrAccount, nil];
}

- (NSString *)tokenForAccount:(NSString *)email {
	if (![email length]) return nil;
	NSMutableDictionary *query = [self queryForAccount:email];
	[query setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];
	[query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];
	CFTypeRef result = NULL;
	if (SecItemCopyMatching((CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
	NSString *token = [[[NSString alloc] initWithData:(NSData *)result encoding:NSUTF8StringEncoding] autorelease];
	CFRelease(result);
	return token;
}

- (BOOL)setToken:(NSString *)token forAccount:(NSString *)email {
	if (![email length] || ![token length]) return NO;
	NSData *secret = [token dataUsingEncoding:NSUTF8StringEncoding];
	NSDictionary *update = [NSDictionary dictionaryWithObject:secret forKey:(id)kSecValueData];
	OSStatus status = SecItemUpdate((CFDictionaryRef)[self queryForAccount:email], (CFDictionaryRef)update);
	if (status == errSecItemNotFound) {
		NSMutableDictionary *item = [self queryForAccount:email];
		[item setObject:secret forKey:(id)kSecValueData];
		[item setObject:@"Simplenote sync token used by nvALT" forKey:(id)kSecAttrDescription];
		status = SecItemAdd((CFDictionaryRef)item, NULL);
	}
	if (status != errSecSuccess) NSLog(@"NVSimplenoteCredentials: could not store token: %d", (int)status);
	return status == errSecSuccess;
}

- (void)removeTokenForAccount:(NSString *)email {
	if (![email length]) return;
	SecItemDelete((CFDictionaryRef)[self queryForAccount:email]);
}

@end
