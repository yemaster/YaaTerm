#import "WindowContent.h"
#import "FindBar.h"
#include <string_view>
#include "TerminalRow.hpp"
#import "SettingsView.h"
#import "TaskNotices.h"
#import "Preferences.h"
#import "Palette.h"
#import "Wallpaper.h"
#import <QuartzCore/QuartzCore.h>
#include <cassert>
#include <chrono>
#include <sys/resource.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <libproc.h>
#include <unistd.h>

@interface TerminalView (FindTest) <NSTextFieldDelegate>
- (void)consume:(std::string_view)bytes;
- (const yaa::Row &)displayRow:(int)y;
- (NSRange)findColumnsInRow:(int)y;
@end

@interface TestKeyView : TerminalView
@property (copy) NSString *sent;
@end
@implementation TestKeyView
- (void)sendString:(NSString *)value { self.sent = value; }
@end

static void checkTerminalKeys() {
    TestKeyView *view = [[TestKeyView alloc] initWithFrame:NSMakeRect(0,0,320,120)];
    auto check = [&](unsigned short code,NSEventModifierFlags modifiers,NSString *expected) {
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
            timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
        [view keyDown:event]; assert([view.sent isEqual:expected]);
    };
    check(122,0,@"\033OP"); check(111,NSEventModifierFlagShift,@"\033[24;2~");
    check(124,NSEventModifierFlagControl,@"\033[1;5C");
    [view consume:"\033[?1h"]; check(115,0,@"\033OH");
}

@interface MotionTestBar : TabBar
@property BOOL motionEnabled;
@end

@implementation MotionTestBar
- (BOOL)allowsSelectionMotion { return self.motionEnabled; }
@end

static void checkSelectionMotion() {
    MotionTestBar *bar = [[MotionTestBar alloc] initWithFrame:NSMakeRect(0,0,640,40)];
    bar.motionEnabled = YES;
    for (NSString *title in @[@"one",@"two",@"three"]) [bar insertTitle:title atIndex:0];
    [bar selectIndex:0]; [bar layoutSubtreeIfNeeded];
    NSView *highlight = [bar valueForKey:@"highlight"];
    NSArray<NSButton *> *items = [bar valueForKey:@"items"];
    assert(highlight.layer.cornerRadius == 7);
    assert(!highlight.hidden && ![highlight.layer animationForKey:@"selection"]);
    assert(NSEqualRects(highlight.frame,items[0].frame));
    [bar selectIndex:2]; [bar layoutSubtreeIfNeeded];
    CABasicAnimation *slide = (CABasicAnimation *)[highlight.layer animationForKey:@"selection"];
    assert([slide.keyPath isEqualToString:@"transform.translation.x"] && slide.duration==.14);
    assert(NSEqualRects(highlight.frame,items[2].frame));
    assert(items[0].state==NSControlStateValueOff && items[2].state==NSControlStateValueOn);
    [bar selectIndex:1]; [bar layoutSubtreeIfNeeded];
    assert(highlight.layer.animationKeys.count == 1);
    bar.motionEnabled = NO;
    [bar selectIndex:0]; [bar layoutSubtreeIfNeeded];
    assert(![highlight.layer animationForKey:@"selection"]);
    assert(NSEqualRects(highlight.frame,items[0].frame));
    NSRect slot = items[1].frame;
    assert([bar insertionSlotAtX:NSMinX(slot)+1] == 1);
    assert([bar insertionSlotAtX:NSMaxX(slot)-1] == 2);
    [bar indicateSlot:1];
    NSView *mark = [bar valueForKey:@"dropMark"];
    assert(NSMinX(slot)-NSMaxX(items[0].frame) >= 6);
    assert(NSMidX(mark.frame) == (NSMinX(slot)+NSMaxX(items[0].frame))/2);
    NSButton *add = [bar valueForKey:@"add"];
    assert(NSMinX(add.frame)-NSMaxX(items.lastObject.frame) >= 8);
    assert(NSMinY(mark.frame) < NSMinY(slot) && NSMaxY(mark.frame) > NSMaxY(slot));
    [bar indicateSlot:NSNotFound];
    assert(!mark.superview);
}

static void waitForTitle(TerminalView *pane, NSString *title) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    while (![pane.sessionTitle isEqualToString:title] && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    assert([pane.sessionTitle isEqualToString:title]);
}

static uint64_t footprint() {
    rusage_info_v0 info{};
    if (proc_pid_rusage(getpid(),RUSAGE_INFO_V0,(rusage_info_t *)&info) != 0) return 0;
    return info.ri_phys_footprint;
}

static void waitUntil(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    assert(done());
}
static void exitShell(TerminalView *pane) {
    [pane insertText:@"exit\r" replacementRange:NSMakeRange(NSNotFound,0)];
}
static void checkSessionExit() {
    TabWorkspace *w = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,800,500)];
    __block NSInteger empty = 0;
    w.onEmpty = ^{ ++empty; };
    [w addTab]; TerminalView *left = w.focused;
    [w splitVertical:YES]; TerminalView *right = w.focused;
    [w splitVertical:NO]; TerminalView *bottom = w.focused;
    [w addTab]; TerminalView *front = w.focused;
    exitShell(right);
    waitUntil(^BOOL{ return !right.superview; });
    assert(w.count==2 && w.focused==front);
    [w selectIndex:0]; assert(w.focused==bottom && [left isDescendantOf:w]);
    exitShell(bottom);
    waitUntil(^BOOL{ return w.focused==left; });
    [w selectIndex:1]; exitShell(left);
    waitUntil(^BOOL{ return w.count==1; });
    assert(w.focused==front && !empty);
    [front insertText:@"\004" replacementRange:NSMakeRange(NSNotFound,0)];
    waitUntil(^BOOL{ return empty==1; });
    assert(!w.count && !w.focused);
}

