#import <XCTest/XCTest.h>
#import <Carbon/Carbon.h>
#import "NVActivationShortcut.h"
#import "PTKeyCombo.h"
#import "GlobalPrefs.h"
#import "PTKeyComboPanel.h"

@interface NVActivationShortcut (Testing)
- (OSStatus)handleHotKeyEvent:(EventRef)event;
- (UInt32)currentIdentifier;
@end

@interface PTKeyComboPanel (Testing)
- (void)chooseHotKeyDidEnd:(NSWindow *)sheet returnCode:(int)returnCode;
@end

@interface NVRecorderDelegate : NSObject
@property(nonatomic) NSInteger calls;
- (void)keyComboPanelEnded:(PTKeyComboPanel *)panel;
@end
@implementation NVRecorderDelegate
- (void)keyComboPanelEnded:(PTKeyComboPanel *)panel { self.calls++; }
@end

@interface NVTestKeyComboPanel : PTKeyComboPanel
@end
@implementation NVTestKeyComboPanel
- (NSWindow *)window { return nil; }
- (void)setDelegateForTest:(id)delegate { currentModalDelegate = (__bridge id)CFBridgingRetain(delegate); }
@end

@interface NVActivationShortcutTests : XCTestCase
@end

@interface NVActivationShortcutTarget : NSObject
@property(nonatomic) NSInteger count;
- (void)activate:(id)sender;
@end
@implementation NVActivationShortcutTarget
- (void)activate:(id)sender { self.count++; }
@end

@implementation NVActivationShortcutTests
- (EventRef)eventForIdentifier:(UInt32)identifier
{
    EventRef event = NULL;
    EventHotKeyID hotKeyID = { 'NVac', identifier };
    XCTAssertEqual(CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed,
                               GetCurrentEventTime(), kEventAttributeNone, &event), noErr);
    XCTAssertEqual(SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                     sizeof(hotKeyID), &hotKeyID), noErr);
    return event;
}

- (void)testStaleEventsAreIgnoredAfterClearAndReassign
{
    NVActivationShortcut *shortcut = [[NVActivationShortcut alloc] init];
    NVActivationShortcutTarget *target = [[NVActivationShortcutTarget alloc] init];
    PTKeyCombo *first = [PTKeyCombo keyComboWithKeyCode:kVK_F18 modifiers:cmdKey | optionKey];
    PTKeyCombo *second = [PTKeyCombo keyComboWithKeyCode:kVK_F19 modifiers:cmdKey | optionKey];
    XCTAssertTrue([shortcut registerKeyCombo:first target:target action:@selector(activate:)]);
    EventRef stale = [self eventForIdentifier:[shortcut currentIdentifier]];
    XCTAssertEqual([shortcut handleHotKeyEvent:stale], noErr);
    XCTAssertEqual(target.count, 1);
    XCTAssertTrue([shortcut registerKeyCombo:[PTKeyCombo clearKeyCombo] target:target action:@selector(activate:)]);
    XCTAssertEqual([shortcut handleHotKeyEvent:stale], eventNotHandledErr);
    XCTAssertTrue([shortcut registerKeyCombo:second target:target action:@selector(activate:)]);
    XCTAssertEqual([shortcut handleHotKeyEvent:stale], eventNotHandledErr);
    XCTAssertEqual(target.count, 1);
    EventRef current = [self eventForIdentifier:[shortcut currentIdentifier]];
    XCTAssertEqual([shortcut handleHotKeyEvent:current], noErr);
    XCTAssertEqual(target.count, 2);
    ReleaseEvent(current);
    ReleaseEvent(stale);
}


- (void)testRecorderCompletionAndClear
{
    NVTestKeyComboPanel *panel = [[NVTestKeyComboPanel alloc] initWithWindowNibName:@"PTKeyComboPanel"];
    NVRecorderDelegate *delegate = [[NVRecorderDelegate alloc] init];
    [panel setDelegateForTest:delegate];
    [panel chooseHotKeyDidEnd:nil returnCode:NSModalResponseCancel];
    XCTAssertEqual(delegate.calls, 0);
    [panel setDelegateForTest:delegate];
    [panel chooseHotKeyDidEnd:nil returnCode:NSModalResponseOK];
    XCTAssertEqual(delegate.calls, 1);
    [panel setKeyCombo:[PTKeyCombo keyComboWithKeyCode:kVK_F18 modifiers:cmdKey]];
    [panel clear:nil];
    XCTAssertTrue([[panel keyCombo] isClearCombo]);
}

