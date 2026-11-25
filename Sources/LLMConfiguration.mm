#import "LLMConfiguration.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}
static NSArray<NSString *> *routes() {
    return @[@"chat/completions", @"responses", @"messages"];
}
static dispatch_queue_t credentialQueue() {
    static dispatch_queue_t queue = dispatch_queue_create("dev.yaaterm.llm.credentials", DISPATCH_QUEUE_SERIAL);
    return queue;
}
// Publish a fully written owner-only file. A second process may win first-use key creation.
static BOOL publishPrivateData(NSData *data, NSURL *url, BOOL replace) {
    NSURL *temporary=[[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int fd=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    if (fd<0) return NO;
    BOOL ok=YES;
    size_t offset=0;
    while (offset<data.length) {
        ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) { ok=NO; break; }
        offset+=(size_t)n;
    }
    if (ok) ok=fsync(fd)==0;
    if (close(fd)!=0) ok=NO;
    if (ok) ok=replace ? rename(temporary.fileSystemRepresentation,url.fileSystemRepresentation)==0 :
        (link(temporary.fileSystemRepresentation,url.fileSystemRepresentation)==0 || errno==EEXIST);
    unlink(temporary.fileSystemRepresentation);
    return ok;
}

// Independent 256-bit keys for AES-CBC and HMAC-SHA256. Authenticate the version,
// random IV and ciphertext before decrypting. All cryptography runs in-process.
static NSData *localKey(NSURL *directory, BOOL create) {
    NSURL *file=[directory URLByAppendingPathComponent:@"profile.key"];
    NSData *key=[NSData dataWithContentsOfURL:file];
    if (!key && create) {
        NSMutableData *random=[NSMutableData dataWithLength:2*kCCKeySizeAES256];
        arc4random_buf(random.mutableBytes,random.length);
        if (!publishPrivateData(random,file,NO)) return nil;
        key=[NSData dataWithContentsOfURL:file];
    }
    return key.length==2*kCCKeySizeAES256 ? key : nil;
}
static NSData *cryptProfile(NSData *data, NSData *key, BOOL encrypt) {
    if (!key || !data) return nil;
    constexpr size_t prefix=4+kCCBlockSizeAES128, tag=CC_SHA256_DIGEST_LENGTH;
    const uint8_t *macKey=(const uint8_t *)key.bytes+kCCKeySizeAES256;
    if (encrypt) {
        NSMutableData *sealed=[NSMutableData dataWithLength:prefix+data.length+kCCBlockSizeAES128+tag];
        uint8_t *out=(uint8_t *)sealed.mutableBytes;
        memcpy(out,"YAC1",4); arc4random_buf(out+4,kCCBlockSizeAES128);
        size_t count=0;
        if (CCCrypt(kCCEncrypt,kCCAlgorithmAES,kCCOptionPKCS7Padding,key.bytes,kCCKeySizeAES256,out+4,
                    data.bytes,data.length,out+prefix,sealed.length-prefix-tag,&count)!=kCCSuccess) return nil;
        CCHmac(kCCHmacAlgSHA256,macKey,kCCKeySizeAES256,out,prefix+count,out+prefix+count);
        sealed.length=prefix+count+tag; return sealed;
    }
    const uint8_t *in=(const uint8_t *)data.bytes;
    if (data.length<prefix+kCCBlockSizeAES128+tag || memcmp(in,"YAC1",4)) return nil;
    size_t signedSize=data.length-tag;
    uint8_t expected[tag];
    CCHmac(kCCHmacAlgSHA256,macKey,kCCKeySizeAES256,in,signedSize,expected);
    if (timingsafe_bcmp(expected,in+signedSize,tag)) return nil;
    NSMutableData *plain=[NSMutableData dataWithLength:signedSize-prefix];
    size_t count=0;
    if (CCCrypt(kCCDecrypt,kCCAlgorithmAES,kCCOptionPKCS7Padding,key.bytes,kCCKeySizeAES256,in+4,
                in+prefix,plain.length,plain.mutableBytes,plain.length,&count)!=kCCSuccess) return nil;
    plain.length=count; return plain;
}

static BOOL storeProfile(NSData *plain, NSURL *directory, BOOL replace) {
    if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil]) return NO;
    struct stat info{};
    if (lstat(directory.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode) || info.st_uid!=geteuid() || (info.st_mode&0077)) return NO;
    NSData *cipher=cryptProfile(plain,localKey(directory,YES),YES);
    return cipher && publishPrivateData(cipher,[directory URLByAppendingPathComponent:@"profile.enc"],replace);
}

