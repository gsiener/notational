//
//  NVHTMLMarkdown.m
//  Notation
//

#import "NVHTMLMarkdown.h"

//stands for a <br> while a run of inline text is being built; turned into a hard line
//break (or paragraph break, for two in a row) once the run is finished
#define BREAK_MARK @"\x01"

static NSSet *NameSet(NSString *names) {
	return [NSSet setWithArray:[names componentsSeparatedByString:@" "]];
}

//elements whose content never reaches the output
static NSSet *DroppedNames(void) {
	static NSSet *set = nil;
	if (!set) set = [NameSet(@"script style noscript template head title svg iframe object embed canvas select") retain];
	return set;
}

//plain containers: their children are laid out as paragraphs of their own
static NSSet *ContainerNames(void) {
	static NSSet *set = nil;
	if (!set) set = [NameSet(@"html body p div section article main header footer nav aside form figure figcaption "
							 @"address fieldset dl dt dd details summary center li caption") retain];
	return set;
}

//everything that forces a break in the flow of inline text
static NSSet *StructuralNames(void) {
	static NSSet *set = nil;
	if (!set) {
		set = [[NameSet(@"h1 h2 h3 h4 h5 h6 ul ol blockquote pre hr table") setByAddingObjectsFromSet:ContainerNames()] retain];
	}
	return set;
}

//chrome removed when there is no <article> or <main> to pick
static NSSet *ChromeNames(void) {
	static NSSet *set = nil;
	if (!set) set = [NameSet(@"nav header footer aside form") retain];
	return set;
}

//whitespace runs (including no-break spaces) become one space
static NSString *Collapse(NSString *string) {
	NSUInteger length = [string length], i, out = 0;
	if (!length) return string;
	unichar *buffer = malloc(sizeof(unichar) * length);
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	BOOL inSpace = NO;
	for (i = 0; i < length; i++) {
		unichar c = [string characterAtIndex:i];
		if ([whitespace characterIsMember:c]) {
			if (!inSpace) buffer[out++] = ' ';
			inSpace = YES;
		} else {
			buffer[out++] = c;
			inSpace = NO;
		}
	}
	NSString *result = [[[NSString alloc] initWithCharacters:buffer length:out] autorelease];
	free(buffer);
	return result;
}

static BOOL IsAlnum(unichar c) {
	return [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c];
}

//escapes the characters that would turn ordinary text into emphasis or code
static NSString *EscapeText(NSString *string) {
	NSUInteger length = [string length], i;
	NSMutableString *result = nil;
	for (i = 0; i < length; i++) {
		unichar c = [string characterAtIndex:i];
		unichar next = i + 1 < length ? [string characterAtIndex:i + 1] : 0;
		BOOL escape = NO;
		if (c == '*' || c == '`') {
			escape = YES;
		} else if (c == '_') {
			//snake_case is not emphasis
			escape = !(i > 0 && IsAlnum([string characterAtIndex:i - 1]) && IsAlnum(next));
		} else if (c == '\\') {
			escape = (next == '*' || next == '_' || next == '`' || next == '\\');
		}
		if (escape && !result) result = [NSMutableString stringWithString:[string substringToIndex:i]];
		if (escape) [result appendString:@"\\"];
		if (result) [result appendFormat:@"%C", c];
	}
	return result ? result : string;
}

//keeps a line that starts like Markdown syntax from being read as such
static NSString *EscapeLineStart(NSString *line) {
	NSUInteger length = [line length], i = 0;
	if (!length) return line;
	unichar c = [line characterAtIndex:0];
	unichar next = length > 1 ? [line characterAtIndex:1] : 0;
	if (c == '#' || c == '>')
		return [@"\\" stringByAppendingString:line];
	if ((c == '-' && (length == 1 || next == ' ' || next == '-')) || (c == '+' && (length == 1 || next == ' ')))
		return [@"\\" stringByAppendingString:line];
	while (i < length && [line characterAtIndex:i] >= '0' && [line characterAtIndex:i] <= '9') i++;
	if (i > 0 && i < length && ([line characterAtIndex:i] == '.' || [line characterAtIndex:i] == ')') &&
		(i + 1 == length || [line characterAtIndex:i + 1] == ' '))
		return [NSString stringWithFormat:@"%@\\%@", [line substringToIndex:i], [line substringFromIndex:i]];
	return line;
}

