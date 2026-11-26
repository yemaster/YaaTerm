#import <AppKit/AppKit.h>

typedef NS_ENUM(NSUInteger, DiagnosisFollowUp) { DiagnosisDone, DiagnosisRetry, DiagnosisConfigure };

// Allocated on first use in a pane and released when closed.
@interface TerminalAssistant : NSObject
@property (copy) void (^onClose)(void), (^onConfigure)(void);
@property (copy) NSString *(^currentDirectory)(void);
@property (copy) BOOL (^onShellLine)(NSString *command);
@property (copy) void (^onStop)(void);
@property (copy) NSString *localTool;
- (void)lineAcknowledged:(BOOL)accepted;
@property (copy) void (^onComplete)(NSString *summary, BOOL failed);
@property (copy) void (^onTranscript)(NSString *text);
@property (copy) void (^onPreview)(NSString *text);
@property (copy) void (^onActivity)(BOOL busy);
@property (nonatomic, readonly) BOOL busy;
@property (readonly) NSString *expectedCommand;
@property (copy) void (^onDiagnosis)(NSString *text, NSString *command, DiagnosisFollowUp followUp);
- (instancetype)initWithDirectory:(NSString *)directory shell:(NSString *)shell;
- (void)submitTask:(NSString *)input;
- (void)explain:(NSDictionary *)result;
- (void)receivedResult:(NSDictionary *)result;
- (void)cancel;
@end
