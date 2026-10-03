//
//  NVHereNowMixedListTests.m
//  NotationTests
//
//  here.now Sites interleave with Notes by the Notes list's sort, and every row maps back to
//  the right Note however the Sites fall among them.
//

#import <XCTest/XCTest.h>
#import "NVTestSupport.h"
#import "NVHereNowSites.h"
#import "NoteObject.h"
#import "NoteAttributeColumn.h"
#import "GlobalPrefs.h"
#import "UnifiedCell.h"
#import "LabelColumnCell.h"
#import "NSString_NV.h"
#import "AppController.h"
#import "NotationController.h"
#import "NotesTableView.h"

@interface NVHereNowSites (MixedListTests)
- (NSArray *)sitesFromRows:(NSArray *)rows accountID:(NSString *)accountID;
@end

@interface AppController (MixedListTests)
- (void)hereNowSitesChanged:(NSNotification *)notification;
@end

//the sort the Notes list is set to, without reading anyone's defaults
@interface FakeSortPrefs : GlobalPrefs
@property(copy) NSString *fakeSortKey;
@property(assign) BOOL fakeReversed;
@end
@implementation FakeSortPrefs
- (NSString *)sortedTableColumnKey { return self.fakeSortKey; }
- (BOOL)tableIsReverseSorted { return self.fakeReversed; }
@end

//the list changes as Notes are deleted; NotesTableView would keep its scroll position
@interface ListTable : NSTableView
@end
@implementation ListTable
- (ViewLocationContext)viewingLocation { ViewLocationContext location = {0}; return location; }
- (void)setViewingLocation:(ViewLocationContext)location { (void)location; }
@end

static const CFAbsoluteTime T = 800000000;
static NSMutableArray *Kept;   //AppControllers and prefs made without -init: their -dealloc expects a launched app

@interface NVHereNowMixedListTests : XCTestCase {
	NoteObject *alpha, *charlie, *echo;
	NVHereNowSite *bravo, *delta, *foxtrot;
	FastListDataSource *notes;
}
@end

@implementation NVHereNowMixedListTests

- (void)setUp {
	[super setUp];
	if (!Kept) Kept = [NSMutableArray array];
	alpha = NVTestNote(@"alpha", @"a", @"work");
	charlie = NVTestNote(@"Charlie", @"c", @"");
	echo = NVTestNote(@"echo", @"e", @"home");
	[alpha setDateModified:T + 300]; [alpha setDateAdded:T + 10];
	[charlie setDateModified:T + 100]; [charlie setDateAdded:T + 30];
	[echo setDateModified:T + 200]; [echo setDateAdded:T + 20];
	bravo = [self site:@"Bravo" modified:T + 250];
	delta = [self site:@"delta" modified:T + 50];
	foxtrot = [self site:@"Foxtrot" modified:0];   //a cache from before dates were kept
	notes = [FastListDataSource new];
}

- (NVHereNowSite *)site:(NSString *)title modified:(CFAbsoluteTime)modified {
	NVHereNowSite *site = [NVHereNowSite new];
	site.identity = [@"account:owned:" stringByAppendingString:title];
	site.title = title;
	site.searchText = [title lowercaseString];
	site.URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@.here.now/", [title lowercaseString]]];
	if (modified) site.modifiedDate = [NSDate dateWithTimeIntervalSinceReferenceDate:modified];
	return site;
}

//the Notes in the order NotationController sorts them: by title, then stably by the column
- (void)sortNotesBy:(NSString *)key reversed:(BOOL)reversed {
	NSDictionary *functions = @{ NoteTitleColumnString: @[[NSValue valueWithPointer:compareTitleString], [NSValue valueWithPointer:compareTitleStringReverse]],
								 NoteLabelsColumnString: @[[NSValue valueWithPointer:compareLabelString], [NSValue valueWithPointer:compareLabelStringReverse]],
								 NoteDateModifiedColumnString: @[[NSValue valueWithPointer:compareDateModified], [NSValue valueWithPointer:compareDateModifiedReverse]],
								 NoteDateCreatedColumnString: @[[NSValue valueWithPointer:compareDateCreated], [NSValue valueWithPointer:compareDateCreatedReverse]] };
	typedef NSInteger (*Compare)(__unsafe_unretained id *, __unsafe_unretained id *);
	Compare title = reversed ? compareTitleStringReverse : compareTitleString;
	Compare column = (Compare)[functions[key][reversed ? 1 : 0] pointerValue];
	[notes fillArrayFromArray:@[alpha, charlie, echo]];
	[notes sortStableUsingFunction:title];
	if (column != title) [notes sortStableUsingFunction:column];
}

