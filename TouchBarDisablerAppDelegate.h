#import <Cocoa/Cocoa.h>

@interface TouchBarDisablerAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (assign) IBOutlet NSWindow *window;


@end
