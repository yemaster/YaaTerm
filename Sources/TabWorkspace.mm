#include "Screen.hpp"
#import "TabWorkspace.h"
#import "SettingsView.h"
#import "TaskNotices.h"
#import "Preferences.h"
#import "Palette.h"
#include <algorithm>

@implementation TabGroup
@end

@interface TerminalTab : NSObject
@property NSView *root;
@property TabGroup *group;
@property NSTimeInterval sleepDeadline;
@property BOOL sleeping;
@property (weak) TabWorkspace *owner;
@property (readonly) NSString *title;
@property (weak) TerminalView *focused;
@end
@implementation TerminalTab
- (NSString *)title {
    NSString *name = self.focused.sessionTitle ?: @"终端";
    return _sleeping ? [name stringByAppendingString:@" · 休眠"] : name;
}
@end

static NSSize minPane(NSView *view) {
    if (![view isKindOfClass:NSSplitView.class]) return NSMakeSize(160,92);
    NSSplitView *split = (NSSplitView *)view;
    NSSize a = minPane(split.subviews.firstObject), b = minPane(split.subviews.lastObject);
    return split.vertical ? NSMakeSize(a.width+b.width+split.dividerThickness,MAX(a.height,b.height))
                          : NSMakeSize(MAX(a.width,b.width),a.height+b.height+split.dividerThickness);
}

@interface Divider : NSSplitView
@end
@implementation Divider
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame]))
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(paletteChanged:)
            name:TerminalPreferenceChanged object:TerminalColorScheme];
    return self;
}
- (void)paletteChanged:(NSNotification *)note { self.needsDisplay = YES; }
- (BOOL)isOpaque { return NO; }
- (NSColor *)dividerColor { return CurrentInterfacePalette().splitRule; }
- (void)drawDividerInRect:(NSRect)rect {
    NSRect pixels = [self convertRectToBacking:rect];
    if (self.vertical) { pixels.origin.x = floor(NSMidX(pixels)); pixels.size.width = 1; }
    else { pixels.origin.y = floor(NSMidY(pixels)); pixels.size.height = 1; }
    [self.dividerColor setFill];
    NSRectFillUsingOperation([self convertRectFromBacking:pixels],NSCompositingOperationSourceOver);
}
@end