// Used only to migrate the previous version's single login-keychain item.
static OSStatus accessLegacyItem(CFTypeRef *record) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // The original item may be protected by a file-based login-keychain ACL.
    // Suppress both legacy password panels and modern authentication UI for this call.
    Boolean allowed=false;
    if (SecKeychainGetUserInteractionAllowed(&allowed)!=errSecSuccess ||
        (allowed && SecKeychainSetUserInteractionAllowed(false)!=errSecSuccess)) return errSecInteractionNotAllowed;
    NSMutableDictionary *query=[@{(id)kSecClass:(id)kSecClassGenericPassword,(id)kSecAttrService:@"dev.yaaterm.llm",
        (id)kSecAttrAccount:@"configuration",(id)kSecUseAuthenticationUI:(id)kSecUseAuthenticationUIFail} mutableCopy];
    if (record) query[(id)kSecReturnData]=@YES;
    OSStatus result=record ? SecItemCopyMatching((__bridge CFDictionaryRef)query,record) : SecItemDelete((__bridge CFDictionaryRef)query);
    if (allowed) SecKeychainSetUserInteractionAllowed(true);
#pragma clang diagnostic pop
    return result;
}

static NSString *responseError(NSHTTPURLResponse *response, id json, LLMAPIFormat format) {
    NSInteger status = response.statusCode;
    if (status < 200 || status >= 300) {
        NSString *hint;
        if (status == 401 || status == 403) hint = @"请检查 API Key 和模型权限。";
        else if (status == 404) hint = @"请检查服务地址和模型名称。";
        else if (status == 429) hint = @"请检查服务额度或稍后再试。";
        else if (status >= 300 && status < 400) hint = @"请直接填写跳转后的服务地址。";
        else hint = @"请检查 API 格式、模型和服务状态。";
        return [NSString stringWithFormat:@"HTTP %ld · %@",(long)status,hint];
    }
    if (![json isKindOfClass:NSDictionary.class]) return @"服务返回了非预期内容，请检查 API 地址。";
    if (json[@"error"] && json[@"error"] != NSNull.null) return @"模型服务返回错误，请检查模型和权限。";
    BOOL valid = NO;
    if (format == LLMChatCompletions) {
        NSArray *choices = json[@"choices"];
        id first = [choices isKindOfClass:NSArray.class] ? choices.firstObject : nil;
        valid = [first isKindOfClass:NSDictionary.class] && [first[@"message"] isKindOfClass:NSDictionary.class];
    } else if (format == LLMResponses) {
        BOOL completed = [json[@"status"] isEqual:@"completed"];
        id details = json[@"incomplete_details"];
        BOOL tokenLimit = [json[@"status"] isEqual:@"incomplete"] && [details isKindOfClass:NSDictionary.class]
                       && [details[@"reason"] isEqual:@"max_output_tokens"];
        valid = [json[@"object"] isEqual:@"response"] && [json[@"output"] isKindOfClass:NSArray.class] && (completed || tokenLimit);
    } else {
        valid = [json[@"type"] isEqual:@"message"] && [json[@"role"] isEqual:@"assistant"] && [json[@"content"] isKindOfClass:NSArray.class];
    }
    return valid ? nil : @"响应与所选 API 格式不符，或模型未完成请求。";
}

static NSString *assistantText(NSDictionary *json, LLMAPIFormat format) {
    id parts;
    if (format == LLMChatCompletions) {
        parts = [json[@"choices"] firstObject][@"message"][@"content"];
        if ([parts isKindOfClass:NSString.class]) return trim(parts);
    } else if (format == LLMResponses) {
        for (id item in json[@"output"]) {
            if ([item isKindOfClass:NSDictionary.class] && [item[@"type"] isEqual:@"message"] &&
                [item[@"role"] isEqual:@"assistant"]) { parts = item[@"content"]; break; }
        }
    } else parts = json[@"content"];
    NSMutableArray *texts = [NSMutableArray array];
    if ([parts isKindOfClass:NSArray.class]) for (id part in parts) {
        if (![part isKindOfClass:NSDictionary.class] || ![part[@"text"] isKindOfClass:NSString.class]) continue;
        if ([part[@"type"] isEqual:format == LLMResponses ? @"output_text" : @"text"]) [texts addObject:part[@"text"]];
    }
    return trim([texts componentsJoinedByString:@"\n"]);
}

