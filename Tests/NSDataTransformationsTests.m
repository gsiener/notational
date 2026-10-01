//
//  NSDataTransformationsTests.m
//  NotationTests
//
//  Pins the byte-level behaviour of the primitives behind the notes database
//  and journal, so on-disk compatibility survives changes to their implementation.
//

#import <XCTest/XCTest.h>
#import "NSData_transformations.h"
#import "NSString_NV.h"

static NSData *DataFromHex(NSString *hex) {
	NSMutableData *data = [NSMutableData dataWithCapacity:[hex length] / 2];
	NSUInteger i;
	for (i = 0; i + 1 < [hex length]; i += 2) {
		unsigned int byte = 0;
		[[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
		unsigned char c = (unsigned char)byte;
		[data appendBytes:&c length:1];
	}
	return data;
}

static NSString *HexFromData(NSData *data) {
	NSMutableString *hex = [NSMutableString stringWithCapacity:[data length] * 2];
	const unsigned char *bytes = [data bytes];
	NSUInteger i;
	for (i = 0; i < [data length]; i++)
		[hex appendFormat:@"%02x", bytes[i]];
	return hex;
}

static NSData *Utf8(NSString *s) {
	return [s dataUsingEncoding:NSUTF8StringEncoding];
}

@interface NSDataTransformationsTests : XCTestCase
@end

@implementation NSDataTransformationsTests

#pragma mark AES-256-CBC

- (NSData *)aesKey {
	NSMutableData *key = [NSMutableData dataWithLength:32];
	unsigned char *bytes = [key mutableBytes];
	int i;
	for (i = 0; i < 32; i++) bytes[i] = (unsigned char)i;
	return key;
}

- (NSData *)aesIV {
	return [[self aesKey] subdataWithRange:NSMakeRange(0, 16)];
}

//expected ciphertexts produced by `openssl enc -aes-256-cbc -K 000102…1f -iv 000102…0f`
- (void)testAESEncryptionMatchesOpenSSL {
	NSDictionary *vectors = [NSDictionary dictionaryWithObjectsAndKeys:
							 @"e9c3ef8ab23453e6f0749cd636e7a88e", @"",
							 @"7fd12dafb7e9599d0b849ad8c2e3c21f", @"hello",
							 @"76a82f9689ba2e6c2cae97d63b539d05808b2333935e52c75905fb5fa2a799eb", @"exactly16bytes!!",
							 nil];
	for (NSString *plaintext in vectors) {
		NSMutableData *data = [[Utf8(plaintext) mutableCopy] autorelease];
		XCTAssertTrue([data encryptAESDataWithKey:[self aesKey] iv:[self aesIV]]);
		XCTAssertEqualObjects(HexFromData(data), [vectors objectForKey:plaintext], @"plaintext '%@'", plaintext);
	}
}

- (void)testAESRoundTrip {
	NSMutableString *long_ = [NSMutableString string];
	while ([long_ length] < 5000) [long_ appendString:@"Notational Velocity ✓ "];
	NSMutableData *data = [[Utf8(long_) mutableCopy] autorelease];
	XCTAssertTrue([data encryptAESDataWithKey:[self aesKey] iv:[self aesIV]]);
	XCTAssertTrue([data decryptAESDataWithKey:[self aesKey] iv:[self aesIV]]);
	XCTAssertEqualObjects(data, Utf8(long_));
}

- (void)testAESDecryptRejectsBadPadding {
	//random ciphertext decrypts to invalid PKCS#7 padding ~255/256 of the time; callers rely on that failure
	NSUInteger accepted = 0, trial;
	for (trial = 0; trial < 2000; trial++) {
		NSMutableData *garbage = [NSMutableData dataWithLength:64];
		arc4random_buf([garbage mutableBytes], 64);
		if ([garbage decryptAESDataWithKey:[self aesKey] iv:[self aesIV]]) accepted++;
	}
	XCTAssertLessThan(accepted, (NSUInteger)40);
}

- (void)testAESDecryptRejectsTruncatedCiphertext {
	NSMutableData *data = [[Utf8(@"hello world") mutableCopy] autorelease];
	XCTAssertTrue([data encryptAESDataWithKey:[self aesKey] iv:[self aesIV]]);
	[data setLength:[data length] - 1];
	XCTAssertFalse([data decryptAESDataWithKey:[self aesKey] iv:[self aesIV]]);
}

- (void)testAESRejectsWrongKeyAndIVLengths {
	NSMutableData *data = [[Utf8(@"hello") mutableCopy] autorelease];
	XCTAssertFalse([data encryptAESDataWithKey:[NSMutableData dataWithLength:16] iv:[self aesIV]]);
	XCTAssertFalse([data encryptAESDataWithKey:[self aesKey] iv:[NSMutableData dataWithLength:8]]);
	XCTAssertEqualObjects(data, Utf8(@"hello"));
}

#pragma mark Key derivation (RFC 6070 PBKDF2-HMAC-SHA1 vectors)

- (void)testPBKDF2MatchesRFC6070 {
	XCTAssertEqualObjects(HexFromData([Utf8(@"password") derivedKeyOfLength:20 salt:Utf8(@"salt") iterations:1]),
						  @"0c60c80f961f0e71f3a9b524af6012062fe037a6");
	XCTAssertEqualObjects(HexFromData([Utf8(@"password") derivedKeyOfLength:20 salt:Utf8(@"salt") iterations:2]),
						  @"ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957");
	XCTAssertEqualObjects(HexFromData([Utf8(@"password") derivedKeyOfLength:20 salt:Utf8(@"salt") iterations:4096]),
						  @"4b007901b765489abead49d926f721d065a429c1");
	XCTAssertEqualObjects(HexFromData([Utf8(@"passwordPASSWORDpassword") derivedKeyOfLength:25
																	   salt:Utf8(@"saltSALTsaltSALTsaltSALTsaltSALTsalt") iterations:4096]),
						  @"3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038");
	XCTAssertEqualObjects(HexFromData([DataFromHex(@"7061737300776f7264") derivedKeyOfLength:16
																			   salt:DataFromHex(@"7361006c74") iterations:4096]),
						  @"56fa6aa75548099dcc37d7f03425e0c3");
}

- (void)testPBKDF2ProducesAES256KeyLength {
	XCTAssertEqual([[Utf8(@"pass") derivedKeyOfLength:32 salt:Utf8(@"salt") iterations:10] length], (NSUInteger)32);
}

#pragma mark Digests and checksums

- (void)testSHA1Digest {
	XCTAssertEqualObjects(HexFromData([Utf8(@"abc") SHA1Digest]), @"a9993e364706816aba3e25717850c26c9cd0d89d");
	XCTAssertEqualObjects(HexFromData([[NSData data] SHA1Digest]), @"da39a3ee5e6b4b0d3255bfef95601890afd80709");
}

- (void)testMD5Digest {
	XCTAssertEqualObjects(HexFromData([Utf8(@"hello") MD5Digest]), @"5d41402abc4b2a76b9719d911017c592");
}

- (void)testCRC32 {
	XCTAssertEqual([Utf8(@"123456789") CRC32], (unsigned long)0xcbf43926);
	XCTAssertEqual([[NSData data] CRC32], (unsigned long)0);
}

#pragma mark Base64

- (void)testBase64WithoutNewlines {
	XCTAssertEqualObjects([Utf8(@"hello world") encodeBase64WithNewlines:NO], @"aGVsbG8gd29ybGQ=");
	XCTAssertEqualObjects([@"aGVsbG8gd29ybGQ=" decodeBase64WithNewlines:NO], Utf8(@"hello world"));
}

- (void)testBase64WithNewlinesMatchesOpenSSLLayout {
	NSString *encoded = [[NSMutableData dataWithLength:100] encodeBase64WithNewlines:YES];
	NSArray *lines = [encoded componentsSeparatedByString:@"\n"];
	XCTAssertEqual([[lines objectAtIndex:0] length], (NSUInteger)64);
	XCTAssertTrue([encoded hasSuffix:@"\n"]);
	XCTAssertEqualObjects([encoded decodeBase64WithNewlines:YES], [NSMutableData dataWithLength:100]);
}

- (void)testBase64DecodeOfGarbageIsEmptyNotNil {
	NSData *decoded = [@"%%%not base64%%%" decodeBase64WithNewlines:NO];
	XCTAssertNotNil(decoded);
	XCTAssertEqual([decoded length], (NSUInteger)0);
}

#pragma mark Compression

- (void)testCompressionRoundTrip {
	NSMutableString *text = [NSMutableString string];
	while ([text length] < 10000) [text appendString:@"compress me "];
	NSMutableData *compressed = [Utf8(text) compressedData];
	XCTAssertTrue([compressed isCompressedFormat]);
	XCTAssertLessThan([compressed length], [Utf8(text) length]);
	XCTAssertEqualObjects([compressed uncompressedData], Utf8(text));
}

@end
