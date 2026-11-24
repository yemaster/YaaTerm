#import "TabWorkspace.h"

NSWindow *CreateTerminalWindow(TabWorkspace *workspace);
@interface WindowContent : NSView
@property (readonly) TabWorkspace *workspace;
- (instancetype)initWithWorkspace:(TabWorkspace *)workspace frame:(NSRect)frame;
- (void)setFullScreenTabBar:(BOOL)fullScreen;
@end
