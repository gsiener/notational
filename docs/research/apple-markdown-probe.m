#import <Cocoa/Cocoa.h>
#import "../../NVTaskPaperMarkdown.h"
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 3 || argc > 4) { fprintf(stderr, "usage: apple-markdown-probe input.txt output.html [--taskpaper]\n"); return 2; }
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:NULL];
    if (!text) { fprintf(stderr, "cannot read fixture\n"); return 2; }
    if (argc == 4) {
        if (strcmp(argv[3], "--taskpaper")) { fprintf(stderr, "unknown option\n"); return 2; }
        text = [NVTaskPaperMarkdown markdownFromTaskPaper:text];
    }
    NSError *error = nil;
    NSAttributedStringMarkdownParsingOptions *options = [[NSAttributedStringMarkdownParsingOptions alloc] init];
    options.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxFull;
    NSAttributedString *parsed = [[NSAttributedString alloc] initWithMarkdown:[text dataUsingEncoding:NSUTF8StringEncoding] options:options baseURL:nil error:&error];
    printf("parse: %s\n", parsed ? "OK" : [[error description] UTF8String]);
    if (!parsed) return 1;
    __block NSUInteger presentationRuns = 0;
    [parsed enumerateAttribute:NSPresentationIntentAttributeName inRange:NSMakeRange(0, parsed.length)
                       options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (value) presentationRuns++;
    }];
    printf("presentation intent runs: %lu\n", (unsigned long)presentationRuns);
    NSData *html = [parsed dataFromRange:NSMakeRange(0, parsed.length) documentAttributes:@{NSDocumentTypeDocumentAttribute:NSHTMLTextDocumentType} error:&error];
    if (!html) { printf("export: %s\n", [[error description] UTF8String]); return 1; }
    if (![html writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]) { fprintf(stderr, "cannot write output\n"); return 2; }
    printf("export: OK\n");
} }
