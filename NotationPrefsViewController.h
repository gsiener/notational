//
//  NotationPrefsViewController.h
//  Notation
//
//  The "Notes" preferences pane: which Simplenote account the notes sync with (and
//  how that's going), plus Secure Text Entry. Built in code so it needs no localized
//  nibs; the old folder, storage-format, encryption and password controls went away
//  with the Simplenote-backed store (ADR 0001).
//

#import <Cocoa/Cocoa.h>
#import "NVSimplenoteAccountWindowController.h"

//what the pane needs from the app (AppController in practice)
@protocol NVNotesPaneAccount <NVSimplenoteAccountDelegate>
- (IBAction)showSimplenoteAccount:(id)sender;
@end

@interface NotationPrefsViewController : NSObject

- (id)initWithAccount:(id<NVNotesPaneAccount>)account;

- (NSView *)view;

//re-read the account and the settings into the controls
- (void)refresh;

@end
