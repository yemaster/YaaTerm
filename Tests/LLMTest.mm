#import "LLMConfiguration.h"
#import "LLMSettingsForm.h"
#import "SettingsView.h"
#import <Security/Security.h>
#include <cassert>
#include <initializer_list>

// This test target substitutes only the three Keychain calls, keeping the user's login keychain untouched.
static NSData *savedRecord;
static BOOL denyWrite = NO;
static void checkQuery(CFDictionaryRef query) {
    NSDictionary *q = (__bridge NSDictionary *)query;
    assert([q[(id)kSecClass] isEqual:(id)kSecClassGenericPassword]);
    assert([q[(id)kSecAttrService] isEqual:@"dev.yaaterm.llm"] && [q[(id)kSecAttrAccount] isEqual:@"configuration"]);
}
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    checkQuery(query);
    if (!savedRecord) return errSecItemNotFound;
    *result = CFBridgingRetain(savedRecord); return errSecSuccess;
}
OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef changes) {
    checkQuery(query);
    if (denyWrite) return errSecAuthFailed;
    if (!savedRecord) return errSecItemNotFound;
    savedRecord = ((__bridge NSDictionary *)changes)[(id)kSecValueData]; return errSecSuccess;
}
OSStatus SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    checkQuery(query);
    if (savedRecord) return errSecDuplicateItem;
    savedRecord = ((__bridge NSDictionary *)query)[(id)kSecValueData]; return errSecSuccess;
}

static void waitFor(BOOL (^done)(void)) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done() && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    assert(done());
}

@interface FixtureProtocol : NSURLProtocol
@end
static NSInteger httpCode;
static NSData *replyData;
@implementation FixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"fixture.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:httpCode
        HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:replyData];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

@interface LLMConfiguration (SessionConfiguration)
- (NSURLSessionConfiguration *)testSessionConfiguration;
@end
@interface FixtureConfig : LLMConfiguration
@end
@implementation FixtureConfig
- (NSURLSessionConfiguration *)testSessionConfiguration {
    NSURLSessionConfiguration *config = [super testSessionConfiguration];
    assert(!config.URLCache && !config.HTTPCookieStorage && !config.URLCredentialStorage);
    config.protocolClasses = @[FixtureProtocol.class];
    return config;
}
@end

