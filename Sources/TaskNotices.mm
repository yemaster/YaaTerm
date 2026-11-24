#import "TaskNotices.h"
#import "TerminalView.h"
#import "Palette.h"
#import "Preferences.h"
#import <QuartzCore/QuartzCore.h>

NSNotificationName const TaskNoticesChanged = @"YaaTerm.TaskNoticesChanged";
static NSMutableArray<TaskNotice *> *inbox;
static TaskNotice *pendingBanner;
@implementation TaskNotice
+ (NSArray<TaskNotice *> *)recent { return [inbox copy] ?: @[]; }
+ (NSUInteger)unreadCount {
    NSUInteger count = 0;
    for (TaskNotice *item in inbox) if (item.unread) ++count;
    return count;
}
+ (void)postFrom:(TerminalView *)source window:(NSWindow *)window title:(NSString *)title summary:(NSString *)summary {
    if (!inbox) inbox = [NSMutableArray arrayWithCapacity:32];
    TaskNotice *item = [TaskNotice new];
    item->_source = source; item->_originWindow = window;
    item->_title = [title copy]; item->_summary = [summary copy]; item->_unread = YES;
    if (inbox.count == 32) [inbox removeLastObject];
    [inbox insertObject:item atIndex:0];
    // Repaint all bells once per batch of PTY output. Keep every retained record in the list.
    BOOL scheduled = pendingBanner != nil;
    pendingBanner = item;
    if (!scheduled) dispatch_async(dispatch_get_main_queue(), ^{
        TaskNotice *latest = pendingBanner; pendingBanner = nil;
        [NSNotificationCenter.defaultCenter postNotificationName:TaskNoticesChanged
            object:latest.unread && [inbox containsObject:latest] ? latest : nil];
    });
}
+ (void)discardFor:(TerminalView *)source {
    if (!inbox.count) return;
    BOOL changed = NO;
    for (NSInteger i=(NSInteger)inbox.count-1; i>=0; --i) {
        if (inbox[i].source != source && inbox[i].source) continue;
        [inbox removeObjectAtIndex:i]; changed = YES;
    }
    if (changed) [NSNotificationCenter.defaultCenter postNotificationName:TaskNoticesChanged object:nil];
}
- (void)open {
    TerminalView *pane = _source;
    if (!pane || ![inbox containsObject:self]) return;
    if (_unread) {
        _unread = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:TaskNoticesChanged object:nil];
    }
    if (pane.revealTask) pane.revealTask(pane);
}
@end

@interface NoticeRow : NSButton
@property (nonatomic) TaskNotice *notice;
@property BOOL banner;
@end
@implementation NoticeRow
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) { self.bordered = NO; self.title = @""; }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setNotice:(TaskNotice *)notice {
    _notice = notice;
    [self setAccessibilityLabel:[NSString stringWithFormat:@"%@，%@",notice.title,notice.summary]];
    self.toolTip = notice.summary;
}
- (void)drawRect:(NSRect)dirty {
    const auto &colors = CurrentInterfacePalette();
    NSRect bounds = self.bounds;
    if (_banner || self.highlighted) {
        NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds,.5,.5) xRadius:10 yRadius:10];
        [colors.chrome setFill]; [box fill];
        [colors.separator setStroke]; box.lineWidth = 1; [box stroke];
    }
    if (_notice.unread) {
        [colors.accent setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(11,15,6,6)] fill];
    }
    static NSMutableParagraphStyle *style;
    if (!style) { style = [NSMutableParagraphStyle new]; style.lineBreakMode = NSLineBreakByTruncatingTail; }
    CGFloat width = MAX(1.,NSWidth(bounds)-35);
    [_notice.title drawInRect:NSMakeRect(23,7,width,20) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:colors.text,NSParagraphStyleAttributeName:style}];
    [_notice.summary drawInRect:NSMakeRect(23,27,width,18) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:colors.secondaryText,NSParagraphStyleAttributeName:style}];
}
@end

@interface NoticeList : NSView
@end
@implementation NoticeList
- (BOOL)isFlipped { return YES; }
@end