- (NVHereNowMixedList *)mixedSortedBy:(NSString *)key reversed:(BOOL)reversed search:(NSString *)search {
	[self sortNotesBy:key reversed:reversed];
	NVHereNowMixedList *mixed = [NVHereNowMixedList new];
	mixed.sites = @[bravo, delta, foxtrot];
	[mixed setNotes:notes sortKey:key reversed:reversed search:search];
	return mixed;
}

- (NSArray *)titlesOf:(NVHereNowMixedList *)mixed {
	NSMutableArray *titles = [NSMutableArray array];
	for (NSUInteger row = 0; row < mixed.count; ++row) {
		NVHereNowSite *site = [mixed siteAtRow:(NSInteger)row];
		[titles addObject:site ? site.title : titleOfNote([mixed noteAtRow:(NSInteger)row])];
	}
	return titles;
}

#pragma mark ordering

- (void)testSitesInterleaveByEverySortKeyAndDirection {
	NSDictionary *expected = @{
		//undated Sites list last either way
		NoteDateModifiedColumnString: @[@[@"delta", @"Charlie", @"echo", @"Bravo", @"alpha", @"Foxtrot"],
										@[@"alpha", @"Bravo", @"echo", @"Charlie", @"delta", @"Foxtrot"]],
		//the list has no creation time: every Site is undated, so they follow the Notes, by title
		NoteDateCreatedColumnString: @[@[@"alpha", @"echo", @"Charlie", @"Bravo", @"delta", @"Foxtrot"],
									   @[@"Charlie", @"echo", @"alpha", @"Foxtrot", @"delta", @"Bravo"]],
		//case-insensitive, as compareTitleString
		NoteTitleColumnString: @[@[@"alpha", @"Bravo", @"Charlie", @"delta", @"echo", @"Foxtrot"],
								 @[@"Foxtrot", @"echo", @"delta", @"Charlie", @"Bravo", @"alpha"]],
		//Sites have no tags, so they sit with the untagged Notes, by title
		NoteLabelsColumnString: @[@[@"Bravo", @"Charlie", @"delta", @"Foxtrot", @"echo", @"alpha"],
								  @[@"alpha", @"echo", @"Foxtrot", @"delta", @"Charlie", @"Bravo"]] };
	for (NSString *key in expected) {
		for (NSUInteger reversed = 0; reversed < 2; ++reversed) {
			NVHereNowMixedList *mixed = [self mixedSortedBy:key reversed:reversed search:nil];
			XCTAssertEqualObjects([self titlesOf:mixed], expected[key][reversed], @"%@%@", key, reversed ? @" reversed" : @"");
			XCTAssertEqual(mixed.noteRowCount, (NSUInteger)3);
		}
	}
}

- (void)testSortChangesReMergeTheSameRows {
	NVHereNowMixedList *mixed = [self mixedSortedBy:NoteDateModifiedColumnString reversed:YES search:nil];
	XCTAssertEqual([mixed rowForSiteIdentity:bravo.identity], (NSUInteger)1);
	[self sortNotesBy:NoteTitleColumnString reversed:NO];
	[mixed setSortKey:NoteTitleColumnString reversed:NO];
	XCTAssertEqualObjects([self titlesOf:mixed], (@[@"alpha", @"Bravo", @"Charlie", @"delta", @"echo", @"Foxtrot"]));
}

- (void)testWithoutASortSitesFollowTheNotes {
	[notes fillArrayFromArray:@[alpha, charlie, echo]];
	NVHereNowMixedList *mixed = [NVHereNowMixedList new];
	mixed.notes = notes; mixed.sites = @[bravo, delta, foxtrot];
	XCTAssertEqualObjects([self titlesOf:mixed], (@[@"alpha", @"Charlie", @"echo", @"Bravo", @"delta", @"Foxtrot"]));
}

