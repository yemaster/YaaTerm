#import "SettingsView.h"
#import "AppUpdates.h"
#import "Preferences.h"
#import "Shortcuts.h"
#import "Palette.h"
#import "Wallpaper.h"
#import "LLMSettingsForm.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <vector>

static NSBezierPath *rounded(NSRect rect, CGFloat radius) {
    return [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
}

static NSImage *symbol(NSString *name, NSColor *color) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
}

static void drawSymbol(NSImage *image, NSRect box) {
    NSSize size = image.size;
    if (size.width <= 0 || size.height <= 0) return;
    CGFloat scale = MIN(NSWidth(box)/size.width,NSHeight(box)/size.height);
    size = NSMakeSize(size.width*scale,size.height*scale);
    NSRect rect = NSMakeRect(floor(NSMidX(box)-size.width/2),floor(NSMidY(box)-size.height/2),size.width,size.height);
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}


// The saved selection drives both the visual mark and the VoiceOver value.
@interface ChoiceButton : NSButton
@property (nonatomic) BOOL chosen;
@end
@implementation ChoiceButton
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.bordered = NO;
        [(NSButtonCell *)self.cell setHighlightsBy:NSNoCellMask];
        [(NSButtonCell *)self.cell setShowsStateBy:NSNoCellMask];
        [self setAccessibilityRole:NSAccessibilityRadioButtonRole];
        [self setAccessibilityValue:@NO];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setChosen:(BOOL)chosen {
    if (chosen == _chosen) return;
    _chosen = chosen; self.needsDisplay = YES;
    [self setAccessibilityValue:@(chosen)];
}
@end

NSString *SettingsSectionTitle(NSInteger section) { return @[@"通用",@"外观",@"终端",@"性能",@"AI 服务",@"快捷键",@"关于"][section]; }

// The form and the search results share the same names and destinations.
enum SettingID : NSInteger {
    EndedSession, History, TabMotion, CommandAlerts, Mode, FontFamily, FontWeight, FontSize, LightTheme, DarkTheme, Material,
    BackOpacity, WallpaperFile, ImageOpacity, APIFormat, APIEndpoint, APIKey, APIModel, APIActions, IdleSleep, Tables, WebLinks, FileLinks,
    AppVersion, AutoCheck, AutoInstall, CheckNow, Repository, Feedback, ReleaseNotes, ErrorHelp, AgentInput, LocalLauncher,
    PromptColor, DirectoryColor, FramePadding, StreamReplies, SettingCount
};
struct SettingInfo { SettingsSection section; NSString *key, *name, *group, *help; };
static const SettingInfo &setting(SettingID index) {
    static const SettingInfo entries[SettingCount] = {
        {GeneralSection,CloseEndedSessions,@"会话结束后自动关闭",@"会话",nil},
        {PerformanceSection,ScrollbackLines,@"回滚内存缓存",@"回滚记录",@"关闭会清空已有的回滚记录。"},
        {GeneralSection,AnimateTabSelection,@"标签动画",@"标签页",@"开启「减少动态效果」时停用。"},
        {GeneralSection,CommandNoticesKey,@"普通命令完成时",@"提醒",@"只提醒后台标签。此项不影响 Agent 提醒。"},
        {AppearanceSection,AppearanceModeKey,@"外观模式",@"主题",nil},
        {AppearanceSection,TerminalFontFamily,@"终端字体",@"主题",nil},
        {AppearanceSection,TerminalFontWeight,@"字体粗细",@"主题",nil},
        {AppearanceSection,TerminalFontSize,@"终端字号",@"主题",nil},
        {AppearanceSection,LightSchemeKey,@"浅色配色",@"主题",nil},
        {AppearanceSection,DarkSchemeKey,@"深色配色",@"主题",nil},
        {AppearanceSection,BackgroundMaterialKey,@"背景材质",@"背景",@"背景不透明度低于 100% 时生效。"},
        {AppearanceSection,BackgroundOpacity,@"背景不透明度",@"背景",nil},
        {AppearanceSection,BackgroundImagePath,@"背景图片",@"背景",nil},
        {AppearanceSection,BackgroundImageOpacity,@"图片不透明度",@"背景",nil},
        {APISection,@"LLMFormat",@"API 格式",@"连接",nil},
        {APISection,@"LLMEndpoint",@"服务地址",@"连接",@"可填完整地址或 /v1 基础地址。"},
        {APISection,@"LLMKey",@"API Key",@"连接",@"仅在本机加密保存。"},
        {APISection,@"LLMModel",@"模型名称",@"连接",nil},
        {APISection,@"LLMActions",@"",@"连接",nil},
        {PerformanceSection,SleepIdleTabs,@"休眠闲置标签页",@"标签页",@"后台闲置 15 分钟后休眠。有前台任务时保持唤醒。"},
        {TerminalSection,PrettyTables,@"列表显示为表格",@"命令输出",@"适用于文件、进程、容器等列表。"},
        {TerminalSection,OpenWebLinks,@"打开网页链接",@"⌘ 点按",@"用默认浏览器打开。"},
        {TerminalSection,RevealFileLinks,@"显示文件位置",@"⌘ 点按",@"在 Finder 中定位文件。"},
        {AboutSection,@"AppVersion",@"当前版本",@"应用",nil},
        {AboutSection,@"AutoCheck",@"自动检查更新",@"软件更新",@"每天检查一次。"},
        {AboutSection,@"AutoInstall",@"自动安装更新",@"软件更新",@"后台下载，退出时安装。"},
        {AboutSection,@"CheckNow",@"检查更新",@"软件更新",nil},
        {AboutSection,@"Repository",@"GitHub 仓库",@"项目",nil},
        {AboutSection,@"Feedback",@"意见反馈",@"项目",nil},
        {AboutSection,@"ReleaseNotes",@"更新日志",@"版本记录",nil},
        {APISection,AIErrorExplanations,@"命令错误解释",@"终端功能",nil},
        {APISection,BuiltInAgent,@"内置 Agent",@"终端功能",nil},
        {APISection,LocalAgentLauncher,@"本机 Agent",@"终端功能",nil},
        {APISection,AgentPromptColor,@"Agent 提示符颜色",@"Agent 显示",nil},
        {APISection,AgentDirectoryColor,@"当前目录颜色",@"Agent 显示",nil},
        {APISection,AgentFramePadding,@"执行框内边距",@"Agent 显示",nil},
        {APISection,AgentStreamReplies,@"流式显示回复",@"Agent 显示",nil}
    };
    return entries[index];
}

static NSArray<NSString *> *materialNames() {
    return SupportsLiquidGlass() ? @[@"无",@"毛玻璃",@"液态玻璃"] : @[@"无",@"毛玻璃"];
}

