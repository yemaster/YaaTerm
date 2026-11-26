#import "TaskNotices.h"
#import "TerminalView.h"
#import "Palette.h"
#import "Preferences.h"
#import <QuartzCore/QuartzCore.h>

NSNotificationName const TaskNoticesChanged = @"YaaTerm.TaskNoticesChanged";
// The notification payload is already bounded by the terminal parser. Prefer an explicit
// summary when present, otherwise take a readable excerpt of the final response.
NSString *AgentNoticeSummary(NSString *reply) {
    if (!reply.length) return nil;
    auto pattern = [](NSString *s) { return [NSRegularExpression regularExpressionWithPattern:s options:0 error:nil]; };
    static NSRegularExpression *escape = pattern(@"\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\|$))");
    static NSRegularExpression *fence = pattern(@"(?ms)^[ \\t]*(`{3,}|~{3,})[^\\n]*\\n.*?(?:^[ \\t]*\\1[ \\t]*$|\\z)");
    static NSRegularExpression *heading = pattern(@"(?im)^[ \\t]*(?:#{1,6}[ \\t]+)?(?:\\*\\*)?(?:任务总结|总结|摘要|summary|tl;dr)(?:\\*\\*)?[ \\t]*(?:[:：][ \\t]*|$)");
    static NSRegularExpression *nextHeading = pattern(@"(?m)^[ \\t]*#{1,6}[ \\t]+");
    static NSRegularExpression *link = pattern(@"\\[([^]\\n]+)\\]\\([^()\\n]*\\)");
    static NSRegularExpression *markup = pattern(@"(?m)^[ \\t]*(?:#{1,6}|[-*+])[ \\t]+|\\*\\*|`");
    static NSRegularExpression *space = pattern(@"[\\s\\p{Cc}\\u202A-\\u202E\\u2066-\\u2069]+");
    NSMutableString *text = [reply mutableCopy];
    auto replace = [&](NSRegularExpression *regex, NSString *replacement) {
        [regex replaceMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:replacement];
    };
    replace(escape,@""); replace(fence,@"");
    NSRange section = [heading rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0,text.length)];
    if (section.location!=NSNotFound && NSMaxRange(section)<text.length) {
        [text deleteCharactersInRange:NSMakeRange(0,NSMaxRange(section))];
        NSRange next = [nextHeading rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0,text.length)];
        if (next.location!=NSNotFound) [text deleteCharactersInRange:NSMakeRange(next.location,text.length-next.location)];
    }
    replace(link,@"$1"); replace(markup,@""); replace(space,@" ");
    NSString *line = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!line.length) return nil;
    if (line.length<=160) return line;
    __block NSUInteger count = 0, end = line.length;
    [line enumerateSubstringsInRange:NSMakeRange(0,line.length)
        options:NSStringEnumerationByComposedCharacterSequences | NSStringEnumerationSubstringNotRequired
        usingBlock:^(NSString *, NSRange range, NSRange, BOOL *stop) {
            if (++count>160) { end = range.location; *stop = YES; }
        }];
    return end==line.length ? line : [[line substringToIndex:end] stringByAppendingString:@"…"];
}
static NSMutableArray<TaskNotice *> *inbox;
static TaskNotice *pendingBanner;
@implementation TaskNotice
+ (NSArray<TaskNotice *> *)recent { return [inbox copy] ?: @[]; }
+ (NSUInteger)unreadCount {
    NSUInteger count = 0;
    for (TaskNotice *item in inbox) if (item.unread) ++count;
    return count;
}
+ (void)postFrom:(TerminalView *)source window:(NSWindow *)window title:(NSString *)title summary:(NSString *)summary failed:(BOOL)failed {
    if (!inbox) inbox = [NSMutableArray arrayWithCapacity:32];
    TaskNotice *item = [TaskNotice new];
    item->_source = source; item->_originWindow = window;
    item->_failed = failed; item->_timestamp = NSDate.timeIntervalSinceReferenceDate;
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
    if (!inbox.count) inbox=nil;
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

static constexpr CGFloat noticeWidth = 336, rowHeight = 54;
static NSTextField *noticeLabel(CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont systemFontOfSize:size weight:weight]; label.textColor = color;
    label.usesSingleLineMode = YES; label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

// Identical typography for the transient banner and reusable inbox rows.
@interface NoticeCell : NSTableCellView
- (instancetype)initForBanner:(BOOL)banner;
- (void)display:(TaskNotice *)item time:(NSString *)time;
@end
@implementation NoticeCell {
    NSTextField *_summary, *_time;
    BOOL _unread;
}
- (instancetype)initForBanner:(BOOL)banner {
    if ((self=[super initWithFrame:NSZeroRect])) {
        NSImageView *icon = [NSImageView new];
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:banner ? 22 : 17 weight:NSFontWeightMedium];
        [self addSubview:icon]; self.imageView=icon;
        NSTextField *title = noticeLabel(13,NSFontWeightSemibold,NSColor.labelColor);
        [self addSubview:title]; self.textField=title;
        _summary = noticeLabel(12,NSFontWeightRegular,NSColor.secondaryLabelColor);
        [self addSubview:_summary];
        if (!banner) {
            _time = noticeLabel(11,NSFontWeightRegular,NSColor.secondaryLabelColor);
            _time.alignment = NSTextAlignmentRight; [self addSubview:_time];
        }
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)display:(TaskNotice *)item time:(NSString *)time {
    _unread = item.unread;
    self.textField.stringValue = item.title; _summary.stringValue = item.summary;
    self.textField.font = [NSFont systemFontOfSize:13 weight:(!_time || _unread) ? NSFontWeightSemibold : NSFontWeightRegular];
    self.imageView.image = [NSImage imageWithSystemSymbolName:item.failed ? @"exclamationmark.circle" : @"checkmark.circle"
                                    accessibilityDescription:nil];
    self.imageView.contentTintColor = item.failed ? NSColor.systemOrangeColor : (_time ? NSColor.secondaryLabelColor : NSColor.systemGreenColor);
    if (_time) {
        _time.stringValue=time;
        [_time sizeToFit];
        [self setAccessibilityLabel:[NSString stringWithFormat:@"%@，%@，%@，%@",_unread ? @"未读" : @"已读",item.title,item.summary,_time.stringValue]];
    }
    self.toolTip = item.summary; self.needsLayout = YES; self.needsDisplay = YES;
}
- (void)layout {
    [super layout];
    CGFloat w=NSWidth(self.bounds), h=NSHeight(self.bounds), icon=_time ? 20 : 26;
    CGFloat lead=_time ? 5 : 14, textX=lead+icon+10, right=w-(_time ? 6 : 14);
    self.imageView.frame=NSMakeRect(lead,floor((h-icon)/2),icon,icon);
    CGFloat titleRight=right;
    if (_time) {
        CGFloat timeWidth=NSWidth(_time.frame);
        _time.frame=NSMakeRect(right-timeWidth,floor(h/2)-18,timeWidth,16);
        titleRight=NSMinX(_time.frame)-(_unread ? 18 : 8);
    }
    self.textField.frame=NSMakeRect(textX,floor(h/2)-18,MAX(0.,titleRight-textX),18);
    _summary.frame=NSMakeRect(textX,floor(h/2)+2,MAX(0.,right-textX),17);
}
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    if (_time && _unread) {
        [NSColor.controlAccentColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(_time.frame)-10,NSMidY(_time.frame)-2.5,5,5)] fill];
    }
}
@end