static NSControl *controlForKey(NSView *page, NSString *key) {
    for (NSView *view in page.subviews) if ([view.identifier isEqual:key]) return (NSControl *)view;
    return nil;
}
static void applyControl(NSControl *control) {
    id target = control.target;
    SEL action = control.action;
    assert(target && [target respondsToSelector:action]);
    auto invoke = (void (*)(id,SEL,id))[target methodForSelector:action];
    invoke(target,action,control);
}
static void checkSettings() {
    // This standalone test binary uses its own defaults domain.
    TabWorkspace *w = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,800,500)];
    [w addTab];
    __weak SettingsView *released = nil;
    @autoreleasepool {
        SettingsView *view = [[SettingsView alloc] initWithFrame:NSMakeRect(0,0,514,222)];
        released = view;
        NSButton *general = (NSButton *)controlForKey(view,@"通用");
        NSButton *appearance = (NSButton *)controlForKey(view,@"外观");
        NSView *page = [view valueForKey:@"page"];
        assert(general && appearance && [appearance.accessibilityValue boolValue]);
        applyControl(general);
        NSSwitch *toggle = (NSSwitch *)controlForKey(page,CloseEndedSessions);
        assert(toggle && toggle.state==NSControlStateValueOn);
        toggle.state = NSControlStateValueOff;
        applyControl(toggle);
        exitShell(w.focused); waitForTitle(w.focused,@"会话已结束");
        assert(w.count==1);
        toggle.state = NSControlStateValueOn;
        applyControl(toggle);

        [view layoutSubtreeIfNeeded];
        assert(NSMaxY(controlForKey(view,@"AI 服务").frame) <= NSHeight(view.bounds));
        applyControl(controlForKey(view,@"终端"));
        for (NSString *key in @[PrettyTables,OpenWebLinks,RevealFileLinks]) {
            NSSwitch *feature = (NSSwitch *)controlForKey(page,key);
            assert(feature && feature.state==NSControlStateValueOn);
            feature.state = NSControlStateValueOff; applyControl(feature);
            assert(![TerminalPreferences() boolForKey:key]);
            feature.state = NSControlStateValueOn; applyControl(feature);
        }
        applyControl(controlForKey(view,@"性能"));
        NSPopUpButton *limit = (NSPopUpButton *)controlForKey(page,ScrollbackLines);
        assert(limit && limit.selectedTag==1500);
        [limit selectItemWithTag:0]; applyControl(limit);
        assert(PreferredScrollbackLines()==0);
        [limit selectItemWithTag:1500]; applyControl(limit);
        applyControl(controlForKey(view,@"性能"));
        NSSwitch *sleep = (NSSwitch *)controlForKey(page,SleepIdleTabs);
        assert(sleep);
        sleep.state = NSControlStateValueOn; applyControl(sleep);
        assert([TerminalPreferences() boolForKey:SleepIdleTabs]);
        sleep.state = NSControlStateValueOff; applyControl(sleep);
        applyControl(appearance);
        assert(!controlForKey(page,CloseEndedSessions));
        assert([appearance.accessibilityValue boolValue] && ![general.accessibilityValue boolValue]);
        assert(general.focusRingType == NSFocusRingTypeNone && appearance.focusRingType == NSFocusRingTypeNone);
        NSSegmentedControl *mode = (NSSegmentedControl *)controlForKey(page,AppearanceModeKey);
        NSView *light = controlForKey(page,LightSchemeKey), *dark = controlForKey(page,DarkSchemeKey);
        NSDictionary *groups = [view valueForKey:@"groupHeadings"];
        NSTextField *theme = groups[AppearanceModeKey], *background = groups[BackgroundMaterialKey];
        assert(groups.count == 2 && [theme.stringValue isEqual:@"主题"] && [background.stringValue isEqual:@"背景"]);
        auto checkGroups = [&] {
            NSTextField *heading = [view valueForKey:@"heading"];
            NSArray<NSTextField *> *labels = [view valueForKey:@"labels"];
            assert(NSMinX(theme.frame)==NSMinX(heading.frame) && NSMinX(background.frame)==NSMinX(heading.frame));
            assert(NSMaxY(heading.frame)<NSMinY(theme.frame) && NSMaxY(theme.frame)<NSMinY(labels[0].frame));
            assert(NSMaxY(dark.frame)<NSMinY(background.frame) && NSMaxY(background.frame)<NSMinY(labels[6].frame));
            assert([labels[6].stringValue isEqual:@"背景材质"]);
            assert(NSContainsRect(page.bounds,controlForKey(page,BackgroundImageOpacity).frame));
        };
        checkGroups();
        assert(light.subviews.count == 6 && dark.subviews.count == 6 && mode.segmentCount == 3);
        for (NSInteger i=0; i<SchemeCount; ++i) {
            NSView *group = SchemeIsLight(i) ? light : dark;
            NSButton *card = (NSButton *)[group viewWithTag:i];
            assert([card.title isEqual:SchemeName(i)] && NSContainsRect(group.bounds,card.frame));
            assert(card.frame.size.width >= 138 && card.frame.size.height >= 44);
        }
        // At this width the third card wraps and the next group remains reachable by scrolling.
        NSScrollView *scroll = page.enclosingScrollView;
        assert(scroll && NSHeight(page.frame) > NSHeight(scroll.contentView.bounds));
        assert(NSMinY(light.subviews[2].frame) > NSMinY(light.subviews[0].frame));
        NSEvent *arrow = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:0 windowNumber:0 context:nil characters:@"\uf701" charactersIgnoringModifiers:@"\uf701"
            isARepeat:NO keyCode:125];
        [(NSButton *)light.subviews[0] keyDown:arrow];
        assert(PreferredSchemeForStyle(YES) == SolarizedLight);
        NSView *fontRow = controlForKey(page,TerminalFontSize);
        NSView *lastCard = dark.subviews.lastObject;
        [lastCard scrollRectToVisible:lastCard.bounds];
        assert(NSContainsRect(page.visibleRect,[page convertRect:lastCard.bounds fromView:lastCard]));
        assert(NSMinX(mode.frame) == NSMinX(light.frame) && NSMinX(fontRow.frame) == NSMinX(light.frame));
        view.frame = NSMakeRect(0,0,920,526); [view layoutSubtreeIfNeeded];
        checkGroups();
        assert(NSMinY(light.subviews[2].frame) == NSMinY(light.subviews[0].frame));
        assert(NSMaxX(light.subviews[0].frame) < NSMinX(light.subviews[1].frame));
        assert(NSMaxX(mode.frame) == NSMaxX(fontRow.frame) && NSMaxX(mode.frame) == NSMaxX(dark.frame));
        NSTextField *heading = [view valueForKey:@"heading"];
        NSArray<NSTextField *> *labels = [view valueForKey:@"labels"];
        assert(labels.count == 10 && [labels.firstObject.stringValue isEqual:@"外观模式"]);
        assert(NSMaxY(heading.frame) < NSMinY(labels.firstObject.frame));
        assert(NSMinX(labels.firstObject.frame) > NSMinX(heading.frame));
        for (NSTextField *label in labels) assert(NSMinX(label.frame) == NSMinX(labels.firstObject.frame));
        NSView *opacity = controlForKey(page,BackgroundOpacity);
        NSView *imageOpacity = controlForKey(page,BackgroundImageOpacity);
        assert(opacity && imageOpacity && controlForKey(page,BackgroundImagePath));
        NSSlider *slider = [opacity valueForKey:@"slider"];
        assert(slider.enabled && !((NSSlider *)[imageOpacity valueForKey:@"slider"]).enabled);
        slider.integerValue = 75; applyControl(slider);
        assert(PreferredOpacity(BackgroundOpacity)==75 && !w.focused.isOpaque);
        assert([slider.accessibilityValueDescription isEqual:@"75%"]);
        SetTerminalPreference(BackgroundOpacity,100);
        SettingsView *other = [[SettingsView alloc] initWithFrame:view.bounds];
        NSSegmentedControl *material = (NSSegmentedControl *)controlForKey(page,BackgroundMaterialKey);
        NSSegmentedControl *otherMaterial = (NSSegmentedControl *)controlForKey([other valueForKey:@"page"],BackgroundMaterialKey);
        assert(material.segmentCount == (SupportsLiquidGlass() ? 3 : 2));
        for (NSInteger i = material.segmentCount-1; i >= 0; --i) {
            material.selectedSegment = i; applyControl(material);
            assert(PreferredBackgroundMaterial()==i && otherMaterial.selectedSegment==i);
            assert([[otherMaterial labelForSegment:i] hasPrefix:@"✓ "]);
        }
        NSView *otherLight = controlForKey([other valueForKey:@"page"],LightSchemeKey);
        mode.selectedSegment = FollowSystem; applyControl(mode);
        UpdateSystemAppearance([NSAppearance appearanceNamed:NSAppearanceNameAqua]);
        applyControl((NSButton *)[light viewWithTag:OneHalfLight]);
        applyControl((NSButton *)[dark viewWithTag:SolarizedDark]);
        assert([((NSButton *)[otherLight viewWithTag:OneHalfLight]).accessibilityValue boolValue]);
        assert(![((NSButton *)[otherLight viewWithTag:CatppuccinLatte]).accessibilityValue boolValue]);
        assert(TerminalBackground() == SchemeInk(OneHalfLight,SchemeBackground));
        UpdateSystemAppearance([NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]);
        assert(PreferredColorScheme() == SolarizedDark);
        mode.selectedSegment = AlwaysLight; applyControl(mode);
        assert(PreferredColorScheme() == OneHalfLight);
        mode.selectedSegment = AlwaysDark; applyControl(mode);
        UpdateSystemAppearance([NSAppearance appearanceNamed:NSAppearanceNameAqua]);
        assert(PreferredColorScheme() == SolarizedDark);
        mode.selectedSegment = FollowSystem; applyControl(mode);
        NSSegmentedControl *otherMode = (NSSegmentedControl *)controlForKey([other valueForKey:@"page"],AppearanceModeKey);
        TabBar *bar = w.tabBar;
        NSButton *gear = [bar valueForKey:@"settings"];
        for (NSInteger i=GitHubLight; i<SchemeCount; ++i) {
            BOOL isLight = SchemeIsLight(i);
            mode.selectedSegment = isLight ? AlwaysLight : AlwaysDark; applyControl(mode);
            NSButton *card = (NSButton *)[(isLight ? light : dark) viewWithTag:i];
            applyControl(card);
            assert(PreferredColorScheme() == i && [card.accessibilityValue boolValue]);
            assert(heading.textColor == SchemeInk(i,SchemeText));
            assert(theme.textColor == CurrentInterfacePalette().secondaryText && background.textColor == theme.textColor);
            assert([[(isLight ? light : dark) accessibilityLabel] containsString:@"使用中"]);
            assert(![[(isLight ? dark : light) accessibilityLabel] containsString:@"使用中"]);
            assert([[otherMode labelForSegment:otherMode.selectedSegment] hasPrefix:@"✓ "]);
            assert(![[otherMode labelForSegment:(otherMode.selectedSegment+1)%3] hasPrefix:@"✓ "]);
            assert(gear.contentTintColor == CurrentInterfacePalette().secondaryText);
        }
        mode.selectedSegment = FollowSystem; applyControl(mode);
        applyControl((NSButton *)[light viewWithTag:CatppuccinLatte]);
        applyControl((NSButton *)[dark viewWithTag:CatppuccinMocha]);
        NSPopUpButton *font = (NSPopUpButton *)controlForKey(page,TerminalFontSize);
        assert(font && font.selectedTag==14);
        [font selectItemWithTag:18]; applyControl(font);
        assert([[w.focused valueForKey:@"fontSize"] integerValue]==18);
        assert(((NSButton *)light.subviews[0]).font.pointSize == 18);
        NSPopUpButton *family = (NSPopUpButton *)controlForKey(page,TerminalFontFamily);
        NSPopUpButton *otherFamily = (NSPopUpButton *)controlForKey([other valueForKey:@"page"],TerminalFontFamily);
        assert(family.numberOfItems==1 && [family.selectedItem.representedObject isEqual:BundledFontFamily]);
        [NSNotificationCenter.defaultCenter postNotificationName:NSPopUpButtonWillPopUpNotification object:family];
        NSInteger menlo = [family indexOfItemWithRepresentedObject:@"Menlo"];
        assert(menlo >= 0 && [family indexOfItemWithRepresentedObject:@"Helvetica"] < 0);
        [w.focused adjustFont:1];
        [family selectItemAtIndex:menlo]; applyControl(family);
        NSFont *liveFont = [w.focused valueForKey:@"regular"];
        assert([liveFont.familyName isEqual:@"Menlo"] && liveFont.pointSize==19);
        assert([otherFamily.selectedItem.representedObject isEqual:@"Menlo"] && [((NSButton *)light.subviews[0]).font.familyName isEqual:@"Menlo"]);
        assert([PreferredTerminalFont(18,YES).fontName isEqual:@"Menlo-Bold"]);
        [w addTab]; assert([[w.focused valueForKey:@"fontSize"] integerValue]==18);
        assert([[[w.focused valueForKey:@"regular"] familyName] isEqual:@"Menlo"]);
        [family selectItemAtIndex:[family indexOfItemWithRepresentedObject:SystemMonospaceFamily]]; applyControl(family);
        assert([[w.focused valueForKey:@"regular"] isEqual:[NSFont monospacedSystemFontOfSize:18 weight:NSFontWeightLight]]);
        NSPopUpButton *weight = (NSPopUpButton *)controlForKey(page,TerminalFontWeight);
        NSPopUpButton *otherWeight = (NSPopUpButton *)controlForKey([other valueForKey:@"page"],TerminalFontWeight);
        assert(weight.numberOfItems==10 && weight.selectedTag==0);
        [w.focused adjustFont:1];
        for (int value : {400,500}) {
            assert([weight selectItemWithTag:value]); applyControl(weight);
            assert(PreferredFontWeight()==value && otherWeight.selectedTag==value);
            assert([[w.focused valueForKey:@"regular"] isEqual:PreferredTerminalFont(19,NO)]);
            assert([((NSButton *)light.subviews[0]).font isEqual:PreferredTerminalFont(18,NO)]);
        }
        [w addTab]; assert([[w.focused valueForKey:@"regular"] isEqual:PreferredTerminalFont(18,NO)]);
        [weight selectItemWithTag:0]; applyControl(weight);
        [family selectItemAtIndex:[family indexOfItemWithRepresentedObject:BundledFontFamily]]; applyControl(family);
        [font selectItemWithTag:14]; applyControl(font);
        applyControl(general);
        assert(!theme.superview && !background.superview);
        assert(!controlForKey(page,TerminalFontSize) && controlForKey(page,CloseEndedSessions));
        NSSearchField *search = [view valueForKey:@"search"];
        search.stringValue = @"字体"; applyControl(search);
        applyControl(controlForKey(page,TerminalFontFamily));
        assert(!search.stringValue.length && [controlForKey(page,TerminalFontFamily) isKindOfClass:NSPopUpButton.class]);
        search.stringValue = @"毛玻璃"; applyControl(search);
        applyControl(controlForKey(page,BackgroundMaterialKey));
        assert(!search.stringValue.length && controlForKey(page,BackgroundMaterialKey) && NSMinY(page.visibleRect)>0);
        search.stringValue = @"API"; applyControl(search);
        assert(controlForKey(page,@"LLMKey") && ![view valueForKey:@"apiForm"]);
        search.stringValue = @"xyz123"; applyControl(search);
        assert([page valueForKey:@"emptyMessage"] && !controlForKey(page,@"LLMKey"));
        search.stringValue = @"背景"; applyControl(search);
        NSControl *result = controlForKey(page,BackgroundOpacity);
        assert(result && ![general.accessibilityValue boolValue]);
        applyControl(result);
        assert(!search.stringValue.length && [appearance.accessibilityValue boolValue]);
        assert([controlForKey(page,BackgroundOpacity) isKindOfClass:NSClassFromString(@"OpacityControl")]);
        assert(NSMinY(page.visibleRect)>0);
    }
    assert(!released);
    [w stopAll];
}

