#import <Cocoa/Cocoa.h>
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: apple-markdown-probe fixture.txt\n"); return 2; }
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:NULL];
    if (!text) { fprintf(stderr, "cannot read fixture\n"); return 2; }
    NSError *error = nil;
    NSAttributedStringMarkdownParsingOptions *options = [[NSAttributedStringMarkdownParsingOptions alloc] init];
    options.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxFull;
    NSAttributedString *parsed = [[NSAttributedString alloc] initWithMarkdown:[text dataUsingEncoding:NSUTF8StringEncoding] options:options baseURL:nil error:&error];
    printf("parse: %s\n", parsed ? "OK" : [[error description] UTF8String]);
    if (!parsed) return 1;
    NSData *html = [parsed dataFromRange:NSMakeRange(0, parsed.length) documentAttributes:@{NSDocumentTypeDocumentAttribute:NSHTMLTextDocumentType} error:&error];
    if (!html) { printf("export: %s\n", [[error description] UTF8String]); return 1; }
    [html writeToFile:@"/tmp/notational-apple-markdown.html" atomically:YES];
    printf("%s\n", [parsed.string UTF8String]);
} }