- (void)testSearchKeepsTheInterleaving {
	NVHereNowMixedList *mixed = [self mixedSortedBy:NoteDateModifiedColumnString reversed:YES search:@"o"];
	XCTAssertEqualObjects([self titlesOf:mixed], (@[@"alpha", @"Bravo", @"echo", @"Charlie", @"Foxtrot"]));
	[mixed filterSitesForString:@"del"];
	XCTAssertEqualObjects([self titlesOf:mixed], (@[@"alpha", @"echo", @"Charlie", @"delta"]));
	[mixed filterSitesForString:@""];
	XCTAssertEqualObjects([self titlesOf:mixed], (@[@"alpha", @"Bravo", @"echo", @"Charlie", @"delta", @"Foxtrot"]));
}

#pragma mark mapping

- (void)testRowsMapToNotesAroundASiteInTheMiddle {
	//alpha, Bravo, echo, Charlie, delta, Foxtrot
	NVHereNowMixedList *mixed = [self mixedSortedBy:NoteDateModifiedColumnString reversed:YES search:nil];
	XCTAssertEqual([mixed noteAtRow:0], alpha);
	XCTAssertNil([mixed noteAtRow:1]);
	XCTAssertEqual([mixed siteAtRow:1], bravo);
	XCTAssertEqual([mixed noteAtRow:2], echo);
	XCTAssertNil([mixed siteAtRow:2]);
	XCTAssertNil([mixed noteAtRow:-1]);
	XCTAssertNil([mixed noteAtRow:6]);
	XCTAssertNil([mixed siteAtRow:6]);

	XCTAssertEqual([mixed rowForNote:echo], (NSUInteger)2);
	XCTAssertEqual([mixed rowForNote:charlie], (NSUInteger)3);
	XCTAssertEqual([mixed rowForNote:NVTestNote(@"unlisted", @"", nil)], (NSUInteger)NSNotFound);
	XCTAssertEqual([mixed rowForNote:(id)bravo], (NSUInteger)NSNotFound);
	XCTAssertEqual([mixed noteIndexForRow:2], (NSUInteger)1);
	XCTAssertEqual([mixed noteIndexForRow:1], (NSUInteger)NSNotFound);
	XCTAssertEqual([mixed rowForNoteIndex:1], (NSUInteger)2);
	XCTAssertEqual([mixed rowForNoteIndex:3], (NSUInteger)NSNotFound);
	XCTAssertEqual([mixed rowForSiteIdentity:delta.identity], (NSUInteger)4);

	NSIndexSet *firstThree = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)];
	XCTAssertEqualObjects([mixed notesAtRows:firstThree], (@[alpha, echo]));
	XCTAssertEqualObjects([mixed objectsAtFilteredIndexes:firstThree], (@[alpha, echo]), @"Notes callers never get a Site");
	NSMutableIndexSet *expected = [NSMutableIndexSet indexSetWithIndex:0];
	[expected addIndex:3];
	XCTAssertEqualObjects(([mixed rowsForNotes:@[charlie, alpha]]), expected);
	XCTAssertEqual([mixed indexOfObjectIdenticalTo:bravo], (NSUInteger)1, @"a Site row can still be a scroll pivot");

	XCTAssertTrue([mixed selectionContainsSite:[NSIndexSet indexSetWithIndex:1]]);
	XCTAssertTrue([mixed selectionContainsSite:firstThree]);
	NSMutableIndexSet *notesAroundSite = [NSMutableIndexSet indexSetWithIndex:0];
	[notesAroundSite addIndex:2];
	XCTAssertFalse([mixed selectionContainsSite:notesAroundSite]);
	XCTAssertFalse([mixed selectionContainsSite:[NSIndexSet indexSet]]);
}

#pragma mark dates

- (void)testSiteRowsShowDatesFormattedAsNotesAre {
	NVHereNowMixedList *mixed = [self mixedSortedBy:NoteDateModifiedColumnString reversed:YES search:nil];
	NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
	NoteAttributeColumn *modified = [[NoteAttributeColumn alloc] initWithIdentifier:NoteDateModifiedColumnString];
	[modified setDereferencingFunction:dateModifiedStringOfNote];
	NoteAttributeColumn *created = [[NoteAttributeColumn alloc] initWithIdentifier:NoteDateCreatedColumnString];
	[created setDereferencingFunction:dateCreatedStringOfNote];

	XCTAssertEqualObjects([mixed tableView:table objectValueForTableColumn:modified row:1], [NSString relativeDateStringWithAbsoluteTime:T + 250]);
	XCTAssertEqualObjects([mixed tableView:table objectValueForTableColumn:modified row:2], [NSString relativeDateStringWithAbsoluteTime:T + 200], @"the Note after the Site");
	XCTAssertEqualObjects([mixed tableView:table objectValueForTableColumn:created row:1], @"", @"the list API has no creation time");
	XCTAssertEqualObjects([mixed tableView:table objectValueForTableColumn:modified row:5], @"", @"an undated Site");
}

