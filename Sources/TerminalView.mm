#include "Emoji.hpp"
#import "TerminalView.h"
#import "FindBar.h"
#import "TerminalAssistant.h"
#import "TerminalOutput.h"
#include "TerminalSearch.hpp"
#include <climits>
#include <signal.h>
#include <optional>
#import "Session.h"
#import "Preferences.h"
#import "Wallpaper.h"
#import <QuartzCore/CALayer.h>
#import "Palette.h"
#include "Screen.hpp"
#include "CellGraphics.hpp"
#include <cmath>

using namespace yaa;
static constexpr CGFloat insetX = 16, insetY = 12;
static NSColor *rgb(int v) {
    return [NSColor colorWithSRGBRed:((v>>16)&255)/255. green:((v>>8)&255)/255. blue:(v&255)/255. alpha:1];
}
NSColor *TerminalBackground(void) { return SchemeInk(PreferredColorScheme(),SchemeBackground); }
static NSColor *foreground() { return SchemeInk(PreferredColorScheme(),SchemeText); }
static NSColor *accent() { return SchemeInk(PreferredColorScheme(),SchemeCursor); }
static NSColor *selectionColor() { return SchemeInk(PreferredColorScheme(),SchemeSelection); }
// Inverse video can use the default foreground as its background.
static constexpr int defaultInk = -2;
static int backgroundCode(const yaa::Style &style) {
    if (style.flags & Inverse) return style.fg == Default ? defaultInk : style.fg;
    return style.bg;
}
static NSColor *resolve(int v, NSColor *fallback) {
    if (v == Default) return fallback;
    if (v < Indexed) return rgb(v);
    return TerminalIndexedColor(PreferredColorScheme(),v-Indexed);
}
static void appendScalar(std::vector<unichar> &s, char32_t c) {
    if (c > 0xffff) { c -= 0x10000; s.push_back(0xd800+(c>>10)); s.push_back(0xdc00+(c&1023)); }
    else s.push_back((unichar)c);
}
static NSString *cellText(const Row &row, int start, int end, bool trim) {
    if (trim) while (end > start && row[end-1].ch == U' ' && !row[end-1].mark) --end;
    if (start == end) return @"";
    std::vector<unichar> units;
    units.reserve(end-start);
    for (int i = start; i < end; ++i) {
        if (!row[i].width) continue;
        appendScalar(units,row[i].ch);
        if (row[i].mark) {
            char32_t tail[yaa::emoji::maxScalars];
            for (char32_t c : yaa::emoji::suffix(row[i].mark,tail)) appendScalar(units,c);
        }
    }
    return units.empty() ? @"" : [NSString stringWithCharacters:units.data() length:units.size()];
}

@interface ListingButtonCell : NSButtonCell
@end
@implementation ListingButtonCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    if (self.imagePosition != NSImageOnly) {
        NSRect chip = NSInsetRect(frame,1,1);
        [[CurrentInterfacePalette().text colorWithAlphaComponent:self.highlighted ? .14 : .06] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:4 yRadius:4] fill];
    }
    [super drawWithFrame:frame inView:view];
}
@end

@interface TerminalView () <NSTextFieldDelegate>
@end

