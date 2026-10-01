//
//  NVMarkupRenderer.m
//  Notation
//

#import "NVMarkupRenderer.h"
#import "NVTaskPaperMarkdown.h"

static NSString *const ToolErrorDomain = @"NVMarkupToolErrorDomain";

@interface NVMarkupProcessTool () {
	NSString *launchPath;
	NSArray *arguments;
}
@end

@implementation NVMarkupProcessTool

+ (NVMarkupProcessTool *)toolWithLaunchPath:(NSString *)aLaunchPath arguments:(NSArray *)someArguments {
	NVMarkupProcessTool *tool = [[[self alloc] init] autorelease];
	tool->launchPath = [aLaunchPath copy];
	tool->arguments = [(someArguments ? someArguments : [NSArray array]) copy];
	return tool;
}

- (void)dealloc {
	[launchPath release];
	[arguments release];
	[super dealloc];
}

- (NSString *)convertText:(NSString *)text error:(NSError **)error {
	NSTask *task = [[[NSTask alloc] init] autorelease];
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
	dispatch_release(group);
	[task waitUntilExit];

	if ([task terminationStatus] != 0) {
		if (error) *error = [NSError errorWithDomain:ToolErrorDomain code:[task terminationStatus] userInfo:
							 [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ exited with status %d",
																 [launchPath lastPathComponent], [task terminationStatus]]
														 forKey:NSLocalizedDescriptionKey]];
		return nil;
	}
	NSString *string = [[[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding] autorelease];
	return string ? string : @"";
}

@end

@interface NVMarkupRenderer () {
	NSDictionary *tools;
	id<NVMarkupTool> taskPaperTool;
}
@end

@implementation NVMarkupRenderer

+ (NVMarkupRenderer *)defaultRenderer {
	static NVMarkupRenderer *renderer = nil;
	if (!renderer) {
		NSString *resources = [[NSBundle mainBundle] resourcePath];
		NVMarkupProcessTool *mmd = [NVMarkupProcessTool toolWithLaunchPath:[resources stringByAppendingPathComponent:@"multimarkdown"] arguments:nil];
		NVTaskPaperMarkdown *taskPaper = [[[NVTaskPaperMarkdown alloc] init] autorelease];
		//plain Markdown is rendered by MultiMarkdown too, as the preview always did
		NSDictionary *byFormat = [NSDictionary dictionaryWithObjectsAndKeys:
								  mmd, [NSNumber numberWithInteger:NVMarkupMarkdown],
								  mmd, [NSNumber numberWithInteger:NVMarkupMultiMarkdown], nil];
		renderer = [[NVMarkupRenderer alloc] initWithTools:byFormat taskPaperTool:taskPaper];
	}
	return renderer;
}

- (id)initWithTools:(NSDictionary *)toolsByFormat taskPaperTool:(id<NVMarkupTool>)aTaskPaperTool {
	if ((self = [super init])) {
		tools = [toolsByFormat copy];
		taskPaperTool = [aTaskPaperTool retain];
	}
	return self;
}

- (void)dealloc {
	[tools release];
	[taskPaperTool release];
	[super dealloc];
}

+ (NVMarkupFormat)formatFromInteger:(NSInteger)value {
	return value == NVMarkupMarkdown ? NVMarkupMarkdown : NVMarkupMultiMarkdown;
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

- (NSString *)htmlForText:(NSString *)text format:(NVMarkupFormat)format {
	format = [[self class] formatFromInteger:format];
	text = text ? text : @"";
	NSError *error = nil;
	if (taskPaperTool && LooksLikeTaskPaper(text)) {
		NSString *markdown = [taskPaperTool convertText:text error:&error];
		if (markdown) text = markdown;
		else NSLog(@"TaskPaper conversion failed, rendering the outline as is: %@", [error localizedDescription]);
		error = nil;
	}
	id<NVMarkupTool> tool = [tools objectForKey:[NSNumber numberWithInteger:format]];
	NSString *html = [tool convertText:text error:&error];
	if (html) return html;

	NSString *reason = tool ? [error localizedDescription] : @"no converter for this format";
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

@end
