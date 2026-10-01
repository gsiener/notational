//
//  NVMarkupRenderer.h
//  Notation
//
//  Turns note text into HTML for the preview, Save HTML and Share (#4). Owns the markup
//  formats, the TaskPaper pre-pass, the preview template and running the tools that do
//  the conversion. Each tool is an adapter behind NVMarkupTool, so swapping one (e.g.
//  replacing perl or ruby, #10/#28) touches only the tool for that format.
//

#import <Foundation/Foundation.h>

//the format a note's text is written in; the values are the View ▸ Preview menu item tags
//and what the markupPreviewMode preference stores
enum {
	NVMarkupMarkdown = 13371,
	NVMarkupMultiMarkdown = 13372,
	NVMarkupTextile = 13373,
};
typedef NSInteger NVMarkupFormat;

//a program (or code) that converts text to HTML
@protocol NVMarkupTool <NSObject>
//nil with *error when the conversion couldn't run
- (NSString *)convertText:(NSString *)text error:(NSError **)error;
@end

//runs a program with the text on standard input and reads the result from standard output
@interface NVMarkupProcessTool : NSObject <NVMarkupTool>
+ (NVMarkupProcessTool *)toolWithLaunchPath:(NSString *)launchPath arguments:(NSArray *)arguments;
@end

@interface NVMarkupRenderer : NSObject

//the tools bundled in the app's Resources
+ (NVMarkupRenderer *)defaultRenderer;

//tools for each format (NSNumber of NVMarkupFormat → id<NVMarkupTool>), and the tool that turns
//TaskPaper outlines into Markdown before MultiMarkdown sees them (may be nil)
- (id)initWithTools:(NSDictionary *)toolsByFormat taskPaperTool:(id<NVMarkupTool>)taskPaperTool;

//the saved preference or a menu tag as a format; anything unknown is MultiMarkdown
+ (NVMarkupFormat)formatFromInteger:(NSInteger)value;

//HTML for the text: usually a fragment, but MultiMarkdown makes a whole document when the
//note starts with metadata. If the tool fails, an HTML message saying so.
- (NSString *)htmlForText:(NSString *)text format:(NVMarkupFormat)format;

//a complete page: the HTML (from -htmlForText:format:) placed in templateHTML, which uses
//{%title%}, {%content%}, {%style%} and {%support%}; without a template, a plain XHTML page.
//HTML that is already a whole document is returned unchanged.
+ (NSString *)documentWithHTML:(NSString *)html title:(NSString *)title templateHTML:(NSString *)templateHTML
						   css:(NSString *)css supportPath:(NSString *)supportPath;

+ (BOOL)isCompleteDocument:(NSString *)html;

@end