static NSString *EscapeLines(NSString *paragraph) {
	NSArray *lines = [paragraph componentsSeparatedByString:@"\n"];
	NSMutableArray *escaped = [NSMutableArray arrayWithCapacity:[lines count]];
	for (NSString *line in lines) [escaped addObject:EscapeLineStart(line)];
	return [escaped componentsJoinedByString:@"\n"];
}

//puts the marks around content, keeping the spaces at its edges outside them
static NSString *Wrap(NSString *before, NSString *content, NSString *after) {
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	NSUInteger length = [content length], start = 0, end = length;
	while (start < end && [whitespace characterIsMember:[content characterAtIndex:start]]) start++;
	while (end > start && [whitespace characterIsMember:[content characterAtIndex:end - 1]]) end--;
	if (start == end) return content;
	return [NSString stringWithFormat:@"%@%@%@%@%@", [content substringToIndex:start], before,
			[content substringWithRange:NSMakeRange(start, end - start)], after, [content substringFromIndex:end]];
}

static BOOL IsBlank(NSString *string) {
	return [[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0;
}

static BOOL IsListBlock(NSString *block) {
	if ([block hasPrefix:@"- "]) return YES;
	NSUInteger i = 0, length = [block length];
	while (i < length && [block characterAtIndex:i] >= '0' && [block characterAtIndex:i] <= '9') i++;
	return i > 0 && i + 1 < length && [block characterAtIndex:i] == '.' && [block characterAtIndex:i + 1] == ' ';
}

//fence for code that is longer than any run of backticks inside it (at least minimum)
static NSString *FenceFor(NSString *code, NSUInteger minimum) {
	NSUInteger run = 0, longest = 0, i, length = [code length];
	for (i = 0; i < length; i++) {
		if ([code characterAtIndex:i] == '`') longest = MAX(longest, ++run);
		else run = 0;
	}
	return [@"" stringByPaddingToLength:MAX(minimum, longest + 1) withString:@"`" startingAtIndex:0];
}

//text of a node, literally; <br> is a newline
static void CollectText(NSXMLNode *node, NSMutableString *into) {
	if ([node kind] == NSXMLTextKind) {
		[into appendString:[node stringValue]];
	} else if ([node kind] == NSXMLElementKind) {
		if ([[[node name] lowercaseString] isEqualToString:@"br"]) {
			[into appendString:@"\n"];
			return;
		}
		for (NSXMLNode *child in [node children]) CollectText(child, into);
	}
}

//HTML5 sectioning elements are rewritten to <div data-nv-tag="..."> before parsing (see
//NVHTMLMarkdown below), because the tidy in the system library drops tags it doesn't know
static NSString *ElementName(NSXMLNode *node) {
	if ([node kind] != NSXMLElementKind) return nil;
	NSString *name = [[node name] lowercaseString];
	if ([name isEqualToString:@"div"]) {
		NSString *original = [[(NSXMLElement *)node attributeForName:@"data-nv-tag"] stringValue];
		if (original) return original;
	}
	return name;
}

static NSString *Attribute(NSXMLNode *node, NSString *name) {
	return [[(NSXMLElement *)node attributeForName:name] stringValue];
}

@interface NVHTMLMarkdownWriter : NSObject {
	NSURL *baseURL;
	BOOL skipChrome;
	NSMutableString *run; //inline text not yet turned into a paragraph
}
- (id)initWithBaseURL:(NSURL *)url skipChrome:(BOOL)skip;
- (NSArray *)blocksForChildrenOf:(NSXMLNode *)node;
@end

@implementation NVHTMLMarkdownWriter

- (id)initWithBaseURL:(NSURL *)url skipChrome:(BOOL)skip {
	if ((self = [super init])) {
		baseURL = [url retain];
		skipChrome = skip;
		run = [[NSMutableString alloc] init];
	}
	return self;
}

- (void)dealloc {
	[baseURL release];
	[run release];
	[super dealloc];
}

//collapses spaces and trims; breaks become Markdown hard breaks when hardBreaks, else spaces
- (NSString *)finishInline:(NSString *)text hardBreaks:(BOOL)hardBreaks {
	text = Collapse(text);
	text = [text stringByReplacingOccurrencesOfString:@" " BREAK_MARK withString:BREAK_MARK];
	text = [text stringByReplacingOccurrencesOfString:BREAK_MARK @" " withString:BREAK_MARK];
	NSMutableCharacterSet *trim = [[[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy] autorelease];
	[trim addCharactersInString:BREAK_MARK];
	text = [text stringByTrimmingCharactersInSet:trim];
	if (hardBreaks) {
		NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:BREAK_MARK @"{2,}" options:0 error:NULL];
		text = [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, [text length]) withTemplate:@"\n\n"];
		text = [text stringByReplacingOccurrencesOfString:BREAK_MARK withString:@"  \n"];
	} else {
		text = [text stringByReplacingOccurrencesOfString:BREAK_MARK withString:@" "];
		text = Collapse(text);
	}
	return text;
}

- (void)flushTo:(NSMutableArray *)blocks {
	NSString *paragraph = [self finishInline:run hardBreaks:YES];
	[run setString:@""];
	if ([paragraph length]) [blocks addObject:EscapeLines(paragraph)];
}

#pragma mark URLs

- (NSString *)resolvedURL:(NSString *)href {
	href = [[href stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
			stringByReplacingOccurrencesOfString:@" " withString:@"%20"];
	if (![href length]) return nil;
	NSString *result = href;
	if (baseURL) {
		NSURL *url = [NSURL URLWithString:href relativeToURL:baseURL];
		if (url) result = [url absoluteString];
	}
	result = [result stringByReplacingOccurrencesOfString:@"(" withString:@"%28"];
	return [result stringByReplacingOccurrencesOfString:@")" withString:@"%29"];
}

#pragma mark Inline content

- (NSString *)inlineChildrenOf:(NSXMLNode *)node {
	NSMutableString *result = [NSMutableString string];
	for (NSXMLNode *child in [node children]) [result appendString:[self inlineForNode:child]];
	return result;
}

- (NSString *)inlineForNode:(NSXMLNode *)node {
	if ([node kind] == NSXMLTextKind)
		return EscapeText(Collapse([node stringValue]));
	NSString *name = ElementName(node);
	if (!name || [DroppedNames() containsObject:name]) return @"";
	if (Attribute(node, @"hidden")) return @"";

	if ([name isEqualToString:@"br"]) return BREAK_MARK;
	if ([name isEqualToString:@"strong"] || [name isEqualToString:@"b"])
		return Wrap(@"**", [self inlineChildrenOf:node], @"**");
	if ([name isEqualToString:@"em"] || [name isEqualToString:@"i"])
		return Wrap(@"*", [self inlineChildrenOf:node], @"*");

	if ([name isEqualToString:@"code"] || [name isEqualToString:@"kbd"] || [name isEqualToString:@"samp"] || [name isEqualToString:@"tt"]) {
		NSMutableString *text = [NSMutableString string];
		CollectText(node, text);
		NSString *code = [Collapse(text) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (![code length]) return @"";
		NSString *fence = FenceFor(code, 1);
		BOOL pad = [code hasPrefix:@"`"] || [code hasSuffix:@"`"];
		return [NSString stringWithFormat:@" %@%@%@%@%@ ", fence, pad ? @" " : @"", code, pad ? @" " : @"", fence];
	}

	if ([name isEqualToString:@"a"]) {
		NSString *content = [self inlineChildrenOf:node];
		NSString *href = Attribute(node, @"href");
		NSString *url = [self resolvedURL:href];
		NSString *lower = [[href stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
		//in-page anchors and script links mean nothing in a note
		if (!url || [lower hasPrefix:@"javascript:"] || [lower hasPrefix:@"#"]) return content;
		content = [content stringByReplacingOccurrencesOfString:BREAK_MARK withString:@" "];
		if (IsBlank(content)) return [NSString stringWithFormat:@"[%@](%@)", url, url];
		return Wrap(@"[", content, [NSString stringWithFormat:@"](%@)", url]);
	}

	if ([name isEqualToString:@"img"]) {
		NSString *source = Attribute(node, @"src");
		if ([[source lowercaseString] hasPrefix:@"data:"]) return @"";
		NSString *url = [self resolvedURL:source];
		if (!url) return @"";
		NSString *alt = Collapse(Attribute(node, @"alt") ? Attribute(node, @"alt") : @"");
		alt = [[alt stringByReplacingOccurrencesOfString:@"[" withString:@""] stringByReplacingOccurrencesOfString:@"]" withString:@""];
		return [NSString stringWithFormat:@"![%@](%@)", [alt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], url];
	}

	NSString *content = [self inlineChildrenOf:node];
	if ([StructuralNames() containsObject:name] || [name isEqualToString:@"tr"] || [name isEqualToString:@"td"] || [name isEqualToString:@"th"])
		return [NSString stringWithFormat:@" %@ ", content];
	return content;
}

#pragma mark Blocks

- (BOOL)hasStructuralDescendant:(NSXMLNode *)node {
	for (NSXMLNode *child in [node children]) {
		NSString *name = ElementName(child);
		if (name && ([StructuralNames() containsObject:name] || [self hasStructuralDescendant:child])) return YES;
	}
	return NO;
}

- (NSArray *)blocksForChildrenOf:(NSXMLNode *)node {
	NSMutableArray *blocks = [NSMutableArray array];
	[self flushTo:blocks];
	for (NSXMLNode *child in [node children]) [self addNode:child to:blocks];
	[self flushTo:blocks];
	return blocks;
}

- (NSString *)listFromNode:(NSXMLNode *)node ordered:(BOOL)ordered {
	NSMutableArray *items = [NSMutableArray array];
	NSInteger number = 1;
	NSString *start = Attribute(node, @"start");
	if (ordered && [start integerValue] > 0) number = [start integerValue];

	for (NSXMLNode *child in [node children]) {
		if ([child kind] != NSXMLElementKind) continue;
		NSArray *blocks = [self blocksForChildrenOf:child];
		if (![blocks count]) continue;

		NSMutableString *body = [NSMutableString stringWithString:[blocks objectAtIndex:0]];
		NSUInteger i;
		for (i = 1; i < [blocks count]; i++) {
			NSString *block = [blocks objectAtIndex:i];
			//a nested list hugs the item's own text; other blocks are separate paragraphs
			[body appendString:IsListBlock(block) ? @"\n" : @"\n\n"];
			[body appendString:block];
		}
		NSString *marker = ordered ? [NSString stringWithFormat:@"%ld. ", (long)number++] : @"- ";
		NSMutableArray *lines = [NSMutableArray array];
		BOOL first = YES;
		for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
			if (first) [lines addObject:[marker stringByAppendingString:line]];
			else [lines addObject:[line length] ? [@"    " stringByAppendingString:line] : line];
			first = NO;
		}
		[items addObject:[lines componentsJoinedByString:@"\n"]];
	}
	return [items componentsJoinedByString:@"\n"];
}

- (void)collectRowsOf:(NSXMLNode *)node into:(NSMutableArray *)rows header:(BOOL *)header {
	for (NSXMLNode *child in [node children]) {
		NSString *name = ElementName(child);
		if ([name isEqualToString:@"tr"]) {
			NSMutableArray *cells = [NSMutableArray array];
			BOOL allHeaders = YES;
			for (NSXMLNode *cell in [child children]) {
				NSString *cellName = ElementName(cell);
				if (![cellName isEqualToString:@"td"] && ![cellName isEqualToString:@"th"]) continue;
				if (![cellName isEqualToString:@"th"]) allHeaders = NO;
				NSString *text = [self finishInline:[self inlineChildrenOf:cell] hardBreaks:NO];
				[cells addObject:[text stringByReplacingOccurrencesOfString:@"|" withString:@"\\|"]];
			}
			if (![cells count]) continue;
			if ([rows count] == 0 && allHeaders) *header = YES;
			[rows addObject:cells];
		} else if ([name isEqualToString:@"thead"] || [name isEqualToString:@"tbody"] || [name isEqualToString:@"tfoot"]) {
			[self collectRowsOf:child into:rows header:header];
		}
	}
}

//rows are lines of cells separated by " | "; a header row gets a GFM separator line
- (NSString *)tableFromNode:(NSXMLNode *)node {
	NSMutableArray *rows = [NSMutableArray array];
	BOOL header = NO;
	[self collectRowsOf:node into:rows header:&header];
	NSUInteger columns = 0;
	for (NSArray *row in rows) columns = MAX(columns, [row count]);
	if (!columns) return nil;

	NSMutableArray *lines = [NSMutableArray array];
	for (NSArray *row in rows) {
		NSMutableArray *cells = [NSMutableArray arrayWithArray:row];
		while ([cells count] < columns) [cells addObject:@""];
		[lines addObject:[[cells componentsJoinedByString:@" | "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
		if (header && [lines count] == 1) {
			NSMutableArray *dashes = [NSMutableArray array];
			NSUInteger i;
			for (i = 0; i < columns; i++) [dashes addObject:@"---"];
			[lines addObject:[dashes componentsJoinedByString:@" | "]];
		}
	}
	return [lines componentsJoinedByString:@"\n"];
}

- (void)addNode:(NSXMLNode *)node to:(NSMutableArray *)blocks {
	if ([node kind] == NSXMLTextKind) {
		[run appendString:[self inlineForNode:node]];
		return;
	}
	NSString *name = ElementName(node);
	if (!name || [DroppedNames() containsObject:name] || Attribute(node, @"hidden")) return;
	if (skipChrome && [ChromeNames() containsObject:name]) return;

	if (![StructuralNames() containsObject:name]) {
		//inline element; one that holds blocks can't be rendered as a span, so look through it
		if ([self hasStructuralDescendant:node]) {
			for (NSXMLNode *child in [node children]) [self addNode:child to:blocks];
		} else {
			[run appendString:[self inlineForNode:node]];
		}
		return;
	}

	[self flushTo:blocks];
	if ([ContainerNames() containsObject:name]) {
		for (NSXMLNode *child in [node children]) [self addNode:child to:blocks];
		[self flushTo:blocks];
	} else if ([name length] == 2 && [name characterAtIndex:0] == 'h' && [name characterAtIndex:1] >= '1' && [name characterAtIndex:1] <= '6') {
		NSString *text = [self finishInline:[self inlineChildrenOf:node] hardBreaks:NO];
		NSUInteger level = [name characterAtIndex:1] - '0';
		if ([text length])
			[blocks addObject:[NSString stringWithFormat:@"%@ %@", [@"" stringByPaddingToLength:level withString:@"#" startingAtIndex:0], text]];
	} else if ([name isEqualToString:@"pre"]) {
		NSMutableString *code = [NSMutableString string];
		CollectText(node, code);
		[code replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0, [code length])];
		//a newline right after <pre> is not part of the content
		if ([code hasPrefix:@"\n"]) [code deleteCharactersInRange:NSMakeRange(0, 1)];
		NSString *trimmed = [code stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
		if (!IsBlank(trimmed)) {
			NSString *fence = FenceFor(trimmed, 3);
			[blocks addObject:[NSString stringWithFormat:@"%@\n%@\n%@", fence, trimmed, fence]];
		}
	} else if ([name isEqualToString:@"ul"] || [name isEqualToString:@"ol"]) {
		NSString *list = [self listFromNode:node ordered:[name isEqualToString:@"ol"]];
		if ([list length]) [blocks addObject:list];
	} else if ([name isEqualToString:@"blockquote"]) {
		NSArray *inner = [self blocksForChildrenOf:node];
		if ([inner count]) {
			NSMutableArray *lines = [NSMutableArray array];
			for (NSString *line in [[inner componentsJoinedByString:@"\n\n"] componentsSeparatedByString:@"\n"])
				[lines addObject:[line length] ? [@"> " stringByAppendingString:line] : @">"];
			[blocks addObject:[lines componentsJoinedByString:@"\n"]];
		}
	} else if ([name isEqualToString:@"hr"]) {
		[blocks addObject:@"---"];
	} else if ([name isEqualToString:@"table"]) {
		NSString *table = [self tableFromNode:node];
		if (table) [blocks addObject:table];
	}
}

@end

@implementation NVHTMLMarkdown

//plain text, for pages the HTML parser rejects
+ (NSString *)plainTextFromHTML:(NSString *)html {
	NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
	if (!data) return @"";
	NSDictionary *options = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInteger:NSUTF8StringEncoding]
														forKey:NSCharacterEncodingDocumentOption];
	NSAttributedString *attributed = [[[NSAttributedString alloc] initWithHTML:data options:options documentAttributes:NULL] autorelease];
	NSString *text = [[attributed string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	return text ? text : @"";
}

//the element Readability-style import keeps: the largest <article>, else <main>
+ (NSXMLNode *)mainContentIn:(NSXMLNode *)body {
	NSArray *queries = [NSArray arrayWithObjects:@".//div[@data-nv-tag='article']", @".//div[@data-nv-tag='main']", nil];
	for (NSString *query in queries) {
		NSXMLNode *best = nil;
		NSUInteger bestLength = 0;
		for (NSXMLNode *candidate in [body nodesForXPath:query error:NULL]) {
			NSString *text = [[candidate stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([text length] > bestLength) {
				best = candidate;
				bestLength = [text length];
			}
		}
		if (best) return best;
	}
	return nil;
}

//<article> and friends become divs that remember their name
+ (NSString *)htmlWithSectioningTagsRewritten:(NSString *)html {
	static NSRegularExpression *open = nil, *close = nil;
	if (!open) {
		NSString *names = @"(article|main|nav|header|footer|aside|section|figure|figcaption|details|summary|address|template)";
		open = [[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"<%@(?=[\\s/>])", names]
														  options:NSRegularExpressionCaseInsensitive error:NULL] retain];
		close = [[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"</%@\\s*>", names]
														   options:NSRegularExpressionCaseInsensitive error:NULL] retain];
	}
	NSRange all = NSMakeRange(0, [html length]);
	html = [open stringByReplacingMatchesInString:html options:0 range:all withTemplate:@"<div data-nv-tag=\"$1\""];
	return [close stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, [html length]) withTemplate:@"</div>"];
}

+ (NSString *)markdownFromHTML:(NSString *)html baseURL:(NSURL *)baseURL articleOnly:(BOOL)articleOnly {
	if (![html length]) return @"";
	html = [self htmlWithSectioningTagsRewritten:html];

	NSXMLDocument *document = [[[NSXMLDocument alloc] initWithXMLString:html
																options:NSXMLDocumentTidyHTML | NSXMLNodePreserveWhitespace
																  error:NULL] autorelease];
	NSXMLElement *root = [document rootElement];
	if (!root) {
		NSString *text = [self plainTextFromHTML:html];
		return [text length] ? [text stringByAppendingString:@"\n"] : @"";
	}

	NSXMLNode *content = root;
	BOOL skipChrome = NO;
	NSArray *bodies = [root elementsForName:@"body"];
	if ([bodies count]) content = [bodies objectAtIndex:0];
	if (articleOnly) {
		NSXMLNode *main = [self mainContentIn:content];
		if (main) content = main;
		else skipChrome = YES;
	}

	NVHTMLMarkdownWriter *writer = [[[NVHTMLMarkdownWriter alloc] initWithBaseURL:baseURL skipChrome:skipChrome] autorelease];
	NSArray *blocks = [writer blocksForChildrenOf:content];

	NSString *markdown = [blocks componentsJoinedByString:@"\n\n"];
	return [markdown length] ? [markdown stringByAppendingString:@"\n"] : @"";
}

@end
