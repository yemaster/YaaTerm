#include <initializer_list>
#import "WindowContent.h"
#import "Preferences.h"
#import "Palette.h"
#import "Wallpaper.h"
#import <QuartzCore/QuartzCore.h>

static NSView *backgroundMaterialView(TerminalBackgroundMaterial material, NSRect frame) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (material == LiquidGlassBackground) {
        if (@available(macOS 26.0, *)) {
            NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:frame];
            glass.style = NSGlassEffectViewStyleRegular;
            glass.cornerRadius = 0;
            [glass setAccessibilityElement:NO];
            return glass;
        }
    }
#endif
    NSVisualEffectView *frost = [[NSVisualEffectView alloc] initWithFrame:frame];
    frost.material = NSVisualEffectMaterialUnderWindowBackground;
    frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    [frost setAccessibilityElement:NO];
    return frost;
}

@interface WindowContent ()
- (void)installTitleAccessory;
- (void)updateBackdrop;
@end

// Modifier changes belong to the window: the pointer may be over an unfocused split.
@interface TerminalWindow : NSWindow
@property (weak) TabWorkspace *workspace;
@end
@implementation TerminalWindow
- (void)sendEvent:(NSEvent *)event {
    if (event.type==NSEventTypeFlagsChanged && self.isKeyWindow)
        [_workspace setLinkModifierDown:(event.modifierFlags & NSEventModifierFlagCommand)!=0];
    [super sendEvent:event];
}
- (void)becomeKeyWindow {
    [super becomeKeyWindow];
    [_workspace setLinkModifierDown:(NSEvent.modifierFlags & NSEventModifierFlagCommand)!=0];
}
- (void)resignKeyWindow {
    [_workspace setLinkModifierDown:NO];
    [super resignKeyWindow];
}
@end

NSWindow *CreateTerminalWindow(TabWorkspace *workspace) {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSRect frame = [NSWindow frameRectForContentRect:workspace.bounds styleMask:style];
    TerminalWindow *window = [[TerminalWindow alloc] initWithContentRect:frame styleMask:style | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:YES];
    window.workspace = workspace;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"YaaTerm.TabStrip"];
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    window.toolbar = toolbar;
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    window.releasedWhenClosed = NO;
    CGFloat titleHeight = NSHeight(window.frame)-NSHeight(window.contentLayoutRect);
    [window setContentSize:NSMakeSize(NSWidth(workspace.bounds),NSHeight(workspace.bounds)+titleHeight)];
    window.contentMinSize = NSMakeSize(300,180+titleHeight);
    WindowContent *content = [[WindowContent alloc] initWithWorkspace:workspace frame:(NSRect){NSZeroPoint,frame.size}];
    window.contentView = content;
    // Mutate the window only after AppKit has installed the content behind the native titlebar.
    [content updateBackdrop];
    [content installTitleAccessory];
    [window.contentView.superview layoutSubtreeIfNeeded];
    return window;
}

