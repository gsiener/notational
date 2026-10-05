//
//  NVHereNowPrefsViewController.h
//  Notation
//
//  The here.now section of Settings ▸ Notes: connection status, the API key, and Refresh
//  and Disconnect. Built in code, like the rest of the Notes pane.
//

#import <Cocoa/Cocoa.h>
#import "NVHereNowSites.h"

@interface NVHereNowPrefsViewController : NSViewController

//updates itself when the source posts NVHereNowSitesDidChangeNotification
- (instancetype)initWithSource:(id<NVHereNowSettingsSource>)source;

//for tests: the controls as the pane shows them
@property(readonly) NSTextField *statusField, *errorField;
@property(readonly) NSSecureTextField *keyField;
@property(readonly) NSButton *connectButton, *refreshButton, *disconnectButton;

- (IBAction)connect:(id)sender;
- (IBAction)refresh:(id)sender;
- (IBAction)disconnect:(id)sender;

@end
