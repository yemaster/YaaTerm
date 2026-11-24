#import "WindowContent.h"
#import "Preferences.h"
#import "Palette.h"
#include <clocale>

@class TerminalWindowController;
@interface App : NSObject <NSApplicationDelegate>
@property NSMutableSet<TerminalWindowController *> *windows;
- (void)terminalWindowClosed:(TerminalWindowController *)controller;
- (TabWorkspace *)detachTab:(TerminalTab *)tab from:(TabWorkspace *)workspace at:(NSRect)preview;
@end

@interface TerminalWindowController : NSWindowController <NSWindowDelegate,WorkspaceWindow>
@property (readonly) TabWorkspace *workspace;
- (instancetype)initWithShell:(BOOL)launchShell;
@end
@implementation TerminalWindowController
- (instancetype)initWithShell:(BOOL)launchShell {
    TabWorkspace *workspace = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,920,526)];
    // Let the login shell run while AppKit builds the window and titlebar controls.
    if (launchShell) [workspace addTab];
    NSWindow *window = CreateTerminalWindow(workspace);
    if ((self = [super initWithWindow:window])) {
        _workspace = workspace;
        window.delegate = self;
        [self updateAppearance:nil];
        window.title = workspace.focused.sessionTitle ?: @"YaaTerm";
        __weak NSWindow *weakWindow = window;
        workspace.onEmpty = ^{ [weakWindow close]; };
        __weak TabWorkspace *weakWorkspace = workspace;
        workspace.onDetach = ^TabWorkspace *(TerminalTab *tab, NSRect preview) {
            return [(App *)NSApp.delegate detachTab:tab from:weakWorkspace at:preview];
        };
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateAppearance:) name:TerminalPreferenceChanged object:AppearanceModeKey];
    }
    return self;
}
- (void)updateAppearance:(NSNotification *)note {
    NSInteger mode = [TerminalPreferences() integerForKey:AppearanceModeKey];
    self.window.appearance = mode == FollowSystem ? nil : SchemeAppearance(PreferredColorScheme());
}
- (void)windowDidEnterFullScreen:(NSNotification *)note { [(WindowContent *)self.window.contentView setFullScreenTabBar:YES]; }
- (void)windowDidExitFullScreen:(NSNotification *)note { [(WindowContent *)self.window.contentView setFullScreenTabBar:NO]; }
- (void)windowDidBecomeKey:(NSNotification *)n {
    if (_workspace.focused) [self.window makeFirstResponder:_workspace.focused];
}
- (void)windowWillClose:(NSNotification *)n {
    [_workspace stopAll];
    [(App *)NSApp.delegate terminalWindowClosed:self];
}
@end

