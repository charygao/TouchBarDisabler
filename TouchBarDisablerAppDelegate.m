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
#include <ServiceManagement/ServiceManagement.h>
#import "Common.h"
#import "HelperTool.h"

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
    
    NSMenuItem *installHelper;
    NSMenuItem *turnOn;
    NSMenuItem *turnOff;


    AVPlayer *player;
    __weak IBOutlet NSWindow *emptyWindow;
    __weak IBOutlet NSTextField *hintLabel;
    __weak IBOutlet NSTextField *hintContent;
    __weak IBOutlet NSButton *dismissButton;
    __weak IBOutlet NSWindow *noSIPWindow;
    __weak IBOutlet AVPlayerView *onboardVideo;
    AuthorizationRef    _authRef;
}
@property (atomic, copy,   readwrite) NSData *                  authorization;
@property (atomic, strong, readwrite) NSXPCConnection *         helperToolConnection;

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
    installHelper = [[NSMenuItem alloc] initWithTitle:@"installHelper" action:@selector(installAction:) keyEquivalent:@""];
    turnOn = [[NSMenuItem alloc] initWithTitle:@"turnOn" action:@selector(getVersionAction:) keyEquivalent:@""];
    turnOff = [[NSMenuItem alloc] initWithTitle:@"turnOff" action:@selector(readLicenseAction:) keyEquivalent:@""];

    [menu addItem:toggler];
    [menu addItem:installHelper];
    [menu addItem:turnOn];
    [menu addItem:turnOff];

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
    
    if (!SMLoginItemSetEnabled((__bridge CFStringRef)@"com.dim.TouchBarDisabler-Helper", YES)) {
        NSLog(@"Login Item Was Not Successful");
    } else {
        NSLog(@"Login Item Added!");
    }
}


- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // external begins here
    OSStatus                    err;
    AuthorizationExternalForm   extForm;
    
    assert(self.window != nil);
    
    // Create our connection to the authorization system.
    //
    // If we can't create an authorization reference then the app is not going to be able
    // to do anything requiring authorization.  Generally this only happens when you launch
    // the app in some wacky, and typically unsupported, way.  In the debug build we flag that
    // with an assert.  In the release build we continue with self->_authRef as NULL, which will
    // cause all authorized operations to fail.
    
    err = AuthorizationCreate(NULL, NULL, 0, &self->_authRef);
    if (err == errAuthorizationSuccess) {
        err = AuthorizationMakeExternalForm(self->_authRef, &extForm);
    }
    if (err == errAuthorizationSuccess) {
        self.authorization = [[NSData alloc] initWithBytes:&extForm length:sizeof(extForm)];
    }
    assert(err == errAuthorizationSuccess);
    
    // If we successfully connected to Authorization Services, add definitions for our default
    // rights (unless they're already in the database).
    
    if (self->_authRef) {
        [Common setupAuthorizationRights:self->_authRef];
    }
    

    // back to my code
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
    NSOperatingSystemVersion osV = [NSProcessInfo processInfo].operatingSystemVersion;
    if (osV.minorVersion == 12) {
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

    } else {
        NSDictionary *error = [NSDictionary new];
        NSString *script =  @"do shell script \"launchctl load /System/Library/LaunchDaemons/com.apple.touchbarserver.plist;killall Dock\" with administrator privileges";
        NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:script];
        if ([appleScript executeAndReturnError:&error]) {
            NSLog(@"success!");
            touchBarDisabled = NO;
            toggler.title = NSLocalizedString(@"DISABLE_TOUCH_BAR", nil);
            [[NSUserDefaults standardUserDefaults] setObject:@NO forKey:@"touchBarDisabled"];

        } else {
            NSLog(@"failure!");
        }
    }
}

- (void)disableTouchBar {
    NSOperatingSystemVersion osV = [NSProcessInfo processInfo].operatingSystemVersion;
    if (osV.minorVersion == 12) {
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
    } else {
        NSDictionary *error = [NSDictionary new];
        NSString *script =  @"do shell script \"killall TouchBarServer;sudo launchctl unload /System/Library/LaunchDaemons/com.apple.touchbarserver.plist\" with administrator privileges";
        NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:script];
        if ([appleScript executeAndReturnError:&error]) {
            NSLog(@"success!");
            touchBarDisabled = YES;
            NSString *enable = NSLocalizedString(@"ENABLE_TOUCH_BAR", nil);
            toggler.title = enable;
            [[NSUserDefaults standardUserDefaults] setObject:@YES forKey:@"touchBarDisabled"];
        } else {
            NSLog(@"failure!");
        }
    }
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

#pragma mark -
#pragma mark - External
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
#pragma unused(sender)
    return YES;
}

- (void)logText:(NSString *)text
// Logs the specified text to the text view.
{
    // any thread
    assert(text != nil);
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        NSLog(text);
        //        [[self.textView textStorage] appendAttributedString:[[NSAttributedString alloc] initWithString:text]];
    }];
}

- (void)logWithFormat:(NSString *)format, ...
// Logs the formatted text to the text view.
{
    va_list ap;
    
    // any thread
    assert(format != nil);
    
    va_start(ap, format);
    [self logText:[[NSString alloc] initWithFormat:format arguments:ap]];
    va_end(ap);
}

- (void)logError:(NSError *)error
// Logs the error to the text view.
{
    // any thread
    assert(error != nil);
    [self logWithFormat:@"error %@ / %d\n", [error domain], (int) [error code]];
}