static void selectSegment(NSSegmentedControl *control, NSArray<NSString *> *labels, NSInteger selected) {
    control.selectedSegment = selected;
    for (NSInteger i=0; i<control.segmentCount; ++i)
        [control setLabel:i == selected ? [@"✓ " stringByAppendingString:labels[i]] : labels[i] forSegment:i];
}

@interface FontFamilyPicker : NSPopUpButton
- (void)syncSelection;
@end
@implementation FontFamilyPicker
- (instancetype)init {
    if ((self = [super initWithFrame:NSMakeRect(0,0,212,26) pullsDown:NO])) {
        self.target = self; self.action = @selector(choose:);
        [self syncSelection];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(loadFamilies:)
            name:NSPopUpButtonWillPopUpNotification object:self];
    }
    return self;
}
- (void)addFamily:(NSString *)family {
    NSString *title = [family isEqual:BundledFontFamily] ? @"JetBrains Mono（默认）" :
                      [family isEqual:SystemMonospaceFamily] ? @"系统等宽字体" : family;
    [self addItemWithTitle:title]; self.lastItem.representedObject = family;
}
- (void)syncSelection {
    NSString *family = PreferredFontFamily();
    NSInteger index = [self indexOfItemWithRepresentedObject:family];
    if (index < 0) { [self addFamily:family]; index = self.numberOfItems-1; }
    [self selectItemAtIndex:index]; self.toolTip = self.selectedItem.title;
}
- (void)loadFamilies:(NSNotification *)note {
    NSDictionary *traits = @{NSFontSymbolicTrait:@(NSFontDescriptorTraitMonoSpace)};
    NSFontDescriptor *query = [NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontTraitsAttribute:traits}];
    NSMutableSet<NSString *> *families = [NSMutableSet set];
    for (NSFontDescriptor *face in [query matchingFontDescriptorsWithMandatoryKeys:[NSSet setWithObject:NSFontTraitsAttribute]]) {
        NSString *name = [face objectForKey:NSFontFamilyAttribute];
        if (name.length && ![name hasPrefix:@"."] && ![name isEqual:BundledFontFamily]) [families addObject:name];
    }
    [self removeAllItems];
    [self addFamily:BundledFontFamily]; [self addFamily:SystemMonospaceFamily];
    if (families.count) [self.menu addItem:NSMenuItem.separatorItem];
    for (NSString *family in [families.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) [self addFamily:family];
    [self syncSelection];
}
- (void)choose:(id)sender { SetTerminalFontFamily(self.selectedItem.representedObject); }
@end

@interface SectionButton : ChoiceButton
@end
@implementation SectionButton
- (void)drawRect:(NSRect)dirty {
    const auto &colors = CurrentInterfacePalette();
    NSColor *color = self.chosen ? colors.text : colors.secondaryText;
    if (self.chosen) { [colors.selectionFill setFill]; [rounded(self.bounds,7) fill]; }
    drawSymbol(self.image,NSMakeRect(10,9,16,16));
    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:self.chosen ? NSFontWeightMedium : NSFontWeightRegular],
                             NSForegroundColorAttributeName:color};
    [self.title drawAtPoint:NSMakePoint(36,floor((NSHeight(self.bounds)-[self.title sizeWithAttributes:attrs].height)/2)) withAttributes:attrs];
    if (self.window.firstResponder == self && self.window.keyWindow && NSApp.fullKeyboardAccessEnabled) {
        [NSColor.keyboardFocusIndicatorColor setStroke]; [rounded(NSInsetRect(self.bounds,1,1),5) stroke];
    }
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 126 || event.keyCode == 125)
        [(SettingsView *)self.superview selectSection:std::clamp<NSInteger>(self.tag + (event.keyCode == 126 ? -1 : 1),0,SectionCount-1)];
    else [super keyDown:event];
}
@end

static constexpr CGFloat cardHeight = 86, cardGap = 8, minCardWidth = 138;

@interface ThemeGallery : NSView
- (instancetype)initForLight:(BOOL)light;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)syncSelection;
- (void)updateFont;
- (void)moveFrom:(NSButton *)button key:(unsigned short)code;
@end

@interface ThemeCard : ChoiceButton
@end
@implementation ThemeCard
- (void)drawRect:(NSRect)dirty {
    NSRect bounds = self.bounds;
    NSBezierPath *outline = rounded(NSInsetRect(bounds,1,1),10);
    if (self.chosen) {
        [[CurrentInterfacePalette().accent colorWithAlphaComponent:.12] setFill]; [outline fill];
    }
    [(self.chosen ? CurrentInterfacePalette().accent : CurrentInterfacePalette().separator) setStroke];
    outline.lineWidth = self.chosen ? 2 : .7;
    [outline stroke];

    NSRect sample = NSMakeRect(6,6,NSWidth(bounds)-12,51);
    NSBezierPath *well = rounded(sample,6);
    [SchemeInk(self.tag,SchemeBackground) setFill]; [well fill];
    [CurrentInterfacePalette().separator setStroke]; well.lineWidth = .5; [well stroke];
    NSDictionary *type = @{NSFontAttributeName:self.font, NSForegroundColorAttributeName:SchemeInk(self.tag,SchemeText)};
    CGFloat textHeight = [@"Aa" sizeWithAttributes:type].height;
    [@"Aa" drawAtPoint:NSMakePoint(15,floor(24-textHeight/2)) withAttributes:type];
    static constexpr NSInteger swatches[] = {1,3,2,6,4,5,8};
    CGFloat x = 16;
    for (NSInteger index : swatches) {
        [SchemeInk(self.tag,index) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x,42,8,8)] fill]; x += 12;
    }
    NSDictionary *caption = @{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:self.chosen ? NSFontWeightMedium : NSFontWeightRegular],
                               NSForegroundColorAttributeName:CurrentInterfacePalette().text};
    [self.title drawAtPoint:NSMakePoint(10,63) withAttributes:caption];
    if (self.chosen) {
        NSRect badge = NSMakeRect(NSWidth(bounds)-24,63,16,16);
        [CurrentInterfacePalette().text setFill];
        [[NSBezierPath bezierPathWithOvalInRect:badge] fill];
        drawSymbol(self.image,NSInsetRect(badge,3,3));
    }
}
- (void)drawFocusRingMask { [rounded(NSInsetRect(self.bounds,1,1),10) fill]; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode >= 123 && event.keyCode <= 126)
        [(ThemeGallery *)self.superview moveFrom:self key:event.keyCode];
    else [super keyDown:event];
}
@end

