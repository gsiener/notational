//
//  NVSplitView.h
//  Notation
//
//  The main window's split view: the notes list beside or above the note editor (#12).
//  An NSSplitView that draws its divider in the Theme's colours, has a divider thickness
//  the app sets (thinner while the list is collapsed), and reports double clicks on the
//  divider to its delegate. Also reads the divider position the old RBSplitView saved.
//

#import <Cocoa/Cocoa.h>

@class NVSplitView;

@protocol NVSplitViewDelegate <NSSplitViewDelegate>
@optional
//the mouse went down on a divider; return NO to swallow the event (no drag starts)
- (BOOL)splitView:(NVSplitView *)splitView shouldTrackMouseDown:(NSEvent *)event onDividerAtIndex:(NSInteger)index;
@end

@interface NVSplitView : NSSplitView

//the divider's thickness; setting it relays out the subviews
@property (nonatomic) CGFloat customDividerThickness;

//RBSplitView saved "RBSplitView V|H <name>" = "<count> <dimension>..." (a collapsed subview's
//dimension is negative; an "H" suffix marks it hidden). Returns the matching
//"NSSplitView Subview Frames" array for a two-subview split view of the given size (the notes
//list first), or nil when the string isn't a two-subview state. The editor takes the rest.
+ (NSArray<NSString *> *)savedFramesFromLegacyState:(NSString *)state
										   vertical:(BOOL)vertical
											   size:(NSSize)size
									dividerThickness:(CGFloat)thickness;

//the defaults keys RBSplitView and NSSplitView use for an autosave name
+ (NSString *)legacyDefaultsKeyForName:(NSString *)name vertical:(BOOL)vertical;
+ (NSString *)defaultsKeyForAutosaveName:(NSString *)name;

//if defaults has the old RBSplitView state for legacyName and nothing yet under the new
//autosave name, writes the converted frames under it. Returns whether it migrated.
+ (BOOL)migrateLegacyStateNamed:(NSString *)legacyName
				toAutosaveName:(NSString *)autosaveName
					  vertical:(BOOL)vertical
						  size:(NSSize)size
			  dividerThickness:(CGFloat)thickness
					  defaults:(NSUserDefaults *)defaults;

@end
