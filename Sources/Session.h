#import <Foundation/Foundation.h>

@interface Session : NSObject
@property (copy) void (^onData)(const void *, size_t);
@property (copy) void (^onExit)(void);
@property (nonatomic) BOOL tracksCommands;
@property (readonly) NSString *agentInputID;
- (BOOL)beginAgentInput:(void (^)(BOOL))ready;
- (void)agentInputReady:(NSString *)identifier;
- (NSString *)takeAgentTask:(NSString *)identifier;
- (void)endAgentInput:(BOOL)wakeEditor;
- (void)postAgentText:(NSString *)text finished:(BOOL)finished wakeEditor:(BOOL)wake;
- (BOOL)approveAgentLine:(NSString *)identifier;
- (NSString *)submitLine:(NSString *)line execute:(BOOL)execute acknowledged:(void (^)(BOOL))reply;
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