@implementation ThemeGallery {
    BOOL _light;
}
- (instancetype)initForLight:(BOOL)light {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _light = light;
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityRadioGroupRole];
        for (NSInteger i=0; i<SchemeCount; ++i) {
            if (SchemeIsLight(i) != light) continue;
            ThemeCard *card = [[ThemeCard alloc] initWithFrame:NSZeroRect];
            card.tag = i; card.title = SchemeName(i);
            [card setAccessibilityLabel:card.title];
            card.target = self; card.action = @selector(choose:);
            [self addSubview:card];
        }
        [self updateFont]; [self syncSelection];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (NSInteger)columnsForWidth:(CGFloat)width {
    return MAX(1,MIN(3L,(NSInteger)floor((width+cardGap)/(minCardWidth+cardGap))));
}
- (CGFloat)heightForWidth:(CGFloat)width {
    NSInteger columns = [self columnsForWidth:width];
    NSInteger rows = (self.subviews.count+columns-1)/columns;
    return rows*cardHeight + MAX(0L,rows-1)*cardGap;
}
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    NSInteger columns = [self columnsForWidth:width];
    CGFloat pitch = (width+cardGap)/columns;
    NSInteger index = 0;
    for (NSView *card in self.subviews) {
        NSInteger col = index%columns;
        CGFloat left = round(col*pitch), right = round((col+1)*pitch-cardGap);
        card.frame = NSMakeRect(left,(index/columns)*(cardHeight+cardGap),right-left,cardHeight);
        ++index;
    }
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout = YES; }
- (void)updateFont {
    NSFont *font = PreferredTerminalFont(PreferredFontSize(),NO);
    for (ThemeCard *card in self.subviews) { card.font = font; card.needsDisplay = YES; }
}
- (void)syncSelection {
    NSInteger picked = PreferredSchemeForStyle(_light);
    for (ThemeCard *card in self.subviews) card.chosen = card.tag == picked;
}
- (void)choose:(ThemeCard *)card { SetTerminalPreference(self.identifier,card.tag); }
- (void)moveFrom:(NSButton *)button key:(unsigned short)code {
    NSInteger columns = [self columnsForWidth:NSWidth(self.bounds)];
    NSInteger delta = code==123 ? -1 : code==124 ? 1 : code==125 ? columns : -columns;
    NSInteger next = (NSInteger)[self.subviews indexOfObjectIdenticalTo:button] + delta;
    if (next < 0 || next >= (NSInteger)self.subviews.count) return;
    ThemeCard *card = self.subviews[next];
    [self.window makeFirstResponder:card]; [card scrollRectToVisible:card.bounds]; [self choose:card];
}
@end

@interface OpacityControl : NSView
- (instancetype)initWithKey:(NSString *)key title:(NSString *)title;
- (void)refresh;
@end
@implementation OpacityControl {
    NSSlider *_slider;
    NSTextField *_value;
}
- (instancetype)initWithKey:(NSString *)key title:(NSString *)title {
    if ((self = [super initWithFrame:NSMakeRect(0,0,204,24)])) {
        self.identifier = key;
        _slider = [NSSlider sliderWithValue:PreferredOpacity(key) minValue:0 maxValue:100 target:self action:@selector(changed:)];
        _slider.frame = NSMakeRect(0,0,152,24); _slider.continuous = YES;
        [_slider setAccessibilityLabel:title];
        _value = [NSTextField labelWithString:@""];
        _value.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        _value.frame = NSMakeRect(158,3,46,18);
        [self addSubview:_slider]; [self addSubview:_value]; [self refresh];
    }
    return self;
}
- (void)refresh {
    NSInteger percent = PreferredOpacity(self.identifier);
    _slider.integerValue = percent;
    _slider.enabled = ![self.identifier isEqual:BackgroundImageOpacity] || (PreferredBackgroundImagePath().length && Wallpaper.shared.image);
    _value.textColor = _slider.enabled ? CurrentInterfacePalette().text : NSColor.disabledControlTextColor;
    _value.stringValue = [NSString stringWithFormat:@"%ld%%",(long)percent];
    [_slider setAccessibilityValueDescription:_value.stringValue];
}
- (void)changed:(NSSlider *)sender {
    SetTerminalPreference(self.identifier,lround(sender.doubleValue));
}
@end

@interface WallpaperPicker : NSView
- (void)refresh;
@end
@implementation WallpaperPicker {
    NSButton *_choose, *_remove;
    NSTextField *_filename;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _choose = [NSButton buttonWithTitle:@"选择图片…" target:self action:@selector(choose:)];
        _remove = [NSButton buttonWithTitle:@"移除" target:self action:@selector(remove:)];
        [_remove setAccessibilityLabel:@"移除背景图片"];
        _filename = [NSTextField labelWithString:@""];
        _filename.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self addSubview:_choose]; [self addSubview:_remove]; [self addSubview:_filename]; [self refresh];
    }
    return self;
}
- (void)refresh {
    NSString *path = PreferredBackgroundImagePath();
    _choose.title = path.length ? @"更换图片…" : @"选择图片…";
    _remove.hidden = !path.length;
    NSString *name = path.lastPathComponent ?: @"";
    _filename.stringValue = path.length && Wallpaper.shared.missingFile ? [@"不可用 · " stringByAppendingString:name] : name;
    _filename.toolTip = path; _filename.textColor = CurrentInterfacePalette().secondaryText;
    self.needsLayout = YES;
}
- (void)layout {
    [super layout];
    CGFloat end = NSWidth(self.bounds);
    _remove.frame = NSMakeRect(end-50,0,50,26);
    _choose.frame = NSMakeRect(end-88-(_remove.hidden ? 0 : 54),0,88,26);
    _filename.frame = NSMakeRect(0,4,MAX(0.,NSMinX(_choose.frame)-6),18);
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout = YES; }
- (void)remove:(id)sender { [Wallpaper.shared removeImage]; }
- (void)choose:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeImage]; panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO; panel.prompt = @"使用图片";
    __weak NSWindow *window = self.window;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        [Wallpaper.shared chooseURL:panel.URL completion:^(BOOL loaded) {
            if (loaded || !window.visible) return;
            NSAlert *alert = [NSAlert new]; alert.messageText = @"无法读取这张图片";
            alert.informativeText = @"请选择可读取的本地图片文件。";
            [alert beginSheetModalForWindow:window completionHandler:nil];
        }];
    }];
}
@end

@interface SettingResult : NSButton
@end
@implementation SettingResult
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    const auto &colors = CurrentInterfacePalette();
    if (self.highlighted) { [[colors.accent colorWithAlphaComponent:.12] setFill]; [rounded(self.bounds,5) fill]; }
    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:14], NSForegroundColorAttributeName:colors.text};
    [self.title drawAtPoint:NSMakePoint(0,floor((NSHeight(self.bounds)-[self.title sizeWithAttributes:attrs].height)/2)) withAttributes:attrs];
    drawSymbol(self.image,NSMakeRect(NSWidth(self.bounds)-15,7,12,14));
}
@end

