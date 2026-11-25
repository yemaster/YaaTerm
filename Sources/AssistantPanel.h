#import <AppKit/AppKit.h>

// Allocated on first use in a pane and released when closed.
@interface AssistantPanel : NSView <NSTextFieldDelegate>
@property (copy) void (^onClose)(void), (^onLayout)(void), (^onConfigure)(void), (^onFocus)(void);
@property (copy) NSString *(^currentDirectory)(void);
@property (copy) BOOL (^onShellLine)(NSString *command, BOOL execute);
@property (copy) void (^onStop)(void);
- (void)prepareForLocalTool:(NSString *)tool diagnosis:(BOOL)diagnosis;
- (void)lineAcknowledged:(BOOL)accepted;
@property (copy) void (^onComplete)(NSString *summary, BOOL failed);
@property (readonly) BOOL inputFocused;
@property (readonly) NSString *expectedCommand;
- (instancetype)initWithDirectory:(NSString *)directory shell:(NSString *)shell;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)focusInput;
- (void)explain:(NSDictionary *)failure;
- (void)receivedResult:(NSDictionary *)result;
- (void)cancel;
- (void)refreshAppearance;
@end