@interface NoticeBanner : NSButton
@property (nonatomic) TaskNotice *notice;
@end
@implementation NoticeBanner {
    NoticeCell *_content;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.bordered=NO; self.title=@""; self.wantsLayer=YES;
        _content=[[NoticeCell alloc] initForBanner:YES]; _content.frame=self.bounds;
        _content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        [_content setAccessibilityElement:NO]; [self addSubview:_content];
        [self setAccessibilityChildren:@[]];
    }
    return self;
}
- (void)setNotice:(TaskNotice *)notice {
    _notice=notice; [_content display:notice time:nil];
    [self setAccessibilityLabel:[NSString stringWithFormat:@"%@，%@",notice.title,notice.summary]];
    self.toolTip=notice.summary;
}
- (void)resizeWithOldSuperviewSize:(NSSize)oldSize {
    [super resizeWithOldSuperviewSize:oldSize];
    NSRect frame=self.frame, bounds=self.superview.bounds;
    frame.size.width=MIN(noticeWidth,MAX(0.,NSWidth(bounds)-24));
    frame.origin.x=NSMaxX(bounds)-frame.size.width-12;
    self.frame=frame;
}
- (NSView *)hitTest:(NSPoint)point { return self.enabled && [super hitTest:point] ? self : nil; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    CALayer *layer=self.layer;
    layer.cornerRadius=14; layer.cornerCurve=kCACornerCurveContinuous;
    layer.backgroundColor=(self.highlighted ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).CGColor;
    layer.borderColor=NSColor.separatorColor.CGColor; layer.borderWidth=1./(self.window.backingScaleFactor ?: 1.);
    layer.shadowColor=NSColor.blackColor.CGColor; layer.shadowOpacity=.16; layer.shadowRadius=5; layer.shadowOffset=CGSizeMake(0,-2);
    CGPathRef path=CGPathCreateWithRoundedRect(NSRectToCGRect(self.bounds),14,14,nil);
    layer.shadowPath=path; CGPathRelease(path);
}
@end