@implementation TabWorkspace {
    NSMutableArray<TerminalTab *> *_tabs;
    TerminalTab *_active;
    SettingsView *_settingsView;
    TabBar *_tabBar;
    NSTimer *_sleepTimer;
    BOOL _sleepEnabled;
    NSUInteger _nextGroup;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tabs = [NSMutableArray array];
        _sleepEnabled = [TerminalPreferences() boolForKey:SleepIdleTabs];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sleepPreferenceChanged:)
            name:TerminalPreferenceChanged object:SleepIdleTabs];
    }
    return self;
}
- (NSTimeInterval)idleSleepDelay { return 15*60; }
- (NSArray<TerminalView *> *)panesInTab:(TerminalTab *)tab {
    NSMutableArray *panes = [NSMutableArray array];
    [self collect:tab.root into:panes];
    return panes;
}
- (void)monitorTab:(TerminalTab *)tab hidden:(BOOL)hidden {
    if (!tab) return;
    NSTimeInterval since = hidden && _sleepEnabled ? NSProcessInfo.processInfo.systemUptime : 0;
    if (!since && !tab.sleeping && !tab.sleepDeadline) return;
    for (TerminalView *pane in [self panesInTab:tab]) {
        if (tab.sleeping) [pane wakeFromIdle];
        pane.idleSince = since;
    }
    if (tab.sleeping) {
        tab.sleeping = NO;
        [self showTitleFor:tab];
    }
    tab.sleepDeadline = since ? since + self.idleSleepDelay : 0;
}
- (void)armSleepTimer {
    NSTimeInterval next = INFINITY;
    for (TerminalTab *tab in _tabs) if (tab.sleepDeadline) next = MIN(next,tab.sleepDeadline);
    if (!isfinite(next)) { [_sleepTimer invalidate]; _sleepTimer = nil; return; }
    NSTimeInterval delay = MAX(.016,next-NSProcessInfo.processInfo.systemUptime);
    if (_sleepTimer) {
        _sleepTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
        return;
    }
    __weak TabWorkspace *owner = self;
    _sleepTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) { [owner sleepIdleTabs]; }];
    _sleepTimer.tolerance = MIN(10.,delay*.1);
    [NSRunLoop.mainRunLoop addTimer:_sleepTimer forMode:NSRunLoopCommonModes];
}
- (void)sleepIdleTabs {
    _sleepTimer = nil;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime, delay = self.idleSleepDelay;
    for (TerminalTab *tab in _tabs) {
        if (!tab.sleepDeadline || tab.sleepDeadline > now) continue;
        NSArray<TerminalView *> *panes = [self panesInTab:tab];
        NSTimeInterval quietUntil = 0;
        for (TerminalView *pane in panes) quietUntil = MAX(quietUntil,pane.idleSince + delay);
        if (quietUntil > now) { tab.sleepDeadline = quietUntil; continue; }
        BOOL eligible = YES;
        for (TerminalView *pane in panes) if (!pane.canSleep) { eligible = NO; break; }
        if (!eligible) { tab.sleepDeadline = now + delay; continue; }
        tab.sleepDeadline = 0; tab.sleeping = YES;
        __weak TerminalTab *weakTab = tab;
        dispatch_block_t wake = ^{
            TerminalTab *t = weakTab;
            [t.owner monitorTab:t hidden:YES];
            [t.owner armSleepTimer];
        };
        for (TerminalView *pane in panes) [pane sleepWithWakeHandler:wake];
        [self showTitleFor:tab];
        break; // Let AppKit handle input between tabs with the same deadline.
    }
    [self armSleepTimer];
}
- (void)sleepPreferenceChanged:(NSNotification *)note {
    _sleepEnabled = [TerminalPreferences() boolForKey:SleepIdleTabs];
    for (TerminalTab *tab in _tabs) [self monitorTab:tab hidden:tab != _active || self.showingSettings];
    [self armSleepTimer];
}
- (void)dealloc { [_sleepTimer invalidate]; }
- (TabBar *)tabBar {
    if (!_tabBar) {
        _tabBar = [[TabBar alloc] initWithFrame:NSZeroRect];
        _tabBar.frame = NSMakeRect(0,0,NSWidth(self.bounds),_tabBar.intrinsicContentSize.height);
        _tabBar.workspace = self;
        __weak TabWorkspace *weak = self;
        _tabBar.onAdd = ^{ [weak addTab]; };
        _tabBar.onSelect = ^(NSInteger i){ [weak selectIndex:i]; };
        _tabBar.onClose = ^(NSInteger i){ [weak closeTabAt:i]; };
        _tabBar.onMove = ^(NSInteger from, NSInteger to){ [weak moveFrom:from to:to]; };
        for (NSInteger i=0; i<self.count; ++i) [_tabBar insertTitle:_tabs[i].title atIndex:i];
        if (_active) [_tabBar selectIndex:self.showingSettings ? NSNotFound : self.selectedIndex];
    }
    return _tabBar;
}
- (TerminalTab *)tabAtIndex:(NSInteger)index { return index>=0 && index<self.count ? _tabs[index] : nil; }
- (NSInteger)indexOfTab:(TerminalTab *)tab { return tab ? [_tabs indexOfObjectIdenticalTo:tab] : NSNotFound; }
- (TabGroup *)groupAtIndex:(NSInteger)index { return [self tabAtIndex:index].group; }
- (NSRange)rangeOfGroup:(TabGroup *)group {
    if (group) for (NSInteger i=0; i<self.count; ++i) {
        if (_tabs[i].group != group) continue;
        NSInteger end = i+1;
        while (end<self.count && _tabs[end].group == group) ++end;
        return NSMakeRange(i,end-i);
    }
    return NSMakeRange(NSNotFound,0);
}
- (NSArray<TabGroup *> *)groups {
    NSMutableArray *groups = [NSMutableArray array];
    TabGroup *last = nil;
    for (TerminalTab *tab in _tabs) {
        if (tab.group && tab.group != last) [groups addObject:tab.group];
        last = tab.group;
    }
    return groups;
}
- (TabGroup *)createGroupForTab:(TerminalTab *)tab name:(NSString *)name {
    if ([self indexOfTab:tab] == NSNotFound) return nil;
    [self putTab:tab inGroup:nil];
    TabGroup *group = [TabGroup new];
    group.colorIndex = _nextGroup % 5;
    ++_nextGroup;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    group.name = trimmed.length ? trimmed : [NSString stringWithFormat:@"分组 %lu",(unsigned long)_nextGroup];
    tab.group = group;
    [_tabBar groupsChanged];
    return group;
}
- (void)putTab:(TerminalTab *)tab inGroup:(TabGroup *)group {
    NSInteger from = [self indexOfTab:tab];
    if (from == NSNotFound || tab.group == group) return;
    NSRange range = [self rangeOfGroup:group ?: tab.group];
    if (!range.length) return;
    NSInteger end = NSMaxRange(range);
    tab.group = group;
    if (tab == _active && !self.showingSettings) group.collapsed = NO;
    [self reorderFrom:from to:end-(from<end)];
    [_tabBar groupsChanged];
}
- (void)ungroup:(TabGroup *)group {
    NSRange range = [self rangeOfGroup:group];
    if (!range.length) return;
    for (NSUInteger i=range.location; i<NSMaxRange(range); ++i) _tabs[i].group = nil;
    [_tabBar groupsChanged];
}
- (void)toggleGroup:(TabGroup *)group {
    if (![self rangeOfGroup:group].length) return;
    group.collapsed = !group.collapsed;
    [_tabBar groupsChanged];
}
- (NSInteger)count { return _tabs.count; }
- (NSInteger)selectedIndex { return _active ? [_tabs indexOfObjectIdenticalTo:_active] : NSNotFound; }
- (TerminalView *)focused { return self.showingSettings ? nil : _active.focused; }
- (void)showTitleFor:(TerminalTab *)tab {
    NSInteger index = [_tabs indexOfObjectIdenticalTo:tab];
    if (index == NSNotFound) return;
    NSString *title = tab.title;
    [_tabBar setTitle:title atIndex:index];
    if (!self.showingSettings && _active == tab && ![self.window.title isEqualToString:title]) self.window.title = title;
}
- (BOOL)isAwayFromTab:(TerminalTab *)tab {
    if (self.showingSettings || tab != _active) return YES;
    NSWindow *front = NSApp.mainWindow;
    return self.window && front != self.window && [(id)front.windowController conformsToProtocol:@protocol(WorkspaceWindow)];
}
- (void)finishedCommand:(NSString *)name status:(int)status seconds:(int)seconds inPane:(TerminalView *)pane tab:(TerminalTab *)tab {
    if (!yaa::Screen::isAgentCommand(name.UTF8String)) {
        if (![self isAwayFromTab:tab]) return;
        NSInteger policy = [TerminalPreferences() integerForKey:CommandNoticesKey];
        if (policy==AgentOnly || (policy==LongCommands && seconds<10)) return;
    }
    NSString *title = [name stringByAppendingString:status ? @" 已结束" : @" 已完成"];
    NSString *summary = status ? [NSString stringWithFormat:@"退出码 %d · 用时 %d 秒",status,seconds]
                               : [NSString stringWithFormat:@"命令执行成功 · 用时 %d 秒",seconds];
    [TaskNotice postFrom:pane window:self.window title:title summary:summary];
}
- (TerminalView *)makePane:(NSRect)frame forTab:(TerminalTab *)tab {
    TerminalView *pane = [[TerminalView alloc] initWithFrame:frame];
    pane.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    __weak TerminalTab *weakTab = tab;
    pane.didFocus = ^(TerminalView *v) {
        TerminalTab *t = weakTab;
        if (t && t.focused != v) { t.focused = v; [t.owner showTitleFor:t]; }
    };
    pane.didRename = ^(TerminalView *v) {
        TerminalTab *t = weakTab;
        if (t && t.focused == v) [t.owner showTitleFor:t];
    };
    pane.agentFinished = ^(TerminalView *v, NSString *name, BOOL failed) {
        TerminalTab *t = weakTab;
        if (!t.owner) return;
        NSString *title = [name stringByAppendingString:failed ? @" 任务失败" : @" 任务完成"];
        [TaskNotice postFrom:v window:t.owner.window title:title summary:failed ? @"回到会话查看错误。" : @"本轮任务已结束，点击查看回复。"];
    };
    pane.commandExited = ^(TerminalView *v, NSString *name, int status, int seconds) {
        TerminalTab *t = weakTab;
        [t.owner finishedCommand:name status:status seconds:seconds inPane:v tab:t];
    };
    pane.revealTask = ^(TerminalView *v) {
        TerminalTab *t = weakTab;
        TabWorkspace *owner = t.owner;
        if (!owner || ![v isDescendantOf:t.root]) return;
        [owner selectIndex:[owner indexOfTab:t]]; [owner focusPane:v];
        if (owner.window.miniaturized) [owner.window deminiaturize:nil];
        [owner.window makeKeyAndOrderFront:nil];
    };
    pane.didExit = ^(TerminalView *v) {
        TerminalTab *t = weakTab;
        TabWorkspace *owner = t.owner;
        [owner closePane:v inTab:t];
    };
    return pane;
}
- (void)addTab {
    NSInteger slot = _active ? self.selectedIndex+1 : 0;
    TabGroup *group = _active.group;
    if (group && (group.collapsed || self.showingSettings)) {
        slot = NSMaxRange([self rangeOfGroup:group]); group = nil;
    }
    [self addTabAt:slot group:group];
}
- (void)addTabInGroup:(TabGroup *)group {
    NSRange range = [self rangeOfGroup:group];
    if (range.length) [self addTabAt:NSMaxRange(range) group:group];
}
- (void)addTabAt:(NSInteger)index group:(TabGroup *)group {
    TerminalTab *tab = [TerminalTab new]; tab.group = group;
    tab.root = [[NSView alloc] initWithFrame:self.bounds];
    tab.root.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    TerminalView *pane = [self makePane:tab.root.bounds forTab:tab];
    [tab.root addSubview:pane]; tab.focused = pane;
    [self insertTab:tab atIndex:index];
    [pane start];
}
- (void)insertTab:(TerminalTab *)tab atIndex:(NSInteger)index {
    tab.owner = self;
    [_tabs insertObject:tab atIndex:index];
    [_tabBar insertTitle:tab.title atIndex:index];
    [self selectIndex:index];
}
- (BOOL)showingSettings { return _settingsView.superview == self; }
- (void)showSettings {
    if (self.showingSettings) return;
    if (!_settingsView) {
        _settingsView = [[SettingsView alloc] initWithFrame:self.bounds];
        _settingsView.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        __weak TabWorkspace *weak = self;
        _settingsView.onClose = ^{ [weak dismissSettings]; };
    }
    [self.window makeFirstResponder:nil];
    [_active.root removeFromSuperview];
    if (_sleepEnabled) { [self monitorTab:_active hidden:YES]; [self armSleepTimer]; }
    _settingsView.frame = self.bounds;
    [self addSubview:_settingsView]; [self updateMinimum];
    if (_onSettingsVisibilityChange) _onSettingsVisibilityChange();
    [_tabBar selectIndex:NSNotFound];
    if (self.window) self.window.title = @"设置";
    [self.window makeFirstResponder:_settingsView.navigationButton];
}
- (void)dismissSettings {
    if (self.showingSettings && _active) [self selectIndex:self.selectedIndex];
}
- (void)selectIndex:(NSInteger)index {
    if (index < 0 || index >= self.count) return;
    TerminalTab *tab = _tabs[index];
    if (tab.group.collapsed) { tab.group.collapsed = NO; [_tabBar groupsChanged]; }
    BOOL leavingSettings = self.showingSettings;
    if (leavingSettings || tab != _active) {
        [self.window makeFirstResponder:nil];
        [_settingsView removeFromSuperview]; [_active.root removeFromSuperview];
        if (_sleepEnabled || tab.sleeping || tab.sleepDeadline) {
            if (!leavingSettings && _active != tab) [self monitorTab:_active hidden:YES];
            [self monitorTab:tab hidden:NO];
            [self armSleepTimer];
        }
        _active = tab;
        [self updateMinimum];
        tab.root.frame = self.bounds;
        [self addSubview:tab.root]; [_tabBar selectIndex:index];
        if (leavingSettings && _onSettingsVisibilityChange) _onSettingsVisibilityChange();
        if (self.window) self.window.title = tab.title;
    }
    [self.window makeFirstResponder:tab.focused];
}
- (void)cycleTab:(NSInteger)step {
    NSInteger terminals = self.count;
    if (!terminals) return;
    NSInteger slots = terminals+1, current = self.showingSettings ? terminals : self.selectedIndex;
    NSInteger next = (current+step%slots+slots)%slots;
    if (next == terminals) [self showSettings]; else [self selectIndex:next];
}
- (void)moveFrom:(NSInteger)from to:(NSInteger)to {
    TerminalTab *tab = [self tabAtIndex:from], *neighbor = [self tabAtIndex:to];
    if (!tab || !neighbor || from == to) return;
    [self transferTab:tab to:self atSlot:from < to ? to+1 : to group:neighbor.group];
}
- (void)reorderFrom:(NSInteger)from to:(NSInteger)to {
    if (from == to || from < 0 || to < 0 || from >= self.count || to >= self.count) return;
    TerminalTab *tab = _tabs[from];
    [_tabs removeObjectAtIndex:from]; [_tabs insertObject:tab atIndex:to];
    [_tabBar moveFrom:from to:to];
}
- (void)stopTab:(TerminalTab *)tab {
    NSMutableArray<TerminalView *> *panes = [NSMutableArray array];
    [self collect:tab.root into:panes];
    for (TerminalView *pane in panes) { [TaskNotice discardFor:pane]; [pane stop]; }
}
- (void)closeTabAt:(NSInteger)index {
    if (index < 0 || index >= self.count) return;
    TerminalTab *tab = _tabs[index];
    [self stopTab:tab];
    [self removeTabAt:index];
    if (!self.count && _onEmpty) _onEmpty();
}
- (void)removeTabAt:(NSInteger)index {
    BOOL wasActive = _tabs[index] == _active;
    BOOL inSettings = self.showingSettings;
    if (wasActive) {
        if (!inSettings) [self.window makeFirstResponder:nil];
        [_active.root removeFromSuperview]; _active = nil;
    }
    [self monitorTab:_tabs[index] hidden:NO];
    _tabs[index].owner = nil;
    [_tabs removeObjectAtIndex:index]; [_tabBar removeAtIndex:index];
    if (_sleepEnabled) [self armSleepTimer];
    if (wasActive && self.count) {
        NSInteger next = MIN(index,self.count-1);
        if (inSettings) _active = _tabs[next]; else [self selectIndex:next];
    }
}
- (void)adoptDividers:(NSView *)node {
    if (![node isKindOfClass:Divider.class]) return;
    ((Divider *)node).delegate = self;
    for (NSView *child in node.subviews) [self adoptDividers:child];
}
- (BOOL)transferTab:(TerminalTab *)tab to:(TabWorkspace *)destination atSlot:(NSInteger)slot {
    TabGroup *left = [destination groupAtIndex:slot-1];
    TabGroup *inside = left && left == [destination groupAtIndex:slot] ? left : nil;
    return [self transferTab:tab to:destination atSlot:slot group:inside];
}
- (BOOL)transferTab:(TerminalTab *)tab to:(TabWorkspace *)destination atSlot:(NSInteger)slot group:(TabGroup *)group {
    NSInteger from = [self indexOfTab:tab];
    if (from == NSNotFound || !destination || slot < 0 || slot > destination.count) return NO;
    if (group) {
        NSRange range = [destination rangeOfGroup:group];
        if (!range.length) return NO;
        slot = std::clamp(slot,(NSInteger)range.location,(NSInteger)NSMaxRange(range));
    } else {
        TabGroup *left = [destination groupAtIndex:slot-1];
        if (left && left == [destination groupAtIndex:slot]) group = left;
    }
    if (self == destination) {
        tab.group = group;
        if (tab == _active && !self.showingSettings) group.collapsed = NO;
        [self reorderFrom:from to:slot > from ? slot-1 : slot];
        [_tabBar groupsChanged];
        return YES;
    }
    [self removeTabAt:from];
    tab.group = group;
    [destination adoptDividers:tab.root.subviews.firstObject];
    [destination insertTab:tab atIndex:slot];
    // The receiving window owns the live tree before the last source window can close.
    if (!self.count && _onEmpty) _onEmpty();
    return YES;
}
- (void)stopAll {
    [_sleepTimer invalidate]; _sleepTimer = nil;
    for (TerminalTab *tab in _tabs) [self stopTab:tab];
}
- (void)focusPane:(TerminalView *)pane {
    _active.focused = pane; [self.window makeFirstResponder:pane]; [self showTitleFor:_active];
}
- (void)splitVertical:(BOOL)vertical {
    TerminalView *a = self.focused;
    if (!a) return;
    CGFloat length = vertical ? NSWidth(a.frame) : NSHeight(a.frame);
    if (length < (vertical ? 321 : 185)) { NSBeep(); return; }
    NSView *parent = a.superview;
    Divider *split = [[Divider alloc] initWithFrame:a.frame];
    split.vertical = vertical;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    [parent replaceSubview:a with:split];
    CGFloat half = floor((length-split.dividerThickness)/2);
    NSRect first = split.bounds, second = split.bounds;
    if (vertical) { first.size.width = half; second.origin.x = half+split.dividerThickness; second.size.width = length-second.origin.x; }
    else { first.size.height = half; second.origin.y = half+split.dividerThickness; second.size.height = length-second.origin.y; }
    a.frame = first; TerminalView *b = [self makePane:second forTab:_active];
    [split addSubview:a]; [split addSubview:b]; split.delegate = self;
    [split setPosition:half ofDividerAtIndex:0];
    [self updateMinimum]; [self focusPane:b]; [b start];
}
- (void)updateMinimum {
    NSSize size = self.showingSettings ? NSMakeSize(500,440) : minPane(_active.root.subviews.firstObject);
    CGFloat chrome = self.superview ? NSHeight(self.superview.bounds)-NSHeight(self.bounds) : 0;
    NSSize minimum = NSMakeSize(MAX(300,size.width),MAX(180,size.height)+MAX(0.,chrome));
    self.window.contentMinSize = minimum;
    if (self.window && (NSWidth(self.bounds) < minimum.width || NSHeight(self.bounds)+chrome < minimum.height))
        [self.window setContentSize:NSMakeSize(MAX(NSWidth(self.bounds),minimum.width),MAX(NSHeight(self.bounds)+chrome,minimum.height))];
}
- (CGFloat)splitView:(NSSplitView *)s constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    NSSize size = minPane(s.subviews.firstObject); return MAX(p,s.vertical ? size.width : size.height);
}
- (CGFloat)splitView:(NSSplitView *)s constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    NSSize size = minPane(s.subviews.lastObject);
    return MIN(p,(s.vertical ? NSWidth(s.bounds)-size.width : NSHeight(s.bounds)-size.height)-s.dividerThickness);
}
- (NSRect)splitView:(NSSplitView *)s effectiveRect:(NSRect)proposed forDrawnRect:(NSRect)drawn ofDividerAtIndex:(NSInteger)i {
    return NSUnionRect(proposed,NSInsetRect(drawn,s.vertical ? -4 : 0,s.vertical ? 0 : -4));
}
- (void)collect:(NSView *)node into:(NSMutableArray<TerminalView *> *)panes {
    if ([node isKindOfClass:TerminalView.class]) [panes addObject:(TerminalView *)node];
    else for (NSView *v in node.subviews) [self collect:v into:panes];
}
- (void)nextPane:(NSInteger)direction {
    if (self.showingSettings) return;
    NSMutableArray *panes = [NSMutableArray array];
    [self collect:_active.root into:panes];
    if (!panes.count) return;
    NSInteger i = [panes indexOfObject:self.focused], n = panes.count;
    [self focusPane:panes[(i+direction+n)%n]];
}
- (void)closePane {
    if (self.showingSettings) { [self dismissSettings]; return; }
    [self closePane:self.focused inTab:_active];
}
- (void)closePane:(TerminalView *)pane inTab:(TerminalTab *)tab {
    if (!tab || !pane || ![pane isDescendantOf:tab.root]) return;
    NSView *group = pane.superview;
    if (group == tab.root) { [self closeTabAt:[_tabs indexOfObjectIdenticalTo:tab]]; return; }
    NSView *other = group.subviews.firstObject == pane ? group.subviews.lastObject : group.subviews.firstObject;
    NSView *parent = group.superview;
    NSRect frame = group.frame;
    [TaskNotice discardFor:pane]; [pane stop];
    ((Divider *)group).delegate = nil;
    [other removeFromSuperview]; [parent replaceSubview:group with:other]; other.frame = frame;
    if (tab.focused == pane) {
        NSView *next = other;
        while ([next isKindOfClass:Divider.class]) next = next.subviews.firstObject;
        tab.focused = (TerminalView *)next;
        [self showTitleFor:tab];
    }
    if (tab == _active && !self.showingSettings) {
        [self updateMinimum];
        [self.window makeFirstResponder:tab.focused];
    }
    [pane removeFromSuperview];
}
@end
