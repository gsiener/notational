#import "NVActivationShortcut.h"
#import "PTKeyCombo.h"

static UInt32 nextActivationIdentifier = 0;

@interface NVActivationShortcut () {
    UInt32 activeIdentifier;
}
- (OSStatus)handleHotKeyEvent:(EventRef)event;
@end

static OSStatus activationHotKeyEvent(EventHandlerCallRef handler, EventRef event, void *context)
{
    return [(NVActivationShortcut *)context handleHotKeyEvent:event];
}

@implementation NVActivationShortcut
- (void)dealloc
{
    if (hotKey) UnregisterEventHotKey(hotKey);
    if (eventHandler) RemoveEventHandler(eventHandler);
    [keyCombo release];
    [super dealloc];
}

- (PTKeyCombo *)keyCombo { return keyCombo; }
- (UInt32)currentIdentifier { return activeIdentifier; }

- (OSStatus)handleHotKeyEvent:(EventRef)event
{
    EventHotKeyID identifier;
    if (!hotKey || GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                     NULL, sizeof(identifier), NULL, &identifier) != noErr ||
        identifier.signature != 'NVac' || identifier.id != activeIdentifier)
        return eventNotHandledErr;
    if (target && action) [target performSelector:action withObject:self];
    return noErr;
}

- (BOOL)registerKeyCombo:(PTKeyCombo *)combo target:(id)newTarget action:(SEL)newAction
{
    if (!combo) return NO;
    if (keyCombo && [keyCombo isEqual:combo]) {
        target = newTarget;
        action = newAction;
        return YES;
    }

    // Install the handler first. Registration failure leaves the old shortcut intact.
    if ([combo isValidHotKeyCombo] && !eventHandler) {
        EventTypeSpec eventType = { kEventClassKeyboard, kEventHotKeyPressed };
        if (InstallEventHandler(GetEventDispatcherTarget(), activationHotKeyEvent,
                                1, &eventType, self, &eventHandler) != noErr)
            return NO;
    }

    EventHotKeyRef replacement = NULL;
    UInt32 replacementIdentifier = 0;
    if ([combo isValidHotKeyCombo]) {
        replacementIdentifier = ++nextActivationIdentifier;
        EventHotKeyID identifier = { 'NVac', replacementIdentifier };
        if (RegisterEventHotKey([combo keyCode], [combo modifiers], identifier,
                                GetEventDispatcherTarget(), 0, &replacement) != noErr)
            return NO;
    }
    if (hotKey) UnregisterEventHotKey(hotKey);
    hotKey = replacement;
    activeIdentifier = replacementIdentifier;
    [combo retain];
    [keyCombo release];
    keyCombo = combo;
    target = newTarget;
    action = newAction;
    return YES;
}
@end
