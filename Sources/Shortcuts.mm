#import "Shortcuts.h"
#import "Preferences.h"
#include <array>

NSString *const ShortcutPreferences=@"KeyboardShortcuts";
static constexpr NSUInteger cmd=NSEventModifierFlagCommand, ctrl=NSEventModifierFlagControl;
static constexpr NSUInteger shift=NSEventModifierFlagShift, opt=NSEventModifierFlagOption, mods=cmd|ctrl|shift|opt;

const ShortcutInfo &Shortcut(ShortcutID index) {
    static const ShortcutInfo items[ShortcutCount]={
        {@"addWindow:",@"新建窗口",@"窗口与标签页",cmd|'n'},
        {@"addTab:",@"新建标签页",@"窗口与标签页",cmd|'t'},
        {@"previousSessionTab:",@"上一个标签页",@"窗口与标签页",cmd|shift|'{'},
        {@"nextSessionTab:",@"下一个标签页",@"窗口与标签页",cmd|shift|'}'},
        {@"closePane:",@"关闭当前分屏或标签页",@"窗口与标签页",cmd|'w'},
        {@"splitRight:",@"左右分屏",@"分屏",cmd|'d'}, {@"splitDown:",@"上下分屏",@"分屏",cmd|shift|'d'},
        {@"previousPane:",@"上一个分屏",@"分屏",cmd|opt|'['}, {@"nextPane:",@"下一个分屏",@"分屏",cmd|opt|']'},
        {@"copy:",@"复制",@"编辑与搜索",cmd|'c'}, {@"paste:",@"粘贴",@"编辑与搜索",cmd|'v'},
        {@"showFind:",@"搜索终端内容…",@"编辑与搜索",cmd|'f'}, {@"terminalFind",@"搜索（终端内）",@"编辑与搜索",ctrl|'f'},
        {@"findNext:",@"查找下一处",@"编辑与搜索",cmd|'g'}, {@"findPrevious:",@"查找上一处",@"编辑与搜索",cmd|shift|'g'},
        {@"searchNext",@"下一处（搜索框）",@"编辑与搜索",'\r'}, {@"searchPrevious",@"上一处（搜索框）",@"编辑与搜索",shift|'\r'},
        {@"searchClose",@"关闭搜索框",@"编辑与搜索",0x1b},
        {@"toggleAssistant:",@"切换 Agent 输入",@"Agent",cmd|'j'}, {@"explainFailure:",@"命令解释",@"Agent",cmd|shift|'e'},
        {@"agentApprove",@"确认执行命令",@"Agent",'\r'}, {@"agentStop",@"停止当前任务",@"Agent",ctrl|'c'},
        {@"larger:",@"放大字号",@"显示与应用",cmd|'='}, {@"smaller:",@"缩小字号",@"显示与应用",cmd|'-'},
        {@"normalSize:",@"恢复默认字号",@"显示与应用",cmd|'0'}, {@"showSettings:",@"设置…",@"显示与应用",cmd|','},
        {@"performMiniaturize:",@"最小化",@"显示与应用",cmd|'m'}, {@"toggleFullScreen:",@"切换全屏",@"显示与应用",cmd|ctrl|'f'},
        {@"terminate:",@"退出 YaaTerm",@"显示与应用",cmd|'q'}
    };
    return items[index];
}
static BOOL functionKey(unichar key) { return key>=NSF1FunctionKey && key<=NSF35FunctionKey; }
static unsigned scope(ShortcutID index) {
    if (index>=SearchNextKey && index<=SearchCloseKey) return 1;
    if (index==ApproveKey || index==StopAgentKey || index==TerminalFindKey) return 2;
    return 3;
}
static BOOL valid(ShortcutID index, NSUInteger code) {
    unichar k=code & 0xffff;
    if (!code) return YES;
    if (!k || code & ~(mods|0xffffUL) || (k>=0xd800 && k<=0xdfff)) return NO;
    if (code & (cmd|opt|ctrl) || functionKey(k)) return YES;
    return scope(index)!=3 && (k=='\r' || k==0x1b || k==NSTabCharacter ||
           (k>=NSUpArrowFunctionKey && k<=NSRightArrowFunctionKey));
}
using Bindings=std::array<NSUInteger,ShortcutCount>;
static Bindings &bindings() {
    static Bindings values=[]{
        Bindings result{};
        NSDictionary *saved=[TerminalPreferences() dictionaryForKey:ShortcutPreferences];
        for (NSInteger i=0;i<ShortcutCount;++i) {
            auto id=(ShortcutID)i; const auto &item=Shortcut(id);
            NSNumber *value=saved[item.identifier];
            result[i]=[value isKindOfClass:NSNumber.class] && valid(id,value.unsignedIntegerValue) ? value.unsignedIntegerValue : item.standard;
        }
        return result;
    }();
    return values;
}
NSUInteger ShortcutValue(ShortcutID index) { return bindings()[index]; }
static NSUInteger eventKey(NSEvent *event) {
    switch (event.keyCode) {
        case 36: case 76: return '\r';
        case 48: return NSTabCharacter;
        case 53: return 0x1b;
        case 51: return NSBackspaceCharacter;
    }
    NSString *key=event.charactersIgnoringModifiers.lowercaseString;
    return key.length==1 ? [key characterAtIndex:0] : 0;
}
BOOL MatchesShortcut(NSEvent *event, ShortcutID index) {
    NSUInteger code=ShortcutValue(index);
    return code && (event.modifierFlags & mods)==(code & mods) && eventKey(event)==(code & 0xffff);
}
static NSString *keyString(unichar key) { return [NSString stringWithCharacters:&key length:1]; }
static NSString *label(NSUInteger code) {
    if (!code) return @"未设置";
    unichar k=code & 0xffff;
    NSString *key;
    switch (k) {
        case '\r': key=@"↩"; break; case 0x1b: key=@"Esc"; break; case ' ': key=@"空格"; break;
        case NSTabCharacter: key=@"⇥"; break; case NSBackspaceCharacter: key=@"⌫"; break;
        case NSDeleteFunctionKey: key=@"⌦"; break; case NSLeftArrowFunctionKey: key=@"←"; break;
        case NSRightArrowFunctionKey: key=@"→"; break; case NSUpArrowFunctionKey: key=@"↑"; break;
        case NSDownArrowFunctionKey: key=@"↓"; break; case NSHomeFunctionKey: key=@"Home"; break;
        case NSEndFunctionKey: key=@"End"; break; case NSPageUpFunctionKey: key=@"⇞"; break;
        case NSPageDownFunctionKey: key=@"⇟"; break;
        default: key=functionKey(k) ? [NSString stringWithFormat:@"F%d",k-NSF1FunctionKey+1] : keyString(k).uppercaseString;
    }
    return [NSString stringWithFormat:@"%@%@%@%@%@",code&ctrl ? @"⌃" : @"",code&opt ? @"⌥" : @"",
            code&shift ? @"⇧" : @"",code&cmd ? @"⌘" : @"",key];
}
NSString *ShortcutLabel(ShortcutID index) { return label(ShortcutValue(index)); }
NSString *ShortcutTip(NSString *title, ShortcutID index) {
    return ShortcutValue(index) ? [NSString stringWithFormat:@"%@（%@）",title,ShortcutLabel(index)] : title;
}
static void apply(NSMenuItem *item, ShortcutID index) {
    NSUInteger code=ShortcutValue(index);
    NSString *key=code ? keyString(code & 0xffff) : @"";
    item.keyEquivalent=(code & shift) ? key.uppercaseString : key;
    item.keyEquivalentModifierMask=code & mods;
}
void AddShortcutItem(NSMenu *menu, ShortcutID index) {
    const auto &info=Shortcut(index);
    NSMenuItem *item=[menu addItemWithTitle:info.title action:NSSelectorFromString(info.identifier) keyEquivalent:@""];
    item.identifier=info.identifier; apply(item,index);
}
void UpdateShortcutItems(NSMenu *menu) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) UpdateShortcutItems(item.submenu);
        else if (item.identifier) for (NSInteger i=0;i<ShortcutCount;++i)
            if ([item.identifier isEqual:Shortcut((ShortcutID)i).identifier]) { apply(item,(ShortcutID)i); break; }
    }
}
static void save() {
    NSMutableDictionary *changed=[NSMutableDictionary dictionary];
    for (NSInteger i=0;i<ShortcutCount;++i) {
        const auto &item=Shortcut((ShortcutID)i);
        if (bindings()[i]!=item.standard) changed[item.identifier]=@(bindings()[i]);
    }
    if (changed.count) [TerminalPreferences() setObject:changed forKey:ShortcutPreferences];
    else [TerminalPreferences() removeObjectForKey:ShortcutPreferences];
    UpdateShortcutItems(NSApp.mainMenu);
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:ShortcutPreferences];
}
void RestoreShortcuts() {
    for (NSInteger i=0;i<ShortcutCount;++i) bindings()[i]=Shortcut((ShortcutID)i).standard;
    save();
}

