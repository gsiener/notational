//
//  NVNoteContent.m
//  Notation
//

#import "NVNoteContent.h"

//longest title shown before the rest of a long first line moves into the body
#define MAX_TITLE_LENGTH 60

@interface NVNoteContent () {
	NSString *string, *prefix, *title, *separator, *body;
	BOOL titleIsPlaceholder;
}
@end

@implementation NVNoteContent

@synthesize title, body, string, titleIsPlaceholder;

static NSCharacterSet *LineBreaks(void) {
	static NSCharacterSet *set = nil;
	if (!set) set = [NSCharacterSet characterSetWithCharactersInString:
					 [NSString stringWithFormat:@"\n\r%C%C", (unichar)0x2028, (unichar)0x2029]];
	return set;
}

+ (NVNoteContent *)contentWithString:(NSString *)content {
	return [[NVNoteContent alloc] initWithString:content];
}

- (id)initWithString:(NSString *)content {
	if ((self = [super init])) {
		if (!content) content = @"";
		string = [content copy];
		NSUInteger length = [content length], i = 0;

		//leading blank space isn't part of the title, but it is part of the content
		NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
		while (i < length && [whitespace characterIsMember:[content characterAtIndex:i]]) i++;
		prefix = [[content substringToIndex:i] copy];

		//the title is the rest of the first line, wrapped at a word if very long
		NSRange lineBreak = [content rangeOfCharacterFromSet:LineBreaks() options:0 range:NSMakeRange(i, length - i)];
		NSUInteger titleEnd = lineBreak.location == NSNotFound ? length : lineBreak.location;
		if (titleEnd - i > MAX_TITLE_LENGTH) {
			NSRange space = [content rangeOfString:@" " options:NSBackwardsSearch | NSLiteralSearch
											 range:NSMakeRange(i + MAX_TITLE_LENGTH - 10, 10)];
			titleEnd = space.location == NSNotFound ? i + MAX_TITLE_LENGTH : space.location;
			titleEnd = [content rangeOfComposedCharacterSequenceAtIndex:titleEnd].location;
		}

		//the separator is the blank space between title and body, line breaks included
		NSUInteger bodyStart = titleEnd;
		while (bodyStart < length && [whitespace characterIsMember:[content characterAtIndex:bodyStart]]) bodyStart++;
		//trailing spaces on the title line belong to the separator, not the title
		NSUInteger trimmedTitleEnd = titleEnd;
		while (trimmedTitleEnd > i && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[content characterAtIndex:trimmedTitleEnd - 1]])
			trimmedTitleEnd--;
		NSString *rawTitle = [content substringWithRange:NSMakeRange(i, trimmedTitleEnd - i)];
		separator = [[content substringWithRange:NSMakeRange(trimmedTitleEnd, bodyStart - trimmedTitleEnd)] copy];
		body = [[content substringFromIndex:bodyStart] copy];

		titleIsPlaceholder = ![rawTitle length];
		title = [(titleIsPlaceholder ? NSLocalizedString(@"Untitled Note", @"Title of a nameless note") : rawTitle) copy];
	}
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
	return self;
}

- (NSString *)stringWithTitle:(NSString *)newTitle body:(NSString *)newBody {
	if (!newTitle) newTitle = @"";
	if (!newBody) newBody = @"";
	BOOL titleChanged = ![newTitle isEqualToString:title];
	if (!titleChanged && [newBody isEqualToString:body]) return string;

	NSString *titlePart = (!titleChanged && titleIsPlaceholder) ? @"" : newTitle;
	NSString *sep = separator;
	//title and body must stay distinguishable once there's text on both sides
	if ([newBody length] && [titlePart length] && [sep rangeOfCharacterFromSet:LineBreaks()].location == NSNotFound)
		sep = [sep stringByAppendingString:@"\n"];
	if (![newBody length] && ![sep rangeOfCharacterFromSet:LineBreaks()].length)
		sep = @"";
	return [NSString stringWithFormat:@"%@%@%@%@", prefix, titlePart, sep, newBody];
}

@end
