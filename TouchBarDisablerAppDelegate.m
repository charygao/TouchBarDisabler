#import "TouchBarDisablerAppDelegate.h"
#import "DDHotKeyCenter.h"
#import <Carbon/Carbon.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <CoreFoundation/CoreFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioServices.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ServiceManagement/ServiceManagement.h>

@import CoreMedia;

const int kMaxDisplays = 16;
const CFStringRef kDisplayBrightness = CFSTR(kIODisplayBrightnessKey);
@interface TouchBarDisablerAppDelegate() {
    BOOL hasSeenHelperOnce;
    BOOL touchBarDisabled;
    NSMenu *menu;
    NSMenuItem *toggler;
    NSMenuItem *showHelp;
    NSMenuItem *quit;
    NSMenuItem *onboardHelp;

    AVPlayer *player;
    __weak IBOutlet NSWindow *emptyWindow;
    __weak IBOutlet NSTextField *hintLabel;
    __weak IBOutlet NSTextField *hintContent;
    __weak IBOutlet NSButton *dismissButton;
    __weak IBOutlet NSWindow *noSIPWindow;
    __weak IBOutlet AVPlayerView *onboardVideo;
}
@end
@implementation TouchBarDisablerAppDelegate

@synthesize window;

- (IBAction)hasSeenHelperOnce:(NSButton *)sender {
    [window setIsVisible:NO];
    hasSeenHelperOnce = YES;
    [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:@"hasSeenHelperOnce"];
}

- (void)detectSIP {
    [self launch];
}

- (void)launch {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/csrutil"];
    [task setArguments:[NSArray arrayWithObjects:@"status", nil]];
    NSPipe *outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(readCompleted:) name:NSFileHandleReadToEndOfFileCompletionNotification object:[outputPipe fileHandleForReading]];
    [[outputPipe fileHandleForReading] readToEndOfFileInBackgroundAndNotify];
    [task launch];
}

- (void)readCompleted:(NSNotification *)notification {
    NSData *data = [[notification userInfo] objectForKey:NSFileHandleNotificationDataItem];
    NSString *strOutput = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSFileHandleReadToEndOfFileCompletionNotification object:[notification object]];
    if ([strOutput containsString:@"disabled"]) {
        [self setupAppWhenSIPIsOff];
    } else {
        [self showOnboardHelp];
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == noSIPWindow) {
        NSLog(@"%@ window will close", notification.object);
        player = nil;
        [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0];
    }
}

- (void)showOnboardHelp {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"SIP_ALERT_TITLE", nil)];
    [alert setInformativeText:NSLocalizedString(@"SIP_ALERT_TEXT", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    [alert runModal];
    noSIPWindow.delegate = self;
    noSIPWindow.titleVisibility = NSWindowTitleHidden;
    noSIPWindow.styleMask |= NSWindowStyleMaskFullSizeContentView;
    [noSIPWindow setIsVisible:YES];
    
    NSURL* url = [[NSBundle mainBundle] URLForResource:@"disable_sip_guide" withExtension:@"mp4"];
    player = [[AVPlayer alloc] initWithURL:url];
    onboardVideo.player = player;
    onboardVideo.controlsStyle = AVPlayerViewControlsStyleNone;
    
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:[player currentItem]];
    [player play];
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *p = [notification object];
    [p seekToTime:kCMTimeZero];
}


- (void)setupAppWhenSIPIsOff {
    [hintLabel setStringValue:NSLocalizedString(@"HINT_LABEL", nil)];
    [hintContent setStringValue:NSLocalizedString(@"HINT_CONTENT", nil)];
    [dismissButton setTitle:NSLocalizedString(@"OK", nil)];
    [window setLevel:NSFloatingWindowLevel];
    [self registerHotkeys];
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.title = @"T";
    _statusItem.highlightMode = YES;
    
    menu = [[NSMenu alloc] init];
    NSString *disable = NSLocalizedString(@"DISABLE_TOUCH_BAR", nil);
    NSString *shortcut = NSLocalizedString(@"SHORTCUT_HELP", nil);
    
    toggler = [[NSMenuItem alloc] initWithTitle:disable action:@selector(toggleTouchBar:) keyEquivalent:@""];
    showHelp = [[NSMenuItem alloc] initWithTitle:shortcut action:@selector(displayHUD:) keyEquivalent:@""];

    [menu addItem:toggler];
    
    NSNumber *num = [[NSUserDefaults standardUserDefaults] objectForKey:@"touchBarDisabled"];
    NSNumber *helper = [[NSUserDefaults standardUserDefaults] objectForKey:@"hasSeenHelperOnce"];
    
    if (helper != nil) {
        hasSeenHelperOnce = [helper boolValue];
    }
    
    if (num != nil) {
        touchBarDisabled = [num boolValue];
        if (touchBarDisabled) {
            [self disableTouchBar];
        } else {
        }
    }
    
    [menu addItem:[NSMenuItem separatorItem]]; // A thin grey line
    quit = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"QUIT_TOUCH_BAR_DISABLER", nil) action:@selector(terminate:) keyEquivalent:@""];
    
    [menu addItem:quit];
    _statusItem.menu = menu;
}


- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSOperatingSystemVersion osV = [NSProcessInfo processInfo].operatingSystemVersion;
    if (osV.minorVersion < 12 || (osV.minorVersion == 12 && osV.patchVersion < 1)) {
        [self alertForIncompatibility];
    }
    
    if (osV.minorVersion == 12 && osV.patchVersion == 1) {
        NSDictionary *systemVersionDictionary = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *systemVersion = [systemVersionDictionary objectForKey:@"ProductVersion"];
        if (![systemVersion isEqualToString:@"16B2657"]) {
            [self alertForIncompatibility];
        }
    }
    
    [self detectSIP];
}

- (void)alertForIncompatibility {
    NSString *verString = [NSProcessInfo processInfo].operatingSystemVersionString;
    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:@"OK"];
    [alert setMessageText:@"You can't use this version of the application \"TouchBarDisabler\" with this version of macOS."];
    [alert setInformativeText:[NSString stringWithFormat:@"You have macOS %@. The application requires macOS 10.12.1 (Build 16B2657) or 10.12.2 or later.", verString]];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
    [NSApp terminate:self];
}

- (void)displayHUD:(id)sender {
    [window setIsVisible:YES];
}

- (void)enableTouchBar {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/bash"];
    [task setArguments:@[ @"-c", @"defaults delete com.apple.touchbar.agent PresentationModeGlobal;defaults write com.apple.touchbar.agent PresentationModeFnModes '<dict><key>app</key><string>fullControlStrip</string><key>appWithControlStrip</key><string>fullControlStrip</string><key>fullControlStrip</key><string>app</string></dict>';launchctl load /System/Library/LaunchAgents/com.apple.controlstrip.plist;launchctl load /System/Library/LaunchAgents/com.apple.touchbar.agent.plist;launchctl unload /System/Library/LaunchAgents/com.apple.touchbar.agent.plist;launchctl load /System/Library/LaunchAgents/com.apple.touchbar.agent.plist;pkill \"Touch Bar agent\";killall Dock"]];
    task.terminationHandler = ^(NSTask *task){
        [menu removeItem:showHelp];
    };
    [task launch];
    touchBarDisabled = NO;
    toggler.title = NSLocalizedString(@"DISABLE_TOUCH_BAR", nil);
    [[NSUserDefaults standardUserDefaults] setObject:@NO forKey:@"touchBarDisabled"];
}

- (void)disableTouchBar {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/bash"];
    [emptyWindow makeKeyAndOrderFront:self];
    [NSApp activateIgnoringOtherApps:YES];
    [task setArguments:@[ @"-c", @"defaults write com.apple.touchbar.agent PresentationModeGlobal -string fullControlStrip;launchctl unload /System/Library/LaunchAgents/com.apple.controlstrip.plist;killall ControlStrip;launchctl unload /System/Library/LaunchAgents/com.apple.touchbar.agent.plist;launchctl unload /System/Library/LaunchDaemons/com.apple.touchbar.user-device.plist;pkill \"Touch Bar agent\""]];
    task.terminationHandler = ^(NSTask *task){
        [emptyWindow setIsVisible:NO];
        [menu addItem:showHelp];
    };
    if (hasSeenHelperOnce) {
        [emptyWindow setIsVisible:YES];
    } else {
        [window setIsVisible:YES];
    }
    [task launch];
    touchBarDisabled = YES;
    NSString *enable = NSLocalizedString(@"ENABLE_TOUCH_BAR", nil);
    toggler.title = enable;
    [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:@"touchBarDisabled"];

}

- (void)toggleTouchBar:(id)sender {
    if (touchBarDisabled) {
        [self enableTouchBar];
    } else {
        [self disableTouchBar];
    }
}