@implementation WindowContent {
    NSTitlebarAccessoryViewController *_accessory;
    BOOL _fullScreenTabs;
    NSView *_backdrop;
    NSView *_materialView;
    TerminalBackgroundMaterial _currentMaterial;
    CALayer *_picture;
    BOOL _enabledWorkspaceLayer;
}
- (instancetype)initWithWorkspace:(TabWorkspace *)workspace frame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Recent AppKit versions permit descendants to draw outside their bounds.
        // Terminal and settings fills must stop below the titlebar, including in full screen.
        self.clipsToBounds = YES;
        workspace.clipsToBounds = YES;
        _workspace = workspace;
        __weak WindowContent *owner = self;
        workspace.onSettingsVisibilityChange = ^{ [owner sizeMaterial]; };
        [self addSubview:workspace];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferenceChanged:) name:TerminalPreferenceChanged object:nil];
        [self updateBackdrop];
        self.needsLayout = YES;
    }
    return self;
}
- (void)preferenceChanged:(NSNotification *)note {
    NSString *key = note.object;
    if ([key isEqual:BackgroundMaterialKey]) [self updateMaterial];
    if ([key isEqual:BackgroundOpacity] || [key isEqual:BackgroundImageOpacity] ||
        [key isEqual:BackgroundImagePath] || [key isEqual:TerminalColorScheme]) [self updateBackdrop];
}
- (void)sizeMaterial {
    if (!_materialView) return;
    NSRect bounds = self.bounds;
    if (_workspace.showingSettings) {
        // The opaque settings page covers everything below the tab strip.
        CGFloat top = NSMaxY(_workspace.frame);
        bounds = NSMakeRect(NSMinX(bounds),top,NSWidth(bounds),MAX(0.,NSMaxY(bounds)-top));
    }
    _materialView.frame = bounds;
}
- (void)updateMaterial {
    TerminalBackgroundMaterial material = PlainBackground;
    if (_backdrop && self.window && !self.window.opaque)
        material = PreferredBackgroundMaterial();
    if (material == _currentMaterial) return;
    [_materialView removeFromSuperview];
    _materialView = nil;
    _currentMaterial = material;
    if (material != PlainBackground) {
        // Tint and wallpaper fade together above the material; glyphs are above both.
        _materialView = backgroundMaterialView(material,NSZeroRect);
        [self sizeMaterial];
        [self addSubview:_materialView positioned:NSWindowBelow relativeTo:_backdrop];
    }
}
- (void)updateBackdrop {
    CGFloat opacity = EffectiveBackgroundOpacity()/100.;
    const auto &colors = CurrentInterfacePalette();
    BOOL opaque = opacity == 1;
    NSWindow *window = self.window;
    if (window && window.opaque != opaque) window.opaque = opaque;
    NSColor *windowColor = opaque ? colors.background : NSColor.clearColor;
    if (![window.backgroundColor isEqual:windowColor]) window.backgroundColor = windowColor;
    CGImageRef image = VisibleWallpaperImage();
    if (opaque && !image) {
        [_backdrop removeFromSuperview]; _backdrop = nil; _picture = nil;
        if (_enabledWorkspaceLayer) { _workspace.wantsLayer = NO; _enabledWorkspaceLayer = NO; }
    } else {
        if (!_backdrop) {
            // Keep live terminal text in a separate backing store from the static image.
            _enabledWorkspaceLayer = !_workspace.wantsLayer;
            if (_enabledWorkspaceLayer) _workspace.wantsLayer = YES;
            _backdrop = [[NSView alloc] initWithFrame:self.bounds];
            [_backdrop setAccessibilityElement:NO];
            _backdrop.layer = [CALayer layer]; _backdrop.wantsLayer = YES;
            _backdrop.layer.masksToBounds = YES;
            _backdrop.layer.allowsGroupOpacity = YES;
            [self addSubview:_backdrop positioned:NSWindowBelow relativeTo:_workspace];
        }
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        _backdrop.layer.backgroundColor = colors.background.CGColor;
        _backdrop.layer.opacity = opacity;
        if (image) {
            if (!_picture) {
                _picture = [CALayer layer]; _picture.contentsGravity = kCAGravityResizeAspectFill;
                _picture.frame = _backdrop.bounds;
                _picture.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
                [_backdrop.layer addSublayer:_picture];
            }
            _picture.contents = (__bridge id)image;
            _picture.opacity = PreferredOpacity(BackgroundImageOpacity)/100.;
        } else {
            [_picture removeFromSuperlayer]; _picture = nil;
        }
        [CATransaction commit];
    }
    [self updateMaterial];
}
- (void)sizeTitleAccessory {
    NSWindow *window = self.window;
    if (!window || !_accessory) return;
    CGFloat width = NSWidth(self.bounds);
    // Reserve space even before AppKit has laid out the standard window buttons.
    CGFloat leading = 88;
    for (NSWindowButton type : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
        NSButton *button = [window standardWindowButton:type];
        if (button.window == window && !button.hiddenOrHasHiddenAncestor) {
            NSRect frame = [button convertRect:button.bounds toView:nil];
            leading = MAX(leading,ceil(NSMaxX(frame))+16);
        }
    }
    TabBar *bar = _workspace.tabBar;
    CGFloat available = MAX(0.,width-leading);
    if (available != NSWidth(bar.frame)) [bar setFrameSize:NSMakeSize(available,NSHeight(bar.frame))];
}
- (void)installTitleAccessory {
    if (!self.window || _accessory) return;
    _accessory = [NSTitlebarAccessoryViewController new];
    _accessory.layoutAttribute = NSLayoutAttributeRight;
    [_workspace.tabBar setFrameOrigin:NSZeroPoint];
    _accessory.view = _workspace.tabBar;
    [self sizeTitleAccessory];
    [self.window addTitlebarAccessoryViewController:_accessory];
}
- (void)removeTitleAccessory {
    if (!_accessory) return;
    NSUInteger index = [self.window.titlebarAccessoryViewControllers indexOfObjectIdenticalTo:_accessory];
    if (self.window && index != NSNotFound) [self.window removeTitlebarAccessoryViewControllerAtIndex:index];
    _accessory = nil;
}
- (void)setFullScreenTabBar:(BOOL)fullScreen {
    if (_fullScreenTabs == fullScreen) return;
    _fullScreenTabs = fullScreen;
    // Keep tabs accessible while macOS retracts the native titlebar in full screen.
    if (fullScreen) {
        [self removeTitleAccessory];
        [self addSubview:_workspace.tabBar];
    } else {
        [_workspace.tabBar removeFromSuperview];
        [self installTitleAccessory];
    }
    self.needsLayout = YES;
}
- (NSView *)hitTest:(NSPoint)point {
    // AppKit owns clicks in the native titlebar, including its draggable margins.
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (!_fullScreenTabs && local.y >= NSMaxY(_workspace.frame)) return nil;
    return [super hitTest:point];
}
- (void)layout {
    [super layout];
    NSRect body = self.bounds;
    NSRect title = NSZeroRect;
    if (self.window) {
        NSRect available = [self convertRect:self.window.contentLayoutRect fromView:nil];
        NSDivideRect(self.bounds,&title,&body,MAX(0.,NSMaxY(self.bounds)-NSMaxY(available)),NSMaxYEdge);
    }
    if (_fullScreenTabs) {
        NSRect available = body;
        NSDivideRect(available,&title,&body,_workspace.tabBar.intrinsicContentSize.height,NSMaxYEdge);
        _workspace.tabBar.frame = title;
    } else {
        [self sizeTitleAccessory];
    }
    _workspace.frame = body;
    _backdrop.frame = self.bounds;
    [self sizeMaterial];
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout = YES; }
- (void)viewWillMoveToWindow:(NSWindow *)window {
    if (self.window && self.window != window) [self removeTitleAccessory];
    [super viewWillMoveToWindow:window];
}
@end
