//
//  AppController_Simplenote.h
//  Notation
//
//  Opens the Simplenote-backed Notes store at launch (with the one-time migration
//  from the old database), owns sign-in/out, and starts the Sync engine.
//  See docs/adr/0001-simplenote-backed-storage.md.
//

#import "AppController.h"
#import "NVSyncEngine.h"

@class NotationController;

@interface AppController (Simplenote)

//Opens ~/Library/Application Support/nvALT/Notes.sqlite, migrating from the old
//database on first run, and returns a controller on it. Starts syncing if signed in.
- (NotationController *)openSimplenoteBackedNotationReturningError:(NSError **)error;

//adds "Simplenote Account…" to the app menu
- (void)installSimplenoteMenuItem;

- (IBAction)showSimplenoteAccount:(id)sender;

@end