- (void)testSiteRowsClearTheSharedCellsNote {
	NVHereNowMixedList *mixed = [self mixedSortedBy:NoteDateModifiedColumnString reversed:YES search:nil];
	NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
	NoteAttributeColumn *title = [[NoteAttributeColumn alloc] initWithIdentifier:NoteTitleColumnString];
	UnifiedCell *unified = [[UnifiedCell alloc] init];
	[unified setNoteObject:alpha];
	[title setDataCell:unified];
	NoteAttributeColumn *tags = [[NoteAttributeColumn alloc] initWithIdentifier:NoteLabelsColumnString];
	LabelColumnCell *labels = [[LabelColumnCell alloc] init];
	[labels setNoteObject:alpha];
	[tags setDataCell:labels];

	NSString *value = [mixed tableView:table objectValueForTableColumn:title row:1];
	XCTAssertTrue([value containsString:@"Bravo"], @"%@", value);
	XCTAssertNil([unified noteObject], @"the horizontal layout's cell would otherwise draw alpha's date and tags");
	XCTAssertEqualObjects([mixed tableView:table objectValueForTableColumn:tags row:1], @"");
	XCTAssertNil([labels noteObject]);
}

- (void)testListParsesSiteDatesAndOldCachesLoadWithout {
	NVHereNowSites *service = [[NVHereNowSites alloc] initWithTransport:nil cacheURL:nil];
	NSArray *rows = @[ @{ @"slug": @"content", @"status": @"active", @"ownership": @"owned", @"siteUrl": @"https://content.here.now/",
						  @"contentUpdatedAt": @"2026-10-01T12:00:00.250Z", @"updatedAt": @"2026-10-02T00:00:00Z" },
					   @{ @"slug": @"settings", @"status": @"active", @"ownership": @"owned", @"siteUrl": @"https://settings.here.now/",
						  @"updatedAt": @"2026-09-01T08:30:00Z" },
					   //a cache row written before dates were read, or a bad value
					   @{ @"slug": @"old", @"status": @"active", @"ownership": @"owned", @"siteUrl": @"https://old.here.now/" },
					   @{ @"slug": @"bad", @"status": @"active", @"ownership": @"owned", @"siteUrl": @"https://bad.here.now/",
						  @"contentUpdatedAt": @"yesterday" } ];
	NSArray<NVHereNowSite *> *sites = [service sitesFromRows:rows accountID:@"account"];
	XCTAssertEqual(sites.count, (NSUInteger)4);
	NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
	XCTAssertEqualWithAccuracy([sites[0].modifiedDate timeIntervalSinceDate:[formatter dateFromString:@"2026-10-01T12:00:00Z"]], 0.25, 0.001,
							   @"contentUpdatedAt, the content's own change time, wins over updatedAt");
	XCTAssertEqualObjects(sites[1].modifiedDate, [formatter dateFromString:@"2026-09-01T08:30:00Z"]);
	XCTAssertNil(sites[2].modifiedDate);
	XCTAssertNil(sites[3].modifiedDate);
	for (NVHereNowSite *site in sites) XCTAssertNil(site.createdDate);
}

#pragma mark AppController

