//
//  AlienNoteImporterTests.m
//  Importing a file makes a note whose content is the file's text (#29).
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "AlienNoteImporter.h"
#import "NoteObject.h"
#import "NoteObject_NVRecord.h"
#import "NVNoteRecord.h"

@interface AlienNoteImporterTests : NVTestCase
@end

@implementation AlienNoteImporterTests

- (NSString *)importedContentOfFile:(NSString *)name text:(NSString *)text {
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:name];
	XCTAssertTrue([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
	AlienNoteImporter *importer = [[AlienNoteImporter alloc] initWithStoragePath:path];
	NoteObject *note = [importer noteWithFile:path];
	XCTAssertNotNil(note);
	return [[note noteRecordRepresentation] content];
}

- (void)testFirstLineBecomesTheTitleWithoutRepeating {
	NSString *text = @"A first line longer than the file name\nsecond line\n\nthird paragraph";
	XCTAssertEqualObjects([self importedContentOfFile:@"short.txt" text:text], text);
}

- (void)testLongFirstLineIsKeptWhole {
	NSString *text = @"# A heading that runs well past the thirty-six characters of a synthetic title\nbody";
	XCTAssertEqualObjects([self importedContentOfFile:@"x.txt" text:text], text);
}

- (void)testFileNameTitlesANoteWhoseFirstLineIsShorter {
	//nvALT's one-file-per-note folders: the file name is the title, the file holds the body
	XCTAssertEqualObjects([self importedContentOfFile:@"Shopping list.txt" text:@"eggs\nmilk"], @"Shopping list\neggs\nmilk");
}

- (void)testBlorIsUnsupportedNotImportedAsTextAndOriginalIsPreserved {
	//Blor import was removed (#42); a .blor file must still not turn into a garbage text note
	NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"NotationalDatabase.blor"];
	NSData *original = [@"short invalid Blor" dataUsingEncoding:NSUTF8StringEncoding];
	XCTAssertTrue([original writeToFile:path atomically:YES]);
	AlienNoteImporter *importer = [[AlienNoteImporter alloc] initWithStoragePath:path];
	XCTAssertNil([importer notesInFile:path]);
	XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], original);
}

@end
