/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
	 conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "EmptyView.h"
#import "AppController.h"
//#import "AppController.h"
#import "NVTheme.h"

@implementation EmptyView
{
    NSButton *signInButton;
}

- (id)initWithFrame:(NSRect)frameRect {
	if ((self = [super initWithFrame:frameRect]) != nil) {
		// Add initialization code here
		
		lastNotesNumber = -1;
	}
	return self;
}

- (void)awakeFromNib {
	outletObjectAwoke(self);
	/*
	if (!bgCol) {
		bgCol = [[NVTheme currentTheme] backgroundColor];
	}*/

}

- (void)mouseDown:(NSEvent*)anEvent {
	[[NSApp delegate] performSelector:@selector(bringFocusToControlField:) withObject:nil];
}

- (void)setLabelStatus:(NSInteger)notesNumber {
	if (notesNumber != lastNotesNumber) {
		
		NSString *statusString = nil;
		if (notesNumber > 1) {
			statusString = [NSString stringWithFormat:NSLocalizedString(@"%ld Notes Selected",nil), (long)notesNumber];
		} else {
			statusString = NSLocalizedString(@"No Note Selected",nil); //\nPress return to create one.";
		}
		
		[labelText setStringValue:statusString];
		
		lastNotesNumber = notesNumber;
	}
}

- (void)setShowsSignIn:(BOOL)showsSignIn {
    if (!signInButton) {
        signInButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 170, 32)];
        [signInButton setTitle:NSLocalizedString(@"Sign In to Simplenote…", nil)];
        [signInButton setBezelStyle:NSBezelStyleRounded];
        [signInButton setTarget:NSApp.delegate];
        [signInButton setAction:@selector(showSimplenoteAccount:)];
        [signInButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin];
        [self addSubview:signInButton];
    }
    [signInButton setFrameOrigin:NSMakePoint((NSWidth(self.bounds) - NSWidth(signInButton.frame))/2,
                                           (NSHeight(self.bounds) - NSHeight(signInButton.frame))/2 - 24)];
    [signInButton setHidden:!showsSignIn];
}

//- (void)resetCursorRects {
//	[self addCursorRect:[self bounds] cursor: [NSCursor arrowCursor]];
//}

- (BOOL)isOpaque {	
	return YES;
}
/*
- (void)setBackgroundColor:(NSColor *)inColor{
	if (bgCol) {
	}
	bgCol = inColor;
}

- (void)drawRect:(NSRect)rect {
	//NSRect bounds = [self bounds];
	if (!bgCol) {
		bgCol = [[NVTheme currentTheme] backgroundColor];
	}
	//[bgCol set];
    //NSRectFill(bounds);
}
*/

@end
