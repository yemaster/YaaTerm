#include "Emoji.hpp"
#import "TerminalView.h"
#import "FindBar.h"
#import "TerminalAssistant.h"
#import "TerminalOutput.h"
#include "TerminalSearch.hpp"
#include <climits>
#include <charconv>
#include <signal.h>
#include <optional>
#import "Session.h"
#import "Preferences.h"
#import "Shortcuts.h"
#import "Wallpaper.h"
#import <QuartzCore/CALayer.h>
#import <CoreText/CoreText.h>
#import "Palette.h"
#include "Screen.hpp"
#include "CellGraphics.hpp"
#include <cmath>

using namespace yaa;
static constexpr CGFloat insetX = 16, insetY = 12;
static CGFloat textOrigin(int gutter, CGFloat cellWidth) {
    // Use the pane's spare right inset for the extra gap. Wrapped lines keep their column count.
    return gutter ? insetX + gutter*cellWidth + std::min(cellWidth,insetX-4) : insetX;
}
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
static int textEnd(const Row &row, int start, int end) {
    while (end>start && row[end-1].ch==U' ' && !row[end-1].mark) --end;
    return end;
}
static NSString *cellText(const Row &row, int start, int end, bool trim) {
    if (trim) end=textEnd(row,start,end);
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

// Keep the backing surface within the pane even for thousands of short lines.
@interface ExplanationLabel : NSTextField
@property CGFloat contentHeight;
@end
@implementation ExplanationLabel
- (void)drawRect:(NSRect)dirty {
    if (_contentHeight<=NSHeight(self.bounds)) { [super drawRect:dirty]; return; }
    NSRectClip(self.bounds);
    NSRect text=NSInsetRect(self.bounds,2,0);
    text.origin.y+=NSHeight(text)-_contentHeight; text.size.height=_contentHeight;
    [self.attributedStringValue drawWithRect:text options:NSStringDrawingUsesLineFragmentOrigin context:nil];
}
@end

enum FixState { ExplainCommand, AnalyzingError, SendingExplanation, ShowExplanationAgain, ConfigureDiagnosis, RetryDiagnosis, CopySuggestion };
static NSString *const explanationTitles[]={@"命令解释",@"分析中",@"显示中",@"重新显示",@"配置 AI 服务",@"重试分析",@"复制建议"};
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
    std::vector<int> _frameEdges; // Visible row boundaries with a before/after inset.
    CGFloat _framePadding, _verticalGap;
    Row _fragment;
    FindBar *_findBar;
    TerminalAssistant *_assistant;
    NSProgressIndicator *_agentProgress;
    NSDictionary *_agentResult;
    NSButton *_fixButton;
    CGFloat _fixLabelWidth;
    Cell _failureGlyph;
    NSDictionary *_lastCommand;
    TerminalAssistant *_diagnosis;
    NSString *_explanation, *_suggestion;
    ExplanationLabel *_explanationLabel;
    NSProgressIndicator *_explanationProgress;
    int64_t _promptStart;
    int _previewRow;
    CGFloat _previewGap, _previewShift;
    BOOL _showFailureChip;
    FixState _fixState;
    uint64_t _commandSerial;
    int64_t _commandRow;
    int _commandColumn;
    uint64_t _commandGeneration;
    BOOL _insideCommand, _runningOwned, _diagnostics, _awaitingApproval, _approvalSent;
    NSString *_issuedID, *_panelFeature, *_localTool;
    BOOL _tables, _webLinks, _fileLinks, _codeOutput;
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
        _framePadding=PreferredAgentFramePadding();
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
    _codeOutput = [prefs boolForKey:CodeOutput];
    _screen->setCodeOutput(_codeOutput);
    _session.codeOutputEnabled = _codeOutput;
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
    record.raw = !record.raw; _anchor = _extent = -1; self.needsDisplay = YES;
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
    NSRect frame = NSMakeRect(right-width,[self topOfRow:y],width,_lh);
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
    NSDictionary *inlineStyles[3] = {}; // Primary, secondary, selection.
    NSDictionary *styles[3][2] = {}; // Truncation and non-ASCII layout.
};
- (CGFloat)listingWidth {
    if (!_listingActionWidth) {
        NSDictionary *style = @{NSFontAttributeName:_regular};
        _listingActionWidth = ceil([@"原始数据" sizeWithAttributes:style].width)+12;
        _listingReturnWidth = ceil([@"表格" sizeWithAttributes:style].width)+12;
    }
    return MAX(_cw,NSWidth(self.bounds)-insetX-_listingActionWidth-10);
}
- (BOOL)presentsListings {
    return _tables && !_screen->alternate && !_findBar.field.stringValue.length;
}
- (OutputReference *)listingForRow:(const Row &)row {
    uint32_t tag = row.empty() ? 0 : row.front().tag;
    if (!(tag & 3)) return nil;
    OutputReference *record = [_references record:tag];
    if ((tag & 3) == ExplicitLink) record = [_references record:record.parent];
    return (record.tag & 3) ? record : nil;
}
- (BOOL)loadListing:(OutputReference *)record atRow:(int)y point:(TextPoint)point cache:(PaintedLine &)cache {
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
    return cache.fields != nil;
}
- (NSRect)listingSelectionAtRow:(int)y {
    if (_anchor < 0 || _extent < 0 || _anchor == _extent) return NSZeroRect;
    int base = y*_screen->cols;
    int start = std::max(0,std::min(_anchor,_extent)-base);
    int end = std::min(_screen->cols,std::max(_anchor,_extent)-base+1);
    return end > start ? NSMakeRect(insetX+start*_cw,[self topOfRow:y],(end-start)*_cw,_lh) : NSZeroRect;
}
- (BOOL)drawListing:(OutputReference *)record atRow:(int)y cache:(PaintedLine &)cache header:(BOOL *)hasButton {
    TextPoint point = [self displayPoint:y];
    if (![self loadListing:record atRow:y point:point cache:cache]) return NO;
    BOOL first = cache.first == point.row && point.column == 0;
    if ((first && (cache.header || cache.atStart)) || y == 0) {
        const auto &row = [self displayRow:y];
        [self listingButton:record row:y rawWidth:insetX+MIN(row.used(),_screen->cols)*_cw];
        *hasButton = YES;
    }
    if (record.raw) return NO;

    const auto &palette = CurrentInterfacePalette();
    CGFloat top = [self topOfRow:y], pixel = 1/[self gridScale];
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
    NSRect selection = [self listingSelectionAtRow:y];
    NSColor *selectedInk = nil;
    if (!NSIsEmptyRect(selection)) {
        selection = NSIntersectionRect(selection,NSMakeRect(insetX,top,[self listingWidth],_lh));
        [selectionColor() setFill]; NSRectFill(selection);
        selectedInk = SchemeInk(PreferredColorScheme(),SchemeSelectedText);
    }
    for (int i=0;i<layout.count;++i) {
        auto col = layout.columns[i];
        if (col.band != lineBand) continue;
        NSRect r = NSMakeRect(col.x,top+_textOffsetY,col.width,_lh);
        NSString *value = cache.fields[i];
        if (!value.length) continue;
        bool secondary = cache.header || i != 0, right = resolved.widths[i] < 0;
        CGFloat advance = value.length*_cw;
        bool fits = advance <= col.width && [value canBeConvertedToEncoding:NSASCIIStringEncoding];
        auto draw = [&](NSDictionary *attrs) {
            if (fits) [value drawAtPoint:NSMakePoint(right ? NSMaxX(r)-advance : col.x,NSMinY(r)) withAttributes:attrs];
            else [value drawInRect:r withAttributes:attrs];
        };
        NSDictionary *attrs = fits ? cache.inlineStyles[secondary] : cache.styles[secondary][right];
        if (!selectedInk || NSMaxX(selection) <= col.x || NSMinX(selection) >= NSMaxX(r)) {
            draw(attrs); continue;
        }
        NSDictionary *__strong &selected = fits ? cache.inlineStyles[2] : cache.styles[2][right];
        if (!selected) {
            NSMutableDictionary *style = [attrs mutableCopy];
            style[NSForegroundColorAttributeName] = selectedInk; selected = style;
        }
        if (NSMinX(selection) <= col.x && NSMaxX(selection) >= NSMaxX(r)) {
            draw(selected); continue;
        }
        draw(attrs);
        [NSGraphicsContext saveGraphicsState]; NSRectClip(selection);
        draw(selected); [NSGraphicsContext restoreGraphicsState];
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
    std::vector<int>().swap(_frameEdges); _verticalGap=0;
    Row{}.swap(_fragment);
    [self clearListingButtons];
    for (auto &face : _faceAttributes) for (auto &attrs : face) attrs = nil;
    _screen->freeze();
}
- (void)wakeFromIdle {
    _wakeOnActivity = nil;
    _screen->thaw();
    if (_screen->hasAgentBlocks()) [self updateFrameSpacing];
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
    if (_lastCommand) [self updateFixButton];
    if (_agentProgress || _explanationProgress) [self observeProgress];
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
- (void)updateReviewKeys {
    NSString *confirm=ShortcutValue(ApproveKey)==Shortcut(ApproveKey).standard ? @"Enter" : ShortcutLabel(ApproveKey);
    NSString *stop=ShortcutValue(StopAgentKey)==Shortcut(StopAgentKey).standard ? @"Ctrl+C" : ShortcutLabel(StopAgentKey);
    [_session setReviewKeys:[NSString stringWithFormat:@"%@ / %@",confirm,stop] wake:_awaitingApproval];
}
- (void)preferenceChanged:(NSNotification *)note {
    if ([note.object isEqual:ShortcutPreferences]) {
        if (_lastCommand) [self updateFixButton];
        if (_session.agentInputID) [self updateReviewKeys];
        [_findBar refreshShortcuts]; return;
    }
    if ([note.object isEqual:AgentFramePadding]) {
        _framePadding=PreferredAgentFramePadding();
        if (!_wakeOnActivity && _screen->hasAgentBlocks()) { [self updateFrameSpacing]; self.needsDisplay=YES; }
        return;
    }
    if ([note.object isEqual:AgentPromptColor] || [note.object isEqual:AgentDirectoryColor]) {
        if (_session.agentInputID) [_session updateAgentPromptColor:PreferredAgentPromptColor() directoryColor:PreferredAgentDirectoryColor()
            wakeEditor:!_insideCommand && !_approvalSent && !_assistant.busy && _screen->bracketPaste && !_screen->alternate];
        return;
    }
    if ([note.object isEqual:PrettyTables] || [note.object isEqual:OpenWebLinks] || [note.object isEqual:RevealFileLinks] || [note.object isEqual:CodeOutput]) {
        _linkHitRect = NSZeroRect;
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
        if (![TerminalPreferences() boolForKey:AIErrorExplanations]) [self clearLastCommand];
        [self configureCommandTracking]; return;
    }
    if ([note.object isEqual:TerminalColorScheme]) { [_findBar applyPalette]; _fixButton.contentTintColor=CurrentInterfacePalette().accent; [self refreshExplanation]; self.needsDisplay = YES; }
    if ([note.object isEqual:TerminalFontSize]) [self adjustFont:0];
    if ([note.object isEqual:TerminalFontFamily] || [note.object isEqual:TerminalFontWeight]) [self applyFontChange];
    if ([note.object isEqual:ScrollbackLines]) {
        if (_wakeOnActivity) [self wakeForActivity];
        _screen->setHistoryLimit(PreferredScrollbackLines());
        int64_t offset = std::min(_offset, _screen->historySize());
        if (offset != _offset) {
            _offset = offset; _topColumn = 0; _visibleRows.clear(); [self updateFrameSpacing]; _anchor = _extent = -1; self.needsDisplay = YES;
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
        bool parseError=!identifier.empty() && identifier.front()=='!';
        if (parseError) identifier.remove_prefix(1);
        v->_commandSerial=0;
        if (!identifier.empty()) {
            uint64_t serial=0;
            auto end=identifier.data()+identifier.size();
            auto parsed=std::from_chars(identifier.data(),end,serial);
            if (parsed.ec==std::errc() && parsed.ptr==end) v->_commandSerial=serial;
        }
        v->_insideCommand=YES; v->_approvalSent=NO;
        v->_runningOwned=v->_issuedID && identifier==(v->_issuedID.UTF8String ?: "");
        if (v->_runningOwned) v->_screen->beginAgentOutput(); else v->_screen->endAgentBlock();
        v->_commandGeneration=v->_screen->historyGeneration;
        v->_commandRow=v->_screen->historySize()+v->_screen->y(); v->_commandColumn=v->_screen->x();
        // A rejected line never ran. Its parser diagnostic is immediately above precmd.
        if (parseError && v->_commandRow>0 && !v->_commandColumn) --v->_commandRow;
        if (v->_lastCommand) [v clearLastCommand];
    };
    _screen->promptReturned=[weak](int status,std::string_view line) { [weak promptReturned:status line:line]; };
    _screen->inputAccepted=[weak](std::string_view idBytes,bool accepted) {
        TerminalView *v=weak; if (!v) return;
        NSString *identifier=[[NSString alloc] initWithBytes:idBytes.data() length:idBytes.size() encoding:NSASCIIStringEncoding];
        if (accepted && [v->_issuedID isEqual:identifier]) v->_screen->beginAgentEcho();
        [v->_session acknowledgeLine:identifier accepted:accepted];
    };
}
- (void)clearLastCommand {
    [_diagnosis cancel]; _diagnosis=nil;
    if (_fixState==SendingExplanation) [_session discardPendingLine];
    _lastCommand=nil;
    [self finishExplanation];
}
- (BOOL)hasFailedCommand { return _showFailureChip; }
- (NSString *)explanationActionTitle {
    if (!_lastCommand || _fixState==SendingExplanation) return nil;
    return _fixState==AnalyzingError ? @"取消分析" : explanationTitles[_fixState];
}
- (void)promptReturned:(int)status line:(std::string_view)line {
    uint16_t outputStamp=_screen->agentOutputStamp();
    // Syntax errors return to precmd without ever calling preexec.
    BOOL owned=_runningOwned || (!_insideCommand && _issuedID && outputStamp);
    BOOL began=_insideCommand || owned;
    _screen->endAgentBlock();
    _insideCommand=_runningOwned=_approvalSent=NO;
    if (owned) _issuedID=nil;
    BOOL awaiting=owned && _assistant.expectedCommand!=nil;
    BOOL explainable=_diagnostics && !_assistant && _commandSerial && !line.empty();
    if (!began || (!awaiting && !explainable)) return;
    BOOL failed=explainable && status!=0 && status!=130 && status!=128+SIGTSTP;
    NSString *command=awaiting ? _assistant.expectedCommand :
        [[NSString alloc] initWithBytes:line.data() length:line.size() encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray *rows=[NSMutableArray array];
    TextPoint anchor{-1,0};
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
            int last=index==end ? std::min(_screen->x(),(int)row.size()) : std::min<int>(row.written,row.size());
            int first=_commandGeneration==_screen->historyGeneration && index==_commandRow && !outputStamp ? std::min(last,_commandColumn) : 0;
            last=textEnd(row,first,last);
            if (failed && anchor.row<0 && last>first) anchor={index,last-1};
            NSString *text=cellText(row,first,last,false);
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
    if (explainable) {
        _lastCommand=record;
        _promptStart=_screen->historySize()+_screen->y();
    }
    if (failed) {
        // A silent failure belongs to the echoed command. The start may have scrolled
        // away with history disabled, or moved when the user resized the pane.
        if (anchor.row<0) {
            int64_t cursor=_screen->historySize()+_screen->y();
            for (int64_t index=cursor; index>=std::max<int64_t>(0,cursor-24); --index) {
                const Row &row=_screen->lineAt(index);
                int limit=index==cursor ? _screen->x() : row.written;
                int end=textEnd(row,0,std::min(limit,(int)row.size()));
                if (end) { anchor={index,end-1}; break; }
            }
        }
        if (anchor.row>=0) {
            const Row &row=_screen->lineAt(anchor.row);
            if (anchor.column>0 && !row[anchor.column].width) --anchor.column;
            _failureGlyph=row[anchor.column];
        }
        _screen->failureCell=anchor; _showFailureChip=YES;
        [self setFixState:ExplainCommand];
    }
}
- (void)setFixState:(FixState)state {
    _fixState=state; [self updateFixButton];
}
- (void)updateFixButton {
    if (!self.window || !self.hasFailedCommand) { [_fixButton removeFromSuperview]; _fixButton=nil; return; }
    if (!_fixButton) {
        _fixButton=[NSButton buttonWithTitle:@"" target:self action:@selector(explainFailure:)];
        _fixButton.bordered=NO; _fixButton.controlSize=NSControlSizeSmall;
        _fixButton.font=[NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        _fixButton.imagePosition=NSImageLeading;
        _fixButton.symbolConfiguration=[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
        _fixButton.contentTintColor=CurrentInterfacePalette().accent;
        [self addSubview:_fixButton];
    }
    static NSString *const icons[]={@"text.magnifyingglass",@"stop.circle",@"ellipsis",@"arrow.clockwise",@"slider.horizontal.3",@"arrow.clockwise",@"doc.on.doc"};
    FixState state=_fixState;
    _fixButton.title=explanationTitles[state];
    _fixButton.image=[NSImage imageWithSystemSymbolName:icons[state] accessibilityDescription:nil];
    _fixButton.toolTip=ShortcutTip(state==AnalyzingError ? @"取消分析" : explanationTitles[state],ExplainKey);
    [_fixButton setAccessibilityLabel:_fixButton.toolTip];
    _fixButton.enabled=state!=SendingExplanation;
    _fixButton.imagePosition=NSImageLeading;
    [_fixButton sizeToFit]; _fixLabelWidth=NSWidth(_fixButton.frame);
    [self positionFixButton];
}
// Scrollback can present a single stored row as several visible fragments.
- (int)displayRowForCell:(TextPoint)cell localColumn:(int *)column {
    if (cell.row<0 || cell.row>=_screen->historySize()+_screen->height) return -1;
    if (!_offset) {
        *column=cell.column;
        int64_t y=cell.row-_screen->historySize();
        return y>=0 ? (int)y : -1;
    }
    TextPoint top=[self displayPoint:0];
    if (cell.row<top.row || cell.row>=top.row+_screen->height) return -1;
    int fragment=fragmentStart(_screen->lineAt(cell.row),cell.column,_screen->cols);
    for (int y=0; y<_screen->height; ++y) {
        TextPoint p=[self displayPoint:y];
        if (p.row>cell.row || (p.row==cell.row && p.column>fragment)) break;
        if (p.row==cell.row && p.column==fragment) {
            *column=cell.column-fragment; return y;
        }
    }
    return -1;
}
- (void)positionFixButton {
    if (!_fixButton) return;
    int col=0, y=-1;
    if (!_wakeOnActivity && !_screen->alternate && !_assistant && !_ended && _offset<=_screen->historySize()) {
        if (_fixState==CopySuggestion) {
            if (!_offset) {
                y=_screen->y(); const Row &row=_screen->row(y);
                col=std::max(textEnd(row,0,row.written),_screen->x()+1);
            }
        } else {
            y=[self displayRowForCell:_screen->failureCell localColumn:&col];
            if (y>=0) {
                const Row &row=[self displayRow:y];
                if (col>=(int)row.size() || row[col].ch!=_failureGlyph.ch ||
                    row[col].mark!=_failureGlyph.mark || row[col].width!=_failureGlyph.width) y=-1;
                else {
                    col+=row[col].width;
                    // If another writer filled the rest of the line, use its gutter.
                    if (textEnd(row,0,row.written)>col || (!_offset && y==_screen->y() && _screen->x()>=col)) col=-1;
                }
            }
        }
    }
    if (y>=0) {
        CGFloat end=[self textOriginForRow:y]+col*_cw, right=NSWidth(self.bounds);
        bool compact=col<0 || end+6+_fixLabelWidth>right-2;
        CGFloat width=compact ? insetX : _fixLabelWidth;
        CGFloat x=col<0 || end+width>right ? 0 : MIN(end+6,right-width);
        NSRect frame=NSMakeRect(floor(x),floor([self topOfRow:y]),width,_lh);
        if (!_findBar || !NSIntersectsRect(frame,_findBar.frame)) {
            NSCellImagePosition position=compact ? NSImageOnly : NSImageLeading;
            if (_fixButton.imagePosition!=position) _fixButton.imagePosition=position;
            if (!NSEqualRects(frame,_fixButton.frame)) _fixButton.frame=frame;
            _fixButton.hidden=NO; return;
        }
    }
    _fixButton.hidden=YES;
}
- (BOOL)assistantVisible { return _assistant!=nil; }
- (void)positionAgentProgress {
    const int row=_screen->y(), col=_screen->x();
    CGFloat x=NSWidth(self.bounds)-15;
    int visibleRow=row;
    if (_offset) visibleRow=0;
    else if (!_screen->alternate && col+3 < _screen->cols && col >= _screen->row(row).written)
        x=[self textOriginForRow:row]+col*_cw+5;
    NSPoint origin=NSMakePoint(floor(x),floor([self topOfRow:visibleRow]+(_lh-14)/2));
    if (!NSEqualPoints(_agentProgress.frame.origin,origin)) [_agentProgress setFrameOrigin:origin];
}
- (void)updateProgressAnimation:(NSNotification *)note {
    NSProgressIndicator *progress=_agentProgress ?: _explanationProgress;
    if ((self.window.occlusionState & NSWindowOcclusionStateVisible) && !progress.hiddenOrHasHiddenAncestor &&
        !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) [progress startAnimation:nil];
    else [progress stopAnimation:nil];
}
- (void)observeProgress {
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    if (self.window) [center addObserver:self selector:@selector(updateProgressAnimation:)
                                    name:NSWindowDidChangeOcclusionStateNotification object:self.window];
    [self updateProgressAnimation:nil];
}
- (NSProgressIndicator *)newProgressWithLabel:(NSString *)label {
    NSProgressIndicator *progress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0,0,14,14)];
    progress.style=NSProgressIndicatorStyleSpinning; progress.controlSize=NSControlSizeSmall;
    progress.indeterminate=YES; progress.displayedWhenStopped=YES;
    [progress setAccessibilityLabel:label];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(updateProgressAnimation:)
        name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    return progress;
}
- (void)removeProgress:(NSProgressIndicator *)progress {
    if (!progress) return;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    [progress stopAnimation:nil]; [progress removeFromSuperview];
}
- (void)setAgentBusy:(BOOL)busy {
    if (busy==(_agentProgress!=nil)) return;
    if (busy) {
        _agentProgress=[self newProgressWithLabel:@"Agent 运行中"];
        [self positionAgentProgress]; [self addSubview:_agentProgress]; [self observeProgress];
    } else {
        [self removeProgress:_agentProgress]; _agentProgress=nil;
    }
}
- (BOOL)builtInAgentVisible { return self.assistantVisible && [_panelFeature isEqual:BuiltInAgent]; }
- (void)closeAssistant {
    if (!_assistant) return;
    [_session endAgentInput:!_insideCommand && !_screen->alternate && _screen->bracketPaste];
    _screen->agentEditor={}; _agentResult=nil;
    [_assistant cancel]; _assistant=nil; _panelFeature=nil; _localTool=nil;
    [self configureCommandTracking];
    [self positionFixButton];
    if (_assistantVisibilityChanged) _assistantVisibilityChanged();
}
- (TerminalAssistant *)openAssistantFor:(NSString *)feature tool:(NSString *)tool {
    if (![TerminalPreferences() boolForKey:feature]) return nil;
    if (_ended || _insideCommand || _screen->alternate || !_screen->bracketPaste || ![_session shellIsForeground]) {
        NSBeep(); return nil;
    }
    if (_assistant && (![_panelFeature isEqual:feature] || (tool && ![tool isEqual:_localTool]))) [self closeAssistant];
    if (!_assistant) {
        [self clearLastCommand];
        _panelFeature=feature; _localTool=[tool copy];
        _assistant=[[TerminalAssistant alloc] initWithDirectory:_session.workingDirectory shell:_session.shellName];
        _assistant.localTool=tool;
        [self configureCommandTracking];
        __weak TerminalView *weak=self;
        _assistant.currentDirectory=^NSString *{ return weak.workingDirectory; };
        _assistant.onClose=^{ TerminalView *v=weak; [v closeAssistant]; [v.window makeFirstResponder:v]; };
        _assistant.onConfigure=^{ TerminalView *v=weak; if (v.configureAI) v.configureAI(); };
        _assistant.onShellLine=^BOOL(NSString *command) {
            TerminalView *v=weak;
            if (!v || v->_insideCommand || v->_ended || v->_screen->alternate || !v->_screen->bracketPaste) return NO;
            NSString *identifier=[v->_session submitLine:command execute:YES acknowledged:^(BOOL accepted) {
                TerminalView *pane=weak;
                if (!pane) return;
                if (!accepted) pane->_issuedID=nil;
                [pane->_assistant lineAcknowledged:accepted];
            }];
            if (identifier) v->_issuedID=identifier;
            return identifier!=nil;
        };
        _assistant.onStop=^{
            TerminalView *v=weak; if (!v) return;
            [v->_session discardPendingLine];
            if (v->_issuedID && !v->_insideCommand) { v->_screen->endAgentBlock(); v.needsDisplay=YES; }
            v->_issuedID=nil; v->_awaitingApproval=NO;
            if (v->_runningOwned || v->_approvalSent) {
                [v->_session sendBytes:"\003" length:1]; v->_runningOwned=v->_approvalSent=NO;
            }
        };
        _assistant.onComplete=^(NSString *summary, BOOL failed) {
            TerminalView *v=weak; if (v.agentFinished) v.agentFinished(v,v->_localTool ?: @"Agent",failed,summary);
        };
        _assistant.onActivity=^(BOOL busy) { [weak setAgentBusy:busy]; };
        _assistant.onPreview=^(NSString *text) {
            TerminalView *v=weak;
            if (v && !v->_insideCommand && !v->_issuedID && v->_screen->bracketPaste && !v->_screen->alternate)
                [v->_session previewAgentText:text];
        };
        _assistant.onTranscript=^(NSString *text) {
            TerminalView *v=weak;
            if (v) [v->_session postAgentText:text finished:!v->_assistant.busy wakeEditor:!v->_insideCommand && v->_screen->bracketPaste && !v->_screen->alternate];
        };
        _screen->agentEditor=[weak](std::string_view bytes,std::string_view event) {
            TerminalView *v=weak; if (!v) return;
            NSString *identifier=[[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSASCIIStringEncoding];
            if (event=="review") {
                if ([v->_issuedID isEqual:identifier] && v->_assistant.expectedCommand) {
                    v->_awaitingApproval=YES; [v setAgentBusy:NO];
                }
                return;
            }
            if (![v->_session.agentInputID isEqual:identifier]) return;
            if (event=="ready") {
                [v->_session agentInputReady:identifier];
                NSDictionary *result=v->_agentResult; v->_agentResult=nil;
                if (result) [v->_assistant receivedResult:result];
            } else if (event=="task") {
                NSString *task=[v->_session takeAgentTask:identifier];
                if (task) [v->_assistant submitTask:task];
                else [v->_session postAgentText:@"未能读取任务，请重试。" finished:YES wakeEditor:YES];
            } else if (event=="cancel") {
                if (v->_assistant.busy) [v->_assistant submitTask:@"/stop"];
            } else dispatch_async(dispatch_get_main_queue(),^{
                if ([v->_session.agentInputID isEqual:identifier]) [v closeAssistant];
            });
        };
        if (![_session beginAgentInputWithColor:PreferredAgentPromptColor() directoryColor:PreferredAgentDirectoryColor() ready:^(BOOL ready) {
            if (!ready) { [weak closeAssistant]; NSBeep(); }
        }]) { [self closeAssistant]; NSBeep(); return nil; }
        [self updateReviewKeys];
        [self.window makeFirstResponder:self];
    }
    if (_didFocus) _didFocus(self);
    if (_assistantVisibilityChanged) _assistantVisibilityChanged();
    return _assistant;
}
- (void)toggleAssistant:(id)sender {
    if (![TerminalPreferences() boolForKey:BuiltInAgent]) return;
    if (_assistant) { [self closeAssistant]; return; }
    [self openAssistantFor:BuiltInAgent tool:nil];
}
// Insert a temporary block before the editable prompt in view coordinates. Only the
// accepted final result enters ZLE and scrollback; streaming never resizes the PTY.
- (void)positionExplanation {
    BOOL hidden=_offset || _screen->alternate;
    if (_explanationLabel.hidden!=hidden) {
        _explanationLabel.hidden=hidden;
        if (_explanationProgress) [self updateProgressAnimation:nil];
    }
    if (hidden) { _previewGap=_previewShift=0; return; }
    int64_t start=_promptStart-_screen->historySize();
    if (_showFailureChip && _screen->failureCell.row>=0)
        start=_screen->failureCell.row+1-_screen->historySize();
    _previewRow=(int)std::clamp<int64_t>(start,0,_screen->y());
    NSSize size=_explanationLabel.frame.size;
    _previewGap=ceil(size.height/_lh)*_lh+_lh;
    _previewShift=MAX(0,(_screen->y()+1-_screen->height)*_lh+_previewGap);
    NSPoint origin=NSMakePoint(insetX-2,[self gridTopOfRow:_previewRow]-_previewShift);
    if (!NSEqualPoints(origin,_explanationLabel.frame.origin)) [_explanationLabel setFrameOrigin:origin];
}
- (void)refreshExplanation {
    if (!_explanationLabel) return;
    CGFloat oldGap=_previewGap, oldShift=_previewShift;
    NSString *title=@"命令解释";
    NSString *line=[NSString stringWithFormat:@"%@  %@",title,_explanation ?: @""];
    NSMutableParagraphStyle *style=[[NSMutableParagraphStyle alloc] init];
    style.minimumLineHeight=style.maximumLineHeight=_lh; style.lineBreakMode=NSLineBreakByCharWrapping;
    NSMutableAttributedString *rich=[[NSMutableAttributedString alloc] initWithString:line attributes:@{
        NSFontAttributeName:_regular, NSForegroundColorAttributeName:foreground(), NSParagraphStyleAttributeName:style}];
    NSRange header=NSMakeRange(0,title.length);
    NSDictionary *face=[self attributesForFace:1 underlined:NO];
    [rich addAttributes:face range:header];
    // Each CJK title glyph occupies two cells in the committed shell transcript.
    CGFloat tracking=2*_cw-[title sizeWithAttributes:face].width/title.length;
    [rich addAttribute:NSKernAttributeName value:@(tracking) range:header];
    [rich addAttribute:NSForegroundColorAttributeName value:TerminalIndexedColor(PreferredColorScheme(),4) range:header];
    _explanationLabel.attributedStringValue=rich;
    CGFloat width=MAX(1,NSWidth(self.bounds)-2*insetX+4);
    CGFloat height=[_explanationLabel.cell cellSizeForBounds:NSMakeRect(0,0,width,CGFLOAT_MAX)].height;
    CGFloat visible=MAX(1,_screen->height-3)*_lh;
    _explanationLabel.contentHeight=height;
    [_explanationLabel setFrameSize:NSMakeSize(width,std::clamp(height,_lh,visible))];
    if (_explanationProgress) {
        CGFloat x=MIN(width-14,ceil(rich.size.width)+2);
        [_explanationProgress setFrameOrigin:NSMakePoint(MAX(0,x),MAX(0,(_lh-14)/2))];
    }
    [self positionExplanation];
    if (oldGap!=_previewGap || oldShift!=_previewShift) self.needsDisplay=YES;
}
- (void)showExplanationPreview:(NSString *)text {
    if (!_explanationLabel) {
        _explanationLabel=[ExplanationLabel wrappingLabelWithString:@""];
        _explanationLabel.lineBreakMode=NSLineBreakByCharWrapping;
        [self addSubview:_explanationLabel positioned:NSWindowBelow relativeTo:nil];
    }
    NSString *body=text ? TerminalTranscriptText(text) : nil;
    if (body && [_explanation isEqual:body]) return;
    _explanation=body;
    if (!text && !_explanationProgress) {
        _explanationProgress=[self newProgressWithLabel:@"正在获取命令解释"];
        [_explanationLabel addSubview:_explanationProgress]; [self observeProgress];
    } else if (text && _explanationProgress) {
        [self removeProgress:_explanationProgress]; _explanationProgress=nil;
    }
    if (self.window) [self refreshExplanation];
}
- (void)removeExplanationPreview {
    if (!_explanationLabel) return;
    [self removeProgress:_explanationProgress]; _explanationProgress=nil;
    [_explanationLabel removeFromSuperview]; _explanationLabel=nil;
    _previewGap=_previewShift=0; self.needsDisplay=YES;
}
- (void)finishExplanation {
    [self removeExplanationPreview];
    _showFailureChip=NO; _screen->failureCell={-1,0};
    _fixState=ExplainCommand; _explanation=nil; _suggestion=nil;
    [_fixButton removeFromSuperview]; _fixButton=nil;
}
- (void)deliverExplanation {
    __weak TerminalView *weak=self;
    [self setFixState:SendingExplanation];
    BOOL sent=!_insideCommand && !_screen->alternate && _screen->bracketPaste &&
        [_session showDiagnosis:_explanation suggestion:_suggestion sequence:_commandSerial acknowledged:^(BOOL shown) {
            TerminalView *pane=weak;
            if (!pane || pane->_fixState!=SendingExplanation) return;
            if (!shown) { [pane setFixState:ShowExplanationAgain]; return; }
            [pane removeExplanationPreview]; pane->_explanation=nil;
            if (pane->_suggestion.length) [pane setFixState:CopySuggestion];
            else [pane finishExplanation];
        }];
    if (!sent) [self setFixState:ShowExplanationAgain];
}
- (void)explainFailure:(id)sender {
    if (!_lastCommand || _assistant || _ended || !_diagnostics) return;
    [self.window makeFirstResponder:self];
    switch (_fixState) {
        case AnalyzingError:
            [self removeExplanationPreview]; _explanation=nil;
            [_diagnosis cancel]; _diagnosis=nil; [self setFixState:ExplainCommand]; return;
        case ConfigureDiagnosis:
            [self setFixState:RetryDiagnosis]; if (_configureAI) _configureAI(); return;
        case CopySuggestion:
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:_suggestion forType:NSPasteboardTypeString];
            [self finishExplanation]; return;
        case ShowExplanationAgain: [self deliverExplanation]; return;
        case SendingExplanation: return;
        default: break;
    }
    [self setFixState:AnalyzingError];
    if (_offset) { _offset=0; _topColumn=0; _visibleRows.clear(); [self updateFrameSpacing]; }
    [self showExplanationPreview:nil];
    _diagnosis=[[TerminalAssistant alloc] initWithDirectory:_session.workingDirectory shell:_session.shellName];
    __weak TerminalView *weak=self;
    _diagnosis.onPreview=^(NSString *reason) { [weak showExplanationPreview:reason]; };
    _diagnosis.onDiagnosis=^(NSString *text, NSString *command, DiagnosisFollowUp followUp) {
        TerminalView *pane=weak; if (!pane) return;
        NSString *reason=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [pane showExplanationPreview:reason.length ? reason : @"可尝试下面的命令。"];
        pane->_suggestion=command; pane->_diagnosis=nil;
        if (followUp==DiagnosisDone) [pane deliverExplanation];
        else [pane setFixState:followUp==DiagnosisConfigure ? ConfigureDiagnosis : RetryDiagnosis];
    };
    [_diagnosis explain:_lastCommand];
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
    _ended = YES; [self clearLastCommand]; [self closeAssistant]; _sessionTitle = message;
    NSString *line = [NSString stringWithFormat:@"\r\n\033[0m[%@]\r\n",message];
    [self consume:std::string_view(line.UTF8String)];
    if (_didRename) _didRename(self);
}
- (void)stop { [self clearLastCommand]; [_assistant cancel]; [_session close]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; if (_screen && _cw) [self sizeTerminal]; }
- (void)sizeTerminal {
    int w = std::clamp((int)((self.bounds.size.width-2*insetX)/_cw),2,1000);
    int h = std::clamp((int)((self.bounds.size.height-2*insetY)/_lh),1,500);
    if (w == _screen->cols && h == _screen->height) {
        if (_findBar && !_wakeOnActivity) [self positionFindBar];
        if (_explanationLabel) [self refreshExplanation];
        return;
    }
    if (_wakeOnActivity) [self wakeForActivity];
    [self clearListingButtons];
    _screen->resize(w,h); [_session resizeCols:w rows:h];
    if (_explanationLabel) [self refreshExplanation];
    _offset = 0; _topColumn = 0; _visibleRows.clear(); [self updateFrameSpacing];
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
    if (reset || !historyOnly) {
        _visibleRows.clear();
        if (_screen->hasAgentBlocks() && (_screen->agentOutputStamp() || !_frameEdges.empty() || full || before!=_screen->linesScrolled))
            full |= [self updateFrameSpacing];
    }
    if (_explanationLabel) { [self positionExplanation]; full=YES; }
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
        [self setNeedsDisplayInRect:NSMakeRect(0,[self topOfRow:first]-_verticalGap,self.bounds.size.width,[self topOfRow:last]-[self topOfRow:first]+_lh+2*_verticalGap)];
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
    if ((int)row.size() <= _screen->cols && (!row.codeLine || row.written <= _screen->cols-codeGutterColumns(row.codeLine,_screen->cols))) return row;
    int end = fragmentEnd(row,p.column,_screen->cols);
    _fragment.assign(row.begin()+p.column,row.begin()+end);
    _fragment.agentStamp = row.agentStamp;
    _fragment.codeLine = p.column && row.codeLine ? CodeContinuation | row.codeLine : row.codeLine;
    _fragment.written = end-p.column;
    _fragment.wrapAt = (end < row.used() || row.wrapAt) ? end-p.column : 0;
    return _fragment;
}
- (CGFloat)textOriginForRow:(int)y {
    return textOrigin(_codeOutput ? codeGutterColumns([self displayRow:y].codeLine,_screen->cols) : 0,_cw);
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
    if (_codeOutput && row.codeLine) end = std::min(end,_screen->cols-codeGutterColumns(row.codeLine,_screen->cols));
    if (end <= start) return {};
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
// Share the pane's existing vertical margins across block edges. PTY rows,
// glyph metrics and stored scrollback remain identical at every padding setting.
- (BOOL)updateFrameSpacing {
    int edges[501], count=0; // sizeTerminal caps the viewport at 500 rows.
    if (_framePadding && _screen->hasAgentBlocks()) {
        if (_screen->alternate) {
            if (_screen->agentOutputStamp()) { edges[count++]=0; edges[count++]=_screen->height; }
        } else {
            BOOL previous=[self isAgentRow:-1];
            for (int row=0; row<=_screen->height; ++row) {
                BOOL framed=[self isAgentRow:row];
                if (framed!=previous) edges[count++]=row;
                previous=framed;
            }
        }
    }
    CGFloat gap=count ? MIN(_framePadding,floor((2*insetY-2)/count)) : 0;
    if (gap==_verticalGap && count==(int)_frameEdges.size() && std::equal(edges,edges+count,_frameEdges.begin())) return NO;
    _frameEdges.assign(edges,edges+count); _verticalGap=gap; _linkHitRect=NSZeroRect;
    return YES;
}
- (CGFloat)topOfRow:(int)row {
    CGFloat top=insetY+row*_lh;
    if (_previewGap) top+=(row>=_previewRow ? _previewGap : 0)-_previewShift;
    if (!_verticalGap) return top;
    auto before=std::upper_bound(_frameEdges.begin(),_frameEdges.end(),row)-_frameEdges.begin();
    return top+before*_verticalGap-floor(_frameEdges.size()*_verticalGap/2);
}
- (CGFloat)gridTopOfRow:(int)row {
    return [self topOfRow:row]-(row>=_previewRow ? _previewGap : 0)+_previewShift;
}
- (int)rowAtY:(CGFloat)y {
    CGFloat gridY=y+_previewShift;
    if (_previewGap && gridY>=[self gridTopOfRow:_previewRow])
        gridY=MAX([self gridTopOfRow:_previewRow],gridY-_previewGap);
    int row=std::clamp((int)floor((gridY-insetY)/_lh),0,_screen->height-1);
    if (_verticalGap) {
        while (row>0 && y<[self topOfRow:row]) --row;
        while (row+1<_screen->height && y>=[self topOfRow:row+1]) ++row;
    }
    return row;
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
        CGFloat top=[self topOfRow:start]-(above ? 0 : _verticalGap);
        CGFloat bottom=[self topOfRow:y-1]+_lh+(below ? 0 : _verticalGap);
        NSRect clip=NSMakeRect(0,top,NSWidth(self.bounds),bottom-top);
        CGFloat side=MAX(2.,insetX-(_framePadding ? _framePadding+4 : 1));
        NSRect box=NSInsetRect(clip,side+pixel/2,pixel/2);
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
    if (_explanationLabel) [self positionExplanation];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!_usesBackdrop) { [TerminalBackground() setFill]; NSRectFill(dirty); }
    int first = MAX(0,[self rowAtY:NSMinY(dirty)]-(_verticalGap>0));
    int end = MIN(_screen->height,[self rowAtY:NSMaxY(dirty)]+1+(_verticalGap>0));
    PaintedLine listingCache;
    BOOL present = [self presentsListings];
    BOOL framed = _screen->agentOutputStamp()!=0;
    NSDictionary *gutterAttributes = nil;
    for (int y = first; y < end; ++y) {
        BOOL header = NO, drawn = NO;
        const Row *source = &[self displayRow:y];
        if (source->agentStamp) framed=YES;
        if (present) {
            OutputReference *record = [self listingForRow:*source];
            if (record) {
                drawn = [self drawListing:record atRow:y cache:listingCache header:&header];
                // Reading a wrapped listing can replace the archive's transient row.
                if (!drawn && _offset) source = &[self displayRow:y];
            }
        }
        if (_listingButtons && !header) {
            [_listingButtons[@(y)] removeFromSuperview]; [_listingButtons removeObjectForKey:@(y)];
            if (!_listingButtons.count) _listingButtons = nil;
        }
        if (drawn) continue;
        const auto &row = *source;
        CGFloat py = [self topOfRow:y];
        int gutter = _codeOutput ? codeGutterColumns(row.codeLine,_screen->cols) : 0;
        int count = std::min((int)row.size(),_screen->cols-gutter);
        CGFloat origin = textOrigin(gutter,_cw);
        if (gutter && !(row.codeLine & CodeContinuation)) {
            if (!gutterAttributes) gutterAttributes = @{NSFontAttributeName:_regular,NSLigatureAttributeName:@0,
                NSForegroundColorAttributeName:CurrentInterfacePalette().secondaryText};
            NSString *label = [@(row.codeLine) stringValue];
            CGFloat labelX = insetX + (gutter-1-(CGFloat)label.length)*_cw;
            [label drawAtPoint:NSMakePoint(labelX,py+_textOffsetY) withAttributes:gutterAttributes];
        }

        // Paint backgrounds independently of glyph shaping, then overlay the selection once.
        for (int x = 0; x < count;) {
            int color = backgroundCode(row[x].style);
            int next = x+1;
            while (next < count && backgroundCode(row[next].style) == color) ++next;
            if (color != Default) {
                NSColor *bg = color == defaultInk ? foreground() : resolve(color,TerminalBackground());
                [bg setFill]; fillGridRect(ctx,NSMakeRect(origin+x*_cw,py,(next-x)*_cw,_lh));
            }
            x = next;
        }

        NSRange found = _findHit ? [self findColumnsInRow:y] : NSMakeRange(0,0);
        if (found.length) {
            [CurrentInterfacePalette().findFill setFill];
            fillGridRect(ctx,NSMakeRect(origin+found.location*_cw,py,found.length*_cw,_lh));
        }
        NSRange selected = _anchor < 0 ? NSMakeRange(0,0) : [self selectedColumnsInRow:y];
        NSColor *selectedInk = nil;
        if (selected.length) {
            selectedInk = SchemeInk(PreferredColorScheme(),SchemeSelectedText);
            [selectionColor() setFill];
            fillGridRect(ctx,NSMakeRect(origin+selected.location*_cw,py,selected.length*_cw,_lh));
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
            int ink = cell.style.fg;
            NSColor *fg;
            if (cell.style.flags & Inverse) fg = resolve(cell.style.bg,TerminalBackground());
            else if (ink < CodeColor) fg = resolve(ink,foreground());
            else if (!_codeOutput) fg = foreground();
            else fg = ink == CodeMuted ? CurrentInterfacePalette().secondaryText : TerminalIndexedColor(PreferredColorScheme(),ink-CodeColor);
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
            NSRect rect = NSMakeRect(origin+x*_cw,py,(next-x)*_cw,_lh);
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
    if (_fixButton) [self positionFixButton];
    if (_agentProgress) [self positionAgentProgress];
    if (!_offset && !_ended && self.window.firstResponder == self && (_screen->cursorVisible || _marked.length)) {
        CGFloat x = [self textOriginForRow:_screen->y()]+_screen->x()*_cw, y = [self topOfRow:_screen->y()];
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
    int y = [self rowAtY:p.y];
    return y*_screen->cols + std::clamp((int)((p.x-[self textOriginForRow:y])/_cw),0,_screen->cols-1);
}
- (NSURL *)linkAtPoint:(NSPoint)p {
    return [self linkAtPoint:p stableRect:nullptr];
}
- (NSURL *)linkAtPoint:(NSPoint)p stableRect:(NSRect *)stable {
    if (stable) *stable = NSZeroRect;
    if (!_webLinks && !_fileLinks) return nil;
    int y=[self rowAtY:p.y];
    const auto &row = [self displayRow:y];
    int gutter = _codeOutput ? codeGutterColumns(row.codeLine,_screen->cols) : 0;
    CGFloat origin = textOrigin(gutter,_cw);
    if (!NSPointInRect(p,NSMakeRect(origin,[self topOfRow:y],(_screen->cols-gutter)*_cw,_lh))) return nil;
    int x = int((p.x-origin)/_cw);
    TextPoint start = [self displayPoint:y], point = {start.row,start.column+x};
    uint32_t leading = row.empty() ? 0 : row.front().tag;
    uint32_t tag = x < (int)row.size() ? row[x].tag : 0;
    OutputReference *rec = [_references record:tag];
    OutputReference *block = [_references record:leading];
    if ((leading & 3) == ExplicitLink) block = [_references record:block.parent];
    BOOL files = block && (block.tag & 3) == FileListing;
    BOOL pretty = [self presentsListings] && (block.tag & 3) && !block.raw;
    // Plain output has one hit target per grid cell. Table column edges can fall between cells.
    if (stable && !pretty) *stable = NSMakeRect(origin+x*_cw,[self topOfRow:y],_cw,_lh);
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
                NSRect nameRect = NSMakeRect(column.x,[self topOfRow:y],column.width,_lh);
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
                if (stable) *stable = NSMakeRect(col.x,[self topOfRow:y],col.width,_lh);
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
    int row=[self rowAtY:point.y];
    CGFloat x = std::clamp(point.x-[self textOriginForRow:row],0.,_screen->cols*_cw-1);
    CGFloat y=row*_lh+std::clamp(point.y-[self topOfRow:row],0.,_lh-1);
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
    int next = [self indexAt:event];
    if (_anchor < 0 || next == _extent) return;
    CGFloat top = [self topOfRow:std::min(_extent,next)/_screen->cols];
    CGFloat bottom = [self topOfRow:std::max(_extent,next)/_screen->cols]+_lh;
    _extent = next;
    [self setNeedsDisplayInRect:NSMakeRect(0,top,NSWidth(self.bounds),bottom-top)];
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
    _offset = _screen->historySize()-top.row; _topColumn = top.column; _visibleRows.clear(); [self updateFrameSpacing];
    _anchor = _extent = -1; self.needsDisplay = YES;
}
// Translate a visual selection back into the field being displayed. Only partially
// selected non-ASCII fields need shaping, and only when copying.
static NSString *selectedFieldText(NSString *value, ListingLayout::Column col, bool rightAligned,
                                   NSRect selection, CGFloat cw, NSFont *font) {
    CGFloat left = MAX(NSMinX(selection),col.x)-col.x;
    CGFloat right = MIN(NSMaxX(selection),col.x+col.width)-col.x;
    if (right <= left) return nil;
    if (left == 0 && right >= col.width) return value;
    bool ascii = [value canBeConvertedToEncoding:NSASCIIStringEncoding];
    CTLineRef line = nullptr;
    CGFloat width = value.length*cw;
    if (!ascii) {
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:value
            attributes:@{NSFontAttributeName:font,NSLigatureAttributeName:@0}];
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
        width = CTLineGetTypographicBounds(line,nullptr,nullptr,nullptr);
    }
    CGFloat visible = MIN(width,col.width);
    CGFloat origin = rightAligned ? col.width-visible : 0;
    auto indexAt = [&](CGFloat x, bool end) -> NSUInteger {
        x -= origin;
        if (x <= 0) return 0;
        if (x >= visible) return value.length;
        // Selecting the truncation mark includes the rest of the original field.
        if (width > visible && x > visible-cw) {
            if (end) return value.length;
            x = MAX(0,visible-cw);
        }
        NSInteger index = line ? CTLineGetStringIndexForPosition(line,CGPointMake(x,0)) : std::lround(x/cw);
        return std::clamp<NSInteger>(index,0,value.length);
    };
    NSUInteger first = indexAt(left,false), last = indexAt(right,true);
    if (line) CFRelease(line);
    if (first == last) return nil;
    NSRange range = NSMakeRange(MIN(first,last),MAX(first,last)-MIN(first,last));
    return [value substringWithRange:ascii ? range : [value rangeOfComposedCharacterSequencesForRange:range]];
}
- (NSString *)selectedText {
    if (_anchor < 0) return nil;
    int lo = std::min(_anchor,_extent), hi = std::max(_anchor,_extent), w = _screen->cols;
    NSMutableString *text = [NSMutableString string];
    BOOL tables = [self presentsListings];
    PaintedLine cache;
    int64_t copiedLine = -1;
    for (int y = lo/w; y <= hi/w; ++y) {
        const Row *row = &[self displayRow:y];
        bool wraps = row->wrapAt != 0;
        OutputReference *record = tables ? [self listingForRow:*row] : nil;
        TextPoint point = [self displayPoint:y];
        if (record && !record.raw && [self loadListing:record atRow:y point:point cache:cache]) {
            int band = listingBand(*_screen,cache.first,point,cache.layout.bands);
            NSRect selection = [self listingSelectionAtRow:y];
            const auto &spec = SpecForListing(cache.format);
            for (int i=0;i<cache.layout.count;++i) {
                auto col = cache.layout.columns[i];
                if (col.band != band) continue;
                NSString *part = selectedFieldText(cache.fields[i],col,spec.widths[i]<0,selection,_cw,_regular);
                if (!part) continue;
                if (copiedLine == cache.first) [text appendString:@"\t"];
                [text appendString:part]; copiedLine = cache.first;
            }
        } else {
            NSRange columns = [self selectedColumnsInRow:y];
            row = &[self displayRow:y];
            int count = wraps ? row->wrapAt : (int)row->size();
            [text appendString:cellText(*row,std::min((int)columns.location,count),std::min((int)NSMaxRange(columns),count),!wraps)];
        }
        if (y < hi/w && !wraps) [text appendString:@"\n"];
    }
    return text;
}
- (void)copy:(id)sender {
    NSString *text = [self selectedText];
    if (!text) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}
- (BOOL)agentOwnsEditor {
    return _assistant.busy && _session.agentInputID && !_insideCommand && !_screen->alternate;
}
- (void)approveAgentCommand {
    if (_awaitingApproval && [_session approveAgentLine:_issuedID]) {
        _awaitingApproval=NO; _approvalSent=YES;
        [self setAgentBusy:YES];
    }
}
- (void)sendString:(NSString *)str {
    if ([self agentOwnsEditor]) return;
    if (_offset || _anchor != -1) { _offset = 0; _topColumn = 0; _visibleRows.clear(); [self updateFrameSpacing]; _anchor = _extent = -1; self.needsDisplay = YES; }
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
    int first = [self rowAtY:NSMinY(rect)];
    int end = [self rowAtY:NSMaxY(rect)]+1;
    for (int y=first; y<end; ++y) {
        NSRange hit = [self findColumnsInRow:y];
        if (hit.length && NSIntersectsRect(rect,NSMakeRect([self textOriginForRow:y]+hit.location*_cw,[self topOfRow:y],hit.length*_cw,_lh))) return YES;
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
        _topColumn = _offset ? hit.column : 0; _visibleRows.clear(); [self updateFrameSpacing];
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
- (BOOL)handleFindKey:(NSEvent *)event {
    if (!_findBar || !_findBar.field.currentEditor || self.window.firstResponder!=_findBar.field.currentEditor ||
        [(NSTextView *)_findBar.field.currentEditor hasMarkedText]) return NO;
    if (MatchesShortcut(event,SearchNextKey)) [self findNext:nil];
    else if (MatchesShortcut(event,SearchPreviousKey)) [self findPrevious:nil];
    else if (MatchesShortcut(event,SearchCloseKey)) [self closeFind:nil];
    else return NO;
    return YES;
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)editor doCommandBySelector:(SEL)action {
    if (control!=_findBar.field || editor.hasMarkedText) return NO;
    if (action==@selector(cancelOperation:)) {
        if (ShortcutValue(SearchCloseKey)==Shortcut(SearchCloseKey).standard) [self closeFind:nil];
        return YES;
    }
    if (action==@selector(insertNewline:) || action==@selector(insertLineBreak:) || action==@selector(insertNewlineIgnoringFieldEditor:)) {
        BOOL previous=(NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift)!=0;
        ShortcutID id=previous ? SearchPreviousKey : SearchNextKey;
        if (ShortcutValue(id)==Shortcut(id).standard) {
            if (previous) [self findPrevious:nil]; else [self findNext:nil];
        }
        return YES;
    }
    return NO;
}
- (BOOL)handleTerminalShortcut:(NSEvent *)event {
    if (MatchesShortcut(event,TerminalFindKey)) { [self showFind:nil]; return YES; }
    if (_assistant.busy && _session.agentInputID && MatchesShortcut(event,StopAgentKey)) {
        [self unmarkText]; [_assistant submitTask:@"/stop"]; return YES;
    }
    if (_awaitingApproval && MatchesShortcut(event,ApproveKey)) {
        if (!event.isARepeat) [self approveAgentCommand]; return YES;
    }
    return NO;
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type==NSEventTypeKeyDown &&
        ((self.window.firstResponder==self && [self handleTerminalShortcut:event]) || [self handleFindKey:event])) return YES;
    return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags modifiers=event.modifierFlags & (NSEventModifierFlagControl|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagCommand);
    if ([self handleTerminalShortcut:event]) return;
    if (modifiers & NSEventModifierFlagCommand) { [super keyDown:event]; return; }
    if ([self agentOwnsEditor]) return;
    if (!_marked.length) {
        if (!modifiers && (event.keyCode==125 || event.keyCode==126) && _session.agentInputID &&
            !_insideCommand && !_screen->alternate) {
            [self sendString:event.keyCode==126 ? @"\033[99;7A" : @"\033[99;7B"]; return;
        }
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
    if ([self agentOwnsEditor]) return;
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
    NSRect caret = NSMakeRect([self textOriginForRow:_screen->y()]+_screen->x()*_cw,[self topOfRow:_screen->y()],_cw,_lh);
    return [self.window convertRectToScreen:[self convertRect:caret toView:nil]];
}
- (void)doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:) && [self agentOwnsEditor] && ShortcutValue(ApproveKey)==Shortcut(ApproveKey).standard) [self approveAgentCommand];
    else if (selector == @selector(insertNewline:)) [self sendString:@"\r"];
    else if (selector == @selector(deleteBackward:)) [self sendString:@"\177"];
    else if (selector == @selector(insertTab:)) [self sendString:@"\t"];
    else if (selector == @selector(cancelOperation:)) [self sendString:@"\033"];
}
@end
