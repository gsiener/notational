//
//  NVSplitView.m
//  Notation
//

#import "NVSplitView.h"
#import "NVTheme.h"

@implementation NVSplitView

- (instancetype)initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_customDividerThickness = 8.0;
	}
	return self;
}

- (CGFloat)dividerThickness {
	return _customDividerThickness;
}

- (void)setCustomDividerThickness:(CGFloat)thickness {
	if (thickness == _customDividerThickness) return;
	_customDividerThickness = thickness;
	[self adjustSubviews];
	[self setNeedsDisplay:YES];
}

- (void)drawDividerInRect:(NSRect)rect {
	NVTheme *theme = [NVTheme currentTheme];
	NSColor *background = [theme backgroundColor];
	NSColor *line = [background blendedColorWithFraction:0.28 ofColor:[theme foregroundColor]];
	if (!line) line = [NSColor separatorColor];

	[background setFill];
	NSRectFill(rect);

	//one hairline along the divider's edge nearest the editor, as the shaded divider had
	[line setFill];
	if ([self isVertical]) {
		NSRectFill(NSMakeRect(NSMinX(rect), NSMinY(rect), 1.0, NSHeight(rect)));
	} else {
		NSRectFill(NSMakeRect(NSMinX(rect), NSMaxY(rect) - 1.0, NSWidth(rect), 1.0));
	}
}

- (void)mouseDown:(NSEvent *)event {
	id<NVSplitViewDelegate> delegate = (id<NVSplitViewDelegate>)[self delegate];
	if ([delegate respondsToSelector:@selector(splitView:shouldTrackMouseDown:onDividerAtIndex:)]) {
		NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
		NSArray *subviews = [self subviews];
		//walk along the divider axis; a collapsed subview takes no room
		CGFloat edge = 0.0, position = [self isVertical] ? point.x : point.y;
		for (NSInteger i = 0; i + 1 < (NSInteger)[subviews count]; i++) {
			NSView *subview = [subviews objectAtIndex:i];
			if (![self isSubviewCollapsed:subview]) {
				edge += [self isVertical] ? NSWidth([subview frame]) : NSHeight([subview frame]);
			}
			if (position >= edge && position < edge + _customDividerThickness) {
				if (![delegate splitView:self shouldTrackMouseDown:event onDividerAtIndex:i]) return;
				break;
			}
			edge += _customDividerThickness;
		}
	}
	[super mouseDown:event];
}

#pragma mark Saved state

+ (NSString *)legacyDefaultsKeyForName:(NSString *)name vertical:(BOOL)vertical {
	//RBSplitView called a split view with a vertical divider "vertical" but keyed it by the
	//orientation of its dividers: "H" when stacked, "V" when side by side
	return [NSString stringWithFormat:@"RBSplitView %@ %@", vertical ? @"V" : @"H", name];
}

+ (NSString *)defaultsKeyForAutosaveName:(NSString *)name {
	return [NSString stringWithFormat:@"NSSplitView Subview Frames %@", name];
}

+ (NSArray<NSString *> *)savedFramesFromLegacyState:(NSString *)state
										   vertical:(BOOL)vertical
											   size:(NSSize)size
									dividerThickness:(CGFloat)thickness {
	if (![state isKindOfClass:[NSString class]]) return nil;
	NSArray *parts = [state componentsSeparatedByString:@" "];
	if ([parts count] != 3 || [[parts objectAtIndex:0] integerValue] != 2) return nil;

	NSString *notesPart = [parts objectAtIndex:1];
	NSScanner *scanner = [NSScanner scannerWithString:notesPart];
	double value = 0;
	if (![scanner scanDouble:&value] || isnan(value) || isinf(value)) return nil;
	//only the suffix "H" is valid after the number
	NSString *rest = nil;
	[scanner scanUpToString:@"\n" intoString:&rest];
	if ([rest length] && ![rest isEqualToString:@"H"]) return nil;

	BOOL collapsed = value <= 0.0;
	CGFloat notes = floor(fabs(value));
	CGFloat extent = vertical ? size.width : size.height;
	CGFloat cross = vertical ? size.height : size.width;
	if (extent <= thickness || cross <= 0) return nil;
	//keep at least a sliver for the editor
	notes = MIN(notes, MAX(extent - thickness - 1.0, 0.0));
	CGFloat editor = collapsed ? extent - thickness : extent - notes - thickness;
	CGFloat editorStart = collapsed ? thickness : notes + thickness;

	//a collapsed list keeps its dimension in the saved frame, as NSSplitView saves it
	NSString *notesFrame, *editorFrame;
	if (vertical) {
		notesFrame = [NSString stringWithFormat:@"0.000000, 0.000000, %f, %f, %@, NO", notes, cross, collapsed ? @"YES" : @"NO"];
		editorFrame = [NSString stringWithFormat:@"%f, 0.000000, %f, %f, NO, NO", editorStart, editor, cross];
	} else {
		notesFrame = [NSString stringWithFormat:@"0.000000, 0.000000, %f, %f, %@, NO", cross, notes, collapsed ? @"YES" : @"NO"];
		editorFrame = [NSString stringWithFormat:@"0.000000, %f, %f, %f, NO, NO", editorStart, cross, editor];
	}
	return @[notesFrame, editorFrame];
}

+ (BOOL)migrateLegacyStateNamed:(NSString *)legacyName
				toAutosaveName:(NSString *)autosaveName
					  vertical:(BOOL)vertical
						  size:(NSSize)size
			  dividerThickness:(CGFloat)thickness
					  defaults:(NSUserDefaults *)defaults {
	NSString *newKey = [self defaultsKeyForAutosaveName:autosaveName];
	if ([defaults objectForKey:newKey]) return NO;
	NSString *state = [defaults stringForKey:[self legacyDefaultsKeyForName:legacyName vertical:vertical]];
	NSArray *frames = [self savedFramesFromLegacyState:state vertical:vertical size:size dividerThickness:thickness];
	if (!frames) return NO;
	[defaults setObject:frames forKey:newKey];
	return YES;
}

@end