- (void)testPreferencesStaySavedOnCollision
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id oldCode = [defaults objectForKey:@"AppActivationKeyCode"];
    id oldModifiers = [defaults objectForKey:@"AppActivationModifiers"];
    @try {
        GlobalPrefs *prefs = [[GlobalPrefs alloc] init];
        PTKeyCombo *first = [PTKeyCombo keyComboWithKeyCode:kVK_F18 modifiers:cmdKey | optionKey];
        PTKeyCombo *second = [PTKeyCombo keyComboWithKeyCode:kVK_F19 modifiers:cmdKey | optionKey];
        XCTAssertTrue([prefs trySetAppActivationKeyCombo:first target:nil selector:NULL]);
        EventHotKeyID identifier = { 'NVts', 4 };
        EventHotKeyRef occupied = NULL;
        XCTAssertEqual(RegisterEventHotKey([second keyCode], [second modifiers], identifier,
                                           GetEventDispatcherTarget(), 0, &occupied), noErr);
        if (occupied) {
            XCTAssertFalse([prefs trySetAppActivationKeyCombo:second target:nil selector:NULL]);
            XCTAssertEqual([prefs appActivationKeyCombo], first);
            XCTAssertEqual([defaults integerForKey:@"AppActivationKeyCode"], [first keyCode]);
            XCTAssertEqual([defaults integerForKey:@"AppActivationModifiers"], [first modifiers]);
            UnregisterEventHotKey(occupied);
        }
    } @finally {
        if (oldCode) [defaults setObject:oldCode forKey:@"AppActivationKeyCode"];
        else [defaults removeObjectForKey:@"AppActivationKeyCode"];
        if (oldModifiers) [defaults setObject:oldModifiers forKey:@"AppActivationModifiers"];
        else [defaults removeObjectForKey:@"AppActivationModifiers"];
    }
}

- (void)testInstancesAndDeallocation
{
    PTKeyCombo *first = [PTKeyCombo keyComboWithKeyCode:kVK_F18 modifiers:cmdKey | optionKey];
    PTKeyCombo *second = [PTKeyCombo keyComboWithKeyCode:kVK_F19 modifiers:cmdKey | optionKey];
    NVActivationShortcutTarget *target = [[NVActivationShortcutTarget alloc] init];
    @autoreleasepool {
        NVActivationShortcut *one = [[NVActivationShortcut alloc] init];
        NVActivationShortcut *two = [[NVActivationShortcut alloc] init];
        XCTAssertTrue([one registerKeyCombo:first target:target action:@selector(activate:)]);
        XCTAssertTrue([one registerKeyCombo:first target:target action:@selector(activate:)]);
        XCTAssertTrue([two registerKeyCombo:second target:target action:@selector(activate:)]);
        EventRef other = [self eventForIdentifier:[one currentIdentifier]];
        XCTAssertEqual([two handleHotKeyEvent:other], eventNotHandledErr);
        XCTAssertEqual(target.count, 0);
        ReleaseEvent(other);
    }
    EventHotKeyID identifier = { 'NVts', 3 };
    EventHotKeyRef probe = NULL;
    XCTAssertEqual(RegisterEventHotKey([first keyCode], [first modifiers], identifier,
                                       GetEventDispatcherTarget(), 0, &probe), noErr);
    if (probe) UnregisterEventHotKey(probe);
}

- (void)testRegistrationCollisionRollbackAndClear
{
    NVActivationShortcut *shortcut = [[NVActivationShortcut alloc] init];
    PTKeyCombo *first = [PTKeyCombo keyComboWithKeyCode:kVK_F18 modifiers:cmdKey | optionKey];
    PTKeyCombo *second = [PTKeyCombo keyComboWithKeyCode:kVK_F19 modifiers:cmdKey | optionKey];
    XCTAssertTrue([shortcut registerKeyCombo:first target:nil action:NULL]);
    XCTAssertEqual([shortcut keyCombo], first);

    EventHotKeyID occupiedID = { 'NVts', 1 };
    EventHotKeyRef occupied = NULL;
    OSStatus status = RegisterEventHotKey([second keyCode], [second modifiers], occupiedID,
                                           GetEventDispatcherTarget(), 0, &occupied);
    XCTAssertEqual(status, noErr);
    if (status == noErr) {
        XCTAssertFalse([shortcut registerKeyCombo:second target:nil action:NULL]);
        XCTAssertEqual([shortcut keyCombo], first);
        EventHotKeyID probeID = { 'NVts', 2 };
        EventHotKeyRef probe = NULL;
        XCTAssertNotEqual(RegisterEventHotKey([first keyCode], [first modifiers], probeID,
                                               GetEventDispatcherTarget(), 0, &probe), noErr);
        if (probe) UnregisterEventHotKey(probe);
        UnregisterEventHotKey(occupied);
    }
    XCTAssertTrue([shortcut registerKeyCombo:[PTKeyCombo clearKeyCombo] target:nil action:NULL]);
    XCTAssertTrue([[shortcut keyCombo] isClearCombo]);
}
@end