@interface SettingsPage : NSView
@property NSDictionary<NSString *,NSTextField *> *hints;
@property NSTextField *emptyMessage;
- (void)arrangeFields:(NSArray<NSView *> *)fields labels:(NSArray<NSTextField *> *)labels
              heading:(NSTextField *)heading groups:(NSDictionary<NSString *,NSTextField *> *)groups viewport:(NSSize)viewport;
- (void)applyPalette;
@end
@implementation SettingsPage {
    std::vector<NSRect> _panels;
    std::vector<CGFloat> _dividers;
    CGFloat _rowX, _rowWidth;
    NSColor *_panelColor, *_lineColor;
}
- (BOOL)isFlipped { return YES; }
- (void)applyPalette {
    const auto &colors = CurrentInterfacePalette();
    _panelColor = [colors.background blendedColorWithFraction:SchemeIsLight(PreferredColorScheme()) ? .76 : .035
                                                       ofColor:NSColor.whiteColor];
    _lineColor = [colors.text colorWithAlphaComponent:.15];
    self.needsDisplay = YES;
}
- (void)arrangeFields:(NSArray<NSView *> *)fields labels:(NSArray<NSTextField *> *)labels
              heading:(NSTextField *)heading groups:(NSDictionary<NSString *,NSTextField *> *)groups viewport:(NSSize)viewport {
    CGFloat margin = viewport.width < 510 ? 14 : 32;
    CGFloat width = MAX(1.,MIN(736.,viewport.width-2*margin));
    CGFloat left = floor((viewport.width-width)/2);
    CGFloat inset = width < 400 ? 12 : 17;
    _rowX = left+inset; _rowWidth = MAX(1.,width-2*inset);
    heading.frame = NSMakeRect(left,19,width,32);
    CGFloat y = NSMaxY(heading.frame)+20;
    _emptyMessage.frame = NSMakeRect(left,y,width,24);
    _dividers.clear(); _panels.clear();
    for (NSUInteger i=0; i<fields.count; ++i) {
        NSView *field = fields[i];
        NSTextField *label = labels[i], *hint = self.hints[field.identifier];
        NSTextField *group = groups[field.identifier];
        if (group) {
            if (i) y += 22;
            group.frame = NSMakeRect(left,y,width,20);
            y = NSMaxY(group.frame)+7;
            _panels.push_back(NSMakeRect(left,y,width,0));
        } else {
            _dividers.push_back(y);
        }

        BOOL gallery = [field isKindOfClass:ThemeGallery.class];
        BOOL shortcut = [field isKindOfClass:ShortcutRecorder.class];
        BOOL fullRow = gallery || label.hidden;
        NSSize size = field.frame.size;
        BOOL editor = [field isKindOfClass:NSTextField.class] || [field isKindOfClass:WallpaperPicker.class];
        BOOL stacked = !label.hidden && (gallery || _rowWidth < (shortcut ? 275 : 345));
        if (shortcut) size.width=stacked ? 144 : MIN(144.,floor(_rowWidth*.40));
        if (fullRow || (editor && stacked)) size.width = _rowWidth;
        else if (editor) size.width = MIN(320.,floor(_rowWidth*.48));
        size.width = MIN(size.width,_rowWidth);
        if (gallery) size.height = [(ThemeGallery *)field heightForWidth:size.width];
        else if ([field isKindOfClass:LLMSettingsForm.class]) size.height = [(LLMSettingsForm *)field heightForWidth:size.width];
        CGFloat textWidth = stacked || fullRow ? _rowWidth : MAX(1.,_rowWidth-size.width-20);
        CGFloat hintHeight = hint ? ceil([hint.cell cellSizeForBounds:NSMakeRect(0,0,textWidth,CGFLOAT_MAX)].height) : 0;
        CGFloat textHeight = label.hidden ? 0 : 20+(hint ? 3+hintHeight : 0);
        CGFloat rowHeight = stacked ? textHeight+8+size.height+26 : MAX(50.,MAX(textHeight,size.height)+24);
        if (shortcut && !stacked) rowHeight=MAX(39.,size.height+12);
        CGFloat labelY = stacked ? y+13 : y+floor((rowHeight-textHeight)/2);
        label.frame = NSMakeRect(_rowX,labelY,textWidth,20);
        hint.frame = NSMakeRect(_rowX,labelY+23,textWidth,hintHeight);
        CGFloat controlX = stacked || fullRow ? _rowX : _rowX+_rowWidth-size.width;
        CGFloat controlY = stacked ? labelY+textHeight+8 : y+floor((rowHeight-size.height)/2);
        field.frame = (NSRect){NSMakePoint(controlX,controlY),size};
        y += rowHeight;
        _panels.back().size.height = y-NSMinY(_panels.back());
    }
    self.frame = NSMakeRect(0,0,viewport.width,MAX(viewport.height,y+24));
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    [CurrentInterfacePalette().background setFill]; NSRectFill(dirty);
    CGFloat pixel = 1/MAX(1.,self.window.backingScaleFactor);
    for (NSRect panel : _panels) {
        if (!NSIntersectsRect(dirty,panel)) continue;
        NSBezierPath *path = rounded(NSInsetRect(panel,pixel/2,pixel/2),11);
        [_panelColor setFill]; [path fill];
        [_lineColor setStroke]; path.lineWidth = pixel; [path stroke];
    }
    [_lineColor setFill];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    for (CGFloat y : _dividers) {
        if (y < NSMinY(dirty)-1 || y > NSMaxY(dirty)+1) continue;
        CGRect rule = CGContextConvertRectToDeviceSpace(ctx,CGRectMake(_rowX,y,_rowWidth,0));
        rule.origin.y = round(rule.origin.y); rule.size.height = 1;
        CGContextFillRect(ctx,CGContextConvertRectToUserSpace(ctx,rule));
    }
}
@end

