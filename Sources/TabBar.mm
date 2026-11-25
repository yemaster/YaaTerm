#import "TabWorkspace.h"
#import "TaskNotices.h"
#import "Preferences.h"
#import "Shortcuts.h"
#import "Palette.h"
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>
#include <vector>

static constexpr CGFloat barHeight = 40, itemHeight = 28, minWidth = 106, maxWidth = 176;
static constexpr CGFloat tabGap = 6, titleInset = 14, actionGap = 8, toolWidth = 32, gearWidth = 30, trailingInset = 8;

// A single composited selection surface moves underneath the reusable tab buttons.
@interface TabHighlight : NSView
- (void)updateInk;
- (void)moveTo:(NSRect)target animate:(BOOL)animate;
@end

@implementation TabHighlight
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer = [CALayer layer]; self.wantsLayer = YES;
        self.layer.cornerRadius = 7;
        [self updateInk];
        [self setAccessibilityElement:NO];
    }
    return self;
}
- (void)updateInk {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.layer.backgroundColor = CurrentInterfacePalette().selectionFill.CGColor;
    [CATransaction commit];
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)moveTo:(NSRect)target animate:(BOOL)animate {
    CALayer *layer = self.layer;
    NSRect old = self.frame;
    BOOL hasStart = !self.hidden && !NSIsEmptyRect(old);
    CGFloat startX = NSMinX(old);
    if (animate && hasStart) {
        CALayer *presentation = layer.presentationLayer;
        if (presentation) startX += presentation.transform.m41;
        else {
            // Multiple key presses can arrive before the first transaction reaches the compositor.
            CABasicAnimation *pending = (CABasicAnimation *)[layer animationForKey:@"selection"];
            if ([pending.keyPath isEqualToString:@"transform.translation.x"])
                startX += [pending.fromValue doubleValue];
        }
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.frame = target; self.hidden = NO;
    [CATransaction commit];
    if (!animate || !hasStart) {
        [layer removeAnimationForKey:@"selection"]; return;
    }
    CGFloat distance = startX - NSMinX(target);
    BOOL slides = fabs(distance) > .5 && NSWidth(old) == NSWidth(target);
    CABasicAnimation *transition = [CABasicAnimation animationWithKeyPath:slides ? @"transform.translation.x" : @"opacity"];
    transition.fromValue = slides ? @(distance) : @.55;
    transition.toValue = slides ? @0 : @1;
    transition.duration = .14;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:transition forKey:@"selection"];
}
@end

static NSButton *symbolButton(NSString *symbol, NSString *label, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    NSButton *button = [NSButton buttonWithImage:image target:target action:action];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = CurrentInterfacePalette().secondaryText;
    button.toolTip = label;
    [button setAccessibilityLabel:label];
    return button;
}

static NSArray<NSString *> *groupColors() { return @[@"蓝色",@"紫色",@"绿色",@"橙色",@"粉色"]; }
static NSColor *groupColor(NSInteger i) {
    switch (i) {
        case 1: return NSColor.systemPurpleColor;
        case 2: return NSColor.systemGreenColor;
        case 3: return NSColor.systemOrangeColor;
        case 4: return NSColor.systemPinkColor;
        default: return NSColor.systemBlueColor;
    }
}
@class TabItem;
@interface TabBar (Actions)
- (NSMenu *)menuForItem:(TabItem *)item;
- (void)choose:(TabItem *)item;
- (void)closeItem:(TabItem *)item;
- (void)trackTab:(TerminalTab *)tab fromItem:(TabItem *)item press:(NSPoint)press event:(NSEvent *)event;
@end

@interface TabItem : NSButton
@property (weak) TabBar *bar;
@property TabGroup *group;
- (instancetype)initWithBar:(TabBar *)bar;
- (void)updateLabel:(NSString *)title;
- (void)configureTitle:(NSString *)title tag:(NSInteger)tag group:(TabGroup *)group;
- (void)applyPalette;
@end