// A control can still receive clicks when a sibling has painted over its pixels.
// Render the whole frame, then compare each native circle with the adjacent titlebar.
static void checkTrafficLightPixels(NSWindow *window) {
    @autoreleasepool {
        NSView *frameView = window.contentView.superview;
        [frameView layoutSubtreeIfNeeded];
        NSBitmapImageRep *bitmap = [frameView bitmapImageRepForCachingDisplayInRect:frameView.bounds];
        [frameView cacheDisplayInRect:frameView.bounds toBitmapImageRep:bitmap];
        CGFloat sx = bitmap.pixelsWide / NSWidth(frameView.bounds);
        CGFloat sy = bitmap.pixelsHigh / NSHeight(frameView.bounds);
        // Test blank pixels on both ends of the strip, including the traffic-light gutter.
        NSButton *zoom = [window standardWindowButton:NSWindowZoomButton];
        NSRect zoomRect = [zoom convertRect:zoom.bounds toView:nil];
        NSInteger stripY = floor((NSHeight(frameView.bounds)-NSMidY(zoomRect))*sy);
        for (CGFloat x : {NSMaxX(zoomRect)+3, NSWidth(frameView.bounds)-3}) {
            NSColor *pixel = [bitmap colorAtX:floor(x*sx) y:stripY];
            if (PreferredBackgroundMaterial() == PlainBackground) {
                CGFloat expected = EffectiveBackgroundOpacity()/100.;
                if (fabs(pixel.alphaComponent-expected) >= .025)
                    fprintf(stderr,"Tab strip at x=%.1f: alpha %.3f, expected %.3f\n",x,pixel.alphaComponent,expected);
                assert(fabs(pixel.alphaComponent-expected) < .025);
            }
        }
        WindowContent *content = (WindowContent *)window.contentView;
        if (PreferredBackgroundMaterial() == PlainBackground && content.workspace.focused) {
            NSColor *body = [bitmap colorAtX:floor((NSWidth(frameView.bounds)-8)*sx) y:floor((NSHeight(frameView.bounds)-12)*sy)];
            assert(fabs(body.alphaComponent-EffectiveBackgroundOpacity()/100.) < .025);
        }
        for (NSWindowButton type : {NSWindowCloseButton,NSWindowMiniaturizeButton,NSWindowZoomButton}) {
            NSButton *button = [window standardWindowButton:type];
            NSRect r = [button convertRect:button.bounds toView:nil];
            NSInteger y = floor((NSHeight(frameView.bounds)-NSMidY(r))*sy);
            NSColorSpace *space = NSColorSpace.sRGBColorSpace;
            NSColor *background = [[bitmap colorAtX:floor((NSMaxX(r)+2)*sx) y:y] colorUsingColorSpace:space];
            CGFloat contrast = 0;
            for (NSInteger x = ceil(NSMinX(r)*sx); x < floor(NSMaxX(r)*sx); ++x) {
                NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:space];
                contrast = std::max({contrast,fabs(color.redComponent-background.redComponent),
                    fabs(color.greenComponent-background.greenComponent),fabs(color.blueComponent-background.blueComponent),
                    fabs(color.alphaComponent-background.alphaComponent)});
            }
            assert(contrast > .02);
        }
    }
}

@interface FastSleepWorkspace : TabWorkspace
@end
@implementation FastSleepWorkspace
- (NSTimeInterval)idleSleepDelay { return .14; }
@end