@interface TaskNoticePresenter () <NSPopoverDelegate>
@end
@implementation TaskNoticePresenter {
    NSPopover *_popover;
    NoticeRow *_banner;
    NSTimer *_dismissal;
}
- (void)dismissBanner {
    [_dismissal invalidate]; _dismissal = nil;
    [_banner removeFromSuperview]; _banner = nil;
}
- (void)dealloc { [_dismissal invalidate]; [_banner removeFromSuperview]; [_popover close]; }
- (void)activate:(NoticeRow *)row {
    TaskNotice *item = row.notice;
    [_popover close]; [self dismissBanner]; [item open];
}
- (void)show:(TaskNotice *)notice inContent:(NSView *)content top:(CGFloat)top {
    if (!content || _popover.shown) return;
    [self dismissBanner];
    CGFloat width = MIN(310.,NSWidth(content.bounds)-20);
    _banner = [[NoticeRow alloc] initWithFrame:NSMakeRect(NSWidth(content.bounds)-width-10,top-62,width,52)];
    _banner.banner = YES; _banner.notice = notice; _banner.target = self; _banner.action = @selector(activate:);
    _banner.autoresizingMask = NSViewMinXMargin|NSViewMinYMargin;
    [content addSubview:_banner positioned:NSWindowAbove relativeTo:nil];
    if (TabAnimationsEnabled()) {
        _banner.wantsLayer = YES;
        CABasicAnimation *appear = [CABasicAnimation animationWithKeyPath:@"opacity"];
        appear.fromValue = @0; appear.toValue = @1; appear.duration = .14;
        [_banner.layer addAnimation:appear forKey:@"appear"];
    }
    __weak TaskNoticePresenter *weak = self;
    _dismissal = [NSTimer scheduledTimerWithTimeInterval:4.5 repeats:NO block:^(NSTimer *timer){ [weak dismissBanner]; }];
    NSAccessibilityPostNotificationWithUserInfo(content,NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey:_banner.accessibilityLabel,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityMedium)});
}
- (void)toggleFrom:(NSButton *)bell {
    if (_popover.shown) { [_popover close]; return; }
    [self dismissBanner];
    _popover = [NSPopover new]; _popover.delegate = self; _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = TabAnimationsEnabled();
    _popover.contentViewController = [NSViewController new];
    [self populate];
    [_popover showRelativeToRect:bell.bounds ofView:bell preferredEdge:NSMinYEdge];
}
- (void)popoverDidClose:(NSNotification *)note { if (note.object == _popover) _popover = nil; }
- (void)refresh {
    _banner.needsDisplay = YES;
    if (_banner && (!_banner.notice.unread || ![TaskNotice.recent containsObject:_banner.notice])) [self dismissBanner];
    if (_popover.shown) [self populate];
}
- (void)populate {
    NSArray<TaskNotice *> *items = TaskNotice.recent;
    CGFloat width = 316, height = items.count ? MIN((CGFloat)items.count*52,312.) : 42;
    NoticeList *root = [[NoticeList alloc] initWithFrame:NSMakeRect(0,0,width,height+40)];
    NSTextField *heading = [NSTextField labelWithString:@"通知"];
    heading.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]; heading.frame = NSMakeRect(14,11,width-28,22);
    [root addSubview:heading];
    if (items.count) {
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(4,38,width-8,height)];
        scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.drawsBackground = NO;
        NoticeList *list = [[NoticeList alloc] initWithFrame:NSMakeRect(0,0,scroll.contentSize.width,items.count*52)];
        NSInteger i=0;
        for (TaskNotice *item in items) {
            NoticeRow *row = [[NoticeRow alloc] initWithFrame:NSMakeRect(0,i++*52,NSWidth(list.bounds),52)];
            row.notice = item; row.target = self; row.action = @selector(activate:); [list addSubview:row];
        }
        scroll.documentView = list; [root addSubview:scroll];
    } else {
        NSTextField *empty = [NSTextField labelWithString:@"暂无任务提醒"];
        empty.textColor = NSColor.secondaryLabelColor; empty.frame = NSMakeRect(14,42,width-28,20);
        [root addSubview:empty];
    }
    root.appearance = SchemeAppearance(PreferredColorScheme());
    _popover.contentViewController.view = root; _popover.contentSize = root.bounds.size;
}
@end
