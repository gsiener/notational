//
//  NVTextMerge.h
//  Notation
//
//  Line-based three-way merge and minimal single-range edits for note text.
//
//  Simplenote merges concurrent edits on the server; nvALT needs its own merge only
//  for the narrow case where the user typed while a push was in flight and the server
//  merged in someone else's edit. It also turns "old text -> new text" into the
//  smallest single replacement, so the editor can apply remote changes without
//  moving the selection or breaking undo.
//

#import <Cocoa/Cocoa.h>

@interface NVTextMerge : NSObject

//Three-way merge at line granularity. Changes from both sides are kept, including lines
//both sides inserted at the same point (ours first, as Simplenote's server orders them);
//where both sides changed the same existing lines differently, ours wins for those lines.
+ (NSString *)mergeBase:(NSString *)base ours:(NSString *)ours theirs:(NSString *)theirs;

//The single range of oldText that must be replaced to produce newText (common
//prefix and suffix removed). Returns NO when the texts are equal.
+ (BOOL)changeFrom:(NSString *)oldText to:(NSString *)newText range:(NSRange *)range replacement:(NSString **)replacement;

//Where a selection in oldText ends up after the change to newText.
+ (NSRange)selection:(NSRange)selection afterChangeFrom:(NSString *)oldText to:(NSString *)newText;

//Bring storage up to date with content by replacing only the changed range, and return
//selectedRanges (NSValue ranges) moved to follow the text they were on.
+ (NSArray *)updateStorage:(NSTextStorage *)storage toContent:(NSAttributedString *)content selectedRanges:(NSArray *)selectedRanges;

@end
