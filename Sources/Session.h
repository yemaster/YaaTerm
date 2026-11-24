#import <Foundation/Foundation.h>

@interface Session : NSObject
@property (copy) void (^onData)(const void *, size_t);
@property (copy) void (^onExit)(void);
@property (readonly) NSString *shellName, *commandExitToken;
- (BOOL)startAt:(NSString *)directory cols:(int)cols rows:(int)rows error:(NSError **)error;
- (void)resizeCols:(int)cols rows:(int)rows;
- (void)send:(NSData *)data;
- (void)sendBytes:(const void *)bytes length:(size_t)length;
- (BOOL)shellIsForeground;
- (NSString *)workingDirectory;
- (void)close;
@end