static void checkSleepingTabs() {
    SetTerminalPreference(SleepIdleTabs,0);
    FastSleepWorkspace *work = [[FastSleepWorkspace alloc] initWithFrame:NSMakeRect(0,0,720,380)];
    NSWindow * __attribute__((objc_precise_lifetime)) window = CreateTerminalWindow(work);
    [work addTab];
    TerminalView *left = work.focused;
    [work splitVertical:YES];
    TerminalView *right = work.focused;
    auto send = [](TerminalView *pane, NSString *command) {
        [pane insertText:command replacementRange:NSMakeRange(NSNotFound,0)];
    };
    NSString *fifo = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert(mkfifo(fifo.fileSystemRepresentation,0600)==0);
    send(left,[NSString stringWithFormat:@"token=kept; (read cue < '%@'; printf '\\033]2;%%s-woke\\007' \"$token\") & printf '\\033]2;left-ready\\007'\r",fifo]);
    waitForTitle(left,@"left-ready");
    send(right,@"sh -c 'printf \"\\033]2;busy\\007\"; read answer'; printf '\\033]2;idle\\007'\r");
    waitForTitle(right,@"busy");
    [work addTab];
    id tab = [work tabAtIndex:0];
    auto sleeping = ^BOOL{ return [[tab valueForKey:@"sleeping"] boolValue]; };
    assert(![work valueForKey:@"sleepTimer"] && !sleeping());
    SetTerminalPreference(SleepIdleTabs,1);
    assert([work valueForKey:@"sleepTimer"] && !right.canSleep);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.35]];
    assert(!sleeping() && !work.focused.idleSince);
    send(right,@"done\r"); waitForTitle(right,@"idle");
    waitUntil(sleeping);
    assert(![work valueForKey:@"sleepTimer"] && [[tab valueForKey:@"title"] hasSuffix:@" · 休眠"]);
    SetTerminalFontFamily(@"Menlo");
    assert(sleeping());
    // Output arrives from an already-running background job with no input to its PTY.
    int fd = open(fifo.fileSystemRepresentation,O_WRONLY | O_NONBLOCK);
    assert(fd >= 0 && write(fd,"wake\n",5)==5); close(fd);
    unlink(fifo.fileSystemRepresentation);
    waitForTitle(left,@"kept-woke"); assert(!sleeping());
    assert([[[left valueForKey:@"regular"] familyName] isEqual:@"Menlo"] && [[[right valueForKey:@"regular"] familyName] isEqual:@"Menlo"]);
    SetTerminalFontFamily(BundledFontFamily);
    waitUntil(sleeping);
    SetTerminalPreference(SleepIdleTabs,0);
    assert(!sleeping() && !left.idleSince && !right.idleSince);
    SetTerminalPreference(SleepIdleTabs,1);
    waitUntil(sleeping);
    [work selectIndex:0];
    assert(!sleeping() && work.focused == right && !right.idleSince);
    send(left,@"printf '\\033]2;%s-selected\\007' \"$token\"\r");
    waitForTitle(left,@"kept-selected");
    [work showSettings]; waitUntil(sleeping);
    FastSleepWorkspace *other = [[FastSleepWorkspace alloc] initWithFrame:work.bounds];
    assert([work transferTab:tab to:other atSlot:0] && !sleeping() && other.focused==right);
    send(left,@"printf '\\033]2;%s-moved\\007' \"$token\"\r");
    waitForTitle(left,@"kept-moved");
    SetTerminalPreference(SleepIdleTabs,0);
    [other stopAll]; [work stopAll];
    puts("Idle sleep: whole-tab foreground exclusion, PTY output wake, switch, disable, settings and transfer OK");
}

static void checkVimWheel() {
    NSRect frame = NSMakeRect(0,0,640,240);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    TerminalView *pane = [[TerminalView alloc] initWithFrame:frame];
    window.contentView = pane;
    [pane start];
    auto send = [&](NSString *s) { [pane insertText:s replacementRange:NSMakeRange(NSNotFound,0)]; };
    auto firstLine = ^NSInteger{
        const auto &row = [pane displayRow:0];
        NSInteger line = 0;
        for (const auto &cell : row) {
            if (cell.ch < U'0' || cell.ch > U'9') break;
            line = line*10+cell.ch-U'0';
        }
        return line;
    };
    auto wheel = [&](CGScrollEventUnit units, int delta) {
        CGEventRef cg = CGEventCreateScrollWheelEvent(nullptr,units,1,delta);
        [pane scrollWheel:[NSEvent eventWithCGEvent:cg]];
        CFRelease(cg);
    };
    send(@"/usr/bin/vim -Nu NONE -n -i NONE -c 'call setline(1,range(1001,1180))' -c 'set mouse= scrolloff=0'; printf '\\033]2;wheel-exited\\007'\r");
    waitUntil(^BOOL{ return firstLine()==1001; });
    assert(!pane.canSleep);
    wheel(kCGScrollEventUnitLine,-12);
    waitUntil(^BOOL{ return firstLine()>1001; });
    wheel(kCGScrollEventUnitLine,12);
    waitUntil(^BOOL{ return firstLine()==1001; });
    send(@":set ttymouse=sgr mouse=a title titlestring=wheel-sgr\r");
    waitForTitle(pane,@"wheel-sgr");
    wheel(kCGScrollEventUnitLine,-1);
    waitUntil(^BOOL{ return firstLine()>1001; }); // A single arrow would only move the cursor.
    wheel(kCGScrollEventUnitLine,1);
    waitUntil(^BOOL{ return firstLine()==1001; });
    for (int i=0; i<4; ++i) wheel(kCGScrollEventUnitPixel,-6);
    waitUntil(^BOOL{ return firstLine()>1001; });
    send(@"gg:set titlestring=click-ready\r"); waitForTitle(pane,@"click-ready");
    CGFloat lh = [[pane valueForKey:@"lh"] doubleValue];
    NSPoint point = [pane convertPoint:NSMakePoint(26,12+3.5*lh) toView:nil];
    for (NSNumber *type in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]) {
        NSEvent *event = [NSEvent mouseEventWithType:(NSEventType)type.integerValue location:point modifierFlags:0 timestamp:0
                                        windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        if (event.type==NSEventTypeLeftMouseDown) [pane mouseDown:event]; else [pane mouseUp:event];
    }
    send(@":let &titlestring='clicked-'.line('.')\r"); waitForTitle(pane,@"clicked-4");
    send(@":q!\r"); waitForTitle(pane,@"wheel-exited");
    send(@"seq 1 90; printf '\\033]2;wheel-history\\007'\r");
    waitForTitle(pane,@"wheel-history");
    wheel(kCGScrollEventUnitLine,3);
    assert([[pane valueForKey:@"offset"] integerValue]>0);
    wheel(kCGScrollEventUnitLine,-24);
    assert(![[pane valueForKey:@"offset"] integerValue]);
    [pane stop];
    puts("Actual scrollWheel events: Vim cursor fallback, SGR mouse and precise pixel scroll and return to shell history OK");
}