@implementation TabItem {
    NSButton *_close;
    NSTrackingArea *_tracking;
    BOOL _hovering;
    NSPoint _press;
    __weak TerminalTab *_pressedTab;
}
- (instancetype)initWithBar:(TabBar *)bar {
    if ((self = [super initWithFrame:NSMakeRect(0,0,maxWidth,itemHeight)])) {
        _bar = bar;
        self.bordered = NO;
        self.target = bar; self.action = @selector(choose:);
        [self setAccessibilityRole:NSAccessibilityRadioButtonRole];
        _close = symbolButton(@"xmark",@"关闭标签页",self,@selector(closeTab:));
        _close.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightMedium];
        _close.hidden = YES;
        [self addSubview:_close];
    }
    return self;
}
- (void)updateLabel:(NSString *)title {
    if ([self.title isEqualToString:title]) return;
    self.title = title;
    self.toolTip = title;
    [self setAccessibilityLabel:title];
    [_close setAccessibilityLabel:[@"关闭标签页 " stringByAppendingString:title]];
    self.needsDisplay = YES;
}
- (void)configureTitle:(NSString *)title tag:(NSInteger)tag group:(TabGroup *)group {
    self.tag = tag; self.group = group;
    [self updateLabel:title];
    if (tag < 0) {
        [self setAccessibilityRole:NSAccessibilityButtonRole];
        [self setAccessibilityExpanded:!group.collapsed];
        self.toolTip = [NSString stringWithFormat:@"%@ · %@分组",title,group.collapsed ? @"展开" : @"收起"];
    } else {
        [self setAccessibilityRole:NSAccessibilityRadioButtonRole];
        self.toolTip = title;
    }
    [self refresh];
}
- (void)setState:(NSControlStateValue)state {
    [super setState:state]; [self refresh];
}
- (void)applyPalette {
    _close.contentTintColor = CurrentInterfacePalette().secondaryText; self.needsDisplay = YES;
}
- (void)refresh {
    _close.hidden = self.tag < 0 || (self.state != NSControlStateValueOn && !_hovering);
    self.needsDisplay = YES;
}
- (void)layout {
    [super layout];
    _close.frame = NSMakeRect(NSWidth(self.bounds)-27,(NSHeight(self.bounds)-22)/2,22,22);
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingInVisibleRect|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent *)e { _hovering = YES; [self refresh]; }
- (void)mouseExited:(NSEvent *)e { _hovering = NO; [self refresh]; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (NSMenu *)menuForEvent:(NSEvent *)event { return [_bar menuForItem:self]; }
- (void)mouseDown:(NSEvent *)e {
    if (e.modifierFlags & NSEventModifierFlagControl) {
        [NSMenu popUpContextMenu:[self menuForEvent:e] withEvent:e forView:self]; return;
    }
    if (self.tag < 0) { _pressedTab = nil; [_bar choose:self]; return; }
    _press = e.locationInWindow; _pressedTab = [_bar.workspace tabAtIndex:self.tag]; [_bar choose:self];
}
- (void)mouseDragged:(NSEvent *)e {
    NSPoint point = e.locationInWindow;
    if (!_pressedTab || hypot(point.x-_press.x,point.y-_press.y)<4) return;
    TerminalTab *tab = _pressedTab; _pressedTab = nil;
    [_bar trackTab:tab fromItem:self press:_press event:e];
}
- (void)otherMouseUp:(NSEvent *)e { if (e.buttonNumber == 2 && self.tag >= 0) [_bar closeItem:self]; else [super otherMouseUp:e]; }
- (void)closeTab:(id)sender { [_bar closeItem:self]; }
- (void)drawRect:(NSRect)dirty {
    BOOL selected = self.state == NSControlStateValueOn;
    static NSMutableParagraphStyle *style;
    if (!style) { style = [NSMutableParagraphStyle new]; style.lineBreakMode = NSLineBreakByTruncatingTail; }
    if (self.tag < 0) {
        NSColor *color = groupColor(_group.colorIndex);
        NSRect pill = NSInsetRect(self.bounds,1,3);
        [[color colorWithAlphaComponent:_hovering ? .23 : .14] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
        NSFont *font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        NSDictionary *attrs = @{NSFontAttributeName:font,NSForegroundColorAttributeName:CurrentInterfacePalette().text,NSParagraphStyleAttributeName:style};
        CGFloat h = ceil(font.ascender-font.descender+font.leading);
        [self.title drawInRect:NSMakeRect(9,floor((NSHeight(self.bounds)-h)/2),MAX(0.,NSWidth(self.bounds)-28),h) withAttributes:attrs];
        NSImage *icon = [NSImage imageWithSystemSymbolName:_group.collapsed ? @"chevron.right" : @"chevron.down" accessibilityDescription:nil];
        NSImageSymbolConfiguration *ink = [NSImageSymbolConfiguration configurationWithPaletteColors:@[CurrentInterfacePalette().secondaryText]];
        [[icon imageWithSymbolConfiguration:ink] drawInRect:NSMakeRect(NSWidth(self.bounds)-17,(NSHeight(self.bounds)-8)/2,9,8)];
        return;
    }
    if (_group) {
        [[groupColor(_group.colorIndex) colorWithAlphaComponent:.65] setFill];
        CGFloat y = self.isFlipped ? NSHeight(self.bounds)-2 : 1;
        [NSBezierPath fillRect:NSMakeRect(4,y,MAX(0.,NSWidth(self.bounds)-8),1)];
    }
    NSFont *font = [NSFont systemFontOfSize:13 weight:selected ? NSFontWeightMedium : NSFontWeightRegular];
    NSDictionary *attrs = @{NSFontAttributeName:font,NSForegroundColorAttributeName:(selected || _hovering) ? CurrentInterfacePalette().text : CurrentInterfacePalette().secondaryText,NSParagraphStyleAttributeName:style};
    CGFloat height = ceil(font.ascender-font.descender+font.leading);
    [self.title drawInRect:NSMakeRect(titleInset,floor((NSHeight(self.bounds)-height)/2),MAX(1,NSWidth(self.bounds)-titleInset-32),height) withAttributes:attrs];
}
@end

// A tab slot uses its workspace index. A header uses ~firstIndex; its end
// spans all members when collapsed, or stops before the first tab when open.
struct StripSlot { NSInteger tag, end; CGFloat x, width; };
@interface TabBar () <NSTextFieldDelegate>
@end
@implementation TabBar {
    NSTextField *_nameField;
    __weak TerminalTab *_namingTab;
    __weak TabGroup *_namingGroup;
    std::vector<StripSlot> _slots;
    BOOL _slotsDirty;
    NSMutableArray<NSString *> *_titles;
    NSMutableArray<TabItem *> *_items; // Reusable on-screen slots. Overflow tabs only need a title.
    NSString *_agentOnTip, *_agentOffTip;
    NSButton *_add, *_more, *_agent, *_settings, *_bell;
    TaskNoticePresenter *_notices;
    TabHighlight *_highlight;
    NSBox *_dropMark;
    BOOL _animateAfterLayout;
    NSInteger _selected, _first, _visible;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _items = [NSMutableArray array]; _titles = [NSMutableArray array]; _selected = NSNotFound;
        _highlight = [[TabHighlight alloc] initWithFrame:NSZeroRect];
        _highlight.hidden = YES;
        [self addSubview:_highlight];
        _add = symbolButton(@"plus",@"新建标签页",self,@selector(add:));
        _more = symbolButton(@"chevron.down",@"所有标签页",self,@selector(showAll:));
        _settings = symbolButton(@"gearshape",@"设置",self,@selector(openSettings:));
        [_settings setAccessibilityRole:NSAccessibilityRadioButtonRole];
        [_settings setAccessibilityLabel:@"设置"];
        _bell = symbolButton(@"bell",@"通知",self,@selector(showNotices:));
        for (NSButton *b in @[_add,_more,_settings,_bell]) {
            b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium];
            [self addSubview:b];
        }
        _bell.symbolConfiguration = _settings.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
        [self shortcutChanged:nil]; [self agentPreference:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(shortcutChanged:) name:TerminalPreferenceChanged object:ShortcutPreferences];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(agentPreference:) name:TerminalPreferenceChanged object:BuiltInAgent];
        [self updateBell];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(noticesChanged:) name:TaskNoticesChanged object:nil];
        [self setAccessibilityElement:YES];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(paletteChanged:) name:TerminalPreferenceChanged object:TerminalColorScheme];
        [self setAccessibilityRole:NSAccessibilityTabGroupRole];
        [self setAccessibilityLabel:@"终端标签页"];
    }
    return self;
}
- (void)paletteChanged:(NSNotification *)note {
    const auto &colors = CurrentInterfacePalette();
    for (NSButton *button in @[_add,_more,_settings]) button.contentTintColor = colors.secondaryText;
    for (TabItem *item in _items) [item applyPalette];
    if (self.workspace.showingSettings) _settings.contentTintColor = colors.accent;
    [self updateAssistantState]; [_notices refresh]; [self updateBell]; [_highlight updateInk]; _dropMark.fillColor = colors.accent;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric,barHeight); }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)groupsChanged { _slotsDirty = YES; self.needsLayout = YES; }
