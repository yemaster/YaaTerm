#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *TerminalTranscriptText(NSString *text);

@interface Session : NSObject
@property (copy) void (^onData)(const void *, size_t);
@property (copy) void (^onExit)(void);
@property (nonatomic) BOOL tracksCommands;
@property (nonatomic) BOOL codeOutputEnabled;
@property (readonly) NSString *agentInputID;
- (BOOL)beginAgentInputWithColor:(NSInteger)color directoryColor:(NSInteger)directoryColor ready:(void (^)(BOOL))ready;
- (void)updateAgentPromptColor:(NSInteger)color directoryColor:(NSInteger)directoryColor wakeEditor:(BOOL)wake;
- (void)agentInputReady:(NSString *)identifier;
- (NSString *)takeAgentTask:(NSString *)identifier;
- (void)endAgentInput:(BOOL)wakeEditor;
- (void)postAgentText:(NSString *)text finished:(BOOL)finished wakeEditor:(BOOL)wake;
- (void)setReviewKeys:(NSString *)keys wake:(BOOL)wake;
- (void)previewAgentText:(NSString *)text;
- (BOOL)approveAgentLine:(NSString *)identifier;
- (NSString *)submitLine:(NSString *)line execute:(BOOL)execute acknowledged:(void (^)(BOOL))reply;
- (BOOL)showDiagnosis:(NSString *)text suggestion:(NSString *)command sequence:(uint64_t)sequence acknowledged:(void (^)(BOOL))reply;
- (void)acknowledgeLine:(NSString *)identifier accepted:(BOOL)accepted;
- (void)discardPendingLine;
@property (readonly) NSString *shellName, *commandExitToken;
- (BOOL)startAt:(NSString *)directory cols:(int)cols rows:(int)rows error:(NSError **)error;
- (void)resizeCols:(int)cols rows:(int)rows;
- (void)send:(NSData *)data;
- (void)sendBytes:(const void *)bytes length:(size_t)length;
- (BOOL)shellIsForeground;
- (NSString *)workingDirectory;
- (void)close;
@end