// One short-lived delegate per user request. Bound memory even if the URL serves a large file.
@interface LLMExchange : NSObject <NSURLSessionDataDelegate>
@property LLMAPIFormat format;
@property NSMutableData *bytes;
@property BOOL tooLarge;
@property BOOL wantsText;
@property (copy) void (^completion)(NSString *, NSString *);
@end
@implementation LLMExchange
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))reply {
    reply(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.tooLarge) return;
    if (data.length > 128*1024-self.bytes.length) { self.tooLarge = YES; [task cancel]; return; }
    [self.bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *message = nil;
    if (self.tooLarge) message = @"响应过大，请检查 API 地址。";
    else if (error.code == NSURLErrorTimedOut) message = @"连接超时，请检查服务地址或网络。";
    else if (error) message = @"未能连接服务，请检查网络、地址和 TLS 证书。";
    NSString *text = nil;
    if (!message) {
        id json = [NSJSONSerialization JSONObjectWithData:self.bytes options:0 error:nil];
        message = responseError((NSHTTPURLResponse *)task.response,json,self.format);
        if (!message && self.wantsText) {
            BOOL incomplete = (self.format==LLMResponses && [json[@"status"] isEqual:@"incomplete"]) ||
                (self.format==LLMChatCompletions && [[[json[@"choices"] firstObject] objectForKey:@"finish_reason"] isEqual:@"length"]) ||
                (self.format==LLMAnthropicMessages && [json[@"stop_reason"] isEqual:@"max_tokens"]);
            if (incomplete) message = @"模型回复超过长度限制，请缩小任务范围。";
            else {
                text = assistantText(json,self.format);
                if (!text.length) message = @"模型没有返回文本。";
            }
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ self.completion(text,message); });
    [session finishTasksAndInvalidate];
}
@end

@interface LLMConfiguration ()
- (NSURLSessionConfiguration *)testSessionConfiguration;
@end
@implementation LLMConfiguration
- (instancetype)initWithEndpoint:(NSString *)endpoint key:(NSString *)key model:(NSString *)model format:(LLMAPIFormat)format {
    if ((self = [super init])) {
        _endpoint = [trim(endpoint) copy]; _apiKey = [trim(key) copy]; _model = [trim(model) copy]; _format = format;
    }
    return self;
}
- (NSURL *)requestURL {
    if (_format < LLMChatCompletions || _format > LLMAnthropicMessages) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:_endpoint];
    if (!parts.host.length || parts.user || parts.password || parts.fragment ||
        [_endpoint rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
    NSString *host = parts.host.lowercaseString, *scheme = parts.scheme.lowercaseString;
    BOOL local = [@[@"localhost",@"127.0.0.1",@"::1",@"[::1]"] containsObject:host];
    if (![scheme isEqual:@"https"] && !(local && [scheme isEqual:@"http"])) return nil;
    NSString *path = parts.percentEncodedPath;
    BOOL directory = [path hasSuffix:@"/"];
    while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length-1];
    NSString *route = routes()[_format];
    BOOL fullRoute = NO;
    for (NSString *known in routes()) {
        if (![path hasSuffix:[@"/" stringByAppendingString:known]]) continue;
        if (![known isEqual:route]) return nil;
        fullRoute = YES; break;
    }
    if (!path.length) path = [@"/v1/" stringByAppendingString:route];
    else if (!fullRoute && (directory || [path.lastPathComponent isEqual:@"v1"]))
        path = [path stringByAppendingPathComponent:route];
    parts.percentEncodedPath = path;
    return parts.URL;
}
- (NSString *)validationError {
    if (!self.requestURL) return @"请填写与 API 格式匹配的 HTTPS 地址。本机服务也支持 HTTP。";
    if (!_apiKey.length || [_apiKey rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return @"请输入有效的 API Key。";
    if (!_model.length) return @"请输入服务提供的模型名称。";
    return nil;
}
- (NSURLRequest *)connectionTestRequest {
    return [self requestWithInstruction:nil input:@"Reply OK." limit:16];
}
- (NSURLRequest *)requestWithInstruction:(NSString *)instruction input:(NSString *)prompt limit:(NSInteger)limit {
    if (self.validationError) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.requestURL];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSMutableDictionary *body = [@{@"model":_model} mutableCopy];
    if (_format == LLMResponses) {
        body[@"input"] = prompt; if (instruction) body[@"instructions"] = instruction;
        body[@"max_output_tokens"] = @(limit); body[@"store"] = @NO;
    } else {
        NSDictionary *user = @{@"role":@"user", @"content":prompt};
        if (instruction && _format == LLMChatCompletions)
            body[@"messages"] = @[@{@"role":@"system", @"content":instruction},user];
        else body[@"messages"] = @[user];
        if (instruction && _format == LLMAnthropicMessages) body[@"system"] = instruction;
        body[_format == LLMChatCompletions ? @"max_completion_tokens" : @"max_tokens"] = @(limit);
    }
    if (_format == LLMAnthropicMessages) {
        [request setValue:_apiKey forHTTPHeaderField:@"x-api-key"];
        [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    } else {
        [request setValue:[@"Bearer " stringByAppendingString:_apiKey] forHTTPHeaderField:@"Authorization"];
    }
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return request;
}
- (NSURLSessionConfiguration *)testSessionConfiguration {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30;
    config.URLCache = nil; config.HTTPCookieStorage = nil; config.URLCredentialStorage = nil;
    return config;
}
- (NSURLSessionDataTask *)testConnection:(void (^)(NSString *))completion {
    return [self performRequest:self.connectionTestRequest wantsText:NO completion:^(NSString *, NSString *error){ completion(error); }];
}
- (NSURLSessionDataTask *)ask:(NSString *)input instruction:(NSString *)instruction completion:(void (^)(NSString *,NSString *))completion {
    return [self performRequest:[self requestWithInstruction:instruction input:input limit:2048] wantsText:YES completion:completion];
}
- (NSURLSessionDataTask *)performRequest:(NSURLRequest *)request wantsText:(BOOL)wantsText completion:(void (^)(NSString *,NSString *))completion {
    if (!request) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,self.validationError); });
        return nil;
    }
    LLMExchange *probe = [LLMExchange new];
    probe.wantsText = wantsText; probe.format = _format; probe.bytes = [NSMutableData data]; probe.completion = completion;
    NSURLSessionConfiguration *config = [self testSessionConfiguration];
    if (wantsText) { config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 120; }
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:probe delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    [task resume]; return task;
}
+ (NSURL *)credentialDirectory {
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"YaaTerm/Credentials" isDirectory:YES];
}
+ (instancetype)profileFromData:(NSData *)data {
    if (!data) return nil;
    id record=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"endpoint"] isKindOfClass:NSString.class] ||
        ![record[@"model"] isKindOfClass:NSString.class] || ![record[@"key"] isKindOfClass:NSString.class] ||
        ![record[@"format"] isKindOfClass:NSNumber.class]) return nil;
    LLMConfiguration *profile=[[self alloc] initWithEndpoint:record[@"endpoint"] key:record[@"key"]
        model:record[@"model"] format:(LLMAPIFormat)[record[@"format"] integerValue]];
    return profile.validationError ? nil : profile;
}
+ (void)loadSaved:(void (^)(LLMConfiguration *, NSString *))completion {
    dispatch_async(credentialQueue(), ^{
        NSURL *dir=[self credentialDirectory], *file=[dir URLByAppendingPathComponent:@"profile.enc"];
        NSError *readError=nil;
        NSData *cipher=[NSData dataWithContentsOfURL:file options:0 error:&readError];
        NSString *error=nil;
        BOOL migrated=NO;
        if (!cipher && [readError.domain isEqual:NSCocoaErrorDomain] && readError.code==NSFileReadNoSuchFileError) {
            CFTypeRef result=nullptr;
            OSStatus status=accessLegacyItem(&result);
            NSData *old=CFBridgingRelease(result);
            if (status==errSecSuccess && [self profileFromData:old] && storeProfile(old,dir,NO)) {
                cipher=[NSData dataWithContentsOfURL:file]; migrated=YES;
            } else if (status!=errSecItemNotFound) {
                error=@"请重新输入 API 配置，保存后即可在本机使用。";
            }
        } else if (!cipher) error=@"无法读取本机 API 配置。";
        LLMConfiguration *profile=nil;
        if (cipher) {
            profile=[self profileFromData:cryptProfile(cipher,localKey(dir,NO),NO)];
            if (!profile) error=@"本机 API 配置无法解密，请重新保存。";
            else if (migrated) {
                OSStatus removed=accessLegacyItem(nullptr);
                if (removed!=errSecSuccess && removed!=errSecItemNotFound)
                    error=@"配置已迁移。旧钥匙串条目仍需手动移除。";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(profile,error); });
    });
}
- (void)save:(void (^)(NSString *))completion {
    dispatch_async(credentialQueue(), ^{
        NSString *error=self.validationError;
        if (!error) {
            NSDictionary *record=@{@"endpoint":self.endpoint,@"model":self.model,@"key":self.apiKey,@"format":@(self.format)};
            NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
            if (!data || !storeProfile(data,[self.class credentialDirectory],YES)) error=@"无法保存本机 API 配置。";
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}
@end
