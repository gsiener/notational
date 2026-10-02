//
//  NVMarkupRenderer.h
//  Notation
//
//  Turns note text into HTML for the preview and Save HTML (#4). Owns the TaskPaper
//  pre-pass, the preview template and running the tools that do the conversion. Each
//  tool is an adapter behind NVMarkupTool, so swapping one touches only that tool.
//

#import <Foundation/Foundation.h>

//the View ▸ Preview menu's modes: its items' tags and what the markupPreviewMode preference
//stores. The renderer doesn't tell them apart; both render with MultiMarkdown.
enum {
	NVMarkupMarkdown = 13371,
	NVMarkupMultiMarkdown = 13372,
	//13373 was Textile, dropped with its perl (#28); a saved 13373 reads as MultiMarkdown
};

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

//the bundled multimarkdown and the native TaskPaper pass; the preview template from the
//application support folder, falling back to the copy in the app
+ (NVMarkupRenderer *)defaultRenderer;

//markdownTool turns the note into HTML; taskPaperTool (may be nil) first turns TaskPaper
//outlines into Markdown
- (id)initWithMarkdownTool:(id<NVMarkupTool>)markdownTool taskPaperTool:(id<NVMarkupTool>)taskPaperTool;

//where the preview template comes from: template.html and custom.css in customTemplateFolder
//when the user has them, else in bundledTemplateFolder. customTemplateFolder is also the
//template's {%support%}.
@property (nonatomic, copy) NSString *customTemplateFolder;
@property (nonatomic, copy) NSString *bundledTemplateFolder;

//HTML for the text: usually a fragment, but MultiMarkdown makes a whole document when the
//note starts with metadata. If the tool fails, an HTML message saying so.
- (NSString *)htmlForText:(NSString *)text;

//the HTML (from -htmlForText:) as a complete page in the preview template. The template files
//are read once, and again only when the one in use changes.
- (NSString *)pageForHTML:(NSString *)html title:(NSString *)title;

//copies starter template.html and custom.css into customTemplateFolder for the user to edit,
//leaving any already there alone
- (void)installCustomTemplate;

//a complete page: the HTML placed in templateHTML, which uses {%title%}, {%content%}, {%style%}
//and {%support%}; without a template, a plain XHTML page. HTML that is already a whole document
//is returned unchanged.
+ (NSString *)documentWithHTML:(NSString *)html title:(NSString *)title templateHTML:(NSString *)templateHTML
						   css:(NSString *)css supportPath:(NSString *)supportPath;

+ (BOOL)isCompleteDocument:(NSString *)html;

@end
