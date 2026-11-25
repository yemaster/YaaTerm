#import "LLMConfiguration.h"
#import "LLMSettingsForm.h"
#import "TerminalAssistant.h"
#import <objc/runtime.h>
#import "SettingsView.h"
#import "Preferences.h"
#import <Security/Security.h>
#include <sys/stat.h>
#include <cassert>
#include <initializer_list>

// Use an isolated local store and a noninteractive fixture for legacy migration.
static NSURL *storeDirectory;
static NSData *legacyRecord;
static NSUInteger legacyReads;
static Boolean legacyUI=true;
static BOOL lockedLegacy=NO;
OSStatus SecKeychainGetUserInteractionAllowed(Boolean *allowed) { *allowed=legacyUI; return errSecSuccess; }
OSStatus SecKeychainSetUserInteractionAllowed(Boolean allowed) { legacyUI=allowed; return errSecSuccess; }
@interface LLMConfiguration (Storage)
+ (NSURL *)credentialDirectory;
@end
@interface LLMConfiguration (CredentialFixture)
+ (NSURL *)fixtureDirectory;
@end
@implementation LLMConfiguration (CredentialFixture)
+ (NSURL *)fixtureDirectory { return storeDirectory; }
@end
static void checkQuery(CFDictionaryRef query) {
    NSDictionary *q=(__bridge NSDictionary *)query;
    assert([q[(id)kSecClass] isEqual:(id)kSecClassGenericPassword]);
    assert([q[(id)kSecAttrService] isEqual:@"dev.yaaterm.llm"] && [q[(id)kSecAttrAccount] isEqual:@"configuration"]);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    assert([q[(id)kSecUseAuthenticationUI] isEqual:(id)kSecUseAuthenticationUIFail]);
#pragma clang diagnostic pop
}
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    checkQuery(query); assert(!legacyUI); ++legacyReads;
    if (lockedLegacy) return errSecInteractionNotAllowed;
    if (!legacyRecord) return errSecItemNotFound;
    *result=CFBridgingRetain(legacyRecord); return errSecSuccess;
}
OSStatus SecItemDelete(CFDictionaryRef query) {
    checkQuery(query); assert(!legacyUI); legacyRecord=nil; return errSecSuccess;
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
static NSArray<NSData *> *streamChunks;
static NSDictionary *(^scriptedReply)(NSDictionary *request);
@implementation FixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"fixture.invalid"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:httpCode
        HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":streamChunks ? @"text/event-stream; charset=utf-8" : @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (streamChunks) {
        NSArray *chunks=streamChunks;
        for (NSData *chunk in [chunks subarrayWithRange:NSMakeRange(0,chunks.count-1)])
            [self.client URLProtocol:self didLoadData:chunk];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,110*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            [self.client URLProtocol:self didLoadData:chunks.lastObject];
            [self.client URLProtocolDidFinishLoading:self];
        });
        return;
    }
    NSData *data=replyData;
    if (scriptedReply) {
        NSData *payload=self.request.HTTPBody;
        if (!payload) {
            NSInputStream *stream=self.request.HTTPBodyStream;
            [stream open]; NSMutableData *bytes=[NSMutableData data];
            uint8_t buffer[2048]; NSInteger size;
            while ((size=[stream read:buffer maxLength:sizeof(buffer)])>0) [bytes appendBytes:buffer length:size];
            [stream close]; payload=bytes;
        }
        NSDictionary *body=[NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        data=[NSJSONSerialization dataWithJSONObject:scriptedReply(body) options:0 error:nil];
    }
    [self.client URLProtocol:self didLoadData:data];
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
        assert(!legacyRecord);
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

// Each stream cuts through a UTF-8 scalar and ends later, after the first visible update.
static void checkStreaming() {
    auto frame=[](NSDictionary *event) {
        NSData *json=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        NSString *payload=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        return [NSString stringWithFormat:@"data: %@\r\n\r\n",payload];
    };
    for (NSInteger i=0;i<3;++i) {
        auto format=(LLMAPIFormat)i;
        auto delta=[&](NSString *text) {
            if (format==LLMChatCompletions) return frame(@{@"choices":@[@{@"delta":@{@"content":text}}]});
            if (format==LLMResponses) return frame(@{@"type":@"response.output_text.delta",@"delta":text});
            return frame(@{@"type":@"content_block_delta",@"delta":@{@"type":@"text_delta",@"text":text}});
        };
        NSString *end=format==LLMChatCompletions ? @"data: [DONE]\r\n\r\n" :
            frame(@{@"type":format==LLMResponses ? @"response.completed" : @"message_stop"});
        NSString *first=[@": heartbeat\r\n\r\n" stringByAppendingString:delta(@"已经")];
        NSData *bytes=[first dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger split=[bytes rangeOfData:[@"已" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,bytes.length)].location+1;
        assert(split>0 && split<bytes.length);
        for (BOOL complete : {YES,NO}) {
            NSString *tail=[delta(@"完成") stringByAppendingString:complete ? end : @""];
            streamChunks=@[[bytes subdataWithRange:NSMakeRange(0,split)],
                [bytes subdataWithRange:NSMakeRange(split,bytes.length-split)],[tail dataUsingEncoding:NSUTF8StringEncoding]];
            __block BOOL sawFirst=NO, done=NO;
            httpCode=200;
            [profile(@"https://fixture.invalid",format) ask:@"input" instruction:@"rules" progress:^(NSString *text) {
                assert(NSThread.isMainThread && !done); if ([text isEqual:@"已经"]) sawFirst=YES;
            } completion:^(NSString *text,NSString *error) {
                assert(sawFirst && (complete ? [text isEqual:@"已经完成"] && !error : !text && error.length)); done=YES;
            }];
            waitFor(^BOOL{ return done; });
        }
    }
    streamChunks=nil;
}

static void click(NSControl *control) {
    assert(control.enabled && control.target && control.action);
    auto call = (void (*)(id,SEL,id))[control.target methodForSelector:control.action];
    call(control.target,control.action,control);
}
static void checkForm() {
    lockedLegacy=YES;
    SettingsView *settings = [[SettingsView alloc] initWithFrame:NSMakeRect(0,0,920,526)];
    assert(![settings valueForKey:@"apiForm"]);
    NSArray *sections = [settings.subviews filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@",@"AI 服务"]];
    assert(sections.count==1); click(sections[0]);
    LLMSettingsForm *form = [settings valueForKey:@"apiForm"];
    waitFor(^BOOL{ return form.apiKey.enabled; });
    NSPopUpButton *colors = [settings valueForKey:@"promptColors"];
    assert(colors && colors.numberOfItems==6 && colors.selectedTag==PreferredAgentPromptColor());
    for (NSMenuItem *item in colors.itemArray) assert(item.image);
    [colors selectItemWithTag:4]; click(colors); assert(PreferredAgentPromptColor()==4);
    NSArray *fields=[settings valueForKey:@"fields"];
    auto field=^(NSString *key){ return [fields filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@",key]].firstObject; };
    NSPopUpButton *padding=field(AgentFramePadding);
    NSSwitch *stream=field(AgentStreamReplies);
    [padding selectItemWithTag:10]; click(padding); assert(PreferredAgentFramePadding()==10);
    stream.state=NSControlStateValueOff; click(stream); assert(![TerminalPreferences() boolForKey:AgentStreamReplies]);
    SetTerminalPreference(AgentStreamReplies,YES); SetTerminalPreference(AgentFramePadding,6);
    assert([form.apiKey isKindOfClass:NSSecureTextField.class] && form.format.numberOfItems==3);
    for (CGFloat width : {920.,500.,700.}) {
        [settings setFrameSize:NSMakeSize(width,526)]; [settings layoutSubtreeIfNeeded];
        for (NSView *control in @[form.endpoint,form.apiKey,form.model,form.format,form])
            assert(NSContainsRect(control.superview.bounds,control.frame) && NSWidth(control.frame)>=150);
    }
    NSButton *save = [form valueForKey:@"save"], *test = [form valueForKey:@"test"];
    NSTextField *status = [form valueForKey:@"status"];
    NSURL *blob=[storeDirectory URLByAppendingPathComponent:@"profile.enc"];
    assert([status.stringValue containsString:@"重新输入"] && legacyUI); lockedLegacy=NO;
    click(test); assert(status.stringValue.length && ![NSData dataWithContentsOfURL:blob]);
    form.endpoint.stringValue = @"https://fixture.invalid/v1";
    form.apiKey.stringValue = @"fixture-secret";
    form.model.stringValue = @"chosen-model";
    [form.format selectItemAtIndex:LLMResponses]; click(save);
    waitFor(^BOOL{ return save.enabled; }); assert([status.stringValue containsString:@"已在本机加密保存"]);
    NSData *first=[NSData dataWithContentsOfURL:blob];
    NSData *secret=[@"fixture-secret" dataUsingEncoding:NSUTF8StringEncoding];
    assert(first.length && [first rangeOfData:secret options:0 range:NSMakeRange(0,first.length)].location==NSNotFound);
    for (NSString *name in @[@"profile.key",@"profile.enc"]) {
        struct stat info{}; assert(!stat([storeDirectory URLByAppendingPathComponent:name].fileSystemRepresentation,&info) && (info.st_mode & 0777)==0600);
    }
    NSUInteger reads=legacyReads;
    assert(!chmod(storeDirectory.fileSystemRepresentation,0755));
    form.model.stringValue=@"changed"; click(save); waitFor(^BOOL{ return save.enabled; });
    assert([[NSData dataWithContentsOfURL:blob] isEqual:first] && [status.stringValue containsString:@"无法保存"]);
    assert(!chmod(storeDirectory.fileSystemRepresentation,0700));
    click(save); waitFor(^BOOL{ return save.enabled; }); assert(![[NSData dataWithContentsOfURL:blob] isEqual:first]);

    LLMSettingsForm *reopened = [[LLMSettingsForm alloc] initWithFrame:form.bounds];
    waitFor(^BOOL{ return reopened.apiKey.enabled; });
    assert([reopened.endpoint.stringValue isEqual:form.endpoint.stringValue] && [reopened.model.stringValue isEqual:@"changed"]);
    assert([reopened.apiKey.stringValue isEqual:@"fixture-secret"] && reopened.format.indexOfSelectedItem==LLMResponses);
    reopened.endpoint.stringValue = @"https://other.invalid/v1";
    click([reopened valueForKey:@"test"]);
    assert([[(NSTextField *)[reopened valueForKey:@"status"] stringValue] containsString:@"重新输入"]);
    SetTerminalPreference(AIErrorExplanations,NO);
    assert([settings valueForKey:@"apiForm"]==form);
    SetTerminalPreference(BuiltInAgent,NO);
    assert(![settings valueForKey:@"apiForm"] && !form.superview && [NSData dataWithContentsOfURL:blob]);
    SetTerminalPreference(LocalAgentLauncher,NO);
    assert(![settings valueForKey:@"promptColors"]);
    SetTerminalPreference(LocalAgentLauncher,YES);
    assert([(NSPopUpButton *)[settings valueForKey:@"promptColors"] selectedTag]==4);
    SetTerminalPreference(BuiltInAgent,YES); SetTerminalPreference(AIErrorExplanations,YES);
    assert([settings valueForKey:@"apiForm"]!=form && legacyReads==reads);
    NSMutableData *damaged=[[NSData dataWithContentsOfURL:blob] mutableCopy];
    ((uint8_t *)damaged.mutableBytes)[damaged.length-1]^=1;
    assert([damaged writeToURL:blob atomically:YES]);
    __block BOOL checked=NO;
    [LLMConfiguration loadSaved:^(LLMConfiguration *p,NSString *e){ assert(!p && e && legacyReads==reads); checked=YES; }];
    waitFor(^BOOL{ return checked; });
    assert([NSFileManager.defaultManager removeItemAtURL:blob error:nil]);
    legacyRecord=[NSJSONSerialization dataWithJSONObject:@{@"endpoint":@"https://fixture.invalid/v1",@"model":@"old",@"key":@"old-secret",@"format":@0} options:0 error:nil];
    checked=NO;
    [LLMConfiguration loadSaved:^(LLMConfiguration *p,NSString *e){ assert(!e && [p.apiKey isEqual:@"old-secret"] && !legacyRecord && legacyUI); checked=YES; }];
    waitFor(^BOOL{ return checked; });
}
@interface FixtureConfig (AssistantTest)
+ (void)loadFixture:(void (^)(LLMConfiguration *,NSString *))completion;
@end
@implementation FixtureConfig (AssistantTest)
+ (void)loadFixture:(void (^)(LLMConfiguration *,NSString *))completion {
    completion(profile(@"https://fixture.invalid/v1",LLMChatCompletions),nil);
}
@end

static void checkAssistant() {
    for (NSInteger i=0;i<3;++i) {
        FixtureConfig *config=profile(@"https://fixture.invalid/v1",(LLMAPIFormat)i);
        httpCode=200; scriptedReply=^NSDictionary *(NSDictionary *body) {
            if (i==LLMResponses) {
                assert([body[@"input"] isEqual:@"input"] && [body[@"instructions"] isEqual:@"rules"] && [body[@"store"] isEqual:@NO]);
                return @{@"object":@"response",@"status":@"completed",@"output":@[@{@"type":@"reasoning"},
                    @{@"type":@"message",@"role":@"assistant",@"content":@[@{@"type":@"output_text",@"text":@"fixed"}]}]};
            }
            if (i==LLMAnthropicMessages) {
                assert([body[@"system"] isEqual:@"rules"]);
                return @{@"type":@"message",@"role":@"assistant",@"content":@[@{@"type":@"thinking",@"thinking":@"hidden"},
                    @{@"type":@"text",@"text":@"fixed"}]};
            }
            assert([body[@"messages"][0][@"role"] isEqual:@"system"] && [body[@"messages"][1][@"content"] isEqual:@"input"]);
            return @{@"choices":@[@{@"message":@{@"content":@"fixed"}}]};
        };
        __block BOOL done=NO;
        [config ask:@"input" instruction:@"rules" progress:nil completion:^(NSString *value,NSString *error) {
            assert(!error && [value isEqual:@"fixed"] && NSThread.isMainThread); done=YES;
        }];
        waitFor(^BOOL{ return done; });
    }

    NSFileManager *files=NSFileManager.defaultManager;
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([files createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"alpha" writeToFile:[dir stringByAppendingPathComponent:@"sample.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([files createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:@"shortcut"] withDestinationPath:@"/etc/hosts" error:nil]);
    Method saved=class_getClassMethod(LLMConfiguration.class,@selector(loadSaved:));
    IMP original=method_setImplementation(saved,method_getImplementation(class_getClassMethod(FixtureConfig.class,@selector(loadFixture:))));
    TerminalAssistant *panel=[[TerminalAssistant alloc] initWithDirectory:dir shell:@"zsh"];
    __block BOOL completed=NO; __block int proposals=0;
    panel.onComplete=^(NSString *summary, BOOL failed){ assert(!failed && [summary isEqual:@"已核对"]); completed=YES; };
    __weak TerminalAssistant *owner=panel;
    panel.onShellLine=^BOOL(NSString *cmd, BOOL execute){
        assert(execute);
        NSDictionary *outputs=@{@"command yaa-inspect list '.'":@"sample.txt",
            @"command yaa-inspect read 'shortcut'":@"无法打开该路径。",@"command yaa-inspect read 'sample.txt'":@"alpha"};
        NSString *output=outputs[cmd];
        if (!output) { ++proposals; return [cmd isEqual:@"wc -l sample.txt"]; }
        dispatch_async(dispatch_get_main_queue(),^{
            [owner receivedResult:@{@"command":cmd,@"status":@([cmd containsString:@"shortcut"]),@"output":output}];
        });
        return YES;
    };
    scriptedReply=^NSDictionary *(NSDictionary *body) {
        NSString *input=[body[@"messages"] lastObject][@"content"];
        NSDictionary *task=[NSJSONSerialization JSONObjectWithData:[input dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSArray *steps=task[@"steps"]; NSString *json;
        switch (steps.count) {
            case 0: json=@"{\"action\":\"list\",\"path\":\".\"}"; break;
            case 1: assert([steps[0][@"output"] containsString:@"sample.txt"]);
                json=@"{\"action\":\"read\",\"path\":\"shortcut\"}"; break;
            case 2: assert([steps[1][@"output"] containsString:@"无法"]);
                json=@"{\"action\":\"read\",\"path\":\"sample.txt\"}"; break;
            case 3: assert([steps[2][@"output"] isEqual:@"alpha"]);
                json=@"{\"text\":\"统计行数\",\"command\":\"wc -l sample.txt\"}"; break;
            default: assert([steps.lastObject[@"output"] isEqual:@"1 sample.txt"]);
                json=@"{\"text\":\"已核对\"}"; break;
        }
        return @{@"choices":@[@{@"message":@{@"content":json}}]};
    };
    __block NSString *transcript=nil;
    panel.onTranscript=^(NSString *line){ transcript=line; };
    [panel submitTask:@"核对文件"];
    waitFor(^BOOL{ return proposals==1; });
    assert(!completed && !panel.diagnosisView && [panel.expectedCommand isEqual:@"wc -l sample.txt"]);
    [panel receivedResult:@{@"command":panel.expectedCommand,@"status":@0,@"output":@"1 sample.txt"}];
    waitFor(^BOOL{ return completed; }); assert(!panel.expectedCommand);
    scriptedReply=^NSDictionary *(NSDictionary *body) {
        NSDictionary *task=[NSJSONSerialization JSONObjectWithData:[[body[@"messages"] lastObject][@"content"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        assert([task[@"failure"][@"status"] isEqual:@127] && [task[@"mode"] isEqual:@"diagnose"]);
        return @{@"choices":@[@{@"message":@{@"content":@"{\"text\":\"拼写有误\",\"command\":\"ls\\nwhoami\"}"}}]};
    };
    TerminalAssistant *diagnosis=[[TerminalAssistant alloc] initWithDirectory:dir shell:@"zsh"];
    [diagnosis prepareForLocalTool:nil diagnosis:YES];
    [diagnosis explain:@{@"command":@"lss",@"status":@127,@"output":@"command not found"}];
    waitFor(^BOOL{ return ![[diagnosis valueForKey:@"busy"] boolValue]; });
    assert([[diagnosis.diagnosisView valueForKey:@"action"] isHidden] && !diagnosis.expectedCommand);
    // A stopped request must not publish a late result or continue inspecting files.
    scriptedReply=^NSDictionary *(NSDictionary *) {
        return @{@"choices":@[@{@"message":@{@"content":@"late reply"}}]};
    };
    completed=NO; [panel submitTask:@"取消这次任务"]; [panel submitTask:@"/stop"];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.08]];
    assert(!completed && [transcript isEqual:@"已停止"]);
    scriptedReply=nil; method_setImplementation(saved,original);
    assert([files removeItemAtPath:dir error:nil]);
}
int main() {
    @autoreleasepool {
        storeDirectory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        Method directory=class_getClassMethod(LLMConfiguration.class,@selector(credentialDirectory));
        method_setImplementation(directory,method_getImplementation(class_getClassMethod(LLMConfiguration.class,@selector(fixtureDirectory))));
        checkProtocols(); checkStreaming(); checkForm(); checkAssistant();
        assert([NSFileManager.defaultManager removeItemAtURL:storeDirectory error:nil]);
    }
    puts("Three LLM wire formats, local encryption and migration, agent directory/read loop, reviewed shell continuation and error diagnosis OK");
}