static void checkTabGroups() {
    TabWorkspace *w = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,1100,400)];
    NSWindow * __attribute__((objc_precise_lifetime)) window = CreateTerminalWindow(w);
    [w addTab]; TerminalTab *a = [w tabAtIndex:0];
    TerminalView *left = w.focused;
    [w splitVertical:YES]; TerminalView *right = w.focused;
    [right insertText:@"keep=grouped; printf '\\033]2;group-ready\\007'\r" replacementRange:NSMakeRange(NSNotFound,0)];
    waitForTitle(right,@"group-ready");
    [w addTab]; TerminalTab *b = [w tabAtIndex:1];
    [w addTab]; TerminalTab *c = [w tabAtIndex:2];
    [w addTab]; TerminalTab *d = [w tabAtIndex:3];
    TabGroup *other = [w createGroupForTab:d name:@"服务"];
    TabBar *bar = w.tabBar;
    auto itemFor = [&](NSInteger tag)->NSButton * {
        [bar layoutSubtreeIfNeeded];
        for (NSButton *button in [bar valueForKey:@"items"]) if (button.tag==tag) return button;
        return nil;
    };
    auto action = [](NSMenuItem *item) { assert(item && [NSApp sendAction:item.action to:item.target from:item]); };
    NSEvent *contextClick = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:NSZeroPoint modifierFlags:0
        timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    auto submitName = [&](NSMenuItem *menuItem, NSString *name) {
        action(menuItem);
        NSTextField *field = [bar valueForKey:@"nameField"];
        NSTextView *editor = (NSTextView *)field.currentEditor;
        assert(editor && window.firstResponder==editor);
        [editor insertText:name replacementRange:NSMakeRange(0,editor.string.length)];
        NSEvent *enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [editor interpretKeyEvents:@[enter]];
        assert(![bar valueForKey:@"nameField"]);
    };
    submitName([[itemFor(0) menuForEvent:contextClick] itemWithTitle:@"新建分组…"],@"临时");
    waitUntil(^BOOL{ return [w groupAtIndex:0] != nil; });
    TabGroup *g = [w groupAtIndex:0];
    submitName([[itemFor(~0L) menuForEvent:contextClick] itemWithTitle:@"重命名分组…"],@"项目");
    waitUntil(^BOOL{ return [g.name isEqual:@"项目"]; });
    NSMenu *tabMenu = [itemFor([w indexOfTab:c]) menuForEvent:contextClick];
    action([[tabMenu itemWithTitle:@"移入分组"].submenu itemWithTitle:g.name]);
    assert(NSEqualRanges([w rangeOfGroup:g],NSMakeRange(0,2)) && [w tabAtIndex:1]==c && [w tabAtIndex:2]==b);
    [w selectIndex:0];
    NSButton *header = itemFor(~0L);
    assert(header && [header.title isEqual:@"项目"]);
    action([[[header menuForEvent:contextClick] itemWithTitle:@"分组颜色"].submenu itemWithTitle:@"绿色"]);
    assert(g.colorIndex==2);
    [header performClick:nil]; [bar layoutSubtreeIfNeeded];
    assert(g.collapsed && w.focused==right && !itemFor(0) && !itemFor(1));
    assert(itemFor(~0L).state == NSControlStateValueOn && itemFor(~0L).accessibilityExpanded==NO);
    assert([bar insertionSlotAtX:NSMaxX(header.frame)-1]==2);
    [right insertText:@"printf '\\033]2;%s-live\\007' \"$keep\"\r" replacementRange:NSMakeRange(NSNotFound,0)];
    waitForTitle(right,@"grouped-live");
    [w selectIndex:[w indexOfTab:b]]; left.revealTask(left);
    assert(!g.collapsed && w.focused==left && w.count==4);
    [w toggleGroup:g]; [w addTab];
    assert(w.count==5 && ![w groupAtIndex:w.selectedIndex] && NSEqualRanges([w rangeOfGroup:g],NSMakeRange(0,2)));
    [w addTabInGroup:g];
    assert(!g.collapsed && [w groupAtIndex:w.selectedIndex]==g && [w rangeOfGroup:g].length==3);
    [w putTab:c inGroup:nil];
    assert([w rangeOfGroup:g].length==2 && [w indexOfTab:c]==2);
    [w putTab:c inGroup:other]; assert([w rangeOfGroup:other].length==2);
    TabWorkspace *dest = [[TabWorkspace alloc] initWithFrame:w.bounds];
    [dest addTab]; TabGroup *target = [dest createGroupForTab:[dest tabAtIndex:0] name:@"接收"];
    [dest toggleGroup:target];
    assert([w transferTab:a to:dest atSlot:0 group:target]);
    assert(!target.collapsed && dest.focused==left && [dest groupAtIndex:0]==target);
    [right insertText:@"printf '\\033]2;%s-transferred\\007' \"$keep\"\r" replacementRange:NSMakeRange(NSNotFound,0)];
    waitForTitle(right,@"grouped-transferred");
    [dest ungroup:target]; assert(!dest.groups.count && dest.count==2);
    [w closeTabAt:[w rangeOfGroup:g].location]; assert(![w rangeOfGroup:g].length);
    [w ungroup:other]; assert(!w.groups.count);
    [w stopAll]; [dest stopAll];
    puts("Tab groups: native menus, contiguous membership, folded active PTY, split reveal, group creation/removal and cross-window drop OK");
}

static void checkFind() {
    NSRect bounds = NSMakeRect(0,0,580,240);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:bounds styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    TerminalView *pane = [[TerminalView alloc] initWithFrame:bounds];
    window.contentView = pane;
    [pane start];
    [pane insertText:@"printf '\\033[2J\\033[H\\033[3J'; awk 'BEGIN { print \"early: TOKEN-041\"; for(i=0;i<2100;i++) print \"background output\"; printf \"latest: TOKEN-041\" }'; printf '\\033]2;search-ready\\007'\r"
        replacementRange:NSMakeRange(NSNotFound,0)];
    waitForTitle(pane,@"search-ready");
    [window makeFirstResponder:pane];
    NSEvent *ctrlF = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagControl
        timestamp:0 windowNumber:0 context:nil characters:@"\006" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
    [pane keyDown:ctrlF];
    FindBar *bar = [pane valueForKey:@"findBar"];
    assert(bar && (bar.field.currentEditor == window.firstResponder || window.firstResponder == bar.field));
    auto query = [&](NSString *s) {
        bar.field.stringValue = s;
        [pane controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:bar.field]];
    };
    auto status = ^NSString *{ return ((NSTextField *)[bar valueForKey:@"status"]).stringValue; };
    int rows = MAX(1,(int)((NSHeight(pane.bounds)-24)/[[pane valueForKey:@"lh"] doubleValue]));
    auto visibleHit = ^BOOL{
        for (int i=0; i<rows; ++i) if ([pane findColumnsInRow:i].length) return YES;
        return NO;
    };
    query(@"discarded query"); query(@"ToKeN-041");
    waitUntil(visibleHit);
    assert([[pane valueForKey:@"offset"] integerValue] == 0);
    [pane findPrevious:nil];
    waitUntil(^BOOL{ return [[pane valueForKey:@"offset"] integerValue] > 2000; });
    assert([pane findColumnsInRow:0].length == 9);
    [pane findNext:nil]; waitUntil(visibleHit);
    [pane findNext:nil]; waitUntil(^BOOL{ return [status() isEqual:@"已循环"]; });
    query(@"即将出现"); waitUntil(^BOOL{ return [status() isEqual:@"未找到"]; });
    // Rechecks of a settled miss must never hide the label between PTY batches.
    for (int i=0; i<6; ++i) {
        [pane consume:"\r\nmore output"];
        assert([status() isEqual:@"未找到"]);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.065]];
        assert([status() isEqual:@"未找到"]);
    }
    [pane consume:"\r\n即将出现"];
    waitUntil(visibleHit);
    [pane consume:"\033[3J"];
    query(@"never here"); waitUntil(^BOOL{ return [status() isEqual:@"未找到"]; });
    NSButton *clear = [bar valueForKey:@"clear"], *next = [bar valueForKey:@"next"];
    NSView *icon = [bar valueForKey:@"magnifier"], *close = [bar valueForKey:@"close"];
    NSTextField *label = [bar valueForKey:@"status"];
    for (CGFloat width : {580.,265.,161.,300.,580.}) {
        [window setContentSize:NSMakeSize(width,240)];
        [pane layoutSubtreeIfNeeded];
        NSRect frame = bar.frame, fieldFrame = bar.field.frame;
        assert(NSContainsRect(pane.bounds,frame));
        for (NSView *v in bar.subviews) assert(NSContainsRect(bar.bounds,v.frame));
        assert(NSMaxX(icon.frame)<=NSMinX(fieldFrame) && NSMaxX(fieldFrame)<=NSMinX(clear.frame));
        assert(NSMidY(fieldFrame)==NSMidY(icon.frame) && NSMidY(fieldFrame)==NSMidY(clear.frame) && NSMidY(close.frame)==NSMidY(next.frame));
        assert(fabs(NSMidY(label.frame)-NSMidY(next.frame))<1.);
        NSTextView *editor = (NSTextView *)bar.field.currentEditor;
        assert(editor && window.firstResponder==editor);
        NSRect clip = [editor.superview convertRect:editor.superview.bounds toView:bar];
        NSRect editingFrame = [editor convertRect:editor.bounds toView:bar];
        assert(fabs(NSMidY(editingFrame)-NSMidY(fieldFrame))<=1.);
        assert(!NSIntersectsRect(clip,icon.frame) && !NSIntersectsRect(clip,clear.frame));

        applyControl(clear);
        assert(!bar.field.stringValue.length && !status().length && clear.hidden && !next.enabled);
        [editor insertText:@"未命中 search" replacementRange:NSMakeRange(NSNotFound,0)];
        waitUntil(^BOOL{ return [status() isEqual:@"未找到"]; });
        [pane layoutSubtreeIfNeeded];
        assert(!clear.hidden && !next.enabled && NSEqualRects(frame,bar.frame) && NSEqualRects(fieldFrame,bar.field.frame));
        [editor insertText:@"x" replacementRange:NSMakeRange(NSNotFound,0)];
        assert([status() isEqual:@"未找到"]);
    }

    assert([pane control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(cancelOperation:)]);
    assert(![pane valueForKey:@"findBar"] && window.firstResponder == pane);
    [pane stop];
    puts("Real PTY: Ctrl-F field focus, archived/current matches, case folding, wraparound, stable live misses, editing/resizing across five pane widths and Esc OK");
}

