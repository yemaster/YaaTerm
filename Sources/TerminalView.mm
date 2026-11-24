#include "Emoji.hpp"
#import "TerminalView.h"
#import "FindBar.h"
#import "TerminalOutput.h"
#include "TerminalSearch.hpp"
#include <climits>
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
    unsigned _reportedButtons;
    char _lastMotion[48];
    size_t _lastMotionSize;
    int64_t _offset;
    int _topColumn, _anchor, _extent;
    std::vector<TextPoint> _visibleRows;
    Row _fragment;
    FindBar *_findBar;
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
        _screen->agentFinished = [weak](std::string_view name, bool failed) {
            TerminalView *pane = weak;
            if (pane.agentFinished) {
                NSString *label = [[NSString alloc] initWithBytes:name.data() length:name.size() encoding:NSUTF8StringEncoding];
                pane.agentFinished(pane,label,failed);
            }
        };
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
}
- (void)wakeForActivity {
    dispatch_block_t wake = _wakeOnActivity;
    if (wake) wake();
}
- (void)updateFont {
    _listingActionWidth = 0;
    _regular = [NSFont fontWithName:@"JetBrainsMono-Light" size:_fontSize] ?: [NSFont monospacedSystemFontOfSize:_fontSize weight:NSFontWeightLight];
    for (auto &face : _faceAttributes) for (auto &attrs : face) attrs = nil;
    _cw = [@"0" sizeWithAttributes:@{NSFontAttributeName:_regular}].width;
    [self updateRowMetrics];
}
- (NSMutableDictionary *)attributesForFace:(int)face underlined:(BOOL)underlined {
    auto &attrs = _faceAttributes[face][underlined ? 1 : 0];
    if (!attrs) {
        NSFont *font = _regular;
        if (face & 1) font = [NSFont fontWithName:@"JetBrainsMono-Medium" size:_fontSize] ?: [NSFont monospacedSystemFontOfSize:_fontSize weight:NSFontWeightMedium];
        attrs = [@{NSFontAttributeName:font,NSLigatureAttributeName:@0} mutableCopy];
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
    if (self.window && _wakeOnActivity) [self wakeForActivity];
    if (_focusWindow || (_screen && _screen->focusReporting)) [self trackWindowFocus];
    if (_regular && self.window) { [self updateRowMetrics]; [self sizeTerminal]; self.needsDisplay = YES; }
    if (_findBar) {
        if (!self.window) { ++_findTicket; _findScan.reset(); }
        else if (!_findHit && !_findScan) [self restartFind];
    }
}
- (void)adjustFont:(CGFloat)delta {
    _fontSize = delta ? std::clamp(_fontSize+delta,9.,28.) : PreferredFontSize();
    [self updateFont]; [self sizeTerminal]; self.needsDisplay = YES;
}
- (void)preferenceChanged:(NSNotification *)note {
    if ([note.object isEqual:PrettyTables] || [note.object isEqual:OpenWebLinks] || [note.object isEqual:RevealFileLinks]) {
        [self configureOutput]; self.needsDisplay = YES; return;
    }
    if ([note.object isEqual:BackgroundOpacity] || [note.object isEqual:BackgroundImageOpacity] || [note.object isEqual:BackgroundImagePath]) {
        BOOL enabled = UsesTerminalBackdrop();
        if (_usesBackdrop != enabled) {
            _usesBackdrop = enabled;
            self.layer.opaque = !enabled;
            self.needsDisplay = YES;
        }
    }
    if ([note.object isEqual:TerminalColorScheme]) { [_findBar applyPalette]; self.needsDisplay = YES; }
    if ([note.object isEqual:TerminalFontSize]) [self adjustFont:0];
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
    _ended = YES; _sessionTitle = message;
    NSString *line = [NSString stringWithFormat:@"\r\n\033[0m[%@]\r\n",message];
    [self consume:std::string_view(line.UTF8String)];
    if (_didRename) _didRename(self);
}
- (void)stop { [_session close]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; if (_screen && _cw) [self sizeTerminal]; }
- (void)sizeTerminal {
    int w = std::clamp((int)((self.bounds.size.width-2*insetX)/_cw),2,1000);
    int h = std::clamp((int)((self.bounds.size.height-2*insetY)/_lh),1,500);
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
        if (_motionArea) { [self removeTrackingArea:_motionArea]; _motionArea = nil; }
        if (_screen->mouseTracking==1003) {
            _motionArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                options:NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
            [self addTrackingArea:_motionArea];
        }
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
        [self setNeedsDisplayInRect:NSMakeRect(0, insetY+_screen->dirtyFirst*_lh,self.bounds.size.width,
                                               (_screen->dirtyLast-_screen->dirtyFirst+1)*_lh)];
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
- (void)drawRect:(NSRect)dirty {
    if (_wakeOnActivity) [self wakeForActivity];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!_usesBackdrop) { [TerminalBackground() setFill]; NSRectFill(dirty); }
    int first = std::max(0,(int)floor((NSMinY(dirty)-insetY)/_lh));
    int end = std::min(_screen->height,(int)ceil((NSMaxY(dirty)-insetY)/_lh));
    PaintedLine listingCache;
    BOOL selecting = _anchor >= 0 && _extent != _anchor;
    BOOL present = _tables && !_screen->alternate && !selecting && !_findBar.field.stringValue.length;
    for (int y = first; y < end; ++y) {
        BOOL header = NO, drawn = NO;
        const Row *source = &[self displayRow:y];
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
    if (!_offset && !_ended && self.window.firstResponder == self && (_screen->cursorVisible || _marked.length)) {
        CGFloat x = insetX+_screen->x()*_cw, y = insetY+_screen->y()*_lh;
        if (_marked.length) [_marked drawAtPoint:NSMakePoint(x,y) withAttributes:@{NSFontAttributeName:_regular,
              NSBackgroundColorAttributeName:TerminalBackground(), NSForegroundColorAttributeName:foreground(),
              NSUnderlineStyleAttributeName:@1}];
        else { [accent() setFill]; NSRectFill(NSMakeRect(x,y+2,2,_lh-4)); }
    }
}
- (int)indexAt:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    return std::clamp((int)((p.y-insetY)/_lh),0,_screen->height-1)*_screen->cols +
           std::clamp((int)((p.x-insetX)/_cw),0,_screen->cols-1);
}
- (NSURL *)linkAtPoint:(NSPoint)p {
    if ((!_webLinks && !_fileLinks) || !NSPointInRect(p,NSMakeRect(insetX,insetY,_cw*_screen->cols,_lh*_screen->height))) return nil;
    int y = int((p.y-insetY)/_lh), x = int((p.x-insetX)/_cw);
    TextPoint start = [self displayPoint:y], point = {start.row,start.column+x};
    const auto &row = [self displayRow:y];
    uint32_t leading = row.empty() ? 0 : row.front().tag;
    uint32_t tag = x < (int)row.size() ? row[x].tag : 0;
    OutputReference *rec = [_references record:tag];
    OutputReference *block = [_references record:leading];
    if ((leading & 3) == ExplicitLink) block = [_references record:block.parent];
    auto line = ReadOutputLine(*_screen,point);
    BOOL files = block && (block.tag & 3) == FileListing;
    BOOL pretty = _tables && block && (block.tag & 3) && !block.raw && !_screen->alternate && !_findBar.field.stringValue.length;
    if (!pretty && (tag & 3) == ExplicitLink && rec.url)
        return rec.url.fileURL ? (_fileLinks ? rec.url : nil) : (_webLinks ? rec.url : nil);
    NSString *directory = rec.directory ?: block.directory;
    if (_fileLinks && !directory && !tag && !leading) directory = _session.workingDirectory;
    if (files || (_fileLinks && !pretty)) {
        NSArray *fields = ListingFields(ListingFormat::Files,line.text);
        NSString *name = fields.firstObject;
        if (name) {
            BOOL nameHit = pretty ? start.row == line.first && start.column == 0 &&
                       p.x-insetX < layoutListing(block.format,[self listingWidth],_cw).columns[0].width
                       : line.index != NSNotFound && line.index >= line.text.length-name.length;
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
- (void)mouseMoved:(NSEvent *)event {
    if (![self reportPointer:event button:3 action:MouseAction::Motion]) [super mouseMoved:event];
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
    bottom.origin.y = MAX(margin,NSHeight(self.bounds)-height-margin);
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