@implementation TerminalView {
    std::unique_ptr<Screen> _screen;
    Session *_session;
    NSFont *_regular;
    NSMutableDictionary<NSAttributedStringKey,id> *_faceAttributes[4][2];
    CGFloat _fontSize, _cw, _lh, _listingActionWidth, _listingReturnWidth, _textOffsetY, _scrollRemainder;
    bool _ignoreWheelMomentum;
    NSTrackingArea *_motionArea;
    BOOL _trackLinks, _linkCursorVisible;
    NSRect _linkHitRect;
    unsigned _reportedButtons;
    char _lastMotion[48];
    size_t _lastMotionSize;
    int64_t _offset;
    int _topColumn, _anchor, _extent;
    std::vector<TextPoint> _visibleRows;
    Row _fragment;
    FindBar *_findBar;
    TerminalAssistant *_assistant;
    NSProgressIndicator *_agentProgress;
    NSDictionary *_agentResult;
    NSButton *_fixButton;
    NSDictionary *_failure;
    int64_t _commandRow;
    int _commandColumn;
    uint64_t _commandGeneration;
    BOOL _insideCommand, _runningOwned, _diagnostics;
    NSString *_issuedID, *_panelFeature, *_localTool;
    BOOL _tables, _webLinks, _fileLinks;
    OutputReferences *_references;
    NSMutableDictionary<NSNumber *, NSButton *> *_listingButtons;
    NSString *_findQuery;
    CFTimeInterval _findProgressAfter;
    BOOL _findAtBottom;
    std::unique_ptr<TerminalSearch> _findScan;
    std::optional<TextMatch> _findHit;
    NSUInteger _findTicket;
    int64_t _pendingFindRow;
    BOOL _ended, _usesBackdrop;
    NSString *_sessionTitle, *_marked;
    BOOL _reportedFocus;
    dispatch_block_t _wakeOnActivity;
    BOOL _fontChangePending;
    __weak NSWindow *_focusWindow;
    NSRange _markedSelection;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _pendingFindRow = INT64_MAX;
        _screen = std::make_unique<Screen>(2,1);
        _screen->setHistoryLimit(PreferredScrollbackLines());
        _session = [Session new]; _sessionTitle = @"终端";
        _anchor = _extent = -1;
        _usesBackdrop = UsesTerminalBackdrop();
        _fontSize = PreferredFontSize();
        [self updateFont];
        [self sizeTerminal];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferenceChanged:)
                                                  name:TerminalPreferenceChanged object:nil];
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityTextAreaRole];
        [self setAccessibilityLabel:@"终端"];
        __weak TerminalView *weak = self;
        _screen->title = [weak](std::string_view bytes) {
            TerminalView *v = weak;
            NSString *s = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
            if (s.length && v) {
                if (s.length > 128) s = [s substringToIndex:128];
                if ([v->_sessionTitle isEqualToString:s]) return;
                v->_sessionTitle = s;
                if (v.didRename) v.didRename(v);
            }
        };
        _screen->agentFinished = [weak](std::string_view name, bool failed, std::string_view detail) {
            TerminalView *pane = weak;
            if (pane.agentFinished) {
                NSString *label = [[NSString alloc] initWithBytes:name.data() length:name.size() encoding:NSUTF8StringEncoding];
                NSString *text = detail.empty() ? nil : [[NSString alloc] initWithBytes:detail.data() length:detail.size() encoding:NSUTF8StringEncoding];
                pane.agentFinished(pane,label,failed,text);
            }
        };
        [self configureCommandTracking];
        _screen->commandExited = [weak](std::string_view name, int status, int seconds) {
            TerminalView *pane = weak;
            if (pane.commandExited) {
                NSString *label = [[NSString alloc] initWithBytes:name.data() length:name.size() encoding:NSUTF8StringEncoding];
                pane.commandExited(pane,label,status,seconds);
            }
        };
        _screen->reply = [weak](std::string_view bytes) {
            TerminalView *v = weak;
            if (v) [v->_session sendBytes:bytes.data() length:bytes.size()];
        };
        [self configureOutput];
        _session.onData = ^(const void *bytes, size_t n) {
            TerminalView *v = weak;
            if (v) [v consume:std::string_view((const char *)bytes,n)];
        };
        _session.onExit = ^{
            TerminalView *v = weak;
            if (v.didExit && [TerminalPreferences() boolForKey:CloseEndedSessions]) v.didExit(v);
            else [v finish:@"会话已结束"];
        };
    }
    return self;
}
- (OutputReferences *)outputReferences {
    if (!_references) _references = [OutputReferences new];
    return _references;
}
- (void)configureOutput {
    NSUserDefaults *prefs = TerminalPreferences();
    _tables = [prefs boolForKey:PrettyTables];
    _webLinks = [prefs boolForKey:OpenWebLinks];
    BOOL previousFiles = _fileLinks;
    _fileLinks = [prefs boolForKey:RevealFileLinks];
    [_references discardTables:!_tables web:!_webLinks files:!_fileLinks];
    if (!_tables) [self clearListingButtons];
    __weak TerminalView *weak = self;
    _screen->outputContext = {};
    if (_tables || _fileLinks) {
        _screen->outputContext = [weak](std::string_view kind, std::string_view path) -> uint32_t {
            TerminalView *pane = weak;
            if (!pane || path.empty()) return 0;
            if (kind == "osc7") {
                if (!pane->_fileLinks) return 0;
                NSString *uri = [[NSString alloc] initWithBytes:path.data() length:path.size() encoding:NSUTF8StringEncoding];
                return [[pane outputReferences] context:DirectoryContext directory:TerminalURI(uri,NO,YES).path];
            }
            if (path.front() != '/') return 0;
            auto format = pane->_tables && kind != "cwd" ? FormatForOutput(kind) : std::nullopt;
            if (!pane->_fileLinks && !format) return 0;
            NSString *directory = pane->_fileLinks ? [[NSString alloc] initWithBytes:path.data() length:path.size() encoding:NSUTF8StringEncoding] : nil;
            return format ? [[pane outputReferences] listing:*format directory:directory] :
                            [[pane outputReferences] context:DirectoryContext directory:directory];
        };
    }
    _screen->hyperlink = {};
    if (_webLinks || _fileLinks) {
        _screen->hyperlink = [weak](std::string_view uri, uint32_t context) -> uint32_t {
            TerminalView *pane = weak;
            if (!pane) return 0;
            NSString *s = [[NSString alloc] initWithBytes:uri.data() length:uri.size() encoding:NSUTF8StringEncoding];
            NSURL *url = TerminalURI(s,pane->_webLinks,pane->_fileLinks);
            return url ? [[pane outputReferences] link:url parent:context] : 0;
        };
    }
    if (!_tables && !_fileLinks) _screen->setOutputContext(0);
    if (!_tables && !_fileLinks && !_webLinks) _screen->resetPresentation();
    if (_fileLinks && !previousFiles) {
        NSString *directory = _session.workingDirectory;
        if (directory) {
            // Start a fresh context so re-enabling tracking never rewrites older cells.
            _screen->setOutputContext([[self outputReferences] context:DirectoryContext directory:directory]);
        }
    }
}
- (void)clearListingButtons {
    for (NSButton *button in _listingButtons.allValues) [button removeFromSuperview];
    _listingButtons = nil;
}
- (void)toggleListing:(NSButton *)sender {
    OutputReference *record = [_references record:(uint32_t)sender.tag];
    record.raw = !record.raw; self.needsDisplay = YES;
    [self.window makeFirstResponder:self];
}
- (void)listingButton:(OutputReference *)record row:(int)y rawWidth:(CGFloat)rawWidth {
    if (!_listingButtons) _listingButtons = [NSMutableDictionary dictionary];
    NSButton *button = _listingButtons[@(y)];
    if (!button) {
        button = [NSButton new];
        button.cell = [[ListingButtonCell alloc] initTextCell:@""];
        button.target = self; button.action = @selector(toggleListing:);
        button.bordered = NO; button.controlSize = NSControlSizeSmall; button.alignment = NSTextAlignmentCenter;
        [self addSubview:button positioned:NSWindowBelow relativeTo:_findBar]; _listingButtons[@(y)] = button;
    }
    CGFloat right = NSWidth(self.bounds)-2;
    CGFloat desired = record.raw ? _listingReturnWidth : _listingActionWidth;
    CGFloat width = record.raw && right-rawWidth < desired ? MIN(insetX-2,right) : MIN(desired,right);
    NSString *action = record.raw ? @"表格" : @"原始数据";
    NSString *tip = record.raw ? @"显示表格" : @"显示原始数据";
    BOOL icon = width < desired;
    NSColor *tint = CurrentInterfacePalette().secondaryText;
    if (button.font != _regular || button.contentTintColor != tint || button.tag != record.tag ||
        ![button.toolTip isEqual:tip] || (button.imagePosition == NSImageOnly) != icon) {
        button.font = _regular; button.contentTintColor = tint;
        button.attributedTitle = [[NSAttributedString alloc] initWithString:icon ? @"" : action
            attributes:@{NSFontAttributeName:_regular,NSForegroundColorAttributeName:tint}];
        button.image = icon ? [NSImage imageWithSystemSymbolName:@"tablecells" accessibilityDescription:action] : nil;
        button.imagePosition = icon ? NSImageOnly : NSNoImage;
        button.toolTip = tip; [button setAccessibilityLabel:tip]; button.tag = record.tag;
    }
    NSRect frame = NSMakeRect(right-width,insetY+y*_lh,width,_lh);
    if (!NSEqualRects(button.frame,frame)) button.frame = frame;
}
struct ListingLayout {
    struct Column { CGFloat x, width; int band; };
    std::array<Column,8> columns{};
    int count = 0, bands = 0;
};
static ListingLayout layoutListing(ListingFormat format, CGFloat width, CGFloat glyph) {
    const auto &spec = SpecForListing(format);
    ListingLayout layout;
    CGFloat gap = round(glyph*1.5);
    while (layout.count < (int)spec.labels.count) {
        int first = layout.count;
        bool hasDetails = format == ListingFormat::Files || format == ListingFormat::Containers;
        int maxCount = hasDetails && !first && width < 85*glyph ? 4 : 8;
        CGFloat used = 0;
        while (layout.count < (int)spec.labels.count && layout.count-first < maxCount) {
            CGFloat w = std::abs(spec.widths[layout.count])*glyph;
            if (layout.count != first && used+gap+w > width) break;
            if (layout.count != first) used += gap;
            layout.columns[layout.count] = {0,MIN(w,width),layout.bands};
            used += layout.columns[layout.count++].width;
        }
        CGFloat extra = MAX(0,width-used);
        int last = layout.count-1;
        int flexible = format == ListingFormat::Remotes && first == 0 && last >= 1 ? 1 : first;
        if (last > first && last != flexible && spec.widths[last] > 0) {
            CGFloat share = floor(extra*.28); layout.columns[last].width += share; extra -= share;
        }
        layout.columns[flexible].width += extra;
        CGFloat x = insetX;
        for (int i=first;i<layout.count;++i) {
            layout.columns[i].x = x; x += layout.columns[i].width+gap;
        }
        ++layout.bands;
    }
    return layout;
}
// Archived rows may split again when a pane narrows. A listing has at most eight bands.
static int listingBand(const Screen &screen, int64_t first, TextPoint point, int bands) {
    TextPoint cursor{first,0};
    for (int i=0;i<bands;++i) {
        if (cursor.row == point.row && cursor.column == point.column) return i;
        cursor = moveDisplayRow(screen,cursor,true);
    }
    return bands;
}
struct PaintedLine {
    uint32_t tag = 0;
    int64_t first = 0, last = -1;
    bool header = false, atStart = false;
    ListingFormat format = ListingFormat::Files;
    NSColor *headerFill = nil, *alternateFill = nil;
    NSArray<NSString *> *fields = nil;
    ListingLayout layout;
    NSDictionary *inlineStyles[2] = {};
    NSDictionary *styles[2][2] = {}; // Truncation and non-ASCII layout.
};
- (CGFloat)listingWidth {
    if (!_listingActionWidth) {
        NSDictionary *style = @{NSFontAttributeName:_regular};
        _listingActionWidth = ceil([@"原始数据" sizeWithAttributes:style].width)+12;
        _listingReturnWidth = ceil([@"表格" sizeWithAttributes:style].width)+12;
    }
    return MAX(_cw,NSWidth(self.bounds)-insetX-_listingActionWidth-10);
}
- (BOOL)drawListing:(OutputReference *)record atRow:(int)y cache:(PaintedLine &)cache header:(BOOL *)hasButton {
    TextPoint point = [self displayPoint:y];
    ListingFormat format = record.format;
    const auto &spec = SpecForListing(format);
    if (record.raw && y > 0) {
        const auto &row = [self displayRow:y];
        if (row.empty() || point.column) return NO;
        if (format == ListingFormat::Files) {
            if (row.size() >= 2 && (row[1].ch == '-' || row[1].ch == 'r')) return NO;
        } else if (spec.headerPattern) {
            size_t x = 0;
            while (x < row.size() && row[x].ch == ' ') ++x;
            if (x == row.size() || row[x].ch < 'A' || row[x].ch > 'Z') return NO;
        } else if (point.row > 0) {
            const auto &previous = _screen->lineAt(point.row-1);
            if (!previous.empty() && previous.front().tag == record.tag) return NO;
        }
    }
    if (cache.tag != record.tag || point.row < cache.first || point.row > cache.last) {
        auto line = ReadOutputLine(*_screen,point);
        if (!line.text) return NO;
        cache.first = line.first; cache.last = line.last;
        cache.atStart = false;
        if (!spec.headerPattern) {
            const auto previous = line.first ? &_screen->lineAt(line.first-1) : nullptr;
            cache.atStart = !previous || previous->empty() || previous->front().tag != record.tag;
        }
        auto parsed = ParseListing(format,line.text,!record.raw || y == 0 || cache.atStart);
        if (cache.tag != record.tag || cache.format != parsed.format)
            cache.layout = layoutListing(parsed.format,[self listingWidth],_cw);
        cache.format = parsed.format; cache.tag = record.tag;
        cache.header = parsed.header; cache.fields = parsed.fields;
    }
    BOOL first = cache.first == point.row && point.column == 0;
    if (cache.fields && ((first && (cache.header || cache.atStart)) || y == 0)) {
        const auto &row = [self displayRow:y];
        [self listingButton:record row:y rawWidth:insetX+MIN(row.used(),_screen->cols)*_cw];
        *hasButton = YES;
    }
    if (record.raw || !cache.fields) return NO;

    const auto &palette = CurrentInterfacePalette();
    CGFloat top = insetY+y*_lh, pixel = 1/[self gridScale];
    NSRect band = NSMakeRect(insetX-5,top,MAX(0,NSWidth(self.bounds)-insetX+1),_lh);
    if (!cache.headerFill) {
        cache.headerFill = [palette.text colorWithAlphaComponent:.065];
        cache.alternateFill = [palette.text colorWithAlphaComponent:.026];
    }
    if (cache.header) {
        [cache.headerFill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:band xRadius:3 yRadius:3] fill];
        [palette.separator setFill];
        if (point.row == cache.last) NSRectFillUsingOperation(NSMakeRect(insetX,NSMaxY(band)-pixel,MAX(0,NSWidth(band)-10),pixel),NSCompositingOperationSourceOver);
    } else if (!cache.header && (cache.first & 1)) {
        [cache.alternateFill setFill]; NSRectFillUsingOperation(band,NSCompositingOperationSourceOver);
    }
    if (!cache.styles[0][0]) {
        static NSArray<NSParagraphStyle *> *alignment = [] {
            NSMutableParagraphStyle *left = [NSMutableParagraphStyle new];
            left.lineBreakMode = NSLineBreakByTruncatingTail;
            NSMutableParagraphStyle *right = [left mutableCopy]; right.alignment = NSTextAlignmentRight;
            return @[[left copy],[right copy]];
        }();
        for (int tone=0;tone<2;++tone) {
            NSColor *ink = tone ? palette.secondaryText : foreground();
            cache.inlineStyles[tone] = @{NSFontAttributeName:_regular,NSLigatureAttributeName:@0,NSForegroundColorAttributeName:ink};
            for (int right=0;right<2;++right)
                cache.styles[tone][right] = @{NSFontAttributeName:_regular,NSLigatureAttributeName:@0,
                    NSForegroundColorAttributeName:ink, NSParagraphStyleAttributeName:alignment[right]};
        }
    }
    if (!cache.header && cache.last > cache.first && point.row == cache.last) {
        [cache.headerFill setFill];
        NSRectFillUsingOperation(NSMakeRect(insetX,NSMaxY(band)-pixel,MAX(0,NSWidth(band)-10),pixel),NSCompositingOperationSourceOver);
    }
    const auto &layout = cache.layout;
    int lineBand = first ? 0 : listingBand(*_screen,cache.first,point,layout.bands);
    const auto &resolved = SpecForListing(cache.format);
    for (int i=0;i<layout.count;++i) {
        auto col = layout.columns[i];
        if (col.band != lineBand) continue;
        NSRect r = NSMakeRect(col.x,top+_textOffsetY,col.width,_lh);
        NSString *value = cache.fields[i];
        if (!value.length) continue;
        bool secondary = cache.header || i != 0, right = resolved.widths[i] < 0;
        CGFloat advance = value.length*_cw;
        if (advance <= col.width && [value canBeConvertedToEncoding:NSASCIIStringEncoding]) {
            CGFloat x = right ? NSMaxX(r)-advance : col.x;
            [value drawAtPoint:NSMakePoint(x,NSMinY(r)) withAttributes:cache.inlineStyles[secondary]];
        } else {
            [value drawInRect:r withAttributes:cache.styles[secondary][right]];
        }
    }
    return YES;
}
- (BOOL)canSleep {
    return !_screen->alternate && (_ended || [_session shellIsForeground]);
}
- (void)sleepWithWakeHandler:(dispatch_block_t)handler {
    _wakeOnActivity = [handler copy];
    ++_findTicket; _findScan.reset();
    std::vector<TextPoint>().swap(_visibleRows);
    Row{}.swap(_fragment);
    [self clearListingButtons];
    for (auto &face : _faceAttributes) for (auto &attrs : face) attrs = nil;
    _screen->freeze();
}
- (void)wakeFromIdle {
    _wakeOnActivity = nil;
    _screen->thaw();
    if (_fontChangePending) [self applyFontChange];
}
- (void)wakeForActivity {
    dispatch_block_t wake = _wakeOnActivity;
    if (wake) wake();
}
- (void)updateFont {
    _listingActionWidth = 0;
    _regular = PreferredTerminalFont(_fontSize,NO);
    for (auto &face : _faceAttributes) for (auto &attrs : face) attrs = nil;
    _cw = [@"0" sizeWithAttributes:@{NSFontAttributeName:_regular}].width;
    [self updateRowMetrics];
}
- (NSMutableDictionary *)attributesForFace:(int)face underlined:(BOOL)underlined {
    auto &attrs = _faceAttributes[face][underlined ? 1 : 0];
    if (!attrs) {
        NSFont *font = face & 1 ? PreferredTerminalFont(_fontSize,YES) : _regular;
        attrs = [@{NSFontAttributeName:font,NSLigatureAttributeName:@0} mutableCopy];
        if ((face & 1) && [font isEqual:_regular])
            attrs[NSStrokeWidthAttributeName] = @(-2); // Some monospace families have only one weight.
        if (face & 2) attrs[NSObliquenessAttributeName] = @0.18;
        if (underlined) attrs[NSUnderlineStyleAttributeName] = @1;
    }
    return attrs;
}
- (CGFloat)gridScale { return self.window.backingScaleFactor ?: 1; }
- (void)updateRowMetrics {
    CGFloat scale = [self gridScale];
    CGFloat body = _regular.ascender - _regular.descender;
    _lh = round((body + _regular.leading)*scale)/scale;
    _textOffsetY = round((_lh-body)*scale/2)/scale;
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    if (_regular) { [self updateRowMetrics]; [self sizeTerminal]; self.needsDisplay = YES; }
}
- (void)reportFocus:(BOOL)focused {
    if (!_screen || !_screen->focusReporting || focused == _reportedFocus) return;
    _reportedFocus = focused;
    [_session send:[NSData dataWithBytes:focused ? "\033[I" : "\033[O" length:3]];
}
- (void)windowFocusChanged:(NSNotification *)note {
    [self reportFocus:[note.name isEqual:NSWindowDidBecomeKeyNotification] && self.window.firstResponder == self];
}
- (void)trackWindowFocus {
    NSWindow *window = _screen && _screen->focusReporting ? self.window : nil;
    if (_focusWindow != window) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
            if (_focusWindow) [center removeObserver:self name:name object:_focusWindow];
            if (window) [center addObserver:self selector:@selector(windowFocusChanged:) name:name object:window];
        }
        _focusWindow = window;
    }
    [self reportFocus:window.isKeyWindow && window.firstResponder == self];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (_agentProgress) [self observeAgentProgress];
    if (self.window && _wakeOnActivity) [self wakeForActivity];
    if (_focusWindow || (_screen && _screen->focusReporting)) [self trackWindowFocus];
    [self setLinkModifierDown:self.window.isKeyWindow && (NSEvent.modifierFlags & NSEventModifierFlagCommand)];
    [self updatePointerTracking];
    if (_regular && self.window) { [self updateRowMetrics]; [self sizeTerminal]; self.needsDisplay = YES; }
    if (_findBar) {
        if (!self.window) { ++_findTicket; _findScan.reset(); }
        else if (!_findHit && !_findScan) [self restartFind];
    }
}
- (void)adjustFont:(CGFloat)delta {
    _fontSize = delta ? std::clamp(_fontSize+delta,9.,28.) : PreferredFontSize();
    [self applyFontChange];
}
- (void)applyFontChange {
    _fontChangePending = _wakeOnActivity != nil;
    if (_fontChangePending) return;
    [self updateFont]; [self sizeTerminal]; self.needsDisplay = YES;
}
- (void)preferenceChanged:(NSNotification *)note {
    if ([note.object isEqual:PrettyTables] || [note.object isEqual:OpenWebLinks] || [note.object isEqual:RevealFileLinks]) {
        [self configureOutput];
        [self setLinkModifierDown:self.window.isKeyWindow && (NSEvent.modifierFlags & NSEventModifierFlagCommand)];
        self.needsDisplay = YES; return;
    }
    if ([note.object isEqual:BackgroundOpacity] || [note.object isEqual:BackgroundImageOpacity] || [note.object isEqual:BackgroundImagePath]) {
        BOOL enabled = UsesTerminalBackdrop();
        if (_usesBackdrop != enabled) {
            _usesBackdrop = enabled;
            self.layer.opaque = !enabled;
            self.needsDisplay = YES;
        }
    }
    if ([note.object isEqual:AIErrorExplanations] || [note.object isEqual:BuiltInAgent] || [note.object isEqual:LocalAgentLauncher]) {
        if ([note.object isEqual:_panelFeature] && ![TerminalPreferences() boolForKey:_panelFeature]) [self closeAssistant];
        if (![TerminalPreferences() boolForKey:AIErrorExplanations]) [self clearFailure];
        [self configureCommandTracking]; return;
    }
    if ([note.object isEqual:TerminalColorScheme]) { [_findBar applyPalette]; [_assistant refreshAppearance]; self.needsDisplay = YES; }
    if ([note.object isEqual:TerminalFontSize]) [self adjustFont:0];
    if ([note.object isEqual:TerminalFontFamily] || [note.object isEqual:TerminalFontWeight]) [self applyFontChange];
    if ([note.object isEqual:ScrollbackLines]) {
        if (_wakeOnActivity) [self wakeForActivity];
        _screen->setHistoryLimit(PreferredScrollbackLines());
        int64_t offset = std::min(_offset, _screen->historySize());
        if (offset != _offset) {
            _offset = offset; _topColumn = 0; _visibleRows.clear(); _anchor = _extent = -1; self.needsDisplay = YES;
        }
        if (_findBar && !PreferredScrollbackLines()) [self restartFind];
    }
}
- (NSString *)sessionTitle { return _sessionTitle; }
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return !_usesBackdrop; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { [self reportFocus:self.window.isKeyWindow]; self.needsDisplay = YES; if (_didFocus) _didFocus(self); return YES; }
- (BOOL)resignFirstResponder { [self reportFocus:NO]; [self unmarkText]; self.needsDisplay = YES; return YES; }
- (void)configureCommandTracking {
    _diagnostics=[TerminalPreferences() boolForKey:AIErrorExplanations];
    BOOL enabled=_diagnostics || _assistant!=nil;
    _session.tracksCommands=enabled;
    if (!enabled) {
        _screen->commandBegan={}; _screen->promptReturned={}; _screen->inputAccepted={};
        _screen->endAgentBlock();
        _insideCommand=_runningOwned=NO; _issuedID=nil; return;
    }
    if (_screen->commandBegan) return;
    __weak TerminalView *weak=self;
    _screen->commandBegan=[weak](std::string_view identifier) {
        TerminalView *v=weak; if (!v) return;
        v->_insideCommand=YES;
        v->_runningOwned=v->_issuedID && identifier==(v->_issuedID.UTF8String ?: "");
        if (v->_runningOwned) v->_screen->beginAgentOutput(); else v->_screen->endAgentBlock();
        v->_commandGeneration=v->_screen->historyGeneration;
        v->_commandRow=v->_screen->historySize()+v->_screen->y(); v->_commandColumn=v->_screen->x();
        if (v->_failure) [v clearFailure];
    };
    _screen->promptReturned=[weak](int status,std::string_view line) { [weak promptReturned:status line:line]; };
    _screen->inputAccepted=[weak](std::string_view idBytes,bool accepted) {
        TerminalView *v=weak; if (!v) return;
        NSString *identifier=[[NSString alloc] initWithBytes:idBytes.data() length:idBytes.size() encoding:NSASCIIStringEncoding];
        if (accepted && [v->_issuedID isEqual:identifier]) v->_screen->beginAgentEcho();
        [v->_session acknowledgeLine:identifier accepted:accepted];
    };
}
- (void)clearFailure {
    _failure=nil; [_fixButton removeFromSuperview]; _fixButton=nil;
}
- (BOOL)hasFailedCommand { return _failure!=nil; }
- (void)promptReturned:(int)status line:(std::string_view)line {
    uint16_t outputStamp=_screen->agentOutputStamp();
    // Syntax errors return to precmd without ever calling preexec.
    BOOL owned=_runningOwned || (!_insideCommand && _issuedID && outputStamp);
    BOOL began=_insideCommand || owned;
    _screen->endAgentBlock();
    _insideCommand=_runningOwned=NO;
    if (owned) _issuedID=nil;
    BOOL awaiting=owned && _assistant.expectedCommand!=nil;
    BOOL failed=_diagnostics && !awaiting && status && status!=130 && status!=128+SIGTSTP && !line.empty();
    if (!began || (!awaiting && !failed)) return;
    NSString *command=awaiting ? _assistant.expectedCommand :
        [[NSString alloc] initWithBytes:line.data() length:line.size() encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray *rows=[NSMutableArray array];
    if ((awaiting && outputStamp) || _commandGeneration==_screen->historyGeneration) {
        int64_t end=_screen->historySize()+_screen->y();
        int64_t start=awaiting && outputStamp ? 0 : _commandRow;
        NSUInteger used=0;
        for (int64_t index=end; index>=std::max(start,end-23) && used<3072; --index) {
            const Row &row=_screen->lineAt(index);
            if (awaiting && outputStamp && row.agentStamp!=outputStamp) {
                if (index==end && !_screen->x()) continue;
                break;
            }
            int last=index==end ? std::min(_screen->x(),(int)row.size()) : std::min(row.written,(int)row.size());
            int first=_commandGeneration==_screen->historyGeneration && index==_commandRow && !outputStamp ? std::min(last,_commandColumn) : 0;
            NSString *text=cellText(row,first,last,true);
            if (row.wrapAt==0 && rows.count) text=[text stringByAppendingString:@"\n"];
            if (text.length) { [rows addObject:text]; used+=text.length; }
        }
    }
    NSString *output=[[[rows reverseObjectEnumerator] allObjects] componentsJoinedByString:@""];
    if (output.length>3072) {
        NSRange first=[output rangeOfComposedCharacterSequenceAtIndex:output.length-3072];
        output=[output substringFromIndex:NSMaxRange(first)];
    }
    NSDictionary *record=@{@"command":command,@"status":@(status),@"output":output};
    if (awaiting) _agentResult=record; // Deliver after the same zsh prompt is ready for the next step.
    if (failed && command.length) {
        _failure=record;
        _fixButton=[NSButton buttonWithTitle:@"解释错误" target:self action:@selector(explainFailure:)];
        _fixButton.bezelStyle=NSBezelStyleRounded; _fixButton.controlSize=NSControlSizeSmall;
        _fixButton.toolTip=@"解释这条失败的命令（⌘⇧E）"; [_fixButton setAccessibilityLabel:_fixButton.toolTip];
        [self addSubview:_fixButton]; [self positionAssistant];
    }
}
- (CGFloat)positionAssistant {
    CGFloat height=_assistant.diagnosisView ? MIN([_assistant heightForWidth:NSWidth(self.bounds)],MAX(0.,NSHeight(self.bounds)-_lh-2*insetY)) : 0;
    if (_assistant.diagnosisView) _assistant.diagnosisView.frame=NSMakeRect(0,NSHeight(self.bounds)-height,NSWidth(self.bounds),height);
    if (_fixButton) {
        _fixButton.hidden=_assistant!=nil;
        _fixButton.frame=NSMakeRect(MAX(0.,NSWidth(self.bounds)-84),MAX(0.,NSHeight(self.bounds)-29),76,23);
    }
    return height;
}
- (BOOL)assistantVisible { return _assistant!=nil; }
- (void)positionAgentProgress {
    const int row=_screen->y(), col=_screen->x();
    CGFloat x=NSWidth(self.bounds)-15;
    int visibleRow=row;
    if (_offset) visibleRow=0;
    else if (!_screen->alternate && col+3 < _screen->cols && col >= _screen->row(row).written)
        x=insetX+col*_cw+5;
    NSPoint origin=NSMakePoint(floor(x),floor(insetY+visibleRow*_lh+(_lh-14)/2));
    if (!NSEqualPoints(_agentProgress.frame.origin,origin)) [_agentProgress setFrameOrigin:origin];
}
- (void)updateAgentAnimation:(NSNotification *)note {
    BOOL visible=(self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    if (visible && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion)
        [_agentProgress startAnimation:nil];
    else [_agentProgress stopAnimation:nil];
}
- (void)observeAgentProgress {
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    if (self.window) [center addObserver:self selector:@selector(updateAgentAnimation:)
                                   name:NSWindowDidChangeOcclusionStateNotification object:self.window];
    [self updateAgentAnimation:nil];
}
- (void)setAgentBusy:(BOOL)busy {
    if (busy) {
        _agentProgress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0,0,14,14)];
        _agentProgress.style=NSProgressIndicatorStyleSpinning;
        _agentProgress.controlSize=NSControlSizeSmall;
        _agentProgress.indeterminate=YES; _agentProgress.displayedWhenStopped=YES;
        [_agentProgress setAccessibilityLabel:@"Agent 运行中"];
        [self positionAgentProgress]; [self addSubview:_agentProgress];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(updateAgentAnimation:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        [self observeAgentProgress];
    } else {
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
        [_agentProgress stopAnimation:nil]; [_agentProgress removeFromSuperview]; _agentProgress=nil;
    }
}
- (BOOL)builtInAgentVisible { return self.assistantVisible && [_panelFeature isEqual:BuiltInAgent]; }
- (void)closeAssistant {
    if (!_assistant) return;
    BOOL diagnostic=_assistant.diagnosisView!=nil;
    [_session endAgentInput:!_insideCommand && !_screen->alternate && _screen->bracketPaste];
    _screen->agentEditor={}; _agentResult=nil;
    [_assistant cancel]; [_assistant.diagnosisView removeFromSuperview]; _assistant=nil; _panelFeature=nil; _localTool=nil;
    [self configureCommandTracking];
    if (diagnostic) [self sizeTerminal]; else [self positionAssistant];
    if (_assistantVisibilityChanged) _assistantVisibilityChanged();
}
- (TerminalAssistant *)openAssistantFor:(NSString *)feature tool:(NSString *)tool {
    if (![TerminalPreferences() boolForKey:feature]) return nil;
    BOOL diagnostic=[feature isEqual:AIErrorExplanations];
    if (!diagnostic && (_ended || _insideCommand || _screen->alternate || !_screen->bracketPaste || ![_session shellIsForeground])) {
        NSBeep(); return nil;
    }
    if (_assistant && (![_panelFeature isEqual:feature] || (tool && ![tool isEqual:_localTool]))) [self closeAssistant];
    if (!_assistant) {
        _panelFeature=feature; _localTool=[tool copy];
        _assistant=[[TerminalAssistant alloc] initWithDirectory:_session.workingDirectory shell:_session.shellName];
        [_assistant prepareForLocalTool:tool diagnosis:[feature isEqual:AIErrorExplanations]];
        [self configureCommandTracking];
        __weak TerminalView *weak=self;
        _assistant.currentDirectory=^NSString *{ return weak.workingDirectory; };
        _assistant.onClose=^{ TerminalView *v=weak; [v closeAssistant]; [v.window makeFirstResponder:v]; };
        _assistant.onLayout=^{ [weak sizeTerminal]; };
        _assistant.onConfigure=^{ TerminalView *v=weak; if (v.configureAI) v.configureAI(); };
        _assistant.onShellLine=^BOOL(NSString *command, BOOL execute) {
            TerminalView *v=weak;
            if (!v || v->_insideCommand || v->_ended || v->_screen->alternate || !v->_screen->bracketPaste) return NO;
            NSString *identifier=[v->_session submitLine:command execute:execute acknowledged:^(BOOL accepted) {
                TerminalView *pane=weak;
                if (!pane) return;
                if (!accepted) pane->_issuedID=nil;
                [pane->_assistant lineAcknowledged:accepted];
                if (accepted && !execute && pane.window.isKeyWindow && [pane isDescendantOf:pane.window.contentView])
                    [pane.window makeFirstResponder:pane];
            }];
            if (identifier && execute) v->_issuedID=identifier;
            return identifier!=nil;
        };
        _assistant.onStop=^{
            TerminalView *v=weak; if (!v) return;
            [v->_session discardPendingLine]; v->_issuedID=nil;
            if (v->_runningOwned) { [v->_session sendBytes:"\003" length:1]; v->_runningOwned=NO; }
        };
        _assistant.onComplete=^(NSString *summary, BOOL failed) {
            TerminalView *v=weak; if (v.agentFinished) v.agentFinished(v,v->_localTool ?: @"Agent",failed,summary);
        };
        if (diagnostic) {
            [self addSubview:_assistant.diagnosisView]; [self sizeTerminal];
        } else {
            _assistant.onActivity=^(BOOL busy) { [weak setAgentBusy:busy]; };
            _assistant.onTranscript=^(NSString *text) {
                TerminalView *v=weak;
                if (v) [v->_session postAgentText:text wakeEditor:!v->_insideCommand && v->_screen->bracketPaste && !v->_screen->alternate];
            };
            _screen->agentEditor=[weak](std::string_view bytes,std::string_view event) {
                TerminalView *v=weak; if (!v) return;
                NSString *identifier=[[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSASCIIStringEncoding];
                if (![v->_session.agentInputID isEqual:identifier]) return;
                if (event=="ready") {
                    [v->_session agentInputReady:identifier];
                    NSDictionary *result=v->_agentResult; v->_agentResult=nil;
                    if (result) [v->_assistant receivedResult:result];
                } else if (event=="task") {
                    NSString *task=[v->_session takeAgentTask:identifier];
                    if (task) [v->_assistant submitTask:task];
                } else dispatch_async(dispatch_get_main_queue(),^{
                    if ([v->_session.agentInputID isEqual:identifier]) [v closeAssistant];
                });
            };
            if (![_session beginAgentInput:^(BOOL ready) {
                if (!ready) { [weak closeAssistant]; NSBeep(); }
            }]) { [self closeAssistant]; NSBeep(); return nil; }
            [self positionAssistant];
            [self.window makeFirstResponder:self];
        }
    }
    if (_didFocus) _didFocus(self);
    if (_assistantVisibilityChanged) _assistantVisibilityChanged();
    return _assistant;
}
- (void)toggleAssistant:(id)sender {
    if (![TerminalPreferences() boolForKey:BuiltInAgent]) return;
    if (_assistant && ![_panelFeature isEqual:AIErrorExplanations]) { [self closeAssistant]; return; }
    [self openAssistantFor:BuiltInAgent tool:nil];
}
- (void)explainFailure:(id)sender {
    if (!_failure) { NSBeep(); return; }
    [[self openAssistantFor:AIErrorExplanations tool:nil] explain:_failure];
}
- (NSString *)workingDirectory { return _session.workingDirectory; }
- (void)showLocalAgent:(NSString *)tool {
    if ([@[@"codex",@"claude",@"agy",@"qodercn",@"omp"] containsObject:tool ?: @""]) [self openAssistantFor:LocalAgentLauncher tool:tool];
}
- (void)start {
    [self sizeTerminal];
    NSError *error;
    if (![_session startAt:NSHomeDirectory() cols:_screen->cols rows:_screen->height error:&error]) {
        [self finish:[NSString stringWithFormat:@"无法启动 shell · %@",error.localizedDescription]]; return;
    }
    _screen->commandExitToken = _session.commandExitToken.UTF8String ?: "";
    _sessionTitle = _session.shellName;
    if (_didRename) _didRename(self);
}
- (void)finish:(NSString *)message {
    _ended = YES; [self closeAssistant]; _sessionTitle = message;
    NSString *line = [NSString stringWithFormat:@"\r\n\033[0m[%@]\r\n",message];
    [self consume:std::string_view(line.UTF8String)];
    if (_didRename) _didRename(self);
}
- (void)stop { [_assistant cancel]; [_session close]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; if (_screen && _cw) [self sizeTerminal]; }
- (void)sizeTerminal {
    int w = std::clamp((int)((self.bounds.size.width-2*insetX)/_cw),2,1000);
    CGFloat assistantHeight=(_assistant || _fixButton) ? [self positionAssistant] : 0;
    int h = std::clamp((int)((self.bounds.size.height-assistantHeight-2*insetY)/_lh),1,500);
    if (w == _screen->cols && h == _screen->height) { if (_findBar && !_wakeOnActivity) [self positionFindBar]; return; }
    if (_wakeOnActivity) [self wakeForActivity];
    [self clearListingButtons];
    _screen->resize(w,h); [_session resizeCols:w rows:h];
    _offset = 0; _topColumn = 0; _visibleRows.clear();
    _anchor = _extent = -1; self.needsDisplay = YES;
    if (_findBar) { [self restartFind]; [self positionFindBar]; }
}
- (void)consume:(std::string_view)bytes {
    if (_wakeOnActivity) [self wakeForActivity];
    if (_idleSince) _idleSince = NSProcessInfo.processInfo.systemUptime;
    auto before = _screen->linesScrolled, generation = _screen->historyGeneration;
    bool historyOnly = _offset >= _screen->height && _anchor == -1;
    bool tracking = _screen->focusReporting;
    int mouseMode = _screen->mouseTracking;
    _screen->feed(bytes);
    if (mouseMode != _screen->mouseTracking) {
        _lastMotionSize = 0;
        if (!_screen->mouseTracking) _reportedButtons = 0;
        [self updatePointerTracking];
    }
    if (tracking != _screen->focusReporting) {
        _reportedFocus = !(self.window.isKeyWindow && self.window.firstResponder == self);
        [self trackWindowFocus];
    }
    BOOL full = _offset || _screen->bufferChanged || _anchor != -1 || generation != _screen->historyGeneration;
    BOOL reset = _screen->bufferChanged || generation != _screen->historyGeneration;
    if (reset || mouseMode != _screen->mouseTracking) {
        _scrollRemainder = 0;
        _ignoreWheelMomentum = true;
    }
    if (reset) { _offset = 0; _topColumn = 0; }
    else if (_offset) {
        _offset = std::min((uint64_t)_screen->historySize(), _offset + _screen->linesScrolled-before);
    }
    if (reset || !historyOnly) _visibleRows.clear();
    if (reset && _findBar) [self restartFind];
    else if (_findHit && _findHit->last.row >= _screen->historySize()+_screen->dirtyFirst &&
             _findHit->first.row <= _screen->historySize()+_screen->dirtyLast) [self restartFind];
    else if (_findBar && !_findHit && self.window && _findBar.field.stringValue.length) {
        int64_t changed = _screen->historySize() - static_cast<int64_t>(_screen->linesScrolled-before) + _screen->dirtyFirst;
        _pendingFindRow = std::min(_pendingFindRow,changed);
        [self findChangedRows];
    }
    _anchor = _extent = -1;
    if (!self.window || (historyOnly && !reset)) return;
    if (full) self.needsDisplay = YES;
    else {
        int first=_screen->dirtyFirst, last=_screen->dirtyLast;
        if (_screen->hasAgentBlocks() && !_screen->alternate) {
            if (first>0 && _screen->row(first-1).agentStamp) --first;
            if (last+1<_screen->height && _screen->row(last+1).agentStamp) ++last;
        }
        [self setNeedsDisplayInRect:NSMakeRect(0,insetY+first*_lh,self.bounds.size.width,(last-first+1)*_lh)];
    }
}
- (TextPoint)displayPoint:(int)y {
    if (!_offset) return {_screen->historySize()+y,0};
    if (_visibleRows.empty()) _visibleRows.push_back({_screen->historySize()-_offset,_topColumn});
    while ((int)_visibleRows.size() <= y)
        _visibleRows.push_back(moveDisplayRow(*_screen,_visibleRows.back(),true));
    return _visibleRows[y];
}
- (const Row &)displayRow:(int)y {
    if (!_offset) return _screen->row(y);
    TextPoint p = [self displayPoint:y];
    const Row &row = _screen->lineAt(p.row);
    if ((int)row.size() <= _screen->cols) return row;
    int end = fragmentEnd(row,p.column,_screen->cols);
    _fragment.assign(row.begin()+p.column,row.begin()+end);
    _fragment.agentStamp = row.agentStamp;
    _fragment.written = end-p.column;
    _fragment.wrapAt = (end < row.used() || row.wrapAt) ? end-p.column : 0;
    return _fragment;
}
- (NSRange)findColumnsInRow:(int)y {
    if (!_findHit) return {};
    TextPoint p = [self displayPoint:y];
    auto hit = *_findHit;
    if (p.row < hit.first.row || p.row > hit.last.row) return {};
    int first = p.row == hit.first.row ? std::max(0,hit.first.column-p.column) : 0;
    int end = fragmentEnd(_screen->lineAt(p.row),p.column,_screen->cols)-p.column;
    if (p.row == hit.last.row) end = std::min(end,hit.last.column+1-p.column);
    return end > first ? NSMakeRange(first,end-first) : NSMakeRange(0,0);
}
- (NSRange)selectedColumnsInRow:(int)y {
    if (_anchor < 0 || _extent < 0) return NSMakeRange(0,0);
    int base = y*_screen->cols;
    int start = std::max(0,std::min(_anchor,_extent)-base);
    int end = std::min(_screen->cols,std::max(_anchor,_extent)-base+1);
    if (end <= start) return NSMakeRange(0,0);
    const auto &row = [self displayRow:y];
    // Either half of a double-width glyph selects and copies the whole character.
    if (start > 0 && start < (int)row.size() && row[start].width == 0) --start;
    if (end < _screen->cols && end < (int)row.size() && row[end].width == 0) ++end;
    return NSMakeRange(start,end-start);
}
// Retired rows may wrap into several visible fragments. Look one fragment past
// the dirty region so repainting or scrolling never introduces a seam in the frame.
- (BOOL)isAgentRow:(int)y {
    TextPoint p;
    if (y < 0) {
        p=[self displayPoint:0];
        if (!p.row && !p.column) return 0;
        p=moveDisplayRow(*_screen,p,false);
    } else p=[self displayPoint:y];
    // A program may be waiting for stdin on its next, still empty, line.
    if (_screen->agentOutputStamp() && p.row==_screen->historySize()+_screen->y())
        return YES;
    return p.row < _screen->historySize()+_screen->height && _screen->lineAt(p.row).agentStamp!=0;
}
- (void)drawAgentFramesFrom:(int)first to:(int)end {
    BOOL fullScreen=_screen->alternate;
    [[foreground() colorWithAlphaComponent:.32] setStroke];
    CGFloat pixel=1./(self.window.backingScaleFactor ?: 1.);
    for (int y=first; y<end;) {
        if (!fullScreen && ![self isAgentRow:y]) { ++y; continue; }
        int start=y++;
        while (y<end && (fullScreen || [self isAgentRow:y])) ++y;
        BOOL above=fullScreen ? start>0 : [self isAgentRow:start-1];
        BOOL below=fullScreen ? y<_screen->height : [self isAgentRow:y];
        NSRect clip=NSMakeRect(0,insetY+start*_lh,NSWidth(self.bounds),(y-start)*_lh);
        NSRect box=NSInsetRect(clip,8+pixel/2,pixel/2);
        if (above) { box.origin.y-=6; box.size.height+=6; }
        if (below) box.size.height+=6;
        [NSGraphicsContext saveGraphicsState]; NSRectClip(clip);
        NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:box xRadius:4 yRadius:4];
        path.lineWidth=pixel; [path stroke];
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (void)drawRect:(NSRect)dirty {
    if (_wakeOnActivity) [self wakeForActivity];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!_usesBackdrop) { [TerminalBackground() setFill]; NSRectFill(dirty); }
    int first = std::max(0,(int)floor((NSMinY(dirty)-insetY)/_lh));
    int end = std::min(_screen->height,(int)ceil((NSMaxY(dirty)-insetY)/_lh));
    PaintedLine listingCache;
    BOOL selecting = _anchor >= 0 && _extent != _anchor;
    BOOL present = _tables && !_screen->alternate && !selecting && !_findBar.field.stringValue.length;
    BOOL framed = _screen->agentOutputStamp()!=0;
    for (int y = first; y < end; ++y) {
        BOOL header = NO, drawn = NO;
        const Row *source = &[self displayRow:y];
        if (source->agentStamp) framed=YES;
        if (present) {
            uint32_t tag = source->empty() ? 0 : source->front().tag;
            if (tag & 3) {
                OutputReference *record = [_references record:tag];
                if ((tag & 3) == ExplicitLink) record = [_references record:record.parent];
                if (record && (record.tag & 3)) {
                    drawn = [self drawListing:record atRow:y cache:listingCache header:&header];
                    // Reading a wrapped listing can replace the archive's transient row.
                    if (!drawn && _offset) source = &[self displayRow:y];
                }
            }
        }
        if (_listingButtons && !header) {
            [_listingButtons[@(y)] removeFromSuperview]; [_listingButtons removeObjectForKey:@(y)];
            if (!_listingButtons.count) _listingButtons = nil;
        }
        if (drawn) continue;
        const auto &row = *source;
        int count = std::min((int)row.size(),_screen->cols);
        CGFloat py = insetY+y*_lh;

        // Paint backgrounds independently of glyph shaping, then overlay the selection once.
        for (int x = 0; x < count;) {
            int color = backgroundCode(row[x].style);
            int next = x+1;
            while (next < count && backgroundCode(row[next].style) == color) ++next;
            if (color != Default) {
                NSColor *bg = color == defaultInk ? foreground() : resolve(color,TerminalBackground());
                [bg setFill]; fillGridRect(ctx,NSMakeRect(insetX+x*_cw,py,(next-x)*_cw,_lh));
            }
            x = next;
        }

        NSRange found = _findHit ? [self findColumnsInRow:y] : NSMakeRange(0,0);
        if (found.length) {
            [CurrentInterfacePalette().findFill setFill];
            fillGridRect(ctx,NSMakeRect(insetX+found.location*_cw,py,found.length*_cw,_lh));
        }
        NSRange selected = _anchor < 0 ? NSMakeRange(0,0) : [self selectedColumnsInRow:y];
        NSColor *selectedInk = nil;
        if (selected.length) {
            selectedInk = SchemeInk(PreferredColorScheme(),SchemeSelectedText);
            [selectionColor() setFill];
            fillGridRect(ctx,NSMakeRect(insetX+selected.location*_cw,py,selected.length*_cw,_lh));
        }
        for (int x = 0; x < count;) {
            auto &cell = row[x];
            if (!cell.width) { ++x; continue; }
            int next = x + cell.width;
            // Shape ASCII with identical attributes together. Non-ASCII starts at its grid position.
            if (cell.width == 1 && cell.ch < 128 && !cell.mark) {
                while (next < count && row[next].width == 1 && row[next].ch < 128 && !row[next].mark &&
                       row[next].style == cell.style) ++next;
            }
            next = std::min(next,count);
            NSColor *fg = cell.style.flags & Inverse ? resolve(cell.style.bg,TerminalBackground()) : resolve(cell.style.fg,foreground());
            NSColor *original = fg;
            if (found.length) {
                if (x < (int)found.location) next = std::min(next,(int)found.location);
                else if (x < (int)NSMaxRange(found)) {
                    next = std::min(next,(int)NSMaxRange(found));
                    fg = CurrentInterfacePalette().findText;
                }
            }
            if (selected.length && (selectedInk || found.length)) {
                int start = (int)selected.location, end = (int)NSMaxRange(selected);
                if (x < start) next = std::min(next,start);
                else if (x < end) {
                    next = std::min(next,end);
                    fg = selectedInk ?: original;
                }
            }
            NSRect rect = NSMakeRect(insetX+x*_cw,py,(next-x)*_cw,_lh);
            if (cell.ch >= 0x2500 && cell.ch <= 0x259f && !cell.mark) {
                [fg setFill];
                if (drawCellGraphic(ctx,cell.ch,rect,std::max(1.,_fontSize/14.))) {
                    if (cell.style.flags & Underline)
                        fillGridRect(ctx,NSMakeRect(NSMinX(rect),py+_textOffsetY+_regular.ascender-_regular.underlinePosition,
                                                   NSWidth(rect),std::max(1.,_regular.underlineThickness)));
                    x = next;
                    continue;
                }
            }
            NSString *str = cellText(row,x,next,!(cell.style.flags & Underline));
            if (str.length) {
                int face = ((cell.style.flags & Bold) ? 1 : 0) | ((cell.style.flags & Italic) ? 2 : 0);
                NSMutableDictionary *attrs = [self attributesForFace:face underlined:(cell.style.flags & Underline) != 0];
                if (attrs[NSForegroundColorAttributeName] != fg) attrs[NSForegroundColorAttributeName] = fg;
                [str drawAtPoint:NSMakePoint(rect.origin.x,py+_textOffsetY) withAttributes:attrs];
            }
            x = next;
        }
    }
    if (framed) [self drawAgentFramesFrom:first to:end];
    if (_agentProgress) [self positionAgentProgress];
    if (!_offset && !_ended && self.window.firstResponder == self && (_screen->cursorVisible || _marked.length)) {
        CGFloat x = insetX+_screen->x()*_cw, y = insetY+_screen->y()*_lh;
        if (_marked.length) [_marked drawAtPoint:NSMakePoint(x,y) withAttributes:@{NSFontAttributeName:_regular,
              NSBackgroundColorAttributeName:TerminalBackground(), NSForegroundColorAttributeName:foreground(),
              NSUnderlineStyleAttributeName:@1}];
        else { [accent() setFill]; NSRectFill(NSMakeRect(x,y+2,2,_lh-4)); }
    }
    if (_trackLinks) {
        NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        if (NSPointInRect(p,dirty)) {
            _linkHitRect = NSZeroRect;
            [self updateLinkCursorAtPoint:p];
        }
    }
}
- (int)indexAt:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    return std::clamp((int)((p.y-insetY)/_lh),0,_screen->height-1)*_screen->cols +
           std::clamp((int)((p.x-insetX)/_cw),0,_screen->cols-1);
}
- (NSURL *)linkAtPoint:(NSPoint)p {
    return [self linkAtPoint:p stableRect:nullptr];
}
- (NSURL *)linkAtPoint:(NSPoint)p stableRect:(NSRect *)stable {
    if (stable) *stable = NSZeroRect;
    if ((!_webLinks && !_fileLinks) || !NSPointInRect(p,NSMakeRect(insetX,insetY,_cw*_screen->cols,_lh*_screen->height))) return nil;
    int y = int((p.y-insetY)/_lh), x = int((p.x-insetX)/_cw);
    TextPoint start = [self displayPoint:y], point = {start.row,start.column+x};
    const auto &row = [self displayRow:y];
    uint32_t leading = row.empty() ? 0 : row.front().tag;
    uint32_t tag = x < (int)row.size() ? row[x].tag : 0;
    OutputReference *rec = [_references record:tag];
    OutputReference *block = [_references record:leading];
    if ((leading & 3) == ExplicitLink) block = [_references record:block.parent];
    BOOL files = block && (block.tag & 3) == FileListing;
    BOOL selecting = _anchor >= 0 && _extent != _anchor;
    BOOL pretty = _tables && block && (block.tag & 3) && !block.raw && !_screen->alternate && !selecting && !_findBar.field.stringValue.length;
    // Plain output has one hit target per grid cell. Table column edges can fall between cells.
    if (stable && !pretty) *stable = NSMakeRect(insetX+x*_cw,insetY+y*_lh,_cw,_lh);
    if (!pretty && (tag & 3) == ExplicitLink && rec.url)
        return rec.url.fileURL ? (_fileLinks ? rec.url : nil) : (_webLinks ? rec.url : nil);
    if (!pretty && x >= (int)row.size()) return nil;
    auto line = ReadOutputLine(*_screen,point);
    if (!pretty && line.index==NSNotFound) return nil;
    NSString *directory = rec.directory ?: block.directory;
    if (_fileLinks && !directory && !tag && !leading) directory = _session.workingDirectory;
    if (files || (_fileLinks && !pretty)) {
        NSArray *fields = ListingFields(ListingFormat::Files,line.text);
        NSString *name = fields.firstObject;
        if (name) {
            BOOL nameHit = line.index != NSNotFound && line.index >= line.text.length-name.length;
            if (pretty) {
                auto column = layoutListing(block.format,[self listingWidth],_cw).columns[0];
                NSRect nameRect = NSMakeRect(column.x,insetY+y*_lh,column.width,_lh);
                nameHit = start.row==line.first && start.column==0 && NSPointInRect(p,nameRect);
                if (stable && nameHit) *stable = nameRect;
            }
            if (nameHit && _fileLinks) {
                if ([fields[3] hasPrefix:@"l"]) {
                    NSRange arrow = [name rangeOfString:@" -> "];
                    if (arrow.location != NSNotFound) name = [name substringToIndex:arrow.location];
                }
                return ExistingListingFile(name,directory);
            }
            if (pretty) return nil;
        }
    }
    if (pretty) {
        auto format = block.format;
        auto parsed = ParseListing(format,line.text,true);
        if (parsed.header) return nil;
        if (parsed.fields) {
            auto layout = layoutListing(parsed.format,[self listingWidth],_cw);
            int band = listingBand(*_screen,line.first,start,layout.bands);
            for (int i=0;i<layout.count;++i) {
                auto col = layout.columns[i];
                if (col.band != band || p.x < col.x || p.x >= col.x+col.width) continue;
                if (stable) *stable = NSMakeRect(col.x,insetY+y*_lh,col.width,_lh);
                NSString *value = parsed.fields[i];
                NSURL *url = TerminalURI(value,_webLinks,_fileLinks);
                if (url) return url;
                if (_fileLinks && value.isAbsolutePath) return ExistingListingFile(value,directory);
                break;
            }
            return nil;
        }
    }
    return LinkInOutput(line.text,line.index,directory,_webLinks,_fileLinks);
}
- (void)openTerminalLink:(NSURL *)url {
    if (url.fileURL && _fileLinks) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
    else if (!url.fileURL && _webLinks) [NSWorkspace.sharedWorkspace openURL:url];
}
- (void)followMenuLink:(NSMenuItem *)item { [self openTerminalLink:item.representedObject]; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSURL *url = [self linkAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (!url) return [super menuForEvent:event];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *item = [menu addItemWithTitle:url.fileURL ? @"在 Finder 中显示" : @"打开网页链接"
                                      action:@selector(followMenuLink:) keyEquivalent:@""];
    item.target = self; item.representedObject = url; item.toolTip = url.absoluteString;
    return menu;
}
- (size_t)mousePacket:(char (&)[48])packet event:(NSEvent *)event button:(int)button action:(MouseAction)action {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat x = std::clamp(point.x-insetX,0.,_screen->cols*_cw-1);
    CGFloat y = std::clamp(point.y-insetY,0.,_screen->height*_lh-1);
    auto flags = event.modifierFlags;
    int mods = ((flags & NSEventModifierFlagShift) ? 4 : 0) | ((flags & NSEventModifierFlagOption) ? 8 : 0) |
               ((flags & NSEventModifierFlagControl) ? 16 : 0);
    return _screen->mouseReport(packet,button,action,mods,int(x/_cw)+1,int(y/_lh)+1,int(x)+1,int(y)+1);
}
- (BOOL)reportPointer:(NSEvent *)event button:(int)button action:(MouseAction)action {
    if (!_screen->mouseTracking || _offset) return NO;
    if (action==MouseAction::Press) {
        if (event.modifierFlags & (NSEventModifierFlagShift|NSEventModifierFlagCommand)) return NO;
        _reportedButtons |= 1u<<button;
    } else if (button!=3 && !(_reportedButtons & (1u<<button))) return NO;
    if (action==MouseAction::Release) _reportedButtons &= ~(1u<<button);
    char packet[48];
    size_t size = [self mousePacket:packet event:event button:button action:action];
    if (action==MouseAction::Motion) {
        if (size==_lastMotionSize && !memcmp(packet,_lastMotion,size)) return YES;
        memcpy(_lastMotion,packet,size); _lastMotionSize = size;
    } else _lastMotionSize = 0;
    if (size) [_session sendBytes:packet length:size];
    return YES;
}
- (void)updatePointerTracking {
    NSTrackingAreaOptions options = 0;
    if (self.window && (_trackLinks || (_screen && _screen->mouseTracking==1003))) {
        options = NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
        if (_trackLinks) options |= NSTrackingCursorUpdate | NSTrackingMouseEnteredAndExited;
    }
    if (_motionArea.options==options) return;
    if (_motionArea) { [self removeTrackingArea:_motionArea]; _motionArea = nil; }
    if (options) {
        _motionArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil];
        [self addTrackingArea:_motionArea];
    }
}
- (void)setLinkCursorVisible:(BOOL)visible {
    if (visible) {
        if (NSCursor.currentCursor != NSCursor.pointingHandCursor) [NSCursor.pointingHandCursor set];
    } else if (_linkCursorVisible && NSCursor.currentCursor==NSCursor.pointingHandCursor) [NSCursor.arrowCursor set];
    _linkCursorVisible = visible;
}
- (void)setLinkModifierDown:(BOOL)down {
    BOOL track = down && self.window && (_webLinks || _fileLinks);
    if (track==_trackLinks) return;
    _trackLinks = track;
    _linkHitRect = NSZeroRect;
    [self updatePointerTracking];
    if (track) [self updateLinkCursorAtPoint:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil]];
    else [self setLinkCursorVisible:NO];
}
- (void)updateLinkCursorAtPoint:(NSPoint)p {
    NSView *content = self.window.contentView;
    if (!NSPointInRect(p,self.visibleRect) || [content hitTest:[self convertPoint:p toView:content.superview]] != self) {
        _linkHitRect = NSZeroRect; [self setLinkCursorVisible:NO]; return;
    }
    if (NSPointInRect(p,_linkHitRect)) {
        if (_linkCursorVisible) [self setLinkCursorVisible:YES];
        return;
    }
    [self setLinkCursorVisible:[self linkAtPoint:p stableRect:&_linkHitRect]!=nil];
}
- (void)cursorUpdate:(NSEvent *)event {
    if (_trackLinks) {
        [self updateLinkCursorAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
        if (_linkCursorVisible) return;
    }
    [super cursorUpdate:event];
}
- (void)mouseExited:(NSEvent *)event {
    if (event.trackingArea==_motionArea) {
        // AppKit restores the cursor for the view being entered.
        _linkHitRect = NSZeroRect; _linkCursorVisible = NO;
    }
    [super mouseExited:event];
}
- (void)mouseMoved:(NSEvent *)event {
    if (![self reportPointer:event button:3 action:MouseAction::Motion]) [super mouseMoved:event];
    if (_trackLinks) [self updateLinkCursorAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)rightMouseDown:(NSEvent *)event {
    if (![self reportPointer:event button:2 action:MouseAction::Press]) [super rightMouseDown:event];
}
- (void)rightMouseDragged:(NSEvent *)event {
    if (![self reportPointer:event button:2 action:MouseAction::Motion]) [super rightMouseDragged:event];
}
- (void)rightMouseUp:(NSEvent *)event {
    if (![self reportPointer:event button:2 action:MouseAction::Release]) [super rightMouseUp:event];
}
- (void)otherMouseDown:(NSEvent *)event {
    if (event.buttonNumber!=2 || ![self reportPointer:event button:1 action:MouseAction::Press]) [super otherMouseDown:event];
}
- (void)otherMouseDragged:(NSEvent *)event {
    if (event.buttonNumber!=2 || ![self reportPointer:event button:1 action:MouseAction::Motion]) [super otherMouseDragged:event];
}
- (void)otherMouseUp:(NSEvent *)event {
    if (event.buttonNumber!=2 || ![self reportPointer:event button:1 action:MouseAction::Release]) [super otherMouseUp:event];
}
- (void)mouseDown:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) && (_webLinks || _fileLinks)) {
        NSURL *url = [self linkAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
        if (url) {
            [self openTerminalLink:url];
            return;
        }
    }
    [self.window makeFirstResponder:self];
    if ([self reportPointer:event button:0 action:MouseAction::Press]) return;
    _anchor = _extent = [self indexAt:event]; self.needsDisplay = YES;
}
- (void)mouseDragged:(NSEvent *)event {
    if ([self reportPointer:event button:0 action:MouseAction::Motion]) return;
    _extent = [self indexAt:event]; self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    if ([self reportPointer:event button:0 action:MouseAction::Release]) return;
    if (_extent == _anchor) { _extent = _anchor = -1; self.needsDisplay = YES; }
}
- (void)scrollWheel:(NSEvent *)event {
    if (event.momentumPhase != NSEventPhaseNone && _ignoreWheelMomentum) return;
    CGFloat delta = event.scrollingDeltaY;
    if (!delta) return;
    _ignoreWheelMomentum = false;
    bool reporting = _screen->mouseTracking && !_offset;
    if (_screen->alternate && !reporting && !_screen->alternateScroll) return;
    if (event.phase == NSEventPhaseBegan || delta*_scrollRemainder < 0) _scrollRemainder = 0;
    _scrollRemainder += delta * (event.hasPreciseScrollingDeltas ? 1/_lh : (reporting ? 1. : 3.));
    int steps = (int)_scrollRemainder; _scrollRemainder -= steps;
    if (!steps) return;
    if (reporting || _screen->alternate) {
        char sequence[48];
        size_t length;
        if (reporting) {
            length = [self mousePacket:sequence event:event button:steps>0 ? 64 : 65 action:MouseAction::Press];
        } else {
            sequence[0] = '\033'; sequence[1] = _screen->applicationCursor ? 'O' : '[';
            sequence[2] = steps>0 ? 'A' : 'B'; length = 3;
        }
        if (!length) return;
        int remaining = std::abs(steps);
        if (remaining == 1) { [_session sendBytes:sequence length:length]; return; }
        char batch[768];
        int count = std::min(remaining,int(sizeof(batch)/length));
        for (int i=0; i<count; ++i) memcpy(batch+i*length,sequence,length);
        while (remaining) {
            int n = std::min(remaining,count);
            [_session sendBytes:batch length:n*length];
            remaining -= n;
        }
        return;
    }
    TextPoint top = [self displayPoint:0];
    TextPoint original = top;
    for (int i=0; i<std::abs(steps); ++i) {
        if (steps<0 && top.row>=_screen->historySize()) break;
        if (steps>0 && !top.row && !top.column) break;
        top = moveDisplayRow(*_screen,top,steps<0);
    }
    if (top.row == original.row && top.column == original.column) return;
    _offset = _screen->historySize()-top.row; _topColumn = top.column; _visibleRows.clear();
    _anchor = _extent = -1; self.needsDisplay = YES;
}
- (void)copy:(id)sender {
    if (_anchor < 0) return;
    int lo = std::min(_anchor,_extent), hi = std::max(_anchor,_extent), w = _screen->cols;
    NSMutableString *text = [NSMutableString string];
    for (int y = lo/w; y <= hi/w; ++y) {
        const auto &row = [self displayRow:y];
        NSRange columns = [self selectedColumnsInRow:y];
        int count = row.wrapAt ? row.wrapAt : (int)row.size();
        [text appendString:cellText(row,std::min((int)columns.location,count),std::min((int)NSMaxRange(columns),count),!row.wrapAt)];
        if (y < hi/w && !row.wrapAt) [text appendString:@"\n"];
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}
- (void)sendString:(NSString *)str {
    if (_offset || _anchor != -1) { _offset = 0; _topColumn = 0; _visibleRows.clear(); _anchor = _extent = -1; self.needsDisplay = YES; }
    [_session send:[str dataUsingEncoding:NSUTF8StringEncoding]];
}
- (void)paste:(id)sender {
    NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    if (_screen->bracketPaste) {
        s = [s stringByReplacingOccurrencesOfString:@"\033" withString:@""];
        s = [NSString stringWithFormat:@"\033[200~%@\033[201~",s];
    }
    [self sendString:s];
}
- (BOOL)findHitIntersects:(NSRect)rect {
    int first = std::max(0,(int)floor((NSMinY(rect)-insetY)/_lh));
    int end = std::min(_screen->height,(int)ceil((NSMaxY(rect)-insetY)/_lh));
    for (int y=first; y<end; ++y) {
        NSRange hit = [self findColumnsInRow:y];
        if (hit.length && NSIntersectsRect(rect,NSMakeRect(insetX+hit.location*_cw,insetY+y*_lh,hit.length*_cw,_lh))) return YES;
    }
    return NO;
}
- (void)positionFindBar {
    if (!_findBar) return;
    CGFloat margin = NSWidth(self.bounds) < 260 ? 5 : 10;
    CGFloat width = MIN(352.,MAX(0.,NSWidth(self.bounds)-2*margin));
    CGFloat height = [_findBar heightForWidth:width];
    NSRect top = NSMakeRect(NSWidth(self.bounds)-width-margin,margin,width,height);
    NSRect bottom = top;
    bottom.origin.y = MAX(margin,NSHeight(self.bounds)-NSHeight(_assistant.diagnosisView.frame)-height-margin);
    NSRect frame = _findAtBottom ? bottom : top;
    if (_findHit && [self findHitIntersects:frame]) {
        NSRect other = _findAtBottom ? top : bottom;
        if (![self findHitIntersects:other]) { _findAtBottom = !_findAtBottom; frame = other; }
    }
    if (!NSEqualRects(_findBar.frame,frame)) _findBar.frame = frame;
}
- (void)showFind:(id)sender {
    if (!_findBar) {
        _findBar = [[FindBar alloc] initWithTarget:self];
        [self addSubview:_findBar]; [self positionFindBar];
        [_findBar layoutSubtreeIfNeeded];
    }
    [self.window makeFirstResponder:_findBar.field];
    [_findBar.field selectText:nil];
}
- (void)closeFind:(id)sender {
    ++_findTicket; _findScan.reset(); _findHit.reset();
    [_findBar removeFromSuperview]; _findBar = nil; _findQuery = nil; _findAtBottom = NO;
    [self.window makeFirstResponder:self]; self.needsDisplay = YES;
}
- (void)revealFindHit {
    TextPoint hit = _findHit->first;
    BOOL visible = NO;
    for (int y=0; y<_screen->height; ++y) {
        TextPoint pos = [self displayPoint:y];
        if (pos.row == hit.row && hit.column >= pos.column && hit.column < fragmentEnd(_screen->lineAt(pos.row),pos.column,_screen->cols)) {
            visible = YES; break;
        }
    }
    if (!visible) {
        hit.column = fragmentStart(_screen->lineAt(hit.row),hit.column,_screen->cols);
        for (int i=0; i<_screen->height/3 && (hit.row || hit.column); ++i)
            hit = moveDisplayRow(*_screen,hit,false);
        _offset = std::max<int64_t>(0,_screen->historySize()-hit.row);
        _topColumn = _offset ? hit.column : 0; _visibleRows.clear();
    }
    [self positionFindBar]; self.needsDisplay = YES;
}
- (void)continueFind:(NSUInteger)ticket {
    if (ticket != _findTicket || !_findScan) return;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent()+.003;
    TerminalSearch::Result result;
    do { result = _findScan->step(*_screen,8); }
    while (result == TerminalSearch::Searching && CFAbsoluteTimeGetCurrent() < deadline);
    if (result == TerminalSearch::Searching) {
        if (_findProgressAfter && CACurrentMediaTime() >= _findProgressAfter) {
            [_findBar showStatus:@"查找中…" hasMatch:NO];
            _findProgressAfter = 0;
        }
        __weak TerminalView *owner = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [owner continueFind:ticket]; });
        return;
    }
    if (result == TerminalSearch::Found) {
        _findHit = _findScan->match;
        [_findBar showStatus:_findScan->wrapped ? @"已循环" : @"" hasMatch:YES];
        [self revealFindHit];
    } else {
        [_findBar showStatus:_screen->archiveFailed() ? @"历史不完整" : @"未找到" hasMatch:NO];
    }
    _findScan.reset();
    [self findChangedRows];
}
- (void)findChangedRows {
    if (_findScan || _findHit || _pendingFindRow == INT64_MAX) return;
    // Include enough preceding cells to catch a query that crosses the first changed row.
    int64_t lower = std::max<int64_t>(0,_pendingFindRow-(int64_t)_findBar.field.stringValue.length);
    [self startFindBackwards:YES fromHit:NO delayed:YES lower:lower];
}
- (void)startFindBackwards:(BOOL)reverse fromHit:(BOOL)fromHit delayed:(BOOL)delayed lower:(int64_t)lower {
    _pendingFindRow = INT64_MAX;
    if (!_findBar) { [self showFind:nil]; return; }
    NSUInteger ticket = ++_findTicket;
    int64_t count = _screen->historySize()+_screen->height;
    TextPoint start = reverse ? TextPoint{count-1,INT_MAX} : TextPoint{};
    if (fromHit && _findHit) {
        start = reverse ? _findHit->first : _findHit->last;
        start.column += reverse ? -1 : 1;
    }
    if (_findHit) { _findHit.reset(); self.needsDisplay = YES; }
    _findScan.reset();
    NSTextView *editor = (NSTextView *)_findBar.field.currentEditor;
    NSString *text = editor.hasMarkedText ? (_findQuery ?: @"") : _findBar.field.stringValue;
    BOOL changed = ![_findQuery isEqualToString:text];
    if (changed && _tables && (!_findQuery.length != !text.length)) self.needsDisplay = YES;
    if (changed) { _findQuery = [text copy]; [_findBar queryDidChange]; }
    // A live-output recheck keeps the last result visible until it finds a different one.
    _findProgressAfter = changed || fromHit ? CACurrentMediaTime()+.25 : 0;
    if (!text.length) { [_findBar showStatus:@"" hasMatch:NO]; return; }
    std::u32string query;
    for (NSUInteger i=0; i<text.length; ++i) {
        unichar c = [text characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(c) && i+1<text.length &&
            CFStringIsSurrogateLowCharacter([text characterAtIndex:i+1]))
            query += CFStringGetLongCharacterForSurrogatePair(c,[text characterAtIndex:++i]);
        else query += c;
    }
    _findScan = std::make_unique<TerminalSearch>(std::move(query),reverse,start,count,lower);
    if (delayed) {
        __weak TerminalView *owner = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,55*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [owner continueFind:ticket]; });
    } else [self continueFind:ticket];
}
- (void)restartFind {
    if (self.window) [self startFindBackwards:YES fromHit:NO delayed:YES lower:0];
    else { ++_findTicket; _findScan.reset(); _findHit.reset(); }
}
- (void)findNext:(id)sender { [self startFindBackwards:NO fromHit:YES delayed:NO lower:0]; }
- (void)findPrevious:(id)sender { [self startFindBackwards:YES fromHit:YES delayed:NO lower:0]; }
- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object == _findBar.field && ![(NSTextView *)_findBar.field.currentEditor hasMarkedText]) [self restartFind];
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)editor doCommandBySelector:(SEL)action {
    if (control != _findBar.field || editor.hasMarkedText) return NO;
    if (action == @selector(cancelOperation:)) { [self closeFind:nil]; return YES; }
    if (action == @selector(insertNewline:) || action == @selector(insertLineBreak:) || action == @selector(insertNewlineIgnoringFieldEditor:)) {
        if (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) [self findPrevious:nil];
        else [self findNext:nil];
        return YES;
    }
    return NO;
}
- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagControl|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagCommand);
    if (modifiers == NSEventModifierFlagControl && [event.charactersIgnoringModifiers.lowercaseString isEqual:@"f"]) {
        [self showFind:nil]; return;
    }
    if (event.modifierFlags & NSEventModifierFlagCommand) { [super keyDown:event]; return; }
    if (!_marked.length) {
        NSString *seq = nil;
        switch (event.keyCode) {
            case 123: seq = _screen->applicationCursor ? @"\033OD" : @"\033[D"; break;
            case 124: seq = _screen->applicationCursor ? @"\033OC" : @"\033[C"; break;
            case 125: seq = _screen->applicationCursor ? @"\033OB" : @"\033[B"; break;
            case 126: seq = _screen->applicationCursor ? @"\033OA" : @"\033[A"; break;
            case 115: seq = _screen->applicationCursor ? @"\033OH" : @"\033[H"; break;
            case 119: seq = _screen->applicationCursor ? @"\033OF" : @"\033[F"; break;
            case 114: seq = @"\033[2~"; break; // Insert / Help
            case 122: seq = @"\033OP"; break; case 120: seq = @"\033OQ"; break;
            case 99: seq = @"\033OR"; break; case 118: seq = @"\033OS"; break;
            case 96: seq = @"\033[15~"; break; case 97: seq = @"\033[17~"; break;
            case 98: seq = @"\033[18~"; break; case 100: seq = @"\033[19~"; break;
            case 101: seq = @"\033[20~"; break; case 109: seq = @"\033[21~"; break;
            case 103: seq = @"\033[23~"; break; case 111: seq = @"\033[24~"; break;
            case 116: seq = @"\033[5~"; break; case 121: seq = @"\033[6~"; break;
            case 117: seq = @"\033[3~"; break; case 51: seq = @"\177"; break;
            case 36: case 76: seq = @"\r"; break; case 53: seq = @"\033"; break;
            case 48: seq = (event.modifierFlags & NSEventModifierFlagShift) ? @"\033[Z" : @"\t"; break;
        }
        if (seq) {
            if (seq.length>=3 && event.keyCode!=48 && modifiers) {
                int mod = 1 + !!(modifiers & NSEventModifierFlagShift) + 2*!!(modifiers & NSEventModifierFlagOption)
                            + 4*!!(modifiers & NSEventModifierFlagControl);
                unichar final = [seq characterAtIndex:seq.length-1];
                NSString *param = final=='~' ? [seq substringWithRange:NSMakeRange(2,seq.length-3)] : @"1";
                seq = [NSString stringWithFormat:@"\033[%@;%d%C",param,mod,final];
            }
            [self sendString:seq]; return;
        }
        if (event.modifierFlags & NSEventModifierFlagControl) {
            NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
            if (chars.length == 1) {
                unichar c = [chars characterAtIndex:0];
                if (c == ' ' || (c >= '@' && c <= '_') || (c >= 'a' && c <= 'z')) {
                    uint8_t b = c & 31; [_session send:[NSData dataWithBytes:&b length:1]]; return;
                }
            }
        }
    }
    [self interpretKeyEvents:@[event]];
}
- (void)insertText:(id)str replacementRange:(NSRange)r {
    [self unmarkText]; [self sendString:[str isKindOfClass:NSAttributedString.class] ? [str string] : str];
}
- (void)setMarkedText:(id)s selectedRange:(NSRange)selection replacementRange:(NSRange)r {
    _marked = [[s isKindOfClass:NSAttributedString.class] ? [s string] : s copy];
    _markedSelection = selection; self.needsDisplay = YES;
}
- (void)unmarkText { _marked = nil; self.needsDisplay = YES; }
- (BOOL)hasMarkedText { return _marked.length != 0; }
- (NSRange)markedRange { return _marked.length ? NSMakeRange(0,_marked.length) : NSMakeRange(NSNotFound,0); }
- (NSRange)selectedRange { return _marked.length ? _markedSelection : NSMakeRange(NSNotFound,0); }
- (NSArray *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r actualRange:(NSRangePointer)a { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)p { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)a {
    if (a) *a = r;
    NSRect caret = NSMakeRect(insetX+_screen->x()*_cw,insetY+_screen->y()*_lh,_cw,_lh);
    return [self.window convertRectToScreen:[self convertRect:caret toView:nil]];
}
- (void)doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:)) [self sendString:@"\r"];
    else if (selector == @selector(deleteBackward:)) [self sendString:@"\177"];
    else if (selector == @selector(insertTab:)) [self sendString:@"\t"];
    else if (selector == @selector(cancelOperation:)) [self sendString:@"\033"];
}
@end