static void checkBackdrop() {
    Wallpaper *store = Wallpaper.shared;
    [store removeImage]; SetTerminalPreference(BackgroundOpacity,100);
    NSRect frame = NSMakeRect(0,0,600,400);
    TabWorkspace *work = [[TabWorkspace alloc] initWithFrame:frame];
    NSWindow * __attribute__((objc_precise_lifetime)) imageWindow = CreateTerminalWindow(work);
    WindowContent *first = (WindowContent *)imageWindow.contentView;
    WindowContent *second = [[WindowContent alloc] initWithWorkspace:[[TabWorkspace alloc] initWithFrame:frame] frame:frame];
    [work addTab]; [work splitVertical:YES];
    TerminalView *pane = work.focused;
    assert([first valueForKey:@"backdrop"] == nil && pane.isOpaque);
    SetTerminalPreference(BackgroundOpacity,58);
    NSView *backdrop = [first valueForKey:@"backdrop"];
    assert(backdrop && fabs(backdrop.layer.opacity-.58)<.001 && !pane.isOpaque);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:4096 pixelsHigh:64
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(rep.bitmapData,255,rep.bytesPerRow*rep.pixelsHigh);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
    NSURL *url = [NSURL fileURLWithPath:path];
    assert([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToURL:url atomically:YES]);
    __block BOOL finished = NO;
    [store chooseURL:url completion:^(BOOL ok) { assert(ok && NSThread.isMainThread); finished = YES; }];
    waitUntil(^BOOL{ return finished; });
    assert([PreferredBackgroundImagePath() isEqual:path] && CGImageGetWidth(store.image)==2048);
    CALayer *picture = [first valueForKey:@"picture"];
    CALayer *other = [second valueForKey:@"picture"];
    assert(picture.contents == (__bridge id)store.image && picture.contents == other.contents);
    SetTerminalPreference(BackgroundImageOpacity,42);
    assert(fabs(other.opacity-.42)<.001 && fabs(picture.opacity-.42)<.001);
    [first layoutSubtreeIfNeeded];
    checkTrafficLightPixels(imageWindow);
    NSView *frameView = first.superview; [frameView layoutSubtreeIfNeeded];
    for (NSWindowButton type : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
        NSButton *button = [imageWindow standardWindowButton:type];
        NSRect rect = [button convertRect:button.bounds toView:nil];
        assert([frameView hitTest:NSMakePoint(NSMidX(rect),NSMidY(rect))] == button);
    }
    assert(NSEqualRects(backdrop.frame,first.bounds) && NSEqualSizes(picture.frame.size,first.bounds.size));
    // Sample the composed backdrop independently of glyphs and the titlebar.
    SetTerminalPreference(BackgroundImageOpacity,100);
    unsigned char rgba[4] = {};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef sample = CGBitmapContextCreate(rgba,1,1,8,4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextTranslateCTM(sample,-250,-120);
    [backdrop.layer renderInContext:sample]; CGContextFlush(sample);
    assert(abs(rgba[3]-lround(255*.58))<=2);
    for (int i=0; i<3; ++i) assert(abs((int)rgba[i]-rgba[3])<=2);
    CGContextRelease(sample); CGColorSpaceRelease(space);
    SetTerminalPreference(BackgroundImageOpacity,42);
    [work addTab]; assert(!work.focused.isOpaque && [first valueForKey:@"picture"]==picture);
    [work selectIndex:0]; assert(work.focused==pane && [first valueForKey:@"picture"]==picture);
    CGImageRef previous = store.image;
    SetTerminalPreference(BackgroundOpacity,100); SetTerminalPreference(BackgroundImageOpacity,0);
    assert(![first valueForKey:@"backdrop"] && pane.isOpaque && store.image==previous);
    SetTerminalPreference(BackgroundImageOpacity,42);
    assert(!pane.isOpaque && ((CALayer *)[first valueForKey:@"picture"]).contents==(__bridge id)previous);
    finished = NO;
    [store chooseURL:[url URLByAppendingPathExtension:@"missing"] completion:^(BOOL ok) { assert(!ok); finished = YES; }];
    waitUntil(^BOOL{ return finished; });
    assert(store.image==previous && [PreferredBackgroundImagePath() isEqual:path]);
    [store chooseURL:url completion:nil]; [store removeImage]; // Never restore a canceled selection.
    [store chooseURL:[url URLByAppendingPathExtension:@"missing"] completion:^(BOOL ok) { assert(!ok); finished = NO; }];
    waitUntil(^BOOL{ return !finished; });
    assert(!store.image && !PreferredBackgroundImagePath().length && ![first valueForKey:@"picture"]);
    SetTerminalPreference(BackgroundOpacity,120); SetTerminalPreference(BackgroundImageOpacity,25);
    assert(PreferredOpacity(BackgroundOpacity)==100 && ![first valueForKey:@"backdrop"] && pane.isOpaque);
    [work stopAll]; [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    puts("Wallpaper decode cap, shared contents, opacity, failure, cancellation and release OK");
}

static void checkWindowEdge() {
    TabWorkspace *workspace = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,920,526)];
    NSWindow *window = CreateTerminalWindow(workspace);
    WindowContent *content = (WindowContent *)window.contentView;
    NSView *frameView = content.superview;
    assert(window.titlebarAccessoryViewControllers.count == 1);
    assert(window.titlebarAccessoryViewControllers.firstObject.view == workspace.tabBar);
    auto checkButtons = [&] {
        [frameView layoutSubtreeIfNeeded];
        TabBar *bar = workspace.tabBar;
        assert(bar.window == window && ![bar isDescendantOf:content]);
        NSRect tabs = [bar convertRect:bar.bounds toView:nil];
        NSRect body = [workspace convertRect:workspace.bounds toView:nil];
        NSButton *gear = [bar valueForKey:@"settings"];
        NSRect gearRect = [gear convertRect:gear.bounds toView:nil];
        NSButton *bell = [bar valueForKey:@"bell"];
        NSRect bellRect = [bell convertRect:bell.bounds toView:nil];
        assert(NSMaxX(bellRect)+8==NSWidth(content.bounds) && NSMaxX(gearRect)<NSMinX(bellRect));
        assert([frameView hitTest:NSMakePoint(NSMidX(bellRect),NSMidY(bellRect))] == bell);
        assert(NSMaxY(body)<=NSMinY(tabs) && NSHeight(tabs)>=NSHeight(gearRect));
        NSView *gearHit = [frameView hitTest:NSMakePoint(NSMidX(gearRect),NSMidY(gearRect))];
        assert(gearHit == gear || [gearHit isDescendantOf:gear]);
        for (NSWindowButton type : {NSWindowCloseButton,NSWindowMiniaturizeButton,NSWindowZoomButton}) {
            NSButton *button = [window standardWindowButton:type];
            assert(button.window==window && !button.hiddenOrHasHiddenAncestor && button.alphaValue>0);
            NSRect rect = [button convertRect:button.bounds toView:nil];
            assert(!NSIsEmptyRect(rect) && !NSIntersectsRect(rect,tabs) && !NSIntersectsRect(rect,body));
            NSPoint center = NSMakePoint(NSMidX(rect),NSMidY(rect));
            NSView *hit = [frameView hitTest:center];
            assert(hit == button || [hit isDescendantOf:button]);
        }
    };
    for (CGFloat width : {300.,620.,920.,1500.,300.}) {
        [window setContentSize:NSMakeSize(width,526)];
        checkButtons();
    }
    for (NSAppearanceName name in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
        window.appearance = [NSAppearance appearanceNamed:name];
        checkButtons();
    }
    [workspace addTab]; checkTrafficLightPixels(window);
    [workspace showSettings]; checkTrafficLightPixels(window);
    SetTerminalPreference(BackgroundOpacity,45);
    checkButtons(); checkTrafficLightPixels(window);
    NSView *backdrop = [content valueForKey:@"backdrop"];
    assert(backdrop && NSEqualRects(backdrop.frame,content.bounds) && ![content valueForKey:@"materialView"]);
    for (NSInteger opacity : {0,99,15}) {
        SetTerminalPreference(BackgroundOpacity,opacity);
        assert(backdrop == [content valueForKey:@"backdrop"] && fabs(backdrop.layer.opacity-opacity/100.) < .001);
        checkTrafficLightPixels(window);
    }
    SetTerminalPreference(BackgroundMaterialKey,FrostedBackground);
    NSVisualEffectView *frost = [content valueForKey:@"materialView"];
    assert([frost isKindOfClass:NSVisualEffectView.class] && frost.blendingMode == NSVisualEffectBlendingModeBehindWindow);
    assert(NSMinY(frost.frame) == NSMaxY(workspace.frame) && NSHeight(frost.frame)>0);
    SetTerminalPreference(BackgroundOpacity,72);
    assert(frost == [content valueForKey:@"materialView"] && fabs(backdrop.layer.opacity-.72)<.001);
    UpdateReducedTransparency(YES);
    assert(window.opaque && ![content valueForKey:@"materialView"] && !frost.superview && ![content valueForKey:@"backdrop"]);
    assert(PreferredOpacity(BackgroundOpacity) == 72);
    checkTrafficLightPixels(window);
    UpdateReducedTransparency(NO);
    assert(!window.opaque && [[content valueForKey:@"materialView"] isKindOfClass:NSVisualEffectView.class]);
    SetTerminalPreference(BackgroundMaterialKey,LiquidGlassBackground);
    NSView *material = [content valueForKey:@"materialView"];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0,*)) assert([material isKindOfClass:NSGlassEffectView.class]);
    else
