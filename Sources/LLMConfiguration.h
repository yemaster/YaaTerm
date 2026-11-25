#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, LLMAPIFormat) { LLMChatCompletions, LLMResponses, LLMAnthropicMessages };

@interface LLMConfiguration : NSObject
@property (readonly, copy) NSString *endpoint, *apiKey, *model;
@property (readonly) LLMAPIFormat format;
- (instancetype)initWithEndpoint:(NSString *)endpoint key:(NSString *)key model:(NSString *)model format:(LLMAPIFormat)format;
- (NSString *)validationError;
- (NSURL *)requestURL;
- (NSURLRequest *)connectionTestRequest;
// Both callbacks run on the main queue. A nil configuration without an error means first use.
+ (void)loadSaved:(void (^)(LLMConfiguration *, NSString *error))completion;
- (void)save:(void (^)(NSString *error))completion;
- (NSURLSessionDataTask *)ask:(NSString *)input instruction:(NSString *)instruction progress:(void (^)(NSString *partialText))progress completion:(void (^)(NSString *text, NSString *error))completion;
- (NSURLSessionDataTask *)testConnection:(void (^)(NSString *error))completion;
@end
