//
//  NVTaskPaperMarkdown.h
//  Notation
//
//  Turns a TaskPaper outline into Markdown, the pre-pass NVMarkupRenderer runs before
//  MultiMarkdown (#10/#28). A native port of the old tp2md.rb: projects become bold list
//  items, tasks list items nested by tabs, other lines italic notes, and @tags and
//  [[wiki links]] become nvalt://find/ links.
//

#import <Foundation/Foundation.h>
#import "NVMarkupRenderer.h"

@interface NVTaskPaperMarkdown : NSObject <NVMarkupTool>

//the Markdown (with the tag style header) for the TaskPaper text
+ (NSString *)markdownFromTaskPaper:(NSString *)text;

@end