#endif
        assert([material isKindOfClass:NSVisualEffectView.class]);
    [workspace selectIndex:0]; [workspace splitVertical:YES]; [workspace addTab];
    assert(material == [content valueForKey:@"materialView"] && NSEqualRects(material.frame,content.bounds));
    [workspace showSettings]; assert(material == [content valueForKey:@"materialView"] && NSHeight(material.frame)<NSHeight(content.bounds));
    [workspace dismissSettings]; assert(NSEqualRects(material.frame,content.bounds));
    checkTrafficLightPixels(window);
    [content setFullScreenTabBar:YES]; [frameView layoutSubtreeIfNeeded];
    assert([workspace.tabBar isDescendantOf:content] && window.titlebarAccessoryViewControllers.count==0);
    assert(NSContainsRect(material.frame,workspace.tabBar.frame));
    [content setFullScreenTabBar:NO]; checkButtons();
    TabWorkspace *detached = [[TabWorkspace alloc] initWithFrame:workspace.bounds];
    NSWindow *other = CreateTerminalWindow(detached);
    assert([workspace transferTab:[workspace tabAtIndex:workspace.selectedIndex] to:detached atSlot:0]);
    NSView *otherMaterial = [other.contentView valueForKey:@"materialView"];
    assert(otherMaterial && otherMaterial != material && NSEqualRects(otherMaterial.frame,other.contentView.bounds));
    checkTrafficLightPixels(other);
    SetTerminalPreference(BackgroundOpacity,100); checkButtons(); checkTrafficLightPixels(window);
    assert(![content valueForKey:@"materialView"] && !material.superview && !otherMaterial.superview);
    SetTerminalPreference(BackgroundMaterialKey,PlainBackground);
    [detached stopAll]; [workspace stopAll];
    puts("Unified tab/terminal opacity, shared native frost/glass, accessibility fallback and traffic lights verified across splits, full screen and tab transfer");
}
static void checkNoticeEvents() {
    TabWorkspace *work = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,640,400)];
    [work addTab]; TerminalView *pane = work.focused;
    assert([AgentNoticeSummary(@"背景\n```sh\n## 总结\nignore\n```\n**总结**：修复 [滚动](https://example.org)。\n- 测试已通过。\n## 后续\n稍后再做。")
            isEqual:@"修复 滚动。 测试已通过。"]);
    assert(!AgentNoticeSummary(@" \r\n "));
    NSMutableString *longReply = [NSMutableString string];
    for (int i=0;i<161;++i) [longReply appendString:@"👩‍💻"];
    assert([AgentNoticeSummary(longReply) isEqual:[[longReply substringToIndex:160*[@"👩‍💻" length]] stringByAppendingString:@"…"]]);
    SetTerminalPreference(CommandNoticesKey,AgentOnly);
    pane.agentFinished(pane,@"codex",NO,@"## 结果\n已修复 `vim` 滚动。");
    assert(TaskNotice.unreadCount==1 && [TaskNotice.recent.firstObject.title isEqual:@"codex 任务完成"]);
    assert([TaskNotice.recent.firstObject.summary containsString:@"已修复 vim 滚动。"]);
    [work splitVertical:YES];
    pane.agentFinished(pane,@"claude",YES,@"依赖安装失败。");
    assert(TaskNotice.unreadCount==2 && [TaskNotice.recent.firstObject.title isEqual:@"claude 任务失败"]);
    assert([TaskNotice.recent.firstObject.summary isEqual:@"依赖安装失败。"]);
    pane.commandExited(pane,@"agy",0,1); // One-shot agent without a separate turn event.
    assert(TaskNotice.unreadCount==3 && TaskNotice.recent.firstObject.source==pane);
    [TaskNotice discardFor:pane];
    SetTerminalPreference(CommandNoticesKey,AllCommands);
    [work addTab]; [work selectIndex:0];
    pane.commandExited(pane,@"sleep",0,42);
    assert(!TaskNotice.recent.count);
    [work selectIndex:1];
    SetTerminalPreference(CommandNoticesKey,LongCommands);
    pane.commandExited(pane,@"sleep",0,2); assert(!TaskNotice.recent.count);
    pane.commandExited(pane,@"sleep",0,12); assert(TaskNotice.unreadCount==1);
    SetTerminalPreference(CommandNoticesKey,AgentOnly);
    pane.commandExited(pane,@"sleep",0,42); assert(TaskNotice.unreadCount==1);
    [work selectIndex:0];
    NSButton *gear = [work.tabBar valueForKey:@"settings"];
    applyControl(gear);
    [work.tabBar layoutSubtreeIfNeeded];
    NSView *highlight = [work.tabBar valueForKey:@"highlight"];
    assert(work.showingSettings && work.count==2 && [gear.accessibilityValue boolValue]);
    assert(!highlight.hidden && NSEqualRects(highlight.frame,gear.frame));
    SettingsView *settings = (SettingsView *)work.subviews.firstObject;
    [settings selectSection:GeneralSection];
    NSView *page = settings.navigationButton;
    applyControl(gear); assert(settings.navigationButton==page);
    pane.commandExited(pane,@"omp",7,1);
    assert(TaskNotice.unreadCount==2 && [TaskNotice.recent.firstObject.summary containsString:@"退出码 7"]);
    [work selectIndex:0]; applyControl(gear);
    assert(work.subviews.firstObject==settings && settings.navigationButton==page);
    [TaskNotice.recent.firstObject open];
    assert(!work.showingSettings && work.focused==pane);
    [work selectIndex:1];
    pane.agentFinished(pane,@"qodercn",NO,nil);
    assert([TaskNotice.recent.firstObject.title isEqual:@"qodercn 任务完成"]);
    [TaskNotice.recent.firstObject open];
    assert(work.focused==pane);
    SetTerminalPreference(CommandNoticesKey,AllCommands);
    for (int i=0; i<40; ++i) [TaskNotice postFrom:pane window:nil title:@"任务" summary:[@(i) stringValue]];
    assert(TaskNotice.recent.count==32 && [TaskNotice.recent.lastObject.summary isEqual:@"8"]);
    [work stopAll]; assert(!TaskNotice.recent.count);
}
static void checkTransfers() {
    TabWorkspace *source = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,800,500)];
    TabWorkspace *target = [[TabWorkspace alloc] initWithFrame:source.frame];
    [source addTab]; TerminalView *left = source.focused;
    [source splitVertical:YES]; TerminalView *right = source.focused;
    [right insertText:@"pid=$$; printf '\\033]2;running\\007'\r" replacementRange:NSMakeRange(NSNotFound,0)];
    waitForTitle(right,@"running");
    TerminalTab *live = [source tabAtIndex:0];
    [source showSettings];
    left.commandExited(left,@"claude",0,9);
    TaskNotice *notice = TaskNotice.recent.firstObject;
    assert(notice.source == left && [notice.title isEqual:@"claude 已完成"]);
    [source showSettings]; [source showSettings];
    assert(source.count==1 && !source.focused && source.showingSettings);
    __block BOOL empty = NO; source.onEmpty = ^{ empty=YES; };
    [target addTab]; TerminalView *original = target.focused;
    assert([source transferTab:live to:target atSlot:0]);
    assert(target.count==2 && target.selectedIndex==0 && target.focused==right);
    assert(right.superview==left.superview && ((NSSplitView *)right.superview).delegate==target);
    [right insertText:@"test \"$pid\" = \"$$\" && printf '\\033]2;same-shell\\007'\r" replacementRange:NSMakeRange(NSNotFound,0)];
    waitForTitle(right,@"same-shell");
    assert([target transferTab:live to:target atSlot:2] && target.selectedIndex==1);
    assert(![source transferTab:live to:target atSlot:0]);
    [target showSettings]; [target showSettings]; assert(target.count==2);
    assert(empty && !source.count && target.showingSettings);
    [target closePane]; assert(!target.showingSettings && target.focused==right);
    [target selectIndex:0]; [target showSettings];
    TaskNoticePresenter *presenter = [TaskNoticePresenter new];
    [presenter show:notice inContent:target top:NSHeight(target.bounds)];
    NSButton *banner = [presenter valueForKey:@"banner"];
    assert(banner.superview == target && [banner.accessibilityLabel containsString:@"claude"]);
    applyControl(banner);
    assert(!banner.superview);
    assert(target.selectedIndex==1 && target.focused==left && !target.showingSettings && !TaskNotice.unreadCount);
    exitShell(right); waitUntil(^BOOL{ return target.focused==left; });
    [target selectIndex:0]; assert(target.focused==original);
    exitShell(left); waitUntil(^BOOL{ return target.count==1; });
    assert(!TaskNotice.recent.count);
    [target showSettings]; exitShell(original); waitUntil(^BOOL{ return !target.count; });
    puts("Live PTY transfer, split ownership, pinned settings tab, background exit notification jump across windows and exit OK");
}