@implementation App
- (void)installDockIcon {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
    NSURL *url = name ? [bundle URLForResource:name withExtension:nil] : nil;
    NSImage *icon = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (icon.valid) NSApp.applicationIconImage = icon;
}
- (TabWorkspace *)current {
    NSWindowController *controller = NSApp.keyWindow.windowController;
    return [controller isKindOfClass:TerminalWindowController.class] ? ((TerminalWindowController *)controller).workspace : nil;
}
static char systemAppearanceContext;
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == &systemAppearanceContext) UpdateSystemAppearance(NSApp.effectiveAppearance);
    else [super observeValueForKeyPath:path ofObject:object change:change context:context];
}
- (void)applicationWillTerminate:(NSNotification *)note {
    [NSApp removeObserver:self forKeyPath:@"effectiveAppearance" context:&systemAppearanceContext];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
- (void)accessibilityChanged:(NSNotification *)note {
    UpdateReducedTransparency(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency);
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(accessibilityChanged:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    [self accessibilityChanged:nil];
    [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:NSKeyValueObservingOptionInitial context:&systemAppearanceContext];
    NSWindow.allowsAutomaticWindowTabbing = NO;
    self.windows = [NSMutableSet set]; [self addWindow:nil]; [self installMenu];
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_async(dispatch_get_main_queue(), ^{ [self installDockIcon]; });
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)showSettings:(id)sender { [self.current showSettings]; }
- (void)terminalWindowClosed:(TerminalWindowController *)controller { [self.windows removeObject:controller]; }
- (TerminalWindowController *)createWindowWithShell:(BOOL)launchShell {
    TerminalWindowController *controller = [[TerminalWindowController alloc] initWithShell:launchShell];
    [self.windows addObject:controller]; return controller;
}
- (void)addWindow:(id)sender {
    TerminalWindowController *controller = [self createWindowWithShell:YES];
    [controller.window center]; [controller showWindow:nil];
}
static void positionAtDrop(TabWorkspace *workspace, NSRect preview) {
    NSWindow *window = workspace.window;
    [window.contentView.superview layoutSubtreeIfNeeded];
    NSRect tab = [workspace.tabBar selectedTabScreenRect];
    if (NSIsEmptyRect(tab)) return;
    NSRect frame = NSOffsetRect(window.frame, NSMinX(preview)-NSMinX(tab), NSMinY(preview)-NSMinY(tab));
    NSPoint center = NSMakePoint(NSMidX(preview),NSMidY(preview));
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(center,screen.frame)) {
            frame = [window constrainFrameRect:frame toScreen:screen]; break;
        }
    }
    [window setFrame:frame display:NO];
}
- (TabWorkspace *)detachTab:(TerminalTab *)tab from:(TabWorkspace *)source at:(NSRect)preview {
    if ([source indexOfTab:tab] == NSNotFound) return nil;
    if (source.count == 1 && !(source.window.styleMask & NSWindowStyleMaskFullScreen)) {
        positionAtDrop(source,preview);
        return source;
    }
    TerminalWindowController *newWindow = [self createWindowWithShell:NO];
    if (!(source.window.styleMask & NSWindowStyleMaskFullScreen))
        [newWindow.window setContentSize:source.window.contentView.bounds.size];
    [newWindow.window.contentView layoutSubtreeIfNeeded];
    if (![source transferTab:tab to:newWindow.workspace atSlot:0]) {
        [newWindow close]; return nil;
    }
    positionAtDrop(newWindow.workspace,preview);
    NSWindowAnimationBehavior behavior = newWindow.window.animationBehavior;
    newWindow.window.animationBehavior = NSWindowAnimationBehaviorNone;
    BOOL animate = TabAnimationsEnabled();
    if (animate) newWindow.window.alphaValue = .84;
    [newWindow showWindow:nil];
    if (animate) [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = .12;
        newWindow.window.animator.alphaValue = 1;
    } completionHandler:nil];
    newWindow.window.animationBehavior = behavior;
    return newWindow.workspace;
}
- (void)addTab:(id)sender {
    TabWorkspace *workspace = self.current;
    if (workspace) [workspace addTab]; else [self addWindow:sender];
}
- (void)previousSessionTab:(id)sender { [self.current cycleTab:-1]; }
- (void)nextSessionTab:(id)sender { [self.current cycleTab:1]; }
- (void)splitRight:(id)s { [self.current splitVertical:YES]; }
- (void)splitDown:(id)s { [self.current splitVertical:NO]; }
- (void)closePane:(id)s {
    [self.current closePane];
}
- (void)nextPane:(id)s { [self.current nextPane:1]; }
- (void)previousPane:(id)s { [self.current nextPane:-1]; }
- (void)larger:(id)s { [self.current.focused adjustFont:1]; }
- (void)smaller:(id)s { [self.current.focused adjustFont:-1]; }
- (void)normalSize:(id)s { [self.current.focused adjustFont:0]; }
- (void)installMenu {
    NSMenu *bar = [NSMenu new]; NSApp.mainMenu = bar;
    auto menu = [&](NSString *title) {
        NSMenuItem *item = [bar addItemWithTitle:title action:nil keyEquivalent:@""];
        item.submenu = [[NSMenu alloc] initWithTitle:title]; return item.submenu;
    };
    auto item = [](NSMenu *m, NSString *name, SEL action, NSString *key, NSEventModifierFlags flags) {
        NSMenuItem *i = [m addItemWithTitle:name action:action keyEquivalent:key]; i.keyEquivalentModifierMask = flags;
    };
    NSEventModifierFlags cmd = NSEventModifierFlagCommand, shift = cmd|NSEventModifierFlagShift, opt = cmd|NSEventModifierFlagOption;
    NSMenu *app = menu(@"YaaTerm");
    item(app,@"设置…",@selector(showSettings:),@",",cmd);
    [app addItem:NSMenuItem.separatorItem];
    item(app,@"退出 YaaTerm",@selector(terminate:),@"q",cmd);
    NSMenu *session = menu(@"会话");
    item(session,@"新建窗口",@selector(addWindow:),@"n",cmd);
    item(session,@"新建标签页",@selector(addTab:),@"t",cmd);
    [session addItem:NSMenuItem.separatorItem];
    item(session,@"左右分屏",@selector(splitRight:),@"d",cmd);
    item(session,@"上下分屏",@selector(splitDown:),@"D",shift);
    item(session,@"关闭当前分屏或标签页",@selector(closePane:),@"w",cmd);
    NSMenu *edit = menu(@"编辑");
    item(edit,@"复制",@selector(copy:),@"c",cmd); item(edit,@"粘贴",@selector(paste:),@"v",cmd);
    [edit addItem:NSMenuItem.separatorItem];
    item(edit,@"搜索终端内容…",@selector(showFind:),@"f",cmd);
    item(edit,@"查找下一处",@selector(findNext:),@"g",cmd);
    item(edit,@"查找上一处",@selector(findPrevious:),@"G",shift);
    NSMenu *view = menu(@"显示");
    item(view,@"放大字号",@selector(larger:),@"=",cmd); item(view,@"缩小字号",@selector(smaller:),@"-",cmd);
    item(view,@"恢复默认字号",@selector(normalSize:),@"0",cmd);
    NSMenu *window = menu(@"窗口"); NSApp.windowsMenu = window;
    item(window,@"上一个标签页",@selector(previousSessionTab:),@"{",shift);
    item(window,@"下一个标签页",@selector(nextSessionTab:),@"}",shift);
    [window addItem:NSMenuItem.separatorItem];
    item(window,@"上一个分屏",@selector(previousPane:),@"[",opt);
    item(window,@"下一个分屏",@selector(nextPane:),@"]",opt);
    [window addItem:NSMenuItem.separatorItem];
    item(window,@"最小化",@selector(performMiniaturize:),@"m",cmd);
    item(window,@"切换全屏",@selector(toggleFullScreen:),@"f",cmd|NSEventModifierFlagControl);
}
@end

int main() {
    @autoreleasepool {
        setlocale(LC_CTYPE,"en_US.UTF-8");
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        App *delegate = [App new]; app.delegate = delegate;
        [app run];
        (void)delegate.windows;
    }
    return 0;
}
