//
//  NVPerfCorpus.h
//  NotationTests
//
//  A synthetic notes corpus for the performance tests (#62). The same count and seed always give
//  the same notes. Sizes follow the user's real account as of 2026-10: median about 320
//  characters, 90th percentile about 2.8 KB, 99th about 11 KB, plus a few very long notes. About
//  45% of notes have non-ASCII text, 15% have links, and some have Markdown, TaskPaper and @done
//  lines. Tags are used more than in that account (30% of notes), so the label paths get exercised.
//

#import <Foundation/Foundation.h>

@class NVNoteRecord, NVNotesStore;

//words planted in a known number of notes, for search measurements
extern NSString *const NVPerfRareTerm;      //in exactly 3 notes
extern NSString *const NVPerfMissingTerm;   //in no note
extern NSString *const NVPerfCommonTerm;    //the corpus's most frequent word
//title of the one note of about 1 MB that every corpus has
extern NSString *const NVPerfHugeNoteTitle;

@interface NVPerfCorpus : NSObject

//count notes as confirmed records (version 1, with server data), none trashed
+ (NSArray<NVNoteRecord *> *)recordsWithCount:(NSUInteger)count seed:(uint64_t)seed;

//a new store at path holding those records; nil if it couldn't be written
+ (NVNotesStore *)storeAtPath:(NSString *)path count:(NSUInteger)count seed:(uint64_t)seed;

//note text of about length characters in the corpus's style: a title line, then Markdown
+ (NSString *)contentWithLength:(NSUInteger)length seed:(uint64_t)seed;

@end