static FixtureConfig *profile(NSString *endpoint, LLMAPIFormat format) {
    return [[FixtureConfig alloc] initWithEndpoint:endpoint key:@"test-only" model:@"chosen-model" format:format];
}
static NSString *probe(FixtureConfig *config, NSInteger status, id data) {
    httpCode = status;
    replyData = [data isKindOfClass:NSData.class] ? data : [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    __block BOOL done = NO; __block NSString *message;
    [config testConnection:^(NSString *error) { assert(NSThread.isMainThread); message = error; done = YES; }];
    waitFor(^BOOL{ return done; });
    return message;
}
static void checkProtocols() {
    NSArray *routes = @[@"chat/completions",@"responses",@"messages"];
    NSArray *bodies = @[@{@"choices":@[@{@"message":@{@"content":@"OK"}}]},
                        @{@"object":@"response",@"output":@[],@"status":@"completed"},
                        @{@"type":@"message",@"role":@"assistant",@"content":@[@{@"type":@"text",@"text":@"OK"}]}];
    for (NSInteger i = 0; i < 3; ++i) {
        auto format = (LLMAPIFormat)i;
        FixtureConfig *config = profile(@"https://fixture.invalid/v1/",format);
        NSURLRequest *request = config.connectionTestRequest;
        assert([request.URL.path isEqual:[@"/v1/" stringByAppendingString:routes[i]]]);
        assert([profile(request.URL.absoluteString,format).requestURL isEqual:request.URL]);
        assert([profile(@"https://fixture.invalid",format).requestURL isEqual:request.URL]);
        assert([request.HTTPMethod isEqual:@"POST"]);
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
        assert([body[@"model"] isEqual:@"chosen-model"]);
        if (i == LLMResponses) assert([body[@"input"] isEqual:@"Reply OK."] && !body[@"messages"]);
        else assert([body[@"messages"][0][@"content"] isEqual:@"Reply OK."]);
        BOOL anthropic = i == LLMAnthropicMessages;
        assert(anthropic == [[request valueForHTTPHeaderField:@"x-api-key"] isEqual:@"test-only"]);
        assert(anthropic == [[request valueForHTTPHeaderField:@"anthropic-version"] isEqual:@"2023-06-01"]);
        assert(!anthropic == [[request valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer test-only"]);
        assert(!probe(config,200,bodies[i]));
        assert(probe(config,200,bodies[(i+1)%3]).length);
        assert(!savedRecord);
    }
    FixtureConfig *config = profile(@"https://fixture.invalid/proxy/v1?version=fixture",LLMResponses);
    assert([config.requestURL.absoluteString isEqual:@"https://fixture.invalid/proxy/v1/responses?version=fixture"]);
    assert([profile(@"https://fixture.invalid/custom/invoke",LLMResponses).requestURL.path isEqual:@"/custom/invoke"]);
    assert(profile(@"http://localhost:8080/v1",LLMResponses).requestURL && profile(@"http://[::1]:8080/v1",LLMResponses).requestURL);
    for (NSString *invalid in @[@"http://fixture.invalid",@"https://user:pass@fixture.invalid",@"file:///tmp/api",
                                @"https://fixture.invalid/v1/messages",@"https://fixture.invalid/#part"])
        assert(!profile(invalid,LLMResponses).connectionTestRequest);
    assert([probe(config,401,@{}) containsString:@"401"]);
    assert([probe(config,429,@{}) containsString:@"429"]);
    assert([probe(config,302,@{}) containsString:@"跳转"]);
    assert(probe(config,200,[@"<html>" dataUsingEncoding:NSUTF8StringEncoding]).length);
    assert([probe(config,200,[NSMutableData dataWithLength:150000]) containsString:@"过大"]);
    assert(probe(config,200,@{@"status":@"failed",@"object":@"response",@"output":@[]}).length);
}

static void click(NSControl *control) {
    assert(control.enabled && control.target && control.action);
    auto call = (void (*)(id,SEL,id))[control.target methodForSelector:control.action];
    call(control.target,control.action,control);
}
static void checkForm() {
    SettingsView *settings = [[SettingsView alloc] initWithFrame:NSMakeRect(0,0,920,526)];
    assert(![settings valueForKey:@"apiForm"]);
    NSArray *sections = [settings.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@",@"AI 服务"]];
    assert(sections.count==1); click(sections[0]);
    LLMSettingsForm *form = [settings valueForKey:@"apiForm"];
    waitFor(^BOOL{ return form.apiKey.enabled; });
    assert([form.apiKey isKindOfClass:NSSecureTextField.class] && form.format.numberOfItems==3);
    for (CGFloat width : {920.,500.,700.}) {
        [settings setFrameSize:NSMakeSize(width,526)]; [settings layoutSubtreeIfNeeded];
        for (NSView *control in @[form.endpoint,form.apiKey,form.model,form.format,form])
            assert(NSContainsRect(control.superview.bounds,control.frame) && NSWidth(control.frame)>=150);
    }
    NSButton *save = [form valueForKey:@"save"], *test = [form valueForKey:@"test"];
    NSTextField *status = [form valueForKey:@"status"];
    click(test); assert(status.stringValue.length && !savedRecord);
    form.endpoint.stringValue = @"https://fixture.invalid/v1";
    form.apiKey.stringValue = @"fixture-secret";
    form.model.stringValue = @"chosen-model";
    [form.format selectItemAtIndex:LLMResponses]; click(save);
    waitFor(^BOOL{ return save.enabled; }); assert([status.stringValue containsString:@"已保存"] && savedRecord);
    NSData *first = savedRecord;
    denyWrite = YES; form.model.stringValue = @"changed"; click(save);
    waitFor(^BOOL{ return save.enabled; }); assert(savedRecord == first && [status.stringValue containsString:@"钥匙串"]);
    denyWrite = NO; click(save); waitFor(^BOOL{ return save.enabled; }); assert(![savedRecord isEqual:first]);

    LLMSettingsForm *reopened = [[LLMSettingsForm alloc] initWithFrame:form.bounds];
    waitFor(^BOOL{ return reopened.apiKey.enabled; });
    assert([reopened.endpoint.stringValue isEqual:form.endpoint.stringValue] && [reopened.model.stringValue isEqual:@"changed"]);
    assert([reopened.apiKey.stringValue isEqual:@"fixture-secret"] && reopened.format.indexOfSelectedItem==LLMResponses);
    reopened.endpoint.stringValue = @"https://other.invalid/v1";
    click([reopened valueForKey:@"test"]);
    assert([[(NSTextField *)[reopened valueForKey:@"status"] stringValue] containsString:@"重新输入"]);
}
int main() {
    @autoreleasepool { checkProtocols(); checkForm(); }
    puts("Three LLM wire formats, bounded URLSession probes, settings layout, Keychain save/reopen and failure fixtures OK");
}
