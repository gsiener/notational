//
//  NVMarkupRenderer.m
//  Notation
//

#import "NVMarkupRenderer.h"
#import "NVTaskPaperMarkdown.h"
#import "NSFileManager_NV.h"

static NSString *const ToolErrorDomain = @"NVMarkupToolErrorDomain";

@interface NVMarkupProcessTool () {
	NSString *launchPath;
	NSArray *arguments;
}
@end

@implementation NVMarkupProcessTool

+ (NVMarkupProcessTool *)toolWithLaunchPath:(NSString *)aLaunchPath arguments:(NSArray *)someArguments {
	NVMarkupProcessTool *tool = [[self alloc] init];
	tool->launchPath = [aLaunchPath copy];
	tool->arguments = [(someArguments ? someArguments : [NSArray array]) copy];
	return tool;
}

- (NSString *)convertText:(NSString *)text error:(NSError **)error {
	NSTask *task = [[NSTask alloc] init];
	NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
	[task setExecutableURL:[NSURL fileURLWithPath:launchPath]];
	[task setArguments:arguments];
	[task setStandardInput:input];
	[task setStandardOutput:output];
	[task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

	NSError *launchError = nil;
	if (![task launchAndReturnError:&launchError]) {
		if (error) *error = launchError;
		return nil;
	}
	//write on another thread: a long note can fill the pipe before the tool starts writing its
	//output, and both sides would then wait on each other
	NSData *data = [text ? text : @"" dataUsingEncoding:NSUTF8StringEncoding];
	NSFileHandle *writer = [input fileHandleForWriting];
	dispatch_group_t group = dispatch_group_create();
	dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		@try {
			[writer writeData:data];
		} @catch (NSException *e) {
			//the tool exited without reading everything
		}
		[writer closeFile];
	});
	NSData *result = [[output fileHandleForReading] readDataToEndOfFile];
	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
	[task waitUntilExit];

	if ([task terminationStatus] != 0) {
		if (error) *error = [NSError errorWithDomain:ToolErrorDomain code:[task terminationStatus] userInfo:
							 [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ exited with status %d",
																 [launchPath lastPathComponent], [task terminationStatus]]
														 forKey:NSLocalizedDescriptionKey]];
		return nil;
	}
	NSString *string = [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding];
	return string ? string : @"";
}

@end

@interface NVMarkupRenderer () {
	id<NVMarkupTool> markdownTool;
	id<NVMarkupTool> taskPaperTool;
	//file name → {path, modification date, contents} of the template file last read
	NSMutableDictionary *templateFiles;
}
@end

@implementation NVMarkupRenderer

@synthesize customTemplateFolder, bundledTemplateFolder;

+ (NVMarkupRenderer *)defaultRenderer {
	static NVMarkupRenderer *renderer = nil;
	if (!renderer) {
		NSString *resources = [[NSBundle mainBundle] resourcePath];
		NVMarkupProcessTool *mmd = [NVMarkupProcessTool toolWithLaunchPath:[resources stringByAppendingPathComponent:@"multimarkdown"] arguments:nil];
		//plain Markdown is rendered by MultiMarkdown too, as the preview always did
		renderer = [[NVMarkupRenderer alloc] initWithMarkdownTool:mmd taskPaperTool:[[NVTaskPaperMarkdown alloc] init]];
		[renderer setCustomTemplateFolder:[[NSFileManager defaultManager] applicationSupportDirectory]];
		[renderer setBundledTemplateFolder:resources];
	}
	return renderer;
}

- (id)initWithMarkdownTool:(id<NVMarkupTool>)aMarkdownTool taskPaperTool:(id<NVMarkupTool>)aTaskPaperTool {
	if ((self = [super init])) {
		markdownTool = aMarkdownTool;
		taskPaperTool = aTaskPaperTool;
		templateFiles = [[NSMutableDictionary alloc] init];
	}
	return self;
}

static NSString *EscapedHTML(NSString *string) {
	NSMutableString *escaped = [NSMutableString stringWithString:string ? string : @""];
	[escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [escaped length])];
	return escaped;
}

//TaskPaper outlines (an "Archive:" project or a @taskpaper tag) become Markdown lists first
static BOOL LooksLikeTaskPaper(NSString *text) {
	return [text rangeOfString:@"Archive:"].location != NSNotFound || [text rangeOfString:@"@taskpaper"].location != NSNotFound;
}