- (void)insertTitle:(NSString *)title atIndex:(NSInteger)index {
    [_titles insertObject:title atIndex:index];
    if (_selected != NSNotFound && _selected >= index) ++_selected;
    [self groupsChanged];
}
- (void)setTitle:(NSString *)title atIndex:(NSInteger)index {
    if ([_titles[index] isEqualToString:title]) return;
    _titles[index] = title;
    for (TabItem *item in _items) if (item.tag == index) { [item updateLabel:title]; break; }
}
- (void)removeAtIndex:(NSInteger)index {
    [_titles removeObjectAtIndex:index];
    if (index == _selected) _selected = NSNotFound;
    else if (_selected != NSNotFound && index < _selected) --_selected;
    [self groupsChanged];
}
- (TabItem *)itemForSelection:(NSInteger)index {
    if (index == NSNotFound) return nil;
    for (TabItem *item in _items)
        if (item.tag == index || (item.tag < 0 && item.group.collapsed && item.group == [_workspace groupAtIndex:index])) return item;
    return nil;
}
- (void)selectIndex:(NSInteger)index {
    if (_selected == index) { [self positionHighlight:NO]; return; }
    [self itemForSelection:_selected].state = NSControlStateValueOff;
    _selected = index;
    TabItem *item = [self itemForSelection:index];
    if (item) item.state = NSControlStateValueOn; else self.needsLayout = YES;
    if (self.needsLayout) _animateAfterLayout = YES;
    else [self positionHighlight:YES];
}
- (BOOL)allowsSelectionMotion {
    return self.window.visible && !self.window.miniaturized && TabAnimationsEnabled();
}
- (void)positionHighlight:(BOOL)changed {
    BOOL settings = self.workspace.showingSettings;
    [self updateAssistantState];
    [_settings setAccessibilityValue:@(settings)];
    _settings.contentTintColor = settings ? CurrentInterfacePalette().accent : CurrentInterfacePalette().secondaryText;
    TabItem *item = [self itemForSelection:_selected];
    if (!settings && !item) {
        [_highlight.layer removeAnimationForKey:@"selection"]; _highlight.hidden = YES; return;
    }
    NSRect frame = settings ? _settings.frame : item.frame;
    if (changed || _highlight.hidden || !NSEqualRects(_highlight.frame,frame))
        [_highlight moveTo:frame animate:changed && [self allowsSelectionMotion]];
}
- (void)moveFrom:(NSInteger)from to:(NSInteger)to {
    NSString *title = _titles[from];
    [_titles removeObjectAtIndex:from]; [_titles insertObject:title atIndex:to];
    if (_selected == from) _selected = to;
    else if (from < _selected && _selected <= to) --_selected;
    else if (to <= _selected && _selected < from) ++_selected;
    _animateAfterLayout = YES;
    [self groupsChanged];
}
- (void)rebuildSlots {
    _slots.clear();
    CGFloat x = 0;
    auto append = [&](NSInteger tag, NSInteger end, CGFloat width) {
        _slots.push_back({tag,end,x,width}); x += width+tabGap;
    };
    NSInteger count = _titles.count;
    for (NSInteger i=0; i<count;) {
        TabGroup *group = [_workspace groupAtIndex:i];
        NSInteger end = i+1;
        if (group) {
            while (end<count && [_workspace groupAtIndex:end]==group) ++end;
            CGFloat text = [group.name sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}].width;
            append(~i,group.collapsed ? end : i,std::clamp(ceil(text)+29,48.,116.));
            if (group.collapsed) { i = end; continue; }
        }
        while (i<end) { append(i,i+1,minWidth); ++i; }
    }
    _slotsDirty = NO;
}
- (void)layout {
    [super layout];
    BOOL reconfigured = _slotsDirty;
    if (reconfigured) [self rebuildSlots];
    NSInteger n = (NSInteger)_slots.size();
    CGFloat available = MAX(0,NSWidth(self.bounds)-toolWidth-2*gearWidth-trailingInset-2*actionGap-2-(_agent ? gearWidth+2 : 0));
    auto span = [&](NSInteger first,NSInteger last) { return _slots[last].x+_slots[last].width-_slots[first].x; };
    BOOL overflow = n && span(0,n-1)>available;
    if (overflow) available = MAX(0,available-toolWidth);
    _first = n ? std::clamp(_first,0L,n-1) : 0;
    if (!overflow) _first = 0;
    else if (_selected != NSNotFound) {
        auto at = std::upper_bound(_slots.begin(),_slots.end(),_selected,[](NSInteger i,const StripSlot &s){ return i < s.end; });
        NSInteger selected = at == _slots.end() ? n-1 : at-_slots.begin();
        _first = MIN(_first,selected);
        while (_first<selected && span(_first,selected)>available) ++_first;
    }
    while (_first && span(_first-1,n-1)<=available) --_first;
    NSInteger endSlot = _first, tabCount = 0;
    while (endSlot<n && (endSlot==_first || span(_first,endSlot)<=available)) {
        if (_slots[endSlot].tag>=0) ++tabCount;
        ++endSlot;
    }
    _visible = endSlot-_first;
    CGFloat extra = tabCount ? std::clamp(floor((available-span(_first,endSlot-1))/tabCount),0.,maxWidth-minWidth) : 0;
    CGFloat y = floor((NSHeight(self.bounds)-itemHeight)/2);
    while ((NSInteger)_items.count > _visible) {
        [_items.lastObject removeFromSuperview]; [_items removeLastObject];
    }
    while ((NSInteger)_items.count < _visible) {
        TabItem *item = [[TabItem alloc] initWithBar:self];
        [_items addObject:item]; [self addSubview:item];
    }
    CGFloat x = 0;
    for (NSInteger i=0; i<_visible; ++i) {
        TabItem *item = _items[i];
        const StripSlot &slot = _slots[_first+i];
        BOOL header = slot.tag<0;
        NSInteger index = header ? ~slot.tag : slot.tag;
        if (reconfigured || item.tag != slot.tag || !item.toolTip) {
            TabGroup *group = [_workspace groupAtIndex:index];
            [item configureTitle:header ? group.name : _titles[index] tag:slot.tag group:group];
        }
        BOOL chosen = _selected!=NSNotFound && (header ? _selected>=index && _selected<slot.end : _selected==index);
        NSControlStateValue state = chosen ? NSControlStateValueOn : NSControlStateValueOff;
        if (item.state != state) item.state = state;
        CGFloat width = MIN(available,slot.width+(header ? 0 : extra));
        item.frame = NSMakeRect(x,y,width,itemHeight); x += width+tabGap;
    }
    CGFloat end = _visible ? NSMaxX(_items.lastObject.frame)+actionGap : 0;
    _more.hidden = !overflow;
    _more.frame = NSMakeRect(end,y,toolWidth,itemHeight);
    _add.frame = NSMakeRect(end+(overflow ? toolWidth : 0),y,toolWidth,itemHeight);
    _bell.frame = NSMakeRect(NSWidth(self.bounds)-gearWidth-trailingInset,y,gearWidth,itemHeight);
    _settings.frame = NSMakeRect(NSMinX(_bell.frame)-gearWidth-2,y,gearWidth,itemHeight);
    _agent.frame = NSMakeRect(NSMinX(_settings.frame)-gearWidth-2,y,gearWidth,itemHeight);
    [self positionHighlight:_animateAfterLayout]; _animateAfterLayout = NO;
    if (_nameField) [self positionNameEditor];
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout = YES; }
- (void)add:(id)sender { if (_onAdd) _onAdd(); }
- (void)shortcutChanged:(NSNotification *)note {
    _add.toolTip=ShortcutTip(@"新建标签页",NewTabKey); _settings.toolTip=ShortcutTip(@"设置",SettingsKey);
    _agentOnTip=ShortcutTip(@"切换 Agent 输入",AgentKey); _agentOffTip=ShortcutTip(@"切回终端输入",AgentKey);
    [self updateAssistantState];
}
- (void)agentPreference:(NSNotification *)note {
    if ([TerminalPreferences() boolForKey:BuiltInAgent]) {
        if (!_agent) {
            _agent=symbolButton(@"sparkles",_agentOnTip,self,@selector(toggleAssistant:));
            _agent.symbolConfiguration=_add.symbolConfiguration; [self addSubview:_agent];
        }
        [self updateAssistantState];
    } else { [_agent removeFromSuperview]; _agent=nil; }
    self.needsLayout=YES;
}
- (void)updateAssistantState {
    if (!_agent) return;
    BOOL selected=self.workspace.focused.builtInAgentVisible;
    BOOL enabled=self.workspace.focused!=nil;
    if (_agent.enabled!=enabled) _agent.enabled=enabled;
    NSColor *tint=selected ? CurrentInterfacePalette().accent : CurrentInterfacePalette().secondaryText;
    if (_agent.contentTintColor!=tint) _agent.contentTintColor=tint;
    NSString *label=selected ? _agentOffTip : _agentOnTip;
    if (![_agent.toolTip isEqual:label]) {
        [_agent setAccessibilityValue:@(selected)]; [_agent setAccessibilityLabel:label]; _agent.toolTip=label;
    }
}
- (void)toggleAssistant:(id)sender { [self.workspace.focused toggleAssistant:sender]; }
- (void)openSettings:(id)sender { [self.workspace showSettings]; }
- (void)updateBell {
    NSUInteger count = TaskNotice.unreadCount;
    NSString *label = count ? [NSString stringWithFormat:@"通知，%lu 条未读",(unsigned long)count] : @"通知";
    _bell.image = [NSImage imageWithSystemSymbolName:count ? @"bell.badge" : @"bell" accessibilityDescription:nil];
    _bell.contentTintColor = CurrentInterfacePalette().secondaryText;
    NSImageSymbolConfiguration *size = _settings.symbolConfiguration;
    _bell.symbolConfiguration = count ? [size configurationByApplyingConfiguration:
        [NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.controlAccentColor,CurrentInterfacePalette().secondaryText]]] : size;
    [_bell setAccessibilityLabel:label]; _bell.toolTip = label;
}
- (void)showNotices:(id)sender {
    if (!_notices) _notices = [TaskNoticePresenter new];
    [_notices toggleFrom:_bell];
}
- (void)noticesChanged:(NSNotification *)note {
    [self updateBell]; [_notices refresh];
    TaskNotice *item = note.object;
    if (!item || !self.window.visible) return;
    NSWindow *active = NSApp.keyWindow;
    if (![(id)active.windowController conformsToProtocol:@protocol(WorkspaceWindow)]) active = item.originWindow;
    if (self.window != active) return;
    if (!_notices) _notices = [TaskNoticePresenter new];
    NSView *content = self.window.contentView;
    CGFloat top = NSMaxY([self.workspace convertRect:self.workspace.bounds toView:content]);
    [_notices show:item inContent:content top:top];
}
- (void)choose:(TabItem *)item {
    if (item.tag < 0) [_workspace toggleGroup:item.group];
    else if (_onSelect) _onSelect(item.tag);
}
- (void)closeItem:(TabItem *)item { if (_onClose) _onClose(item.tag); }
- (NSRect)selectedTabScreenRect {
    [self layoutSubtreeIfNeeded];
    TabItem *item = [self itemForSelection:_selected];
    if (!self.window || !item) return NSZeroRect;
    return [self.window convertRectToScreen:[self convertRect:item.frame toView:nil]];
}
- (NSInteger)insertionSlotAtX:(CGFloat)x {
    [self layoutSubtreeIfNeeded];
    for (TabItem *item in _items) if (x < NSMidX(item.frame)) return item.tag<0 ? ~item.tag : item.tag;
    return _visible ? _slots[_first+_visible-1].end : 0;
}
- (TabGroup *)dropGroupAtX:(CGFloat)x {
    for (TabItem *item in _items)
        if (x>=NSMinX(item.frame) && x<=NSMaxX(item.frame)) return item.group;
    return nil;
}
- (void)indicateSlot:(NSInteger)slot {
    if (slot == NSNotFound) { [_dropMark removeFromSuperview]; _dropMark = nil; return; }
    if (!_dropMark) {
        _dropMark = [NSBox new]; _dropMark.boxType = NSBoxCustom; _dropMark.borderWidth = 0;
        _dropMark.fillColor = CurrentInterfacePalette().accent; [self addSubview:_dropMark];
    }
    // Leave the ends visible above and below the floating tab.
    CGFloat edge = _items.count ? NSMaxX(_items.lastObject.frame)+tabGap/2 : 0;
    for (TabItem *item in _items) {
        NSInteger start = item.tag < 0 ? ~item.tag : item.tag;
        if (slot<=start) { edge=NSMinX(item.frame)-tabGap/2; break; }
    }
    _dropMark.frame = NSMakeRect(MAX(0.,edge-1),1,2,NSHeight(self.bounds)-2);
}
- (void)trackTab:(TerminalTab *)tab fromItem:(TabItem *)item press:(NSPoint)press event:(NSEvent *)event {
    TabWorkspace *source = self.workspace;
    NSWindow *origin = self.window;
    if (!origin || [source indexOfTab:tab] == NSNotFound) return;
    NSRect start = [origin convertRectToScreen:[item convertRect:item.bounds toView:nil]];
    NSPoint grab = [origin convertPointToScreen:press];
    NSPoint offset = NSMakePoint(grab.x-NSMinX(start),grab.y-NSMinY(start));
    BOOL animate = [self allowsSelectionMotion];
    NSPanel *badge = [[NSPanel alloc] initWithContentRect:start
        styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
    badge.appearance = origin.appearance; badge.releasedWhenClosed = NO; badge.ignoresMouseEvents = YES;
    badge.level = NSFloatingWindowLevel; badge.hasShadow = NO; badge.animationBehavior = NSWindowAnimationBehaviorNone;
    badge.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    badge.opaque = NO; badge.backgroundColor = NSColor.clearColor; badge.alphaValue = .91;
    NSBox *plate = [[NSBox alloc] initWithFrame:(NSRect){NSZeroPoint,start.size}];
    plate.boxType = NSBoxCustom; plate.cornerRadius = 6; plate.borderWidth = 1;
    plate.contentViewMargins = NSZeroSize; plate.borderColor = CurrentInterfacePalette().separator; plate.fillColor = CurrentInterfacePalette().chrome;
    badge.contentView = plate;
    NSTextField *label = [NSTextField labelWithString:item.title]; label.textColor = CurrentInterfacePalette().text;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.lineBreakMode = NSLineBreakByTruncatingTail; [label sizeToFit];
    CGFloat height = NSHeight(label.frame);
    label.frame = NSMakeRect(10,floor((NSHeight(start)-height)/2),MAX(1.,NSWidth(start)-26),height);
    [plate.contentView addSubview:label];
    __block TabWorkspace *target = nil;
    __block NSInteger slot = NSNotFound;
    __block TabGroup *dropGroup = nil;
    void (^update)(NSEvent *) = ^(NSEvent *e) {
        NSPoint point = e.window ? [e.window convertPointToScreen:e.locationInWindow] : e.locationInWindow;
        [badge setFrameOrigin:NSMakePoint(point.x-offset.x,point.y-offset.y)];
        NSInteger number = [NSWindow windowNumberAtPoint:point belowWindowWithWindowNumber:0];
        if (number == badge.windowNumber)
            number = [NSWindow windowNumberAtPoint:point belowWindowWithWindowNumber:number];
        NSWindow *hit = [NSApp windowWithWindowNumber:number];
        id<WorkspaceWindow> controller = (id)hit.windowController;
        TabWorkspace *next = [(id)controller conformsToProtocol:@protocol(WorkspaceWindow)] ? controller.workspace : nil;
        TabBar *bar = next.tabBar;
        NSPoint pos = [bar convertPoint:[hit convertPointFromScreen:point] fromView:nil];
        BOOL inBar = bar && NSPointInRect(pos,bar.bounds);
        if (next == source && !inBar) next = nil;
        NSInteger nextSlot = inBar ? [bar insertionSlotAtX:pos.x] : next.count;
        dropGroup = inBar ? [bar dropGroupAtX:pos.x] : nil;
        if (next == target && nextSlot == slot) return;
        if (next != target) [target.tabBar indicateSlot:NSNotFound];
        target = next; slot = nextSlot;
        [target.tabBar indicateSlot:slot];
    };
    item.alphaValue = .35; update(event); [badge orderFront:nil]; [NSCursor.closedHandCursor push];
    __block BOOL commit = NO;
    [origin trackEventsMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp|NSEventMaskKeyDown|NSEventMaskAppKitDefined
        timeout:NSEventDurationForever mode:NSEventTrackingRunLoopMode handler:^(NSEvent *e, BOOL *stop) {
        if (!NSApp.active || !origin.visible || [source indexOfTab:tab]==NSNotFound ||
            (e.type==NSEventTypeKeyDown && e.keyCode==53)) { *stop = YES; return; }
        if (e.type==NSEventTypeLeftMouseDragged || e.type==NSEventTypeLeftMouseUp) update(e);
        if (e.type==NSEventTypeLeftMouseUp) { commit = YES; *stop = YES; }
    }];
    [target.tabBar indicateSlot:NSNotFound]; [NSCursor pop]; item.alphaValue = 1;
    TabWorkspace *landing = source;
    if (commit && target.window.visible && [source transferTab:tab to:target atSlot:slot group:dropGroup]) {
        landing = target; [target.window makeKeyAndOrderFront:nil];
    } else if (commit && !target && source.onDetach) {
        landing = source.onDetach(tab,badge.frame);
    }
    if (!animate || !NSApp.active || !landing.window.visible) { [badge close]; return; }
    NSRect end = [landing.tabBar selectedTabScreenRect];
    NSRect current = badge.frame;
    BOOL near = !NSIsEmptyRect(end) && hypot(NSMinX(end)-NSMinX(current),NSMinY(end)-NSMinY(current)) <= maxWidth;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .12;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        if (near) [badge.animator setFrame:end display:YES];
        badge.animator.alphaValue = 0;
    } completionHandler:^{ [badge close]; }];
}
- (NSMenu *)menuForItem:(TabItem *)item {
    NSMenu *menu = [NSMenu new];
    auto add = [&](NSMenu *parent, NSString *title, SEL action, id context) {
        NSMenuItem *entry = [parent addItemWithTitle:title action:action keyEquivalent:@""];
        entry.target = self; entry.representedObject = context;
        return entry;
    };
    TabGroup *group = item.group;
    if (item.tag < 0) {
        add(menu,group.collapsed ? @"展开分组" : @"收起分组",@selector(toggleFromMenu:),group);
        add(menu,@"在组内新建标签页",@selector(newInGroup:),group);
        add(menu,@"重命名分组…",@selector(editGroupName:),group);
        NSMenuItem *palette = [menu addItemWithTitle:@"分组颜色" action:nil keyEquivalent:@""];
        NSMenu *colors = [NSMenu new];
        NSInteger i = 0;
        for (NSString *name in groupColors()) {
            NSMenuItem *color = add(colors,name,@selector(setGroupColor:),group);
            color.tag = i++; color.state = color.tag == group.colorIndex ? NSControlStateValueOn : NSControlStateValueOff;
        }
        palette.submenu = colors;
        [menu addItem:NSMenuItem.separatorItem];
        add(menu,@"取消分组",@selector(dissolveGroup:),group);
    } else {
        TerminalTab *tab = [_workspace tabAtIndex:item.tag];
        if (!tab) return nil;
        add(menu,@"新建分组…",@selector(editGroupName:),tab);
        NSMenu *groups = [NSMenu new];
        for (TabGroup *other in _workspace.groups) if (other != group)
            add(groups,other.name,@selector(joinGroup:),@[tab,other]);
        if (groups.numberOfItems) {
            NSMenuItem *join = [menu addItemWithTitle:@"移入分组" action:nil keyEquivalent:@""];
            join.submenu = groups;
        }
        if (group) {
            add(menu,@"收起分组",@selector(toggleFromMenu:),group);
            add(menu,@"移出分组",@selector(removeFromGroup:),tab);
        }
    }
    return menu;
}
- (void)positionNameEditor {
    NSInteger index = [_workspace indexOfTab:_namingTab];
    for (TabItem *item in _items) {
        BOOL matches = _namingGroup ? item.tag<0 && item.group==_namingGroup : item.tag==index;
        if (!matches) continue;
        CGFloat right = MAX(0.,NSMinX((_agent ?: _settings).frame)-actionGap);
        CGFloat width = MIN(right,MAX(minWidth,NSWidth(item.frame)));
        _nameField.frame = NSMakeRect(MIN(NSMinX(item.frame),right-width),floor(NSMidY(item.frame)-11),width,22);
        return;
    }
    [self finishName:NO returnFocus:NO];
}
- (void)finishName:(BOOL)commit returnFocus:(BOOL)restore {
    NSTextField *field = _nameField;
    if (!field) return;
    NSString *value = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    TerminalTab *tab = _namingTab;
    TabGroup *group = _namingGroup;
    _nameField = nil; _namingTab = nil; _namingGroup = nil;
    field.delegate = nil;
    [field removeFromSuperview];
    if (commit && tab) [_workspace createGroupForTab:tab name:value];
    if (commit && group && value.length && [_workspace rangeOfGroup:group].length) {
        group.name = value; [self groupsChanged];
    }
    if (restore && _workspace.focused) [self.window makeFirstResponder:_workspace.focused];
}
- (void)editGroupName:(NSMenuItem *)item {
    [self finishName:NO returnFocus:NO];
    [self layoutSubtreeIfNeeded];
    id context = item.representedObject;
    if ([context isKindOfClass:TabGroup.class]) _namingGroup = context;
    else _namingTab = context;
    _nameField = [NSTextField textFieldWithString:_namingGroup.name ?: @""];
    _nameField.placeholderString = @"分组名称";
    _nameField.usesSingleLineMode = YES; _nameField.font = [NSFont systemFontOfSize:12];
    _nameField.bezelStyle = NSTextFieldRoundedBezel;
    _nameField.delegate = self; [_nameField setAccessibilityLabel:@"分组名称"];
    [self addSubview:_nameField]; [self positionNameEditor];
    [_nameField selectText:nil];
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)editor doCommandBySelector:(SEL)action {
    if (control != _nameField || editor.hasMarkedText) return NO;
    if (action == @selector(cancelOperation:)) { [self finishName:NO returnFocus:YES]; return YES; }
    if (action == @selector(insertNewline:)) { [self finishName:YES returnFocus:YES]; return YES; }
    return NO;
}
- (void)controlTextDidEndEditing:(NSNotification *)note {
    if (_nameField && note.object == _nameField) [self finishName:_nameField.stringValue.length>0 returnFocus:NO];
}
- (void)toggleFromMenu:(NSMenuItem *)item { [_workspace toggleGroup:item.representedObject]; }
- (void)newInGroup:(NSMenuItem *)item { [_workspace addTabInGroup:item.representedObject]; }
- (void)dissolveGroup:(NSMenuItem *)item { [_workspace ungroup:item.representedObject]; }
- (void)joinGroup:(NSMenuItem *)item {
    NSArray *target = item.representedObject;
    [_workspace putTab:target[0] inGroup:target[1]];
}
- (void)removeFromGroup:(NSMenuItem *)item { [_workspace putTab:item.representedObject inGroup:nil]; }
- (void)setGroupColor:(NSMenuItem *)item {
    TabGroup *group = item.representedObject;
    group.colorIndex = item.tag; [self groupsChanged];
}
- (void)showAll:(id)sender {
    NSMenu *menu = [NSMenu new];
    TabGroup *last = nil;
    for (NSInteger i=0; i<(NSInteger)_titles.count; ++i) {
        TabGroup *group = [_workspace groupAtIndex:i];
        if (group && last != group) {
            NSMenuItem *heading = [menu addItemWithTitle:group.name action:nil keyEquivalent:@""];
            heading.enabled = NO;
        } else if (!group && last) [menu addItem:NSMenuItem.separatorItem];
        last = group;
        NSMenuItem *item = [menu addItemWithTitle:_titles[i] action:@selector(menuSelect:) keyEquivalent:@""];
        item.target = self; item.tag = i;
        item.representedObject = [_workspace tabAtIndex:i];
        item.indentationLevel = group ? 1 : 0;
        item.state = i == _selected ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,-3) inView:_more];
}
- (void)menuSelect:(NSMenuItem *)item {
    NSInteger index = _workspace ? [_workspace indexOfTab:item.representedObject] : item.tag;
    if (_onSelect && index != NSNotFound) _onSelect(index);
}
@end