@interface NoticeTable : NSTableView
@end
@implementation NoticeTable
- (void)keyDown:(NSEvent *)event {
    if (!(event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl)) &&
        self.selectedRow>=0 && (event.keyCode==36 || event.keyCode==76 || event.keyCode==49)) {
        [NSApp sendAction:self.doubleAction to:self.target from:self]; return;
    }
    [super keyDown:event];
}
@end

@interface NoticeList : NSView
@end
@implementation NoticeList
- (BOOL)isFlipped { return YES; }
@end

@interface NoticeListController : NSViewController <NSTableViewDelegate,NSTableViewDataSource>
@property (copy) void (^activate)(TaskNotice *);
- (void)refresh;
@end
@implementation NoticeListController {
    NSArray<TaskNotice *> *_items;
    NoticeTable *_table;
    NSScrollView *_scroll;
    NSTextField *_empty;
    NSDateFormatter *_clock;
}
- (void)loadView {
    NoticeList *root=[[NoticeList alloc] initWithFrame:NSMakeRect(0,0,noticeWidth,94)];
    NSTextField *heading=noticeLabel(15,NSFontWeightSemibold,NSColor.labelColor);
    heading.stringValue=@"通知"; heading.frame=NSMakeRect(16,13,noticeWidth-32,21);
    [root addSubview:heading];
    NSBox *rule=[NSBox new]; rule.boxType=NSBoxSeparator; rule.frame=NSMakeRect(14,42,noticeWidth-28,1); [root addSubview:rule];
    _empty=noticeLabel(13,NSFontWeightRegular,NSColor.secondaryLabelColor);
    _empty.stringValue=@"暂无通知"; _empty.alignment=NSTextAlignmentCenter;
    _empty.frame=NSMakeRect(16,59,noticeWidth-32,20); [root addSubview:_empty];
    _scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(4,46,noticeWidth-8,rowHeight)];
    _scroll.hasVerticalScroller=YES; _scroll.autohidesScrollers=YES; _scroll.drawsBackground=NO;
    _table=[[NoticeTable alloc] initWithFrame:_scroll.bounds]; _table.headerView=nil;
    _table.style=NSTableViewStyleInset; _table.backgroundColor=NSColor.clearColor;
    _table.rowHeight=rowHeight; _table.intercellSpacing=NSZeroSize;
    NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:@"notice"];
    column.resizingMask=NSTableColumnAutoresizingMask; [_table addTableColumn:column];
    _table.dataSource=self; _table.delegate=self; _table.target=self;
    _table.action=@selector(openClicked:); _table.doubleAction=@selector(openSelected:);
    [_table setAccessibilityLabel:@"任务通知"]; _scroll.documentView=_table; [root addSubview:_scroll];
    self.view=root;
}
- (void)refresh {
    NSView *root=self.view;
    NSClipView *clip=_scroll.contentView;
    NSPoint offset=clip.bounds.origin;
    NSInteger first=[_table rowAtPoint:offset], selected=_table.selectedRow;
    TaskNotice *anchor=(offset.y>0 && first>=0 && first<(NSInteger)_items.count) ? _items[first] : nil;
    CGFloat inset=anchor ? offset.y-NSMinY([_table rectOfRow:first]) : 0;
    TaskNotice *selection=selected>=0 && selected<(NSInteger)_items.count ? _items[selected] : nil;
    _items=TaskNotice.recent;
    [_table reloadData];
    NSInteger visibleRows=MIN(_table.numberOfRows,6);
    // Inset tables can place the first row below the document origin.
    CGFloat height=visibleRows ? NSMaxY([_table rectOfRow:visibleRows-1]) : 0;
    _scroll.hidden=!_items.count; _empty.hidden=_items.count!=0;
    [_scroll setFrameSize:NSMakeSize(noticeWidth-8,height)];
    root.frame=NSMakeRect(0,0,noticeWidth,height ? 52+height : 94);
    self.preferredContentSize=root.frame.size;
    [_table sizeLastColumnToFit];
    NSUInteger index=selection ? [_items indexOfObjectIdenticalTo:selection] : NSNotFound;
    if (index==NSNotFound) [_table deselectAll:nil];
    else [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    NSUInteger row=anchor ? [_items indexOfObjectIdenticalTo:anchor] : NSNotFound;
    [clip scrollToPoint:NSMakePoint(0,row==NSNotFound ? 0 : NSMinY([_table rectOfRow:row])+inset)];
    [_scroll reflectScrolledClipView:clip];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return _items.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NoticeCell *cell=[table makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) { cell=[[NoticeCell alloc] initForBanner:NO]; cell.identifier=column.identifier; }
    if (!_clock) {
        _clock=[NSDateFormatter new]; _clock.locale=NSLocale.autoupdatingCurrentLocale;
        _clock.timeStyle=NSDateFormatterShortStyle;
    }
    TaskNotice *item=_items[row];
    [cell display:item time:[_clock stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:item.timestamp]]];
    return cell;
}
- (void)openRow:(NSInteger)row { if (row>=0 && row<(NSInteger)_items.count && _activate) _activate(_items[row]); }
- (void)openClicked:(NSTableView *)table { [self openRow:table.clickedRow]; }
- (void)openSelected:(NSTableView *)table { [self openRow:table.selectedRow]; }
@end

