#import "FindBar.h"
#import "Palette.h"
#import "Preferences.h"

static constexpr CGFloat rowHeight = 34, compactWidth = 280, buttonWidth = 24;

@implementation FindBar {
    NSImageView *_magnifier;
    NSButton *_clear, *_previous, *_next, *_close;
    NSTextField *_status;
    NSColor *_surface;
}
- (instancetype)initWithTarget:(id)target {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _magnifier = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil]];
        _magnifier.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
        [_magnifier setAccessibilityElement:NO];
        [self addSubview:_magnifier];
        _field = [NSTextField textFieldWithString:@""];
        _field.placeholderString = @"查找";
        _field.bezeled = NO;
        _field.drawsBackground = NO;
        _field.usesSingleLineMode = YES;
        [(NSTextFieldCell *)_field.cell setScrollable:YES];
        _field.font = [NSFont systemFontOfSize:13];
        _field.focusRingType = NSFocusRingTypeNone;
        [_field setAccessibilityLabel:@"搜索终端内容"];
        [_field setAccessibilitySubrole:NSAccessibilitySearchFieldSubrole];
        _field.delegate = target;
        [self addSubview:_field];
        auto button = [&](NSString *symbol, NSString *title, id receiver, SEL action) {
            NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
                                             target:receiver action:action];
            b.bordered = NO; b.toolTip = title; [b setAccessibilityLabel:title];
            b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular];
            [self addSubview:b]; return b;
        };
        _clear = button(@"xmark.circle.fill",@"清除搜索文字",self,@selector(clearQuery:));
        _previous = button(@"chevron.up",@"上一处（⇧Return）",target,@selector(findPrevious:));
        _next = button(@"chevron.down",@"下一处（Return）",target,@selector(findNext:));
        _close = button(@"xmark",@"关闭搜索（Esc）",target,@selector(closeFind:));
        _clear.hidden = YES;
        _previous.enabled = _next.enabled = NO;
        _status = [NSTextField labelWithString:@""];
        _status.font = [NSFont systemFontOfSize:11];
        _status.hidden = YES;
        [self addSubview:_status];
        [self applyPalette];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)applyPalette {
    const auto &colors = CurrentInterfacePalette();
    self.appearance = SchemeAppearance(PreferredColorScheme());
    _surface = [colors.background blendedColorWithFraction:SchemeIsLight(PreferredColorScheme()) ? .65 : .085 ofColor:NSColor.whiteColor];
    _field.textColor = colors.text;
    _magnifier.contentTintColor = _clear.contentTintColor = colors.secondaryText;
    _status.textColor = _previous.contentTintColor = _next.contentTintColor = _close.contentTintColor = colors.secondaryText;
    self.needsDisplay = YES;
}
- (void)clearQuery:(id)sender {
    [_field selectText:sender];
    [(NSTextView *)_field.currentEditor deleteBackward:sender];
}
- (CGFloat)heightForWidth:(CGFloat)width { return width < compactWidth ? rowHeight+24 : rowHeight; }
- (void)queryDidChange {
    _clear.hidden = !_field.stringValue.length;
    _previous.enabled = _next.enabled = NO;
}
- (void)showStatus:(NSString *)text hasMatch:(BOOL)hasMatch {
    if (_next.enabled != hasMatch) _previous.enabled = _next.enabled = hasMatch;
    if ([_status.stringValue isEqualToString:text]) return;
    _status.stringValue = text;
    _status.hidden = !text.length;
    _field.accessibilityHelp = text;
}
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), closeX = width-5-buttonWidth;
    BOOL compact = width < compactWidth;
    CGFloat navRight = closeX-5;
    CGFloat navY = compact ? rowHeight-1 : (rowHeight-buttonWidth)/2;
    _previous.frame = NSMakeRect(navRight-2*buttonWidth,navY,buttonWidth,buttonWidth);
    _next.frame = NSOffsetRect(_previous.frame,buttonWidth,0);
    _close.frame = NSMakeRect(closeX,navY,buttonWidth,buttonWidth);

    CGFloat clearX = compact ? width-26 : NSMinX(_previous.frame)-22;
    _clear.frame = NSMakeRect(clearX,(rowHeight-20)/2,20,20);
    // The status slot is independent of its text so a live recheck can't shift the editor.
    CGFloat statusEnd = compact ? NSMinX(_previous.frame)-2 : clearX-3;
    CGFloat statusX = compact ? 9 : statusEnd-60;
    CGFloat statusHeight = ceil(_status.intrinsicContentSize.height);
    _status.alignment = compact ? NSTextAlignmentLeft : NSTextAlignmentRight;
    _status.frame = NSMakeRect(statusX,NSMidY(_previous.frame)-statusHeight/2,statusEnd-statusX,statusHeight);

    _magnifier.frame = NSMakeRect(10,(rowHeight-14)/2,14,14);
    CGFloat textX = NSMaxX(_magnifier.frame)+4;
    CGFloat textEnd = (compact ? clearX : statusX)-4;
    CGFloat fieldHeight = ceil(_field.intrinsicContentSize.height);
    _field.frame = NSMakeRect(textX,(rowHeight-fieldHeight)/2,MAX(1.,textEnd-textX),fieldHeight);
}
- (void)drawRect:(NSRect)dirty {
    CGFloat pixel = 1/MAX(1.,self.window.backingScaleFactor);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,pixel/2,pixel/2) xRadius:9 yRadius:9];
    [_surface setFill]; [outline fill];
    [CurrentInterfacePalette().separator setStroke]; outline.lineWidth = pixel; [outline stroke];
}
@end