- (AppController *)appWithTable:(NSTableView **)outTable notation:(NotationController **)outNotation {
	NotationController *notation = [[NotationController alloc] init];
	[notation addNotes:@[alpha, charlie, echo]];
	//addNotes stamps the time; put back the dates the order depends on
	[alpha setDateModified:T + 300]; [charlie setDateModified:T + 100]; [echo setDateModified:T + 200];
	NSTableView *table = [[ListTable alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
	[table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"Title"]];
	table.allowsMultipleSelection = YES;
	FakeSortPrefs *prefs = [FakeSortPrefs alloc];
	prefs.fakeSortKey = NoteDateModifiedColumnString;
	prefs.fakeReversed = YES;
	NVHereNowMixedList *mixed = [NVHereNowMixedList new];
	mixed.sites = @[bravo, delta, foxtrot];

	AppController *app = [AppController alloc];
	[Kept addObjectsFromArray:@[app, prefs]];
	[app setValue:prefs forKey:@"prefsController"];
	[app setValue:notation forKey:@"notationController"];
	[app setValue:mixed forKey:@"mixedList"];
	[app setValue:table forKey:@"notesTableView"];
	//setNotationController: rebuilds the note source; establish the order after it
	FastListDataSource *source = [notation notesListDataSource];
	[source fillArrayFromArray:@[alpha, echo, charlie]];
	[mixed setNotes:source sortKey:NoteDateModifiedColumnString reversed:YES search:nil];
	table.dataSource = mixed;
	[table reloadData];
	*outTable = table;
	*outNotation = notation;
	return app;
}

- (void)testANoteAfterASiteIsTheOneSelectedShownAndDeleted {
	NSTableView *table; NotationController *notation;
	AppController *app = [self appWithTable:&table notation:&notation];
	//alpha, Bravo, echo, Charlie, delta, Foxtrot
	XCTAssertEqual([app noteAtRow:2], echo);
	XCTAssertEqual([app rowForNote:charlie], (NSUInteger)3);

	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
	[app processChangedSelectionForTable:table];
	XCTAssertEqual([app selectedNoteObject], echo, @"row 2 is echo, not the data source's second Note");
	XCTAssertEqualObjects([app selectedNotes], @[echo]);
	XCTAssertTrue([app displayContentsForNoteAtRow:0]);
	XCTAssertEqual([app selectedNoteObject], alpha);
	XCTAssertFalse([app displayContentsForNoteAtRow:1], @"a Site row has no Note to show");

	NSMenuItem *delete = [[NSMenuItem alloc] initWithTitle:@"Delete" action:@selector(deleteNote:) keyEquivalent:@""];
	NSMutableIndexSet *notesAroundSite = [NSMutableIndexSet indexSetWithIndex:0];
	[notesAroundSite addIndex:3];
	[table selectRowIndexes:notesAroundSite byExtendingSelection:NO];
	XCTAssertFalse([app selectionContainsHereNowSite]);
	XCTAssertTrue([(id<NSMenuItemValidation>)app validateMenuItem:delete]);
	XCTAssertEqualObjects([app selectedNotes], (@[alpha, charlie]));
	[table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)] byExtendingSelection:NO];
	XCTAssertTrue([app selectionContainsHereNowSite], @"a Site in the middle of the selection");
	XCTAssertFalse([(id<NSMenuItemValidation>)app validateMenuItem:delete]);

	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:3] byExtendingSelection:NO];
	[app deleteNote:nil];
	FastListDataSource *source = [notation notesListDataSource];
	XCTAssertEqual([source indexOfObjectIdenticalTo:charlie], (NSUInteger)NSNotFound, @"the selected row's Note is deleted");
	XCTAssertNotEqual([source indexOfObjectIdenticalTo:alpha], (NSUInteger)NSNotFound);
	XCTAssertNotEqual([source indexOfObjectIdenticalTo:echo], (NSUInteger)NSNotFound);
}

- (void)testSiteRefreshKeepsASelectedNoteThatMoves {
	NSTableView *table; NotationController *notation;
	AppController *app = [self appWithTable:&table notation:&notation];
	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];   //echo
	//a refresh dates delta after alpha: it moves above echo
	NVHereNowSite *movedDelta = [self site:@"delta" modified:T + 400];
	NVHereNowSites *service = [[NVHereNowSites alloc] initWithTransport:nil cacheURL:nil];
	[service setValue:@[bravo, movedDelta, foxtrot] forKey:@"sites"];
	[app setValue:service forKey:@"hereNowSites"];
	[app hereNowSitesChanged:nil];
	NVHereNowMixedList *mixed = [app valueForKey:@"mixedList"];
	XCTAssertEqualObjects([self titlesOf:mixed], (@[@"delta", @"alpha", @"Bravo", @"echo", @"Charlie", @"Foxtrot"]));
	XCTAssertEqualObjects(table.selectedRowIndexes, [NSIndexSet indexSetWithIndex:3]);
	XCTAssertEqualObjects([app selectedNotes], @[echo]);
}

@end
