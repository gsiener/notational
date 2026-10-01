//
//  NVHTMLMarkdown.h
//  Notation
//
//  Native HTML to Markdown conversion for importing web pages.
//
//  This replaces the bundled Python 2 scripts (readability.py and html2text.py) that
//  the importer used to launch with NSTask, which stopped working once macOS no longer
//  shipped a python. The HTML is parsed with NSXMLDocument's tidy mode and the DOM is
//  walked once, producing plain Markdown (ATX headings, fenced code, "-" lists).
//

#import <Cocoa/Cocoa.h>

@interface NVHTMLMarkdown : NSObject

//Markdown for an HTML document or fragment. articleOnly keeps just the main content
//(<article>, else <main>, else the <body> minus nav/header/footer/aside/form), the way
//the old Readability option did. Relative links and images resolve against baseURL (may be nil).
//The result ends with a single newline, or is empty if the page has no text.
+ (NSString *)markdownFromHTML:(NSString *)html baseURL:(NSURL *)baseURL articleOnly:(BOOL)articleOnly;

@end