@implementation SettingsView {
    SectionButton *_sections[SectionCount];
    LLMSettingsForm *_apiForm;
    NSInteger _selection;
    NSScrollView *_scroll;
    SettingsPage *_page;
    NSTextField *_heading;
    NSMutableDictionary<NSString *,NSTextField *> *_groupHeadings, *_hints;
    NSString *_lastGroup;
    NSTextField *_sidebarTitle;
    NSSearchField *_search;
    BOOL _showingResults;
    NSPoint _shortcutsScroll;
    NSSegmentedControl *_mode, *_material;
    NSPopUpButton *_promptColors, *_directoryColors;
    FontFamilyPicker *_fontFamily;
    ThemeGallery *_light, *_dark;
    WallpaperPicker *_wallpaper;
    OpacityControl *_opacity, *_imageOpacity;
    NSMutableArray<NSView *> *_fields;
    NSMutableArray<NSTextField *> *_labels;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        for (NSInteger i=0; i<SectionCount; ++i) {
            SectionButton *button = [[SectionButton alloc] initWithFrame:NSZeroRect];
            button.title = SettingsSectionTitle(i); button.identifier = button.title;
            button.tag = i; button.target = self; button.action = @selector(chooseSection:);
            button.focusRingType = NSFocusRingTypeNone; [button setAccessibilityLabel:button.title];
            [self addSubview:button]; _sections[i] = button;
        }
        _sidebarTitle = [NSTextField labelWithString:@"设置"];
        _sidebarTitle.font = [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
        [self addSubview:_sidebarTitle];
        _search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        _search.placeholderString = @"搜索设置"; [_search setAccessibilityLabel:@"搜索设置"];
        _search.sendsSearchStringImmediately = YES; _search.target = self; _search.action = @selector(searchChanged:);
        [self addSubview:_search];
        _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scroll.drawsBackground = NO; _scroll.borderType = NSNoBorder;
        _scroll.hasVerticalScroller = YES; _scroll.autohidesScrollers = YES; _scroll.scrollerStyle = NSScrollerStyleOverlay;
        _page = [[SettingsPage alloc] initWithFrame:NSZeroRect];
        _page.autoresizesSubviews = NO;
        _scroll.documentView = _page; [self addSubview:_scroll];
        _fields = [NSMutableArray array]; _labels = [NSMutableArray array];
        _groupHeadings = [NSMutableDictionary dictionary]; _hints = [NSMutableDictionary dictionary]; _page.hints = _hints;
        [self displaySection:AppearanceSection];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferenceChanged:) name:TerminalPreferenceChanged object:nil];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (void)viewWillMoveToWindow:(NSWindow *)window {
    if (!window && self.window && _selection==ShortcutsSection && !_showingResults) {
        _shortcutsScroll=_page.visibleRect.origin;
        [self clearPage];
    }
    [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && _selection==ShortcutsSection && !_showingResults && !_fields.count) {
        [self displaySection:ShortcutsSection];
        [_page scrollPoint:_shortcutsScroll];
    }
}
- (NSView *)navigationButton { return _showingResults ? (NSView *)_search : _sections[_selection]; }
- (CGFloat)sidebarWidth { return NSWidth(self.bounds)<680 ? 122 : MIN(238.,MAX(172.,round(NSWidth(self.bounds)*.215))); }
- (void)drawRect:(NSRect)dirty {
    [CurrentInterfacePalette().background setFill]; NSRectFill(dirty);
    CGFloat side = self.sidebarWidth;
    [CurrentInterfacePalette().chrome setFill]; NSRectFill(NSMakeRect(0,0,side,NSHeight(self.bounds)));
    CGFloat line = 1 / MAX(1.,self.window.backingScaleFactor);
    [CurrentInterfacePalette().separator setFill]; NSRectFill(NSMakeRect(side-line,0,line,NSHeight(self.bounds)));
}
- (void)cancelOperation:(id)sender { if (_onClose) _onClose(); }
- (void)chooseSection:(SectionButton *)button { [self selectSection:button.tag]; }
- (void)selectSection:(NSInteger)section {
    if (_showingResults || _selection != section) {
        _search.stringValue = @""; [self displaySection:section];
        if (self.window.visible && TabAnimationsEnabled()) {
            SectionButton *selected = _sections[section];
            selected.alphaValue = .65;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = .14;
                selected.animator.alphaValue = 1;
            } completionHandler:nil];
        }
    }
    [self.window makeFirstResponder:_sections[section]];
}

- (void)addField:(NSView *)field label:(NSString *)title key:(NSString *)key group:(NSString *)group hint:(NSString *)help {
    if (![_lastGroup isEqual:group]) {
        _groupHeadings[key] = [self addHeading:group fontSize:13];
        _lastGroup = group;
    }
    field.identifier = key;
    if (title.length) [field setAccessibilityLabel:title];
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:14]; label.hidden = !title.length;
    [_fields addObject:field]; [_labels addObject:label];
    [_page addSubview:label];
    if (help) {
        NSTextField *hint = [NSTextField wrappingLabelWithString:help];
        hint.font = [NSFont systemFontOfSize:12]; _hints[key] = hint;
        [_page addSubview:hint]; [field setAccessibilityHelp:help];
    }
    [_page addSubview:field];
}
- (void)addField:(NSView *)field setting:(SettingID)index {
    const auto &info = setting(index);
    [self addField:field label:info.name key:info.key group:info.group hint:info.help];
}
- (void)addSwitch:(SettingID)index {
    NSSwitch *toggle = [NSSwitch new]; [toggle sizeToFit];
    toggle.state = [TerminalPreferences() boolForKey:setting(index).key] ? NSControlStateValueOn : NSControlStateValueOff;
    [self addField:toggle setting:index]; toggle.target = self; toggle.action = @selector(toggleChanged:);
}
- (NSPopUpButton *)picker:(SettingID)index {
    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,94,26) pullsDown:NO];
    [self addField:picker setting:index]; picker.target = self; picker.action = @selector(pickerChanged:);
    return picker;
}
- (NSSegmentedControl *)segmentsFor:(SettingID)index labels:(NSArray<NSString *> *)labels selected:(NSInteger)selected {
    NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithLabels:labels
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(segmentChanged:)];
    control.segmentStyle = NSSegmentStyleRounded;
    for (NSInteger i=0; i<control.segmentCount; ++i)
        [control setWidth:MAX(64.,ceil([labels[i] sizeWithAttributes:@{NSFontAttributeName:control.font}].width)+38) forSegment:i];
    selectSegment(control,labels,selected);
    [control sizeToFit]; [self addField:control setting:index];
    return control;
}
- (NSTextField *)addHeading:(NSString *)title fontSize:(CGFloat)size {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:size weight:size >= 20 ? NSFontWeightSemibold : NSFontWeightMedium];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        [label setAccessibilityRole:NSAccessibilityHeadingRole];
        [label setAccessibilityLabel:title];
    }