- (void) hotkeyWithEvent:(NSEvent *)hkEvent {
    short keyCode = hkEvent.keyCode;
    switch (keyCode) {
        case kVK_ANSI_1:
            [self simulateHardWareKeyPressWithKeyCode:107];
            break;
        case kVK_ANSI_2:
            [self simulateHardWareKeyPressWithKeyCode:113];
            break;
        case kVK_ANSI_3:
            [self toggleExpose];
            break;
        case kVK_ANSI_4:
            [self toggleDashboard];
            break;
        case kVK_ANSI_5:
            break;
        case kVK_ANSI_6:
            break;
        case kVK_ANSI_7:
            break;
        case kVK_ANSI_8:
            [self muteVolume];
            break;
        case kVK_ANSI_9:
            [self decreaseVolume];
            break;
        case kVK_ANSI_0:
            [self increaseVolume];
            break;
        default:
            break;
    }
}

- (void)toggleExpose {
    if(![[NSWorkspace sharedWorkspace] launchApplication:@"Mission Control"])
        NSLog(@"Mission Control failed to launch");
}

- (void)toggleDashboard {
    if(![[NSWorkspace sharedWorkspace] launchApplication:@"Dashboard"])
        NSLog(@"Dashboard failed to launch");
}

static io_connect_t get_event_driver(void)
{
    static  mach_port_t sEventDrvrRef = 0;
    mach_port_t masterPort, service, iter;
    kern_return_t    kr;
    
    if (!sEventDrvrRef)
    {
        kr = IOMasterPort( bootstrap_port, &masterPort );
        kr = IOServiceGetMatchingServices( masterPort, IOServiceMatching( kIOHIDSystemClass ), &iter );
        service = IOIteratorNext( iter );
        kr = IOServiceOpen( service, mach_task_self(),
                           kIOHIDParamConnectType, &sEventDrvrRef );
        IOObjectRelease( service );
        IOObjectRelease( iter );
    }
    return sEventDrvrRef;
}


static void HIDPostAuxKey( const UInt8 auxKeyCode )
{
    NXEventData   event;
    kern_return_t kr;
    IOGPoint      loc = { 0, 0 };
    
    // Key press event
    UInt32      evtInfo = auxKeyCode << 16 | NX_KEYDOWN << 8;
    bzero(&event, sizeof(NXEventData));
    event.compound.subType = NX_SUBTYPE_AUX_CONTROL_BUTTONS;
    event.compound.misc.L[0] = evtInfo;
    kr = IOHIDPostEvent( get_event_driver(), NX_SYSDEFINED, loc, &event, kNXEventDataVersion, 0, FALSE );
    
    // Key release event
    evtInfo = auxKeyCode << 16 | NX_KEYUP << 8;
    bzero(&event, sizeof(NXEventData));
    event.compound.subType = NX_SUBTYPE_AUX_CONTROL_BUTTONS;
    event.compound.misc.L[0] = evtInfo;
    kr = IOHIDPostEvent( get_event_driver(), NX_SYSDEFINED, loc, &event, kNXEventDataVersion, 0, FALSE );
}

- (void)decreaseVolume {
    HIDPostAuxKey(NX_KEYTYPE_SOUND_DOWN);
}

- (void)increaseVolume {
    HIDPostAuxKey(NX_KEYTYPE_SOUND_UP);
}

- (void)muteVolume {
    HIDPostAuxKey(NX_KEYTYPE_MUTE);
}

- (void)simulateHardWareKeyPressWithKeyCode: (int)keyCode {
    CGEventSourceRef sourceRef = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    
    CGEventRef modifierUnpress = CGEventCreateKeyboardEvent (sourceRef, (CGKeyCode)0x3B, false);
    CGEventPost(kCGHIDEventTap, modifierUnpress);
    CFRelease(modifierUnpress);

    [NSTimer scheduledTimerWithTimeInterval:0.05f repeats:NO block:^(NSTimer * _Nonnull timer) {
        CGEventRef keyPress = CGEventCreateKeyboardEvent (sourceRef, (CGKeyCode)keyCode, true);
        CGEventRef keyUnpress = CGEventCreateKeyboardEvent (sourceRef, (CGKeyCode)keyCode, false);
        
        CGEventPost(kCGHIDEventTap, keyPress);
        CGEventPost(kCGHIDEventTap, keyUnpress);
        
        CFRelease(keyPress);
        CFRelease(keyUnpress);
        CFRelease(sourceRef);
    }];

}

- (void) registerHotkeys {
	DDHotKeyCenter *c = [DDHotKeyCenter sharedHotKeyCenter];
    [c registerHotKeyWithKeyCode:kVK_ANSI_1 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_2 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_3 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_4 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_5 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_6 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_7 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_8 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_9 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
    [c registerHotKeyWithKeyCode:kVK_ANSI_0 modifierFlags:NSEventModifierFlagControl target:self action:@selector(hotkeyWithEvent:) object:nil];
}

@end
