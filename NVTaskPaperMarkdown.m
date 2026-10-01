//
//  NVTaskPaperMarkdown.m
//  Notation
//

#import "NVTaskPaperMarkdown.h"

//stand in for *<del> and </del>* while tags become links, so a tag ending a done task
//can't swallow the closing markup into its href (the old ruby script did)
static NSString *const DelOpen = @"\x01";
static NSString *const DelClose = @"\x02";

//ruby's \s, which is ASCII only
#define WS @"[ \\t\\r\\n\\f\\x0B]"

static NSString *Strip(NSString *s) {
	return [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\f\v"]];
}

static NSRegularExpression *Regex(NSString *pattern) {
	return [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionDotMatchesLineSeparators error:NULL];
}

static NSString *Group(NSTextCheckingResult *match, NSInteger index, NSString *line) {
	NSRange range = [match rangeAtIndex:index];
	return range.location == NSNotFound ? @"" : [line substringWithRange:range];
}

//the tabs without the first one, as the nesting of a list item
static NSString *Indent(NSString *tabs) {
	return [tabs length] ? [tabs substringFromIndex:1] : tabs;
}

static NSString *Tabs(NSUInteger count) {
	return [@"" stringByPaddingToLength:count withString:@"\t" startingAtIndex:0];
}

@implementation NVTaskPaperMarkdown

+ (NSString *)markdownFromTaskPaper:(NSString *)text {
	NSRegularExpression *projectRE = Regex(@"\\A(\\t*)(.*?):(" WS @".*?)?\\z");
	NSRegularExpression *taskRE = Regex(@"\\A(\\t*)- (.*)\\z");
	NSRegularExpression *blankRE = Regex(@"\\A" WS @"*\\z");
	NSRegularExpression *dashRE = Regex(@"\\A" WS @"*-" WS @"*");
	NSRegularExpression *headerRE = Regex(@"Format: [^\\n]*");

	//Format: lines are echoed ahead of everything else
	NSMutableArray *header = [NSMutableArray array];
	for (NSTextCheckingResult *match in [headerRE matchesInString:text options:0 range:NSMakeRange(0, [text length])])
		[header addObject:[text substringWithRange:[match range]]];

	NSMutableString *output = [NSMutableString string];
	NSUInteger prevlevel = 0;
	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		NSRange all = NSMakeRange(0, [line length]);
		NSTextCheckingResult *match;
		if ((match = [projectRE firstMatchInString:line options:0 range:all])) {
			NSString *tabs = Group(match, 1, line);
			NSString *project = [dashRE stringByReplacingMatchesInString:Group(match, 2, line) options:0
																  range:NSMakeRange(0, [Group(match, 2, line) length]) withTemplate:@""];
			[output appendFormat:@"%@* **%@**\n", Indent(tabs), project];
			prevlevel = [tabs length];
		} else if ((match = [taskRE firstMatchInString:line options:0 range:all])) {
			NSString *tabs = Group(match, 1, line);
			NSString *task = Group(match, 2, line);
			if ([task rangeOfString:@"@done"].location != NSNotFound)
				task = [NSString stringWithFormat:@"%@%@%@", DelOpen, task, DelClose];
			//an item can nest only one level below the one before it
			if ((NSInteger)[tabs length] - (NSInteger)prevlevel > 1)
				tabs = Tabs(prevlevel + 1);
			if (prevlevel == 0 && [tabs length] > 1)
				tabs = @"";
			[output appendFormat:@"%@* %@\n", Indent(tabs), Strip(task)];
			prevlevel = [tabs length];
		} else {
			if ([blankRE firstMatchInString:line options:0 range:all]) continue;
			[output appendFormat:@"\n%@*%@*\n", Tabs(prevlevel), Strip(line)];
		}
	}

	NSString *body = [Regex(@"\\[\\[([^\\n]*?)\\]\\]") stringByReplacingMatchesInString:output options:0
																				   range:NSMakeRange(0, [output length])
																			withTemplate:@"<a href=\"nvalt://find/$1\">$1</a>"];
	//@tag or @tag(value) to a link; the marker characters end a tag like a space does
	NSRegularExpression *tagRE = Regex(@"(@[^ \\n\\r\\(\\x01\\x02]+)((\\()([^\\)]+)(\\)))?");
	body = [tagRE stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0, [body length])
									  withTemplate:@"<em class=\"tag\"><a href=\"nvalt://find/$0\">$1$3<strong>$4</strong>$5</a></em>"];
	body = [body stringByReplacingOccurrencesOfString:DelOpen withString:@"*<del>"];
	body = [body stringByReplacingOccurrencesOfString:DelClose withString:@"</del>*"];

	NSMutableString *result = [NSMutableString stringWithFormat:@"%@\n", [header componentsJoinedByString:@"\n"]];
	[result appendString:@"<style>.tag strong {font-weight:normal;color:#555} .tag a {text-decoration:none;border:none;color:#777}</style>\n"];
	[result appendString:body];
	if (![body length] || ![body hasSuffix:@"\n"]) [result appendString:@"\n"];
	return result;
}

- (NSString *)convertText:(NSString *)text error:(NSError **)error {
	return [[self class] markdownFromTaskPaper:text];
}

@end