int main() {
    setenv("SHELL","/bin/sh",1); setenv("ENV","/dev/null",1);
    @autoreleasepool {
        checkTerminalKeys(); checkSelectionMotion();
        checkWindowEdge(); checkSessionExit(); checkSettings(); checkVimWheel(); checkTabGroups(); checkSleepingTabs(); checkFind(); checkBackdrop(); checkNoticeEvents(); checkTransfers();
        TabWorkspace *w = [[TabWorkspace alloc] initWithFrame:NSMakeRect(0,0,800,500)];
        __block BOOL closed = NO; w.onEmpty = ^{ closed = YES; };
        [w addTab]; TerminalView *a = w.focused;
        [a insertText:@"tabword=first; printf '\\033]2;ready-first\\007'\r" replacementRange:NSMakeRange(NSNotFound,0)];
        waitForTitle(a,@"ready-first");
        [w splitVertical:YES]; TerminalView *b = w.focused;
        assert(a != b);
        [w addTab]; TerminalView *c = w.focused;
        assert(w.count == 2 && w.selectedIndex == 1 && w.subviews.count == 1);
        assert([c isDescendantOf:w] && ![a isDescendantOf:w] && ![b isDescendantOf:w]);
        [a insertText:@"printf '\\033]2;hidden-%s\\007' \"$tabword\"\r" replacementRange:NSMakeRange(NSNotFound,0)];
        waitForTitle(a,@"hidden-first");
        [c insertText:@"printf '\\033]2;active-%s\\007' \"${tabword-unset}\"\r" replacementRange:NSMakeRange(NSNotFound,0)];
        waitForTitle(c,@"active-unset");
        w.tabBar.onSelect(0);
        assert(w.focused == b && [a isDescendantOf:w] && ![c isDescendantOf:w]);
        [c insertText:@"printf '\\033]2;renamed-in-background\\007'\r" replacementRange:NSMakeRange(NSNotFound,0)];
        waitForTitle(c,@"renamed-in-background");
        [w.tabBar layoutSubtreeIfNeeded];
        NSArray<NSButton *> *buttons = [w.tabBar valueForKey:@"items"];
        assert([buttons[1].title isEqualToString:@"renamed-in-background"] && w.focused == b);
        [w nextPane:-1]; assert(w.focused == a);
        w.tabBar.onMove(0,1);
        assert(w.selectedIndex == 1 && w.focused == a);
        [w cycleTab:1]; assert(w.showingSettings); [w cycleTab:1]; assert(w.focused == c);
        [w cycleTab:-1]; assert(w.showingSettings); [w cycleTab:-1]; assert(w.focused == a);
        w.tabBar.onClose(0); assert(w.focused == a && w.count == 1);
        assert([[[c valueForKey:@"session"] valueForKey:@"fd"] intValue] == -1);
        [w closePane]; assert(w.count == 1 && w.focused == b);
        [w splitVertical:NO]; TerminalView *d = w.focused;
        [w addTab]; w.tabBar.onClose(0);
        assert([[[b valueForKey:@"session"] valueForKey:@"fd"] intValue] == -1);
        assert([[[d valueForKey:@"session"] valueForKey:@"fd"] intValue] == -1);
        [w closePane]; assert(closed && !w.count);

        // Measure the control's incremental allocation separately from terminal grids and child shells.
        TabBar *bar = [[TabBar alloc] initWithFrame:NSMakeRect(0,0,740,40)];
        [bar insertTitle:@"zsh" atIndex:0]; [bar selectIndex:0]; [bar layoutSubtreeIfNeeded];
        uint64_t baseline = footprint();
        @autoreleasepool {
            for (int i = 1; i < 32; ++i) [bar insertTitle:[NSString stringWithFormat:@"shell %d",i] atIndex:i];
            [bar selectIndex:31]; [bar layoutSubtreeIfNeeded];
        }
        uint64_t populated = footprint();
        if (baseline && populated)
            printf("Tab bar only: 1 -> 32 tab titles, process footprint delta %+.0f KiB\n",
                   (double(int64_t(populated)-int64_t(baseline)))/1024);
        bar.frame = NSMakeRect(0,0,165,40); [bar layoutSubtreeIfNeeded];
        NSArray<NSButton *> *items = [bar valueForKey:@"items"];
        assert(items.count == 1 && items[0].tag == 31);
        assert(![[bar valueForKey:@"more"] isHidden]);
        NSButton *gear = [bar valueForKey:@"settings"], *add = [bar valueForKey:@"add"];
        NSButton *bell = [bar valueForKey:@"bell"];
        assert(gear.image && bell.image && NSMaxX(bell.frame)+8==NSMaxX(bar.bounds));
        assert(NSMaxX(add.frame)<=NSMinX(gear.frame) && NSMaxX(gear.frame)<NSMinX(bell.frame));
        [bar selectIndex:0]; [bar layoutSubtreeIfNeeded]; assert(items[0].tag == 0);
        for (int i=0;i<8;++i) {
            [w addTab];
            [w.focused insertText:@"printf '\\033]2;bench-ready\\007'\r" replacementRange:NSMakeRange(NSNotFound,0)];
            waitForTitle(w.focused,@"bench-ready");
        }
        auto start = std::chrono::steady_clock::now();
        for (int i=0;i<1000;++i) { @autoreleasepool { [w selectIndex:(w.selectedIndex+1)%w.count]; [w.tabBar layoutSubtreeIfNeeded]; } }
        double ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        printf("8 live PTYs, 1000 offscreen content switches + tab layouts: %.2f ms total\n",ms);
        TabGroup *benchGroup = [w createGroupForTab:[w tabAtIndex:0] name:@"shells"];
        for (NSInteger i=1; i<w.count; ++i) [w putTab:[w tabAtIndex:i] inGroup:benchGroup];
        start = std::chrono::steady_clock::now();
        for (int i=0; i<200; ++i) { @autoreleasepool { [w toggleGroup:benchGroup]; [w.tabBar layoutSubtreeIfNeeded]; } }
        ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        [w toggleGroup:benchGroup]; [w.tabBar layoutSubtreeIfNeeded];
        assert(w.count==8 && [[w.tabBar valueForKey:@"items"] count]==1);
        printf("8 live PTYs, 200 group toggles with offscreen tab layouts: %.2f ms total, 1 button for the folded group\n",ms);
        [w stopAll];
        puts("Background output, focus, splits, close, reorder and overflow OK");
    }
}
