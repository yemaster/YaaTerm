#import "LLMSettingsForm.h"
#import "LLMConfiguration.h"
#import "Palette.h"

@interface LLMSettingsForm () <NSTextFieldDelegate>
@end

@implementation LLMSettingsForm {
    NSButton *_test, *_save;
    NSTextField *_status;
    NSURLSessionDataTask *_task;
    NSUInteger _revision;
    NSURL *_savedService;
    BOOL _usingSavedKey;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _format = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,204,26) pullsDown:NO];
        [_format addItemsWithTitles:@[@"OpenAI Chat Completions",@"OpenAI Responses",@"Anthropic Messages"]];
        _format.target = self; _format.action = @selector(draftChanged:);
        _endpoint = [NSTextField textFieldWithString:@""];
        _endpoint.placeholderString = @"https://api.example.com/v1";
        _endpoint.toolTip = @"自定义基础路径请以 / 结尾。";
        _apiKey = [[NSSecureTextField alloc] initWithFrame:NSZeroRect]; _apiKey.placeholderString = @"API Key";
        _model = [NSTextField textFieldWithString:@""]; _model.placeholderString = @"模型 ID";
        for (NSTextField *field in @[_endpoint,_apiKey,_model]) {
            field.frame = NSMakeRect(0,0,300,24);
            field.autoresizingMask = NSViewWidthSizable;
            field.delegate = self; field.usesSingleLineMode = YES;
        }
        _test = [NSButton buttonWithTitle:@"测试连接" target:self action:@selector(testConnection:)];
        _test.toolTip = @"发送一条测试消息，可能计费。";
        _save = [NSButton buttonWithTitle:@"保存" target:self action:@selector(save:)];
        _status = [NSTextField wrappingLabelWithString:@""];
        _status.font = [NSFont systemFontOfSize:12];
        self.autoresizingMask = NSViewWidthSizable;
        for (NSView *view in @[_test,_save,_status]) [self addSubview:view];
        [self applyPalette]; [self setFormEnabled:NO];
        __weak LLMSettingsForm *weakSelf = self;
        [LLMConfiguration loadSaved:^(LLMConfiguration *profile, NSString *error) {
            [weakSelf loaded:profile error:error];
        }];
    }
    return self;
}
- (void)loaded:(LLMConfiguration *)profile error:(NSString *)error {
    if (profile) {
        _endpoint.stringValue = profile.endpoint; _apiKey.stringValue = profile.apiKey;
        _model.stringValue = profile.model; [_format selectItemAtIndex:profile.format];
        _savedService = profile.requestURL; _usingSavedKey = YES;
    }
    [self setFormEnabled:YES]; [self showStatus:error];
}
- (void)setFormEnabled:(BOOL)enabled {
    for (NSControl *control in @[_format,_endpoint,_apiKey,_model,_test,_save]) control.enabled = enabled;
}
- (BOOL)isFlipped { return YES; }
- (NSSize)statusSizeForWidth:(CGFloat)width {
    if (!_status.stringValue.length) return NSZeroSize;
    CGFloat available = MAX(1.,width < 400 ? width : width-172);
    CGFloat height = ceil([_status.cell cellSizeForBounds:NSMakeRect(0,0,available,CGFLOAT_MAX)].height);
    return NSMakeSize(available,height);
}
- (CGFloat)heightForWidth:(CGFloat)width {
    NSSize status = [self statusSizeForWidth:width];
    return width < 400 && status.height ? 34+status.height : MAX(28.,status.height);
}
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    NSSize size = [self statusSizeForWidth:width];
    CGFloat y = width < 400 ? 0 : floor((NSHeight(self.bounds)-28)/2);
    _save.frame = NSMakeRect(width-64,y,64,28);
    _test.frame = NSMakeRect(NSMinX(_save.frame)-94,y,88,28);
    _status.frame = (NSRect){NSMakePoint(0,width < 400 ? 34 : floor((NSHeight(self.bounds)-size.height)/2)),size};
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout = YES; }
- (void)applyPalette { _status.textColor = CurrentInterfacePalette().secondaryText; }
- (void)showStatus:(NSString *)message {
    CGFloat width = NSWidth(self.bounds), oldHeight = [self heightForWidth:width];
    _status.stringValue = message ?: @"";
    self.needsLayout = YES;
    if (oldHeight != [self heightForWidth:width] && _onHeightChange) _onHeightChange();
    if (message.length && self.window.isKeyWindow)
        NSAccessibilityPostNotificationWithUserInfo(self,NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey:message,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityMedium)});
}
- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object == _apiKey) _usingSavedKey = NO;
    [self draftChanged:note.object];
}
- (void)draftChanged:(id)sender {
    [self cancelTest]; [self showStatus:nil];
}
- (void)cancelTest {
    ++_revision;
    if (!_task) return;
    [_task cancel]; _task = nil; _test.enabled = YES; [self showStatus:nil];
}
- (void)dealloc { [_task cancel]; }
- (LLMConfiguration *)validatedDraft {
    LLMConfiguration *draft = [[LLMConfiguration alloc] initWithEndpoint:_endpoint.stringValue key:_apiKey.stringValue
        model:_model.stringValue format:(LLMAPIFormat)_format.indexOfSelectedItem];
    NSString *error = draft.validationError;
    if (!error && _usingSavedKey) {
        NSURL *url = draft.requestURL;
        if ([url.host caseInsensitiveCompare:_savedService.host] != NSOrderedSame ||
            [url.scheme caseInsensitiveCompare:_savedService.scheme] != NSOrderedSame ||
            !(url.port == _savedService.port || [url.port isEqual:_savedService.port]))
            error = @"服务地址已更换，请重新输入该服务的 API Key。";
    }
    if (error) { [self showStatus:error]; return nil; }
    return draft;
}
- (void)testConnection:(id)sender {
    LLMConfiguration *draft = [self validatedDraft];
    if (!draft) return;
    [self cancelTest];
    NSUInteger revision = _revision;
    _test.enabled = NO; [self showStatus:@"正在测试连接…"];
    __weak LLMSettingsForm *weakSelf = self;
    _task = [draft testConnection:^(NSString *error) {
        LLMSettingsForm *form = weakSelf;
        if (!form || form->_revision != revision) return;
        form->_task = nil; form->_test.enabled = YES;
        [form showStatus:error ?: @"连接成功，模型已响应。"];
    }];
}
- (void)save:(id)sender {
    LLMConfiguration *draft = [self validatedDraft];
    if (!draft) return;
    [self cancelTest]; [self setFormEnabled:NO]; [self showStatus:@"正在保存…"];
    __weak LLMSettingsForm *weakSelf = self;
    [draft save:^(NSString *error) {
        LLMSettingsForm *form = weakSelf;
        if (!form) return;
        if (!error) { form->_usingSavedKey = YES; form->_savedService = draft.requestURL; }
        [form setFormEnabled:YES]; [form showStatus:error ?: @"已在本机加密保存。"];
    }];
}
@end
