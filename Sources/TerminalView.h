#import <AppKit/AppKit.h>

@interface TerminalView : NSView <NSTextInputClient>
@property (readonly) NSString *sessionTitle;
@property (copy) void (^didFocus)(TerminalView *);
@property (copy) void (^didRename)(TerminalView *);
@property (copy) void (^revealTask)(TerminalView *);
@property (copy) void (^agentFinished)(TerminalView *, NSString *name, BOOL failed, NSString *detail);
@property (copy) void (^commandExited)(TerminalView *, NSString *name, int status, int seconds);
@property (copy) void (^didExit)(TerminalView *);
// Nonzero only while the workspace is monitoring this hidden pane.
@property (nonatomic) NSTimeInterval idleSince;
- (BOOL)canSleep;
- (void)sleepWithWakeHandler:(dispatch_block_t)handler;
- (void)wakeFromIdle;
- (void)start;
- (void)showLocalAgent:(NSString *)tool;
- (NSString *)workingDirectory;
- (void)stop;
- (void)setLinkModifierDown:(BOOL)down;
- (void)adjustFont:(CGFloat)delta;
@property (copy) void (^configureAI)(void), (^assistantVisibilityChanged)(void);
@property (readonly) BOOL assistantVisible;
@property (readonly) BOOL builtInAgentVisible;
@property (readonly) BOOL hasFailedCommand;
- (void)toggleAssistant:(id)sender;
- (void)explainFailure:(id)sender;
- (void)showFind:(id)sender;
- (void)findNext:(id)sender;
- (void)findPrevious:(id)sender;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
@end
NSColor *TerminalBackground(void);
