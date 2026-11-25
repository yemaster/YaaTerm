#import <AppKit/AppKit.h>

// Allocated on first use in a pane and released when closed.
@interface TerminalAssistant : NSObject
@property (copy) void (^onClose)(void), (^onLayout)(void), (^onConfigure)(void);
@property (copy) NSString *(^currentDirectory)(void);
@property (copy) BOOL (^onShellLine)(NSString *command, BOOL execute);
@property (copy) void (^onStop)(void);
- (void)prepareForLocalTool:(NSString *)tool diagnosis:(BOOL)diagnosis;
- (void)lineAcknowledged:(BOOL)accepted;
@property (copy) void (^onComplete)(NSString *summary, BOOL failed);
@property (copy) void (^onTranscript)(NSString *text);
@property (copy) void (^onPreview)(NSString *text);
@property (copy) void (^onActivity)(BOOL busy);
@property (nonatomic, readonly) BOOL busy;
@property (readonly) NSString *expectedCommand;
@property (readonly) NSView *diagnosisView;
- (instancetype)initWithDirectory:(NSString *)directory shell:(NSString *)shell;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)submitTask:(NSString *)input;
- (void)explain:(NSDictionary *)failure;
- (void)receivedResult:(NSDictionary *)result;
- (void)cancel;
- (void)refreshAppearance;
@end
