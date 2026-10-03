#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>

@class PTKeyCombo;

// Owns the application's single global activation shortcut.
@interface NVActivationShortcut : NSObject {
    EventHotKeyRef hotKey;
    EventHandlerRef eventHandler;
    PTKeyCombo *keyCombo;
    id target;
    SEL action;
}
- (PTKeyCombo *)keyCombo;
- (BOOL)registerKeyCombo:(PTKeyCombo *)combo target:(id)newTarget action:(SEL)newAction;
@end
