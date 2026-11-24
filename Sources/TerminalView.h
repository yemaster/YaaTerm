#import <AppKit/AppKit.h>

@interface TerminalView : NSView <NSTextInputClient>
@property (readonly) NSString *sessionTitle;
@property (copy) void (^didFocus)(TerminalView *);
@property (copy) void (^didRename)(TerminalView *);
@property (copy) void (^revealTask)(TerminalView *);
@property (copy) void (^agentFinished)(TerminalView *, NSString *name, BOOL failed);
@property (copy) void (^commandExited)(TerminalView *, NSString *name, int status, int seconds);
@property (copy) void (^didExit)(TerminalView *);
// Nonzero only while the workspace is monitoring this hidden pane.
@property (nonatomic) NSTimeInterval idleSince;
- (BOOL)canSleep;
- (void)sleepWithWakeHandler:(dispatch_block_t)handler;
- (void)wakeFromIdle;
- (void)start;
- (void)stop;
- (void)setLinkModifierDown:(BOOL)down;
- (void)adjustFont:(CGFloat)delta;
- (void)showFind:(id)sender;
- (void)findNext:(id)sender;
- (void)findPrevious:(id)sender;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
@end
NSColor *TerminalBackground(void);