@interface TaskNoticePresenter () <NSPopoverDelegate>
@end
@implementation TaskNoticePresenter {
    NSPopover *_popover;
    NoticeBanner *_banner;
    NSTimer *_dismissal;
    NSUInteger _transition;
}
- (BOOL)allowsBannerMotion { return _banner.window.visible && TabAnimationsEnabled(); }
- (void)showBannerLayer:(BOOL)visible completion:(dispatch_block_t)completion {
    CALayer *layer=_banner.layer;
    CAAnimation *previous=[layer animationForKey:@"noticeMotion"];
    CALayer *current=previous ? layer.presentationLayer : nil;
    CGFloat alpha=current ? current.opacity : (visible ? 0 : 1);
    CGFloat offset=current ? current.transform.m41 : (visible ? 10 : 0);
    _banner.alphaValue=visible ? 1 : 0;
    if (![self allowsBannerMotion]) {
        [layer removeAnimationForKey:@"noticeMotion"];
        if (completion) completion();
        return;
    }
    CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue=@(alpha); fade.toValue=@(_banner.alphaValue);
    CABasicAnimation *slide=[CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue=@(offset); slide.toValue=visible ? @0 : @8;
    CAAnimationGroup *motion=[CAAnimationGroup animation];
    motion.duration=visible ? .18 : .14; fade.duration=slide.duration=motion.duration;
    motion.animations=@[fade,slide];
    motion.timingFunction=[CAMediaTimingFunction functionWithName:visible ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseIn];
    [CATransaction begin];
    [CATransaction setCompletionBlock:completion];
    [layer addAnimation:motion forKey:@"noticeMotion"];
    [CATransaction commit];
}
- (void)dismissBanner {
    [_dismissal invalidate]; _dismissal=nil;
    if (!_banner.enabled) return;
    _banner.enabled=NO; [_banner setAccessibilityElement:NO];
    NSUInteger ticket=++_transition;
    __weak TaskNoticePresenter *weak=self;
    [self showBannerLayer:NO completion:^{
        TaskNoticePresenter *owner=weak;
        if (owner && owner->_transition==ticket) {
            [owner->_banner removeFromSuperview]; owner->_banner=nil;
        }
    }];
}
- (void)dealloc { [_dismissal invalidate]; [_banner removeFromSuperview]; [_popover close]; }
- (void)activateBanner:(NoticeBanner *)sender {
    if (sender!=_banner || !sender.enabled) return;
    TaskNotice *item=sender.notice; [self dismissBanner]; [item open];
}
- (void)show:(TaskNotice *)notice inContent:(NSView *)content top:(CGFloat)top {
    if (!content || _popover.shown) return;
    CGFloat width=MIN(noticeWidth,NSWidth(content.bounds)-24);
    if (width<=0) return;
    NSRect frame=NSMakeRect(NSMaxX(content.bounds)-width-12,top-72,width,60);
    BOOL entering=_banner.superview!=content || !_banner.enabled;
    ++_transition; // A replacement may arrive while the old card is fading out.
    if (_banner.superview!=content) {
        [_banner removeFromSuperview];
        _banner=[[NoticeBanner alloc] initWithFrame:frame];
        _banner.autoresizingMask=NSViewMinXMargin|NSViewMinYMargin;
        _banner.target=self; _banner.action=@selector(activateBanner:);
        [content addSubview:_banner positioned:NSWindowAbove relativeTo:nil];
    }
    _banner.enabled=YES; [_banner setAccessibilityElement:YES];
    if (!entering && _banner.notice!=notice && [self allowsBannerMotion]) {
        CATransition *fade=[CATransition animation]; fade.type=kCATransitionFade; fade.duration=.12;
        [_banner.layer addAnimation:fade forKey:@"noticeContents"];
    }
    _banner.frame=frame; _banner.appearance=SchemeAppearance(PreferredColorScheme()); _banner.notice=notice;
    if (entering) [self showBannerLayer:YES completion:nil];
    [_dismissal invalidate];
    __weak TaskNoticePresenter *weak=self;
    _dismissal=[NSTimer scheduledTimerWithTimeInterval:4.5 repeats:NO block:^(NSTimer *){ [weak dismissBanner]; }];
    _dismissal.tolerance=.25;
    NSAccessibilityPostNotificationWithUserInfo(content,NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey:_banner.accessibilityLabel,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityMedium)});
}
- (void)toggleFrom:(NSButton *)bell {
    if (_popover.shown) { [_popover close]; return; }
    [self dismissBanner];
    NoticeListController *list=[NoticeListController new];
    __weak TaskNoticePresenter *weak=self;
    list.activate=^(TaskNotice *item){ TaskNoticePresenter *owner=weak; if (owner) [owner->_popover close]; [item open]; };
    _popover=[NSPopover new]; _popover.delegate=self; _popover.behavior=NSPopoverBehaviorTransient;
    _popover.animates=TabAnimationsEnabled(); _popover.appearance=SchemeAppearance(PreferredColorScheme());
    _popover.contentViewController=list; [list refresh]; _popover.contentSize=list.preferredContentSize;
    [_popover showRelativeToRect:bell.bounds ofView:bell preferredEdge:NSMinYEdge];
}
- (void)popoverDidClose:(NSNotification *)note { if (note.object==_popover) _popover=nil; }
- (void)refresh {
    if (_banner) {
        if (!_banner.notice.unread || ![inbox containsObject:_banner.notice]) [self dismissBanner];
        else { _banner.appearance=SchemeAppearance(PreferredColorScheme()); _banner.needsDisplay=YES; }
    }
    if (_popover.shown) {
        NoticeListController *list=(NoticeListController *)_popover.contentViewController;
        [list refresh]; _popover.appearance=SchemeAppearance(PreferredColorScheme()); _popover.contentSize=list.preferredContentSize;
    }
}
@end