- (void)connectToHelperTool
// Ensures that we're connected to our helper tool.
{
    assert([NSThread isMainThread]);
    if (self.helperToolConnection == nil) {
        self.helperToolConnection = [[NSXPCConnection alloc] initWithMachServiceName:kHelperToolMachServiceName options:NSXPCConnectionPrivileged];
        self.helperToolConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(HelperToolProtocol)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        // We can ignore the retain cycle warning because a) the retain taken by the
        // invalidation handler block is released by us setting it to nil when the block
        // actually runs, and b) the retain taken by the block passed to -addOperationWithBlock:
        // will be released when that operation completes and the operation itself is deallocated
        // (notably self does not have a reference to the NSBlockOperation).
        self.helperToolConnection.invalidationHandler = ^{
            // If the connection gets invalidated then, on the main thread, nil out our
            // reference to it.  This ensures that we attempt to rebuild it the next time around.
            self.helperToolConnection.invalidationHandler = nil;
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                self.helperToolConnection = nil;
                [self logText:@"connection invalidated\n"];
            }];
        };
#pragma clang diagnostic pop
        [self.helperToolConnection resume];
    }
}

- (void)connectAndExecuteCommandBlock:(void(^)(NSError *))commandBlock
// Connects to the helper tool and then executes the supplied command block on the
// main thread, passing it an error indicating if the connection was successful.
{
    assert([NSThread isMainThread]);
    
    // Ensure that there's a helper tool connection in place.
    
    [self connectToHelperTool];
    
    // Run the command block.  Note that we never error in this case because, if there is
    // an error connecting to the helper tool, it will be delivered to the error handler
    // passed to -remoteObjectProxyWithErrorHandler:.  However, I maintain the possibility
    // of an error here to allow for future expansion.
    
    commandBlock(nil);
}

#pragma mark * IB Actions

- (IBAction)installAction:(id)sender
// Called when the user clicks the Install button.  This uses SMJobBless to install
// the helper tool.
{
#pragma unused(sender)
    
    Boolean             success;
    CFErrorRef          error;
    
    success = SMJobBless(
                         kSMDomainSystemLaunchd,
                         CFSTR("com.example.apple-samplecode.EBAS.HelperTool"),
                         self->_authRef,
                         &error
                         );
    
    if (success) {
        [self logWithFormat:@"success\n"];
    } else {
        [self logError:(__bridge NSError *) error];
        CFRelease(error);
    }
}

- (IBAction)getVersionAction:(id)sender
// Called when the user clicks the Get Version button.  This is the simplest form of
// NSXPCConnection request because it doesn't require any authorization.
{
#pragma unused(sender)
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            [self logError:connectError];
        } else {
            [[self.helperToolConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                [self logError:proxyError];
            }] getVersionWithReply:^(NSString *version) {
                [self logWithFormat:@"version = %@\n", version];
            }];
        }
    }];
}

- (IBAction)readLicenseAction:(id)sender
// Called when the user clicks the Read License button.  This is an example of an
// authorized command that, by default, can be done by anyone.
{
#pragma unused(sender)
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            [self logError:connectError];
        } else {
            [[self.helperToolConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                [self logError:proxyError];
            }] readLicenseKeyAuthorization:self.authorization withReply:^(NSError * commandError, NSString * licenseKey) {
                if (commandError != nil) {
                    [self logError:commandError];
                } else {
                    [self logWithFormat:@"license = %@\n", licenseKey];
                }
            }];
        }
    }];
}

- (IBAction)writeLicenseAction:(id)sender
// Called when the user clicks the Write License button.  This is an example of an
// authorized command that, by default, can only be done by administrators.
{
#pragma unused(sender)
    NSString *  licenseKey;
    
    // Generate a new random license key so that we can see things change.
    
    licenseKey = [[NSUUID UUID] UUIDString];
    
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            [self logError:connectError];
        } else {
            [[self.helperToolConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                [self logError:proxyError];
            }] writeLicenseKey:licenseKey authorization:self.authorization withReply:^(NSError *error) {
                if (error != nil) {
                    [self logError:error];
                } else {
                    [self logWithFormat:@"success\n"];
                }
            }];
        }
    }];
}

- (IBAction)bindAction:(id)sender
// Called when the user clicks the Bind button.  This is an example of an authorized
// command that returns file descriptors.
{
#pragma unused(sender)
    [self connectAndExecuteCommandBlock:^(NSError * connectError) {
        if (connectError != nil) {
            [self logError:connectError];
        } else {
            [[self.helperToolConnection remoteObjectProxyWithErrorHandler:^(NSError * proxyError) {
                [self logError:proxyError];
            }] bindToLowNumberPortAuthorization:self.authorization withReply:^(NSError *error, NSFileHandle *ipv4Handle, NSFileHandle *ipv6Handle) {
                if (error != nil) {
                    [self logError:error];
                } else {
                    // Each of these NSFileHandles has the close-on-dealloc flag set.  If we wanted to hold
                    // on to the underlying descriptor for a long time, we need to call <x-man-page://dup2>
                    // on that descriptor to get our our descriptor that persists beyond the lifetime of
                    // the NSFileHandle.  In this example app, however, we just print the descriptors, which
                    // we can do without any complications.
                    [self logWithFormat:@"IPv4 = %d, IPv6 = %u\n",
                     [ipv4Handle fileDescriptor],
                     [ipv6Handle fileDescriptor]
                     ];
                }
            }];
        }
    }];
}

@end