- (NSString *)htmlForText:(NSString *)text {
	text = text ? text : @"";
	NSError *error = nil;
	if (taskPaperTool && LooksLikeTaskPaper(text)) {
		NSString *markdown = [taskPaperTool convertText:text error:&error];
		if (markdown) text = markdown;
		else NSLog(@"TaskPaper conversion failed, rendering the outline as is: %@", [error localizedDescription]);
		error = nil;
	}
	NSString *html = [markdownTool convertText:text error:&error];
	if (html) return html;

	NSString *reason = markdownTool ? [error localizedDescription] : @"no converter";
	NSLog(@"Couldn't render the note: %@", reason);
	return [NSString stringWithFormat:@"<p><strong>Couldn't render this note</strong> (%@).</p>\n<pre>%@</pre>\n",
			EscapedHTML(reason), EscapedHTML(text)];
}

+ (BOOL)isCompleteDocument:(NSString *)html {
	NSString *start = [[html stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
	return [start hasPrefix:@"<?xml"] || [start hasPrefix:@"<!doctype"] || [start hasPrefix:@"<html"];
}

+ (NSString *)documentWithHTML:(NSString *)html title:(NSString *)title templateHTML:(NSString *)templateHTML
						   css:(NSString *)css supportPath:(NSString *)supportPath {
	html = html ? html : @"";
	if ([self isCompleteDocument:html]) return html;
	title = title ? title : @"";

	if (![templateHTML length]) {
		return [NSString stringWithFormat:@"<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\"\n\t\"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n\n"
				"<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\" lang=\"en\">\n<head>\n"
				"\t<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>\n\n\t<title>%@</title>\n\t\n</head>\n\n"
				"<body>\n%@\n\n</body>\n</html>\n", EscapedHTML(title), html];
	}
	//content last, so text in the note that looks like a placeholder is left alone
	NSMutableString *page = [NSMutableString stringWithString:templateHTML];
	[page replaceOccurrencesOfString:@"{%support%}" withString:supportPath ? supportPath : @"" options:0 range:NSMakeRange(0, [page length])];
	[page replaceOccurrencesOfString:@"{%title%}" withString:EscapedHTML(title) options:0 range:NSMakeRange(0, [page length])];
	[page replaceOccurrencesOfString:@"{%style%}" withString:css ? css : @"" options:0 range:NSMakeRange(0, [page length])];
	[page replaceOccurrencesOfString:@"{%content%}" withString:html options:0 range:NSMakeRange(0, [page length])];
	return page;
}

#pragma mark The preview template

//the user's copy of a template file if there is one, else the app's; read again only when the
//file in use, or its modification date, changes
- (NSString *)templateFile:(NSString *)name {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *path = [customTemplateFolder stringByAppendingPathComponent:name];
	if (!path || ![fileManager fileExistsAtPath:path]) path = [bundledTemplateFolder stringByAppendingPathComponent:name];
	if (!path) return nil;
	NSDate *modified = [[fileManager attributesOfItemAtPath:path error:NULL] fileModificationDate];

	NSDictionary *cached = [templateFiles objectForKey:name];
	NSDate *cachedModified = [cached objectForKey:@"modified"];
	if (![[cached objectForKey:@"path"] isEqualToString:path] || !(modified == cachedModified || [modified isEqualToDate:cachedModified])) {
		NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
		NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:path forKey:@"path"];
		if (modified) [entry setObject:modified forKey:@"modified"];
		if (contents) [entry setObject:contents forKey:@"contents"];
		[templateFiles setObject:entry forKey:name];
		cached = entry;
	}
	return [cached objectForKey:@"contents"];
}

- (NSString *)pageForHTML:(NSString *)html title:(NSString *)title {
	return [[self class] documentWithHTML:html title:title templateHTML:[self templateFile:@"template.html"]
									  css:[self templateFile:@"custom.css"] supportPath:customTemplateFolder];
}

- (NSString *)contentElementHTMLForHTML:(NSString *)html title:(NSString *)title elementID:(NSString **)elementID {
	html = html ? html : @"";
	if ([[self class] isCompleteDocument:html]) return nil;
	NSString *template = [self templateFile:@"template.html"];
	if (![template length]) return nil;
	//the content must land in that element alone: once in the template, and not brought in by the other placeholders
	NSString *placeholder = @"{%content%}";
	if ([[template componentsSeparatedByString:placeholder] count] != 2) return nil;
	NSString *css = [self templateFile:@"custom.css"];
	if ([title rangeOfString:placeholder].location != NSNotFound || [css rangeOfString:placeholder].location != NSNotFound ||
		[customTemplateFolder rangeOfString:placeholder].location != NSNotFound) return nil;

	static NSRegularExpression *container = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		container = [NSRegularExpression regularExpressionWithPattern:@"<([A-Za-z][A-Za-z0-9]*)\\s(?:[^>]*?\\s)?id\\s*=\\s*([\"'])([^\"'<>]+)\\2[^>]*>(\\s*)\\{%content%\\}(\\s*)</\\1\\s*>"
																	  options:NSRegularExpressionCaseInsensitive error:NULL];
	});
	NSTextCheckingResult *match = [container firstMatchInString:template options:0 range:NSMakeRange(0, [template length])];
	if (!match) return nil;
	//and no other element in the template may share its id
	NSString *identifier = [template substringWithRange:[match rangeAtIndex:3]];
	NSString *sameID = [NSString stringWithFormat:@"\\sid\\s*=\\s*[\"']%@[\"']", [NSRegularExpression escapedPatternForString:identifier]];
	if ([[NSRegularExpression regularExpressionWithPattern:sameID options:NSRegularExpressionCaseInsensitive error:NULL]
		 numberOfMatchesInString:template options:0 range:NSMakeRange(0, [template length])] != 1) return nil;
	//parsed on its own, the HTML must come out as it would inside the page: no scripts (they'd not run),
	//no document-level tags, and the element's own tag balanced so the HTML can't close it early
	NSString *tag = [[template substringWithRange:[match rangeAtIndex:1]] lowercaseString];
	NSString *lowered = [html lowercaseString];
	for (NSString *marker in [NSArray arrayWithObjects:@"<script", @"<html", @"<head", @"<body", @"<frameset", nil])
		if ([lowered rangeOfString:marker].location != NSNotFound) return nil;
	NSString *opening = [NSString stringWithFormat:@"<%@[\\s>]", tag], *closing = [NSString stringWithFormat:@"</%@[\\s>]", tag];
	NSRange all = NSMakeRange(0, [lowered length]);
	if ([[NSRegularExpression regularExpressionWithPattern:opening options:0 error:NULL] numberOfMatchesInString:lowered options:0 range:all] !=
		[[NSRegularExpression regularExpressionWithPattern:closing options:0 error:NULL] numberOfMatchesInString:lowered options:0 range:all])
		return nil;
	if (elementID) *elementID = identifier;
	return [NSString stringWithFormat:@"%@%@%@", [template substringWithRange:[match rangeAtIndex:4]], html,
			[template substringWithRange:[match rangeAtIndex:5]]];
}

- (id)templateKey {
	NSString *template = [self templateFile:@"template.html"], *css = [self templateFile:@"custom.css"];
	return [NSArray arrayWithObjects:template ? (id)template : [NSNull null], css ? (id)css : [NSNull null], nil];
}

- (void)installCustomTemplate {
	if (!customTemplateFolder) return;
	NSFileManager *fileManager = [NSFileManager defaultManager];
	[fileManager createDirectoryAtPath:customTemplateFolder withIntermediateDirectories:YES attributes:nil error:NULL];
	//the starters are plainer than the app's own template and style
	NSDictionary *starters = [NSDictionary dictionaryWithObjectsAndKeys:@"customclean.css", @"custom.css", @"templateclean.html", @"template.html", nil];
	for (NSString *name in starters) {
		NSString *path = [customTemplateFolder stringByAppendingPathComponent:name];
		if ([fileManager fileExistsAtPath:path]) continue;
		NSData *starter = [NSData dataWithContentsOfFile:[bundledTemplateFolder stringByAppendingPathComponent:[starters objectForKey:name]]];
		if (starter) [fileManager createFileAtPath:path contents:starter attributes:nil];
	}
}

@end