#endif
    [_page addSubview:label];
    return label;
}
- (void)clearPage {
    [_apiForm cancelTest];
    for (NSView *view in _page.subviews.copy) [view removeFromSuperview];
    [_fields removeAllObjects]; [_labels removeAllObjects]; [_hints removeAllObjects]; [_groupHeadings removeAllObjects];
    _page.emptyMessage = nil; _lastGroup = nil;
    _promptColors = nil; _directoryColors = nil;
    _light = nil; _dark = nil; _mode = nil; _material = nil; _fontFamily = nil; _wallpaper = nil; _opacity = nil; _imageOpacity = nil;
}
- (void)addUpdateControls {
    SPUStandardUpdaterController *controller = AppUpdateController();
    SPUUpdater *updater = controller.updater;
    for (SettingID index : {AutoCheck, AutoInstall}) {
        NSSwitch *toggle = [NSSwitch new]; [toggle sizeToFit];
        if (updater) {
            NSString *key = index == AutoCheck ? @"automaticallyChecksForUpdates" : @"automaticallyDownloadsUpdates";
            [toggle bind:NSValueBinding toObject:updater withKeyPath:key options:nil];
            if (index == AutoInstall)
                [toggle bind:NSEnabledBinding toObject:updater withKeyPath:@"allowsAutomaticUpdates" options:nil];
        } else toggle.enabled = NO;
        [self addField:toggle setting:index];
    }
    NSButton *check = [NSButton buttonWithTitle:@"立即检查…" target:controller action:@selector(checkForUpdates:)];
    [check sizeToFit];
    if (updater) [check bind:NSEnabledBinding toObject:updater withKeyPath:@"canCheckForUpdates" options:nil];
    else check.enabled = NO;
    [self addField:check setting:CheckNow];
}
- (void)addProjectButton:(SettingID)index title:(NSString *)title hint:(NSString *)hint {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(openProjectLink:)];
    button.tag = index; [button sizeToFit];
    const auto &info = setting(index);
    [self addField:button label:info.name key:info.key group:info.group hint:hint];
}
- (void)openProjectLink:(NSButton *)sender {
    NSURL *repo = [NSURL URLWithString:@"https://github.com/yemaster/YaaTerm"];
    NSURL *url = sender.tag == Feedback ? [repo URLByAppendingPathComponent:@"issues/new"] :
        sender.tag == ReleaseNotes ? [repo URLByAppendingPathComponent:@"releases"] : repo;
    [NSWorkspace.sharedWorkspace openURL:url];
}
- (void)displaySection:(NSInteger)section {
    [self clearPage]; _selection = section; _showingResults = NO;
    for (SectionButton *button : _sections) button.chosen = button.tag == section;
    _heading = [self addHeading:SettingsSectionTitle(section) fontSize:23];
    if (section == AppearanceSection) {
        _mode = [self segmentsFor:Mode labels:@[@"系统",@"浅色",@"深色"] selected:[TerminalPreferences() integerForKey:AppearanceModeKey]];
        [_mode setToolTip:@"跟随 macOS 的外观" forSegment:FollowSystem];
        _fontFamily = [FontFamilyPicker new];
        [self addField:_fontFamily setting:FontFamily];
        NSPopUpButton *weight = [self picker:FontWeight];
        [weight addItemWithTitle:@"默认"];
        for (NSInteger value=100; value<=900; value+=100) {
            [weight addItemWithTitle:@(value).stringValue]; weight.lastItem.tag = value;
        }
        [weight selectItemWithTag:PreferredFontWeight()];
        weight.toolTip = @"400 为常规，500 为中等。可用字重取决于字体。";
        NSPopUpButton *font = [self picker:FontSize];
        for (NSInteger pt=9; pt<=28; ++pt) {
            [font addItemWithTitle:[NSString stringWithFormat:@"%ld pt",(long)pt]]; font.lastItem.tag = pt;
        }
        [font selectItemWithTag:PreferredFontSize()];
        _light = [[ThemeGallery alloc] initForLight:YES]; _dark = [[ThemeGallery alloc] initForLight:NO];
        [self addField:_light setting:LightTheme];
        [self addField:_dark setting:DarkTheme];

        _material = [self segmentsFor:Material labels:materialNames() selected:PreferredBackgroundMaterial()];
        _material.toolTip = @"系统开启「降低透明度」时，背景材质会停用。";
        _opacity = [[OpacityControl alloc] initWithKey:BackgroundOpacity title:@"背景不透明度"];
        [self addField:_opacity setting:BackOpacity];
        _wallpaper = [[WallpaperPicker alloc] initWithFrame:NSMakeRect(0,0,260,26)];
        [self addField:_wallpaper setting:WallpaperFile];
        _imageOpacity = [[OpacityControl alloc] initWithKey:BackgroundImageOpacity title:@"图片不透明度"];
        [self addField:_imageOpacity setting:ImageOpacity];
    } else if (section == TerminalSection) {
        [self addSwitch:Tables]; [self addSwitch:WebLinks]; [self addSwitch:FileLinks];
    } else if (section == PerformanceSection) {
        [self addSwitch:IdleSleep];
        NSPopUpButton *limit = [self picker:History];
        for (NSNumber *lines in @[@0,@500,@1500,@3000]) {
            [limit addItemWithTitle:lines.integerValue ? [NSString stringWithFormat:@"%@ 行",lines] : @"关闭"];
            limit.lastItem.tag = lines.integerValue;
        }
        [limit selectItemWithTag:PreferredScrollbackLines()];
        limit.toolTip = @"超过缓存行数的输出仍可回看。";
    } else if (section == GeneralSection) {
        [self addSwitch:EndedSession]; [self addSwitch:TabMotion];
        NSPopUpButton *alerts = [self picker:CommandAlerts];
        [alerts addItemsWithTitles:@[@"全部提醒",@"运行满 10 秒",@"关闭提醒"]];
        for (NSInteger i=0; i<alerts.numberOfItems; ++i) [alerts itemAtIndex:i].tag = i;
        [alerts sizeToFit]; [alerts selectItemWithTag:[TerminalPreferences() integerForKey:CommandNoticesKey]];
    } else if (section == APISection) {
        [self addSwitch:ErrorHelp]; [self addSwitch:AgentInput]; [self addSwitch:LocalLauncher];
        if ([TerminalPreferences() boolForKey:BuiltInAgent] || [TerminalPreferences() boolForKey:LocalAgentLauncher]) {
            _promptColors = [self picker:PromptColor]; _directoryColors = [self picker:DirectoryColor];
            NSArray *names = @[@"终端文字",@"红色",@"绿色",@"黄色",@"蓝色",@"紫色",@"青色"];
            for (NSPopUpButton *picker in @[_promptColors,_directoryColors]) {
                for (NSInteger i=picker==_directoryColors ? 0 : 1; i<(NSInteger)names.count; ++i) {
                    [picker addItemWithTitle:names[i]]; picker.lastItem.tag = i;
                }
                [picker selectItemWithTag:picker==_directoryColors ? PreferredAgentDirectoryColor() : PreferredAgentPromptColor()];
            }
            NSPopUpButton *padding = [self picker:FramePadding];
            [padding addItemsWithTitles:@[@"无",@"标准",@"宽松"]];
            [padding itemAtIndex:0].tag = 0; [padding itemAtIndex:1].tag = 6; [padding itemAtIndex:2].tag = 10;
            [padding selectItemWithTag:PreferredAgentFramePadding()];
            [self addSwitch:StreamReplies];
        }
        if (![TerminalPreferences() boolForKey:AIErrorExplanations] && ![TerminalPreferences() boolForKey:BuiltInAgent]) {
            _apiForm = nil; [self finishPage]; return;
        }
        if (!_apiForm) {
            _apiForm = [[LLMSettingsForm alloc] initWithFrame:NSZeroRect];
            __weak SettingsView *owner = self;
            _apiForm.onHeightChange = ^{ owner.needsLayout = YES; };
        }
        [self addField:_apiForm.format setting:APIFormat];
        [self addField:_apiForm.endpoint setting:APIEndpoint];
        [self addField:_apiForm.apiKey setting:APIKey];
        [self addField:_apiForm.model setting:APIModel];
        [self addField:_apiForm setting:APIActions];
    } else if (section == ShortcutsSection) {
        for (NSInteger i=0;i<ShortcutCount;++i) {
            auto index=(ShortcutID)i; const auto &key=Shortcut(index);
            [self addField:[[ShortcutRecorder alloc] initWithShortcut:index] label:key.title key:key.identifier group:key.group hint:nil];
        }
        NSButton *restore=[NSButton buttonWithTitle:@"全部恢复" target:self action:@selector(resetShortcuts:)];
        [restore sizeToFit];
        [self addField:restore label:@"恢复默认快捷键" key:@"ResetShortcuts" group:@"默认设置" hint:nil];
    } else if (section == AboutSection) {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"YaaTerm";
        NSTextField *number = [NSTextField labelWithString:version && build ?
            [NSString stringWithFormat:@"%@ (%@)",version,build] : @"—"];
        number.alignment = NSTextAlignmentRight; [number sizeToFit];
        [self addField:number label:name key:setting(AppVersion).key group:setting(AppVersion).group hint:nil];
        [self addUpdateControls];
        [self addProjectButton:Repository title:@"yemaster/YaaTerm" hint:nil];
        [self addProjectButton:Feedback title:@"提交反馈…" hint:nil];
        NSURL *notesURL = version ? [bundle URLForResource:version withExtension:@"txt" subdirectory:@"ReleaseNotes"] : nil;
        NSString *notes = notesURL ? [NSString stringWithContentsOfURL:notesURL encoding:NSUTF8StringEncoding error:NULL] : nil;
        [self addProjectButton:ReleaseNotes title:@"全部版本" hint:[notes stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]];
    }
    [self finishPage];
}
- (void)resetShortcuts:(id)sender { RestoreShortcuts(); }
- (void)searchChanged:(NSSearchField *)sender {
    NSString *query = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) { if (_showingResults) [self displaySection:_selection]; return; }
    [self clearPage]; _showingResults = YES;
    for (SectionButton *button : _sections) button.chosen = NO;
    _heading = [self addHeading:@"搜索结果" fontSize:23];
    BOOL modelSettings=[TerminalPreferences() boolForKey:AIErrorExplanations] || [TerminalPreferences() boolForKey:BuiltInAgent];
    for (NSInteger i=0; i<SettingCount; ++i) {
        if (!modelSettings && i>=APIFormat && i<=APIActions) continue;
        if (i>=PromptColor && ![TerminalPreferences() boolForKey:BuiltInAgent] && ![TerminalPreferences() boolForKey:LocalAgentLauncher]) continue;
        const auto &info = setting((SettingID)i);
        if (!info.name.length) continue;
        NSString *section = SettingsSectionTitle(info.section);
        BOOL materialMatch = i == Material && [[materialNames() componentsJoinedByString:@" "] localizedCaseInsensitiveContainsString:query];
        if (!materialMatch && ![info.name localizedCaseInsensitiveContainsString:query] && ![info.group localizedCaseInsensitiveContainsString:query]
            && ![section localizedCaseInsensitiveContainsString:query] && ![info.key localizedCaseInsensitiveContainsString:query]) continue;
        SettingResult *result = [[SettingResult alloc] initWithFrame:NSMakeRect(0,0,180,26)];
        result.bordered = NO; result.title = info.name; result.tag = i;
        [result setAccessibilityLabel:info.name];
        result.target = self; result.action = @selector(openResult:);
        [self addField:result label:@"" key:info.key group:section hint:nil];
    }
    NSString *section=SettingsSectionTitle(ShortcutsSection);
    for (NSInteger i=0;i<ShortcutCount;++i) {
        auto index=(ShortcutID)i; const auto &key=Shortcut(index);
        if (![section containsString:query] && ![key.title localizedCaseInsensitiveContainsString:query] &&
            ![key.group localizedCaseInsensitiveContainsString:query] && ![ShortcutLabel(index) localizedCaseInsensitiveContainsString:query]) continue;
        SettingResult *result=[[SettingResult alloc] initWithFrame:NSMakeRect(0,0,180,26)];
        result.bordered=NO; result.title=key.title; result.tag=SettingCount+i;
        result.target=self; result.action=@selector(openResult:); [result setAccessibilityLabel:key.title];
        [self addField:result label:@"" key:key.identifier group:section hint:nil];
    }
    if (!_fields.count) {
        _page.emptyMessage = [NSTextField labelWithString:@"没有找到匹配的设置"];
        [_page addSubview:_page.emptyMessage];
    }
    [self finishPage];
}
- (void)openResult:(NSButton *)sender {
    BOOL shortcut=sender.tag>=SettingCount;
    NSString *target=shortcut ? Shortcut((ShortcutID)(sender.tag-SettingCount)).identifier : setting((SettingID)sender.tag).key;
    [self selectSection:shortcut ? ShortcutsSection : setting((SettingID)sender.tag).section];
    for (NSUInteger i=0; i<_fields.count; ++i) {
        NSView *field = _fields[i];
        if (![field.identifier isEqual:target]) continue;
        [_page scrollPoint:NSMakePoint(0,MAX(0.,NSMinY(_labels[i].frame)-18))];
        if (field.acceptsFirstResponder) [self.window makeFirstResponder:field];
        break;
    }
}
- (void)finishPage {
    [self applyPalette];
    self.needsLayout = YES; [self layoutSubtreeIfNeeded];
    [_page scrollPoint:NSZeroPoint];
}
- (void)layout {
    [super layout];
    CGFloat side = self.sidebarWidth, height = NSHeight(self.bounds);
    BOOL compact = height < 300;
    _sidebarTitle.hidden = height < 234;
    _sidebarTitle.frame = NSMakeRect(18,compact ? 10 : 19,side-28,23);
    _search.frame = NSMakeRect(10,_sidebarTitle.hidden ? 6 : compact ? 40 : 61,side-20,26);
    CGFloat top = NSMaxY(_search.frame)+(compact ? 6 : 21);
    CGFloat step = MIN(38,floor((height-top-2)/SectionCount));
    for (SectionButton *button : _sections)
        button.frame = NSMakeRect(10,top+button.tag*step,side-20,MAX(1,MIN(34,step-2)));
    _scroll.frame = NSMakeRect(side,0,MAX(0.,NSWidth(self.bounds)-side),height);
    [_page arrangeFields:_fields labels:_labels heading:_heading groups:_groupHeadings viewport:_scroll.contentSize];
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout = YES; }
- (void)applyPalette {
    const auto &colors = CurrentInterfacePalette();
    self.appearance = SchemeAppearance(PreferredColorScheme());
    self.needsDisplay = YES; [_page applyPalette];
    _sidebarTitle.textColor = colors.text;
    _page.emptyMessage.textColor = colors.secondaryText;
    for (NSTextField *hint in _hints.objectEnumerator) hint.textColor = colors.secondaryText;
    for (NSView *field in _fields) if ([field isKindOfClass:SettingResult.class])
        ((NSButton *)field).image = symbol(@"chevron.forward",colors.secondaryText);
    _heading.textColor = colors.text; [_apiForm applyPalette];
    if (_promptColors) {
        for (NSMenuItem *item in _directoryColors.itemArray) {
            NSColor *swatch=item.tag ? TerminalIndexedColor(PreferredColorScheme(),(int)item.tag) : SchemeInk(PreferredColorScheme(),SchemeText);
            item.image = symbol(@"circle.fill",swatch);
            [_promptColors.menu itemWithTag:item.tag].image = item.image;
        }
    }
    for (NSTextField *group in _groupHeadings.objectEnumerator) group.textColor = colors.secondaryText;
    for (NSTextField *label in _labels) label.textColor = colors.text;
    for (SectionButton *button : _sections) {
        button.image = symbol(@[@"slider.horizontal.3",@"sun.max",@"terminal",@"gauge.with.dots.needle.50percent",@"network",@"keyboard",@"info.circle"][button.tag],button.chosen ? colors.accent : colors.secondaryText);
        button.needsDisplay = YES;
    }
    if (_mode) {
        [_wallpaper refresh]; [_opacity refresh]; [_imageOpacity refresh];
        NSImage *check = symbol(@"checkmark",colors.background);
        for (ThemeGallery *gallery in @[_light,_dark]) {
            NSString *title = gallery == _light ? @"浅色配色" : @"深色配色";
            BOOL active = (gallery == _light) == SchemeIsLight(PreferredColorScheme());
            NSString *label = active ? [title stringByAppendingString:@" · 使用中"] : title;
            _labels[[_fields indexOfObjectIdenticalTo:gallery]].stringValue = label;
            [gallery setAccessibilityLabel:label];
            for (ThemeCard *card in gallery.subviews) { card.image = check; card.needsDisplay = YES; }
        }
    }
}
- (void)preferenceChanged:(NSNotification *)note {
    NSString *key = note.object;
    if ([key isEqual:ShortcutPreferences]) {
        if (_showingResults) [self searchChanged:_search];
        else if (_selection==ShortcutsSection)
            for (NSView *field in _fields) if ([field isKindOfClass:ShortcutRecorder.class]) [(ShortcutRecorder *)field refresh];
        return;
    }
    if ([key isEqual:AIErrorExplanations] || [key isEqual:BuiltInAgent] || [key isEqual:LocalAgentLauncher]) {
        BOOL show = [TerminalPreferences() boolForKey:AIErrorExplanations] || [TerminalPreferences() boolForKey:BuiltInAgent];
        BOOL showColor=[TerminalPreferences() boolForKey:BuiltInAgent] || [TerminalPreferences() boolForKey:LocalAgentLauncher];
        if (_selection==APISection && !_showingResults && (show!=(_apiForm!=nil) || showColor!=(_promptColors!=nil))) {
            [self displaySection:APISection]; return;
        }
        if (!show) { [_apiForm cancelTest]; _apiForm=nil; }
        if (_showingResults) { [self searchChanged:_search]; return; }
    }
    if ([key isEqual:TerminalColorScheme]) { [self applyPalette]; return; }
    if ([key isEqual:LightSchemeKey]) { [_light syncSelection]; return; }
    if ([key isEqual:DarkSchemeKey]) { [_dark syncSelection]; return; }
    if ([key isEqual:AppearanceModeKey]) {
        if (_mode) selectSegment(_mode,@[@"系统",@"浅色",@"深色"],[TerminalPreferences() integerForKey:key]);
        return;
    }
    if ([key isEqual:BackgroundMaterialKey]) {
        if (_material) selectSegment(_material,materialNames(),PreferredBackgroundMaterial());
        return;
    }
    if ([key isEqual:BackgroundImagePath]) { [_wallpaper refresh]; [_imageOpacity refresh]; return; }
    if ([key isEqual:BackgroundOpacity]) { [_opacity refresh]; return; }
    if ([key isEqual:BackgroundImageOpacity]) { [_imageOpacity refresh]; return; }
    if ([key isEqual:TerminalFontFamily]) { [_fontFamily syncSelection]; [_light updateFont]; [_dark updateFont]; return; }
    if ([key isEqual:TerminalFontSize] || [key isEqual:TerminalFontWeight]) { [_light updateFont]; [_dark updateFont]; }
    for (NSView *field in _fields) {
        if (![key isEqual:field.identifier]) continue;
        NSInteger value = [TerminalPreferences() integerForKey:key];
        if ([field isKindOfClass:NSPopUpButton.class]) [(NSPopUpButton *)field selectItemWithTag:value];
        else if ([field isKindOfClass:NSSwitch.class]) [(NSSwitch *)field setState:value ? NSControlStateValueOn : NSControlStateValueOff];
    }
}
- (void)segmentChanged:(NSSegmentedControl *)sender { SetTerminalPreference(sender.identifier,sender.selectedSegment); }
- (void)toggleChanged:(NSSwitch *)sender { SetTerminalPreference(sender.identifier,sender.state==NSControlStateValueOn); }
- (void)pickerChanged:(NSPopUpButton *)sender { SetTerminalPreference(sender.identifier,sender.selectedTag); }
@end