@implementation ShortcutRecorder {
    ShortcutID _index;
    id _monitor;
}
- (instancetype)initWithShortcut:(ShortcutID)index {
    if ((self=[super initWithFrame:NSMakeRect(0,0,144,25)])) {
        _index=index; self.bezelStyle=NSBezelStyleRounded; self.controlSize=NSControlSizeSmall;
        self.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.target=self; self.action=@selector(beginRecording:);
        [self setAccessibilityHelp:@"点按后按下组合键，Esc 取消，删除键清除。"];
        [self refresh];
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)refresh {
    if (_monitor) return;
    self.title=ShortcutLabel(_index);
    self.toolTip=@"点按录制快捷键，右键可清除或恢复默认";
    [self setAccessibilityValue:self.title];
}
- (void)stopRecording {
    if (_monitor) {
        [NSEvent removeMonitor:_monitor]; _monitor=nil;
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    }
    [self refresh];
}
- (BOOL)resignFirstResponder { [self stopRecording]; return [super resignFirstResponder]; }
- (void)viewWillMoveToWindow:(NSWindow *)window { [self stopRecording]; [super viewWillMoveToWindow:window]; }
- (void)windowBlurred:(NSNotification *)note { [self stopRecording]; }
- (void)dealloc { if (_monitor) [NSEvent removeMonitor:_monitor]; }
- (void)beginRecording:(id)sender {
    if (_monitor) { [self stopRecording]; return; }
    if (![self.window makeFirstResponder:self]) return;
    self.title=@"按下快捷键…"; self.toolTip=@"Esc 取消，删除键清除";
    __weak ShortcutRecorder *weak=self;
    _monitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        ShortcutRecorder *button=weak;
        if (!button || button.window!=event.window || button.window.firstResponder!=button) return event;
        [button recordEvent:event]; return nil;
    }];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowBlurred:)
                                             name:NSWindowDidResignKeyNotification object:self.window];
}
- (void)keyDown:(NSEvent *)event { if (_monitor) [self recordEvent:event]; else [super keyDown:event]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (_monitor && self.window.firstResponder==self && event.type==NSEventTypeKeyDown) {
        [self recordEvent:event]; return YES;
    }
    return [super performKeyEquivalent:event];
}
- (void)assign:(NSUInteger)code {
    if (!valid(_index,code)) { self.title=@"请加修饰键"; return; }
    for (NSInteger i=0;code && i<ShortcutCount;++i) {
        auto other=(ShortcutID)i;
        if (i!=_index && (scope(_index)&scope(other)) && code==ShortcutValue(other)) {
            NSString *message=[NSString stringWithFormat:@"已用于「%@」",Shortcut(other).title];
            self.title=message; self.toolTip=message; [self setAccessibilityValue:message]; return;
        }
    }
    bindings()[_index]=code; [self stopRecording]; save();
}
- (void)recordEvent:(NSEvent *)event {
    if (event.isARepeat) return;
    NSUInteger flags=event.modifierFlags & mods, key=eventKey(event);
    if (!flags && key==0x1b) { [self stopRecording]; return; }
    if (!flags && (key==NSBackspaceCharacter || key==NSDeleteFunctionKey)) { [self assign:0]; return; }
    if (key) [self assign:flags|key];
}
- (void)clearBinding:(id)sender { [self assign:0]; }
- (void)resetBinding:(id)sender { [self assign:Shortcut(_index).standard]; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu=[NSMenu new];
    [menu addItemWithTitle:@"清除快捷键" action:@selector(clearBinding:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:@"恢复默认快捷键" action:@selector(resetBinding:) keyEquivalent:@""].target=self;
    return menu;
}
@end
