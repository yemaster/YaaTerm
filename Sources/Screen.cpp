#include "Screen.hpp"
#include "Emoji.hpp"
#include <utility>
#include <charconv>
#include <compression.h>
#include <cassert>
#include <cstring>

namespace yaa {
// Encode bounded blocks so neighboring rows share an LZ4 dictionary. Row metadata,
// cursor state and partial parser input stay in place. The PTY never stops reading.
namespace {
struct PackedRowHeader { uint16_t columns, used; };
struct PackedBlockHeader { uint32_t plain, stored; };
constexpr size_t blockLimit = 64 * 1024;

size_t printableRun(const char *data, size_t limit) {
    size_t n = 0;
    // For eight printable ASCII bytes these operations never carry between
    // bytes. A control, DEL or non-ASCII byte sets at least one high bit.
    while (limit-n >= 8) {
        uint64_t word;
        memcpy(&word,data+n,sizeof(word));
        if ((word | (word-0x2020202020202020ULL) | (word+0x0101010101010101ULL)) & 0x8080808080808080ULL) break;
        n += 8;
    }
    while (n<limit && uint8_t(data[n])>=32 && uint8_t(data[n])<127) ++n;
    return n;
}
}
void Screen::freeze() {
    if (frozen()) return;
    std::vector<uint8_t> block, scratch(compression_encode_scratch_buffer_size(COMPRESSION_LZ4));
    auto flush = [&] {
        size_t start = packedRows.size(), plain = block.size();
        packedRows.resize(start + sizeof(PackedBlockHeader) + plain);
        auto *out = packedRows.data()+start+sizeof(PackedBlockHeader);
        size_t stored = compression_encode_buffer(out,plain,block.data(),plain,scratch.data(),COMPRESSION_LZ4);
        if (!stored || stored >= plain) { memcpy(out,block.data(),plain); stored = plain; }
        PackedBlockHeader header{(uint32_t)plain,(uint32_t)stored};
        memcpy(packedRows.data()+start,&header,sizeof(header));
        packedRows.resize(start+sizeof(header)+stored);
        block.clear();
    };
    visitRows([&](Row &row) {
        PackedRowHeader h{(uint16_t)row.size(),(uint16_t)row.used()};
        size_t bytes = h.used*sizeof(Cell);
        if (block.size()+sizeof(h)+bytes > blockLimit) flush();
        size_t start = block.size();
        block.resize(start+sizeof(h)+bytes);
        memcpy(block.data()+start,&h,sizeof(h));
        if (bytes) memcpy(block.data()+start+sizeof(h),row.data(),bytes);
        std::vector<Cell>().swap(row);
    });
    if (!block.empty()) flush();
    packedRows.shrink_to_fit();
    if (archive) archive->dropReadCache();
    hotBytes = 0;
}
void Screen::thaw() {
    if (!frozen()) return;
    const uint8_t *next = packedRows.data(), *rowData = nullptr, *blockEnd = nullptr;
    std::vector<uint8_t> decoded;
    visitRows([&](Row &row) {
        if (rowData == blockEnd) {
            PackedBlockHeader h;
            memcpy(&h,next,sizeof(h)); next += sizeof(h);
            rowData = next;
            if (h.stored != h.plain) {
                decoded.resize(h.plain);
                size_t n = compression_decode_buffer(decoded.data(),h.plain,next,h.stored,nullptr,COMPRESSION_LZ4);
                if (n != h.plain) std::terminate(); // Invariant of our private in-memory snapshot.
                rowData = decoded.data();
            }
            next += h.stored; blockEnd = rowData+h.plain;
        }
        PackedRowHeader h;
        memcpy(&h,rowData,sizeof(h)); rowData += sizeof(h);
        row.resize(h.columns);
        size_t bytes = h.used*sizeof(Cell);
        if (bytes) memcpy(row.data(),rowData,bytes);
        rowData += bytes;
    });
    assert(next == packedRows.data()+packedRows.size() && rowData == blockEnd);
    std::vector<uint8_t>().swap(packedRows);
    for (const auto &row : history) hotBytes += row.capacity()*sizeof(Cell);
}
void Screen::spillOldest() {
    if (!archive) archive = std::make_unique<HistoryArchive>();
    if (!archive->append(history.front())) { commandOutputEnd.row=-1; ++historyGeneration; }
}

Row Screen::remember(Row &&row) {
    Row spare;
    while (!history.empty() && (history.size() >= historyLimit || hotBytes + row.capacity()*sizeof(Cell) > 1024*1024)) {
        hotBytes -= history.front().capacity()*sizeof(Cell);
        spillOldest();
        spare = std::move(history.front());
        history.pop_front();
    }
    hotBytes += row.capacity()*sizeof(Cell);
    history.push_back(std::move(row));
    ++linesScrolled;
    return spare;
}

void Screen::setHistoryLimit(size_t limit) {
    if (frozen()) thaw();
    historyLimit = limit;
    if (!limit) {
        commandOutputEnd.row=std::max<int64_t>(-1,commandOutputEnd.row-archivedRows()-(int64_t)history.size());
        history.clear(); hotBytes = 0; archive.reset(); ++historyGeneration; return;
    }
    while (history.size() > limit) {
        hotBytes -= history.front().capacity()*sizeof(Cell);
        spillOldest(); history.pop_front();
    }
}

void Screen::clearHistory() {
    if (frozen()) thaw();
    if (!alternate) {
        commandOutputEnd.row=std::max<int64_t>(-1,commandOutputEnd.row-historySize());
        history.clear(); hotBytes = 0; archive.reset(); ++historyGeneration;
    }
}

void Screen::resize(int w, int h) {
    w = std::clamp(w, 2, 1000);
    h = std::clamp(h, 1, 500);
    if (w == cols && h == height) return;
    graphicAdjacent = false;
    if (frozen()) thaw();
    resizeBuffer(active(), w, h);
    cols = w; height = h;
    if (codePreview.active()) codePreview.resumeRow(active().row(y()).codeLine);
    updateWriteColumns();
}

void Screen::resizeBuffer(Buffer &b, int w, int h) {
    int oldHeight = (int)b.rows.size();
    int oldWidth = oldHeight ? (int)b.rows.front().size() : 0;
    if (oldHeight == h && oldWidth == w) return;
    ++historyGeneration;
    if (b.firstRow) {
        std::rotate(b.rows.begin(),b.rows.begin()+b.firstRow,b.rows.end());
        b.firstRow = 0;
    }
    if (&b == &main && oldWidth && oldWidth != w) { reflowMain(w,h); return; }
    int bottom = b.cursor.y;
    if (&b == &main && h < oldHeight)
        for (int y=oldHeight-1; y>bottom; --y) if (b.rows[y].used()) { bottom = y; break; }
    int shift = std::max(0, bottom - h + 1);
    if (&b == &main && historyLimit)
        for (int i = 0; i < shift; ++i) remember(std::move(b.rows[i]));
    if (&b==&main && !historyLimit) commandOutputEnd.row=std::max<int64_t>(-1,commandOutputEnd.row-shift);
    b.rows.erase(b.rows.begin(), b.rows.begin()+shift);
    b.rows.resize(h);
    for (auto &r : b.rows) {
        r.resize(w); r.written = std::min<int>(r.written,w);
        if (w != oldWidth) r.wrapAt = 0;
        if (r.back().width == 2) r.back() = Cell{};
    }
    for (Cursor *cursor : {&b.cursor, &b.saved}) {
        cursor->y = std::clamp(cursor->y-shift,0,h-1);
        cursor->x = std::clamp(cursor->x,0,w-1);
        if (w != oldWidth) cursor->wrapPending = false;
    }
    if (oldHeight != h) { b.top = 0; b.bottom = h-1; }
}

// Reflow only the live main grid. Retired rows keep their original width and
// are split into viewport-sized pieces on demand when the user visits them.
void Screen::reflowMain(int w, int h) {
    auto &b = main;
    std::deque<Row> visible;
    Row out(w);
    int filled = 0, emitted = 0;
    const int oldHeight = (int)b.rows.size();
    int last = oldHeight-1;
    while (last > b.cursor.y && b.rows[last].used() == 0 && !b.rows[last-1].wrapAt) --last;
    Cursor next = b.cursor, saved = b.saved;
    const int64_t anchorY=commandOutputEnd.row-historySize();
    TextPoint reflowed{-1,0};
    auto emit = [&](bool soft) {
        out.wrapAt = soft ? filled : 0; out.written = filled;
        visible.push_back(std::move(out)); ++emitted;
        if ((int)visible.size() > h) {
            if (historyLimit) out = remember(std::move(visible.front()));
            else out = std::move(visible.front());
            visible.pop_front();
        }
        out.assign(w,Cell{}); out.wrapAt = out.written = out.codeLine = 0; filled = 0;
    };
    for (int y=0; y<=last; ++y) {
        const Row &src = b.rows[y];
        out.agentStamp = src.agentStamp;
        if (!filled) out.codeLine = src.codeLine;
        int widthLimit = w-codeGutterColumns(src.codeLine,w);
        int end = src.wrapAt ? src.wrapAt : src.used();
        auto insertion = [&](const Cursor &c) { return c.x + (c.wrapPending ? 1 : 0); };
        if (b.cursor.y == y) end = std::max(end,insertion(b.cursor));
        if (b.saved.y == y) end = std::max(end,insertion(b.saved));
        end = std::min(end,(int)src.size());
        auto place = [&](int col) {
            auto map = [&](const Cursor &c,Cursor &dest) {
                if (c.y == y && insertion(c) == col) {
                    dest.y = emitted; dest.x = std::min(widthLimit-1,filled); dest.wrapPending = filled == widthLimit;
                }
            };
            map(b.cursor,next); map(b.saved,saved);
            if (y==anchorY && col==commandOutputEnd.column) reflowed={emitted,filled};
        };
        for (int x=0; x<end;) {
            int width = src[x].width == 2 && x+1<end ? 2 : 1;
            if (filled+width > widthLimit) {
                emit(true); out.agentStamp = src.agentStamp;
                if (src.codeLine) out.codeLine = CodeContinuation | src.codeLine;
            }
            place(x); out[filled++] = src[x++];
            if (width == 2) { place(x); out[filled++] = src[x++]; }
        }
        place(end);
        if (!src.wrapAt || y == last) emit(false);
    }
    int shift = emitted-(int)visible.size();
    for (Cursor *c : {&next,&saved}) {
        c->y = std::clamp(c->y-shift,0,h-1); c->x = std::clamp(c->x,0,w-1);
    }
    if (anchorY>=0) {
        commandOutputEnd=reflowed;
        if (commandOutputEnd.row>=0) commandOutputEnd.row=std::max<int64_t>(-1,historySize()-shift+commandOutputEnd.row);
    }
    b.cursor = next; b.saved = saved;
    b.rows.assign(std::make_move_iterator(visible.begin()),std::make_move_iterator(visible.end()));
    while ((int)b.rows.size()<h) b.rows.emplace_back(w);
    if (oldHeight != h) { b.top = 0; b.bottom = h-1; }
}

const Row &Screen::lineAt(int64_t i) const {
    if (!alternate) {
        int64_t cold = archivedRows();
        if (i < cold) return archive->rowAt(i);
        i -= cold;
        if (i < (int64_t)history.size()) return history[i];
        i -= history.size();
    }
    return active().row((int)i);
}
const Row &Screen::row(int y, int64_t offset) const {
    if (!offset) return active().row(y);
    return lineAt(historySize()-std::clamp<int64_t>(offset,0,historySize())+y);
}

void Screen::scroll(int first, int last, bool up, bool save) {
    damage(first, last);
    auto &b = active();
    bool whole = first==0 && last==height-1;
    bool keep=up && save && !alternate && historyLimit && whole;
    if (!alternate && !keep && commandOutputEnd.row>=0) {
        auto y=commandOutputEnd.row-historySize();
        if (y>=first && y<=last) {
            if (y==(up ? first : last)) commandOutputEnd.row=-1;
            else commandOutputEnd.row+=up ? -1 : 1;
        }
    }
    Row &edge = b.row(up ? first : last);
    if (keep) edge = remember(std::move(edge));
    edge.assign(cols,blank());
    static_cast<RowMetadata &>(edge) = {};
    if (whole) {
        b.firstRow = b.slot(up ? 1 : last);
        return;
    }
    Row spare = std::move(edge);
    int begin = b.slot(first), end = b.slot(last);
    if (begin<=end) {
        auto from=b.rows.begin()+begin, to=b.rows.begin()+end;
        if (up) std::move(from+1,to+1,from);
        else std::move_backward(from,to,to+1);
    } else if (up) {
        for (int i=first; i<last; ++i) b.row(i) = std::move(b.row(i+1));
    } else {
        for (int i=last; i>first; --i) b.row(i) = std::move(b.row(i-1));
    }
    b.row(up ? last : first) = std::move(spare);
}

void Screen::lineFeed(int wrapAt) {
    auto &b = active();
    if (codePreview.active()) {
        Row &row = b.row(b.cursor.y);
        codePreview.finishRow(row,wrapAt ? wrapAt : row.written,wrapAt != 0);
        updateWriteColumns();
    }
    b.row(b.cursor.y).wrapAt = wrapAt;
    if (agentStamp && !alternate) b.row(b.cursor.y).agentStamp = agentStamp;
    b.cursor.wrapPending = false;
    if (b.cursor.y == b.bottom) scroll(b.top, b.bottom, true, true);
    else b.cursor.y = std::min(b.cursor.y + 1, height - 1);
}
void Screen::erase(Row &r, int first, int end) {
    if (first >= end) return;
    if (end == cols) r.wrapAt = 0;
    if (first == 0 && end == cols) { r.agentStamp = 0; r.codeLine = 0; }
    if (first > 0 && r[first].width == 0) --first;
    if (end < cols && r[end].width == 0) ++end;
    if (end >= r.written) r.written = std::min<int>(r.written,first);
    std::fill(r.begin() + first, r.begin() + end, blank());
}
bool Screen::extendEmoji(char32_t ch) {
    auto &b = active();
    auto &cursor = b.cursor;
    Row &row = b.row(cursor.y);
    int x = cursor.wrapPending ? cursor.x : cursor.x-1;
    if (x >= 0 && !row[x].width) --x;
    if (x < 0) return false;
    uint32_t mark = emoji::extend(row[x].ch,row[x].mark,ch);
    if (!mark) return false;
    row[x].mark = mark;
    damage(cursor.y,cursor.y);
    if (row[x].width==2 || !emoji::wideMark(mark)) return true;

    // A variation selector, flag or keycap can widen an already displayed base.
    Cell glyph = row[x];
    if (insert && x+1 < cols) {
        std::move_backward(row.begin()+x+1,row.end()-1,row.end());
        if (row.written>x+1) row.written = std::min(cols,row.written+1);
    }
    if (x+1 == writeColumns) {
        if (!cursor.autoWrap) return true;
        erase(row,x,writeColumns);
        lineFeed(x); x = 0;
    }
    Row &dest = b.row(cursor.y);
    erase(dest,x,x+2);
    dest[x] = glyph; dest[x].width = 2;
    dest[x+1] = Cell{glyph.style,0,0,0,(uint32_t)glyph.tag};
    dest.written = std::max<int>(dest.written,x+2);
    dest.codeLine = writingCodeLine;
    dest.agentStamp = alternate ? 0 : agentStamp;
    cursor.wrapPending = x+2 == writeColumns;
    cursor.x = std::min(writeColumns-1,x+2);
    damage(cursor.y,cursor.y);
    return true;
}
void Screen::put(char32_t ch) {
    auto &b = active();
    int width = 1;
    if (ch >= 127) {
        if (graphicAdjacent && extendEmoji(ch)) return;
        width = wcwidth(static_cast<wchar_t>(ch));
        if (width != 2 && ((ch>=0x2300 && ch<=0x3299) || (ch>=0x1f000 && ch<=0x1faff)) &&
            emoji::wideBase(ch)) width = 2;
    }
    if (width == 0) {
        int prev = b.cursor.wrapPending ? b.cursor.x : b.cursor.x - 1;
        if (prev >= 0 && b.row(b.cursor.y)[prev].width == 0) --prev;
        if (prev >= 0 && b.row(b.cursor.y)[prev].mark < emoji::firstMark) { b.row(b.cursor.y)[prev].mark = ch; damage(b.cursor.y, b.cursor.y); }
        return;
    }
    graphicAdjacent = true;
    writeGlyph(ch,width == 2 ? 2 : 1,0);
}
void Screen::writeGlyph(char32_t ch, int width, uint32_t mark) {
    auto &b = active();
    if (b.cursor.autoWrap && (b.cursor.wrapPending || b.cursor.x + width > writeColumns)) {
        lineFeed(b.cursor.wrapPending ? b.cursor.x+1 : b.cursor.x); b.cursor.x = 0;
    }
    if (width + b.cursor.x > writeColumns) width = 1;
    damage(b.cursor.y, b.cursor.y);
    auto &r = b.row(b.cursor.y);
    if (writingCodeLine || !b.cursor.x || b.cursor.x < r.written) r.codeLine = writingCodeLine;
    if (insert) {
        std::move_backward(r.begin() + b.cursor.x, r.end() - width, r.end());
        if (r.written > b.cursor.x) r.written = std::min(cols,r.written+width);
    }
    if (r[b.cursor.x].width != 1 || (b.cursor.x + width < cols && r[b.cursor.x + width].width == 0))
        erase(r, b.cursor.x, b.cursor.x + width);
    r.written = std::max<int>(r.written,b.cursor.x+width);
    r.agentStamp = alternate ? 0 : agentStamp;
    r[b.cursor.x] = Cell{b.cursor.pen, ch, mark, (uint8_t)width, writeTag};
    if (width == 2) r[b.cursor.x + 1] = Cell{b.cursor.pen, 0, 0, 0, writeTag};
    b.cursor.wrapPending = b.cursor.x + width >= writeColumns;
    b.cursor.x = std::min(writeColumns - 1, b.cursor.x + width);
}

// Wheel presses have no release event. Coordinates from the view are one-based.
size_t Screen::wheelReport(char (&out)[48], bool up, int modifiers, int col, int row, int pixelX, int pixelY) const {
    return mouseReport(out,up ? 64 : 65,MouseAction::Press,modifiers,col,row,pixelX,pixelY);
}
size_t Screen::mouseReport(char (&out)[48], int button, MouseAction action, int modifiers,
                           int col, int row, int pixelX, int pixelY) const {
    if (!mouseTracking || (mouseTracking==9 && action!=MouseAction::Press)) return 0;
    if (action==MouseAction::Motion && (mouseTracking<1002 || (button==3 && mouseTracking!=1003))) return 0;
    bool release = action==MouseAction::Release;
    if (release && mouseEncoding!=MouseEncoding::Sgr && mouseEncoding!=MouseEncoding::SgrPixels) button=3;
    button |= (mouseTracking==9 ? 0 : modifiers) | (action==MouseAction::Motion ? 32 : 0);
    switch (mouseEncoding) {
        case MouseEncoding::SgrPixels: return snprintf(out,sizeof(out),"\033[<%d;%d;%d%c",button,pixelX,pixelY,release ? 'm' : 'M');
        case MouseEncoding::Sgr: return snprintf(out,sizeof(out),"\033[<%d;%d;%d%c",button,col,row,release ? 'm' : 'M');
        case MouseEncoding::Urxvt: return snprintf(out,sizeof(out),"\033[%d;%d;%dM",button+32,col,row);
        default: break;
    }
    if (mouseEncoding == MouseEncoding::Classic && (col>223 || row>223)) return 0;
    out[0] = '\033'; out[1] = '['; out[2] = 'M'; out[3] = char(button+32);
    size_t length = 4;
    for (int value : {col+32,row+32}) {
        if (mouseEncoding == MouseEncoding::Utf8 && value >= 128) {
            out[length++] = char(0xc0 | (value>>6));
            out[length++] = char(0x80 | (value&63));
        } else out[length++] = char(value);
    }
    return length;
}
void Screen::recordPromptStart() {
    promptStart=historySize()+y();
    if (commandOutputEnd.row>=0) rowsToPrompt=promptStart-commandOutputEnd.row;
}

void Screen::expectPromptRedraw() {
    recordPromptStart(); // Fallback when the line editor does not redraw.
    awaitingPromptRedraw=true;
}

void Screen::mode(int n, bool on, bool priv) {
    auto &b = active();
    if (!priv) { if (n == 4) insert = on; return; }
    switch (n) {
        case 1: applicationCursor = on; break;
        case 6:
            b.cursor.origin = on; b.cursor.x = 0; b.cursor.y = on ? b.top : 0;
            b.cursor.wrapPending = false; break;
        case 7: b.cursor.autoWrap = on; if (!on) b.cursor.wrapPending = false; break;
        case 25: cursorVisible = on; break;
        case 9: case 1000: case 1002: case 1003:
            if (on || mouseTracking == n) mouseTracking = on ? n : 0;
            break;
        case 1005: case 1006: case 1015: case 1016:
            if (on || int(mouseEncoding) == n) mouseEncoding = on ? MouseEncoding(n) : MouseEncoding::Classic;
            break;
        case 1004: focusReporting = on; break;
        case 1007: alternateScroll = on; break;
        case 2004:
            bracketPaste = on;
            if (on) awaitingPromptRedraw=false;
            break;
        case 47: case 1047: case 1049:
            if (on == alternate) break;
            awaitingPromptRedraw=false;
            finishCode();
            if (on && n == 1049) {
                main.saved = main.cursor;
                alt = Buffer{};
                alt.cursor.pen = main.cursor.pen;
            }
            alternate = on;
            writeTag = active().link ? active().link : (on ? 0 : context);
            if (!on && n == 1049) main.cursor = main.saved;
            // Adapt the hidden buffer only when shown. Intermediate TUI resizes must not crop it.
            resizeBuffer(active(),cols,height);
            if (!on && n != 47) alt = Buffer{};
            damage(0,height-1); bufferChanged = true;
            break;
        case 1048:
            if (on) b.saved = b.cursor; else b.cursor = b.saved;
            break;
    }
}

void Screen::moveTabs(int count, bool forward) {
    auto &cursor = active().cursor;
    int step = forward ? 1 : -1, edge = forward ? writeColumns-1 : 0;
    cursor.x = std::min(cursor.x,writeColumns-1);
    while (count-- && cursor.x != edge) {
        do { cursor.x += step; } while (cursor.x != edge && !tabs[cursor.x]);
    }
    cursor.wrapPending = false;
}
int Screen::modeStatus(int n, bool priv) const {
    if (!priv) return n==4 ? (insert ? 1 : 2) : 0;
    bool enabled;
    switch (n) {
        case 1: enabled = applicationCursor; break;
        case 6: enabled = active().cursor.origin; break;
        case 7: enabled = active().cursor.autoWrap; break;
        case 25: enabled = cursorVisible; break;
        case 47: case 1047: case 1049: enabled = alternate; break;
        case 9: case 1000: case 1002: case 1003: enabled = mouseTracking==n; break;
        case 1004: enabled = focusReporting; break;
        case 1005: case 1006: case 1015: case 1016: enabled = int(mouseEncoding)==n; break;
        case 1007: enabled = alternateScroll; break;
        case 2004: enabled = bracketPaste; break;
        default: return 0;
    }
    return enabled ? 1 : 2;
}
// Normalize SGR subparameters without interpreting an unknown color space as a separate attribute.
static int extendedSGR(std::string_view sequence,std::array<int,32> &args) {
    int count = 0;
    bool more = true;
    while (more && count<32) {
        auto end = sequence.find(';');
        more = end!=sequence.npos;
        auto field = sequence.substr(0,end);
        sequence = end==sequence.npos ? std::string_view{} : sequence.substr(end+1);
        int values[6]{}, size = 0;
        for (;;) {
            auto i = field.find(':');
            auto atom = field.substr(0,i);
            if (size==6) { size=0; break; }
            if (!atom.empty()) {
                auto parsed = std::from_chars(atom.data(),atom.data()+atom.size(),values[size]);
                if (parsed.ec!=std::errc{} || parsed.ptr!=atom.data()+atom.size() || values[size]<0) { size=0; break; }
            }
            ++size;
            if (i==field.npos) break;
            field.remove_prefix(i+1);
        }
        if (size==1) args[count++] = values[0];
        else if (size==2 && values[0]==4) args[count++] = values[1] ? 4 : 24;
        else if (size>=3 && (values[0]==38 || values[0]==48)) {
            bool indexed = values[1]==5 && size==3;
            bool rgb = values[1]==2 && (size==5 || (size==6 && !values[2]));
            if ((!indexed && !rgb) || count+(indexed?3:5)>32) continue;
            args[count++] = values[0]; args[count++] = values[1];
            for (int i=size-(indexed?1:3); i<size; ++i) args[count++] = values[i];
        }
    }
    return count;
}
void Screen::control(char c) {
    bool priv = !sequence.empty() && sequence[0] == '?';
    if (c=='p' && !sequence.empty() && sequence.back()=='$') {
        int mode = 0;
        auto end = sequence.data()+sequence.size()-1;
        auto parsed = std::from_chars(sequence.data()+priv,end,mode);
        if (reply && parsed.ec==std::errc{} && parsed.ptr==end && mode>=0) {
            char answer[48];
            snprintf(answer,sizeof(answer),"\033[%s%d;%d$y",priv ? "?" : "",mode,modeStatus(mode,priv));
            reply(answer);
        }
        return;
    }
    if (c=='c' && (sequence==">" || sequence==">0")) { if (reply) reply("\033[>0;0;0c"); return; }
    if (c=='q' && (sequence==">" || sequence==">0")) { if (reply) reply("\033P>|YaaTerm\033\\"); return; }
    // Vim's CSI ? 4 m is a keyboard-protocol query, not underline SGR.
    if (priv && c != 'h' && c != 'l' && c != 'n' && c != 'J' && c != 'K') return;
    std::array<int, 32> args{};
    int count = 1;
    if (c=='m' && sequence.find(':')!=sequence.npos) count = extendedSGR(sequence,args);
    else for (size_t i = priv; i < sequence.size(); ++i) {
        char k = sequence[i];
        if (k >= '0' && k <= '9') args[count-1] = std::min(9999, args[count-1]*10 + k-'0');
        else if (k == ';' && count < (int)args.size()) ++count;
        else return;
    }
    auto &b = active();
    int a = args[0], n = std::max(1, a);
    if (c != 's' && c != 'u' && c != 'm' && c != 'h' && c != 'l' && c != 'n' && c != 'c' && c != 'b') b.cursor.wrapPending = false;
    switch (c) {
        case 'g':
            if (!a) tabs.reset(b.cursor.x); else if (a==3) tabs.reset();
            break;
        case 'I': case 'Z': moveTabs(n,c=='I'); break;
        case 'b': {
            int x = b.cursor.wrapPending ? b.cursor.x : b.cursor.x-1;
            if (x>=0 && !b.row(b.cursor.y)[x].width) --x;
            if (x>=0) {
                Cell glyph = b.row(b.cursor.y)[x];
                for (int i=0;i<n;++i) writeGlyph(glyph.ch,glyph.width,glyph.mark);
                graphicAdjacent = true;
            }
            break;
        }
        case 'A': b.cursor.y = std::max(b.cursor.y >= b.top ? b.top : 0, b.cursor.y-n); break;
        case 'B': case 'e': b.cursor.y = std::min(b.cursor.y <= b.bottom ? b.bottom : height-1, b.cursor.y+n); break;
        case 'C': case 'a': b.cursor.x += n; break;
        case 'D': b.cursor.x -= n; break;
        case 'E': b.cursor.x = 0; b.cursor.y += n; break;
        case 'F': b.cursor.x = 0; b.cursor.y -= n; break;
        case 'G': case '`': b.cursor.x = n-1; break;
        case 'd': b.cursor.y = n-1 + (b.cursor.origin ? b.top : 0); break;
        case 'H': case 'f': b.cursor.y = n-1 + (b.cursor.origin ? b.top : 0); b.cursor.x = std::max(1,args[1])-1; break;
        case 'J':
            // ZLE clears from column zero before painting PS1. Prompt expansion and
            // precmd hooks can write to the TTY after the authenticated command-end marker.
            if (awaitingPromptRedraw && !alternate && !priv && a==0 && b.cursor.x==0) {
                recordPromptStart();
                if (bracketPaste) awaitingPromptRedraw=false; // Redisplay inside an active ZLE widget.
            }
            damage(0, height-1);
            if (a == 3) { clearHistory(); break; }
            for (int i = 0; i < height; ++i) {
                if (a == 2 || (a == 0 && i > b.cursor.y) || (a == 1 && i < b.cursor.y)) erase(b.row(i), 0, cols);
                else if (i == b.cursor.y && a <= 1) erase(b.row(i), a == 0 ? b.cursor.x : 0, a == 0 ? cols : b.cursor.x+1);
            }
            break;
        case 'K': if (a <= 2) erase(b.row(b.cursor.y), a == 0 ? b.cursor.x : 0, a == 1 ? b.cursor.x+1 : cols); break;
        case 'X': erase(b.row(b.cursor.y), b.cursor.x, std::min(cols,b.cursor.x+n)); break;
        case 'P': case '@': {
            auto &r = b.row(b.cursor.y);
            n = std::min(n, cols-b.cursor.x);
            if (r.written > b.cursor.x) r.written = c == 'P' ? std::max(b.cursor.x,r.written-n) : std::min(cols,r.written+n);
            if (c == 'P') { std::move(r.begin()+b.cursor.x+n,r.end(),r.begin()+b.cursor.x); erase(r,cols-n,cols); }
            else { std::move_backward(r.begin()+b.cursor.x,r.end()-n,r.end()); erase(r,b.cursor.x,b.cursor.x+n); }
            break;
        }
        case 'r': {
            int first = n-1, last = args[1] ? std::min(args[1],height)-1 : height-1;
            if (first < last || (first == 0 && height == 1)) {
                b.top = first; b.bottom = last;
                b.cursor.x = 0; b.cursor.y = b.cursor.origin ? b.top : 0;
            }
            break;
        }
        case 'S': case 'T': case 'L': case 'M': {
            bool line = c == 'L' || c == 'M';
            if (line && (b.cursor.y < b.top || b.cursor.y > b.bottom)) break;
            int first = line ? b.cursor.y : b.top;
            for (int i = 0; i < std::min(n,b.bottom-first+1); ++i)
                scroll(first,b.bottom,c == 'S' || c == 'M',false);
            break;
        }
        case 's': b.saved = b.cursor; break;
        case 'u': b.cursor = b.saved; break;
        case 'h': case 'l': for (int i = 0; i < count; ++i) mode(args[i],c == 'h',priv); break;
        case 'n':
            if (reply && a == 5) reply("\033[0n");
            if (reply && a == 6) {
                char s[32];
                int row = b.cursor.y - (b.cursor.origin ? b.top : 0) + 1;
                snprintf(s,sizeof(s),"\033[%s%d;%dR",priv ? "?" : "",row,b.cursor.x+1); reply(s);
            }
            break;
        case 'c': if (reply && !a) reply("\033[?1;2c"); break;
        case 'm': {
            Style &pen = b.cursor.pen;
            for (int i = 0; i < count; ++i) {
                int v = args[i];
                if (!v) pen = Style{};
                else if (v == 1) pen.flags |= Bold;
                else if (v == 3) pen.flags |= Italic;
                else if (v == 4) pen.flags |= Underline;
                else if (v == 7) pen.flags |= Inverse;
                else if (v == 22) pen.flags &= ~Bold;
                else if (v == 23) pen.flags &= ~Italic;
                else if (v == 24) pen.flags &= ~Underline;
                else if (v == 27) pen.flags &= ~Inverse;
                else if (v >= 30 && v <= 37) pen.fg = Indexed + v-30;
                else if (v >= 40 && v <= 47) pen.bg = Indexed + v-40;
                else if (v >= 90 && v <= 97) pen.fg = Indexed + v-90+8;
                else if (v >= 100 && v <= 107) pen.bg = Indexed + v-100+8;
                else if (v == 39) pen.fg = Default;
                else if (v == 49) pen.bg = Default;
                else if ((v == 38 || v == 48) && i+2 < count) {
                    int color;
                    if (args[i+1] == 5) { color = Indexed + std::min(255,args[i+2]); i+=2; }
                    else if (args[i+1] == 2 && i+4 < count) {
                        color = (std::min(255,args[i+2])<<16) | (std::min(255,args[i+3])<<8) | std::min(255,args[i+4]); i+=4;
                    } else continue;
                    if (v == 38) pen.fg = color; else pen.bg = color;
                }
            }
        }
    }
    auto &current = active();
    current.cursor.x = std::clamp(current.cursor.x,0,cols-1);
    current.cursor.y = std::clamp(current.cursor.y,current.cursor.origin ? current.top : 0,current.cursor.origin ? current.bottom : height-1);
}

bool Screen::isAgentCommand(std::string_view name) {
    return name=="codex" || name=="claude" || name=="agy" || name=="omp" ||
           name=="qodercn" || name=="qoder-cn" || name=="qoderclicn" || name=="qodercli";
}

// Both OSC 7501 and our stop hooks carry free text as base64, outside the control stream.
static std::string decodeNoticeText(std::string_view text) {
    if (text.empty() || text.size()>2732) return {};
    size_t padding = 0;
    while (!text.empty() && text.back()=='=') { ++padding; text.remove_suffix(1); }
    if (text.size()%4==1 || padding>2 || (padding && (text.size()+padding)%4)) return {};
    std::string result;
    result.reserve(text.size()*3/4);
    unsigned bits = 0, available = 0;
    for (char c : text) {
        unsigned value;
        if (c>='A' && c<='Z') value = c-'A';
        else if (c>='a' && c<='z') value = c-'a'+26;
        else if (c>='0' && c<='9') value = c-'0'+52;
        else if (c=='+') value = 62;
        else if (c=='/') value = 63;
        else return {};
        bits = (bits<<6)|value; available += 6;
        if (available>=8) { available -= 8; result.push_back(char(bits>>available)); }
    }
    return result;
}

void Screen::finishAgentTurn(bool failed, std::string_view detail) {
    reportedTurn = true;
    if (agentFinished) agentFinished(agentCommand,failed,detail);
}

void Screen::finishCode() {
    if (!codePreview.active()) return;
    auto &row = main.row(main.cursor.y);
    if (row.written) codePreview.finishRow(row,row.written,false);
    codePreview = {};
    updateWriteColumns();
}

void Screen::finishOSC() {
    state = Text;
    std::string_view data(sequence);
    auto take = [&](char delimiter) {
        size_t end = data.find(delimiter);
        auto value = data.substr(0,end);
        data = end == data.npos ? std::string_view{} : data.substr(end+1);
        return value;
    };
    auto code = take(';');
    if (code == "133" && data == "D") { finishCode(); return; }
    if (truncated && !(code=="9" && agentCommand=="codex")) return;
    if (code == "0" || code == "2") {
        if (title) title(data);
    } else if (code == "7" && !alternate && outputContext && data.substr(0,7) == "file://") {
        setOutputContext(outputContext("osc7",data));
    } else if (code == "8") {
        take(';'); // Optional OSC 8 parameters.
        active().link = hyperlink && !data.empty() ? hyperlink(data,alternate ? 0 : context) : 0;
        writeTag = active().link ? active().link : (alternate ? 0 : context);
    } else if (code == "7501" && agentCommand=="agy") {
        if (data=="?") {
            if (reply) reply("\033]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\033\\");
            return;
        }
        std::string_view status, message;
        while (!data.empty()) {
            auto field = take(':');
            if (field.substr(0,6)=="state=") status = field.substr(6);
            if (field.substr(0,4)=="msg=") message = field.substr(4);
        }
        if (status=="working") reportedTurn = false;
        if ((status=="done" || status=="error") && !reportedTurn) finishAgentTurn(status=="error",decodeNoticeText(message));
    } else if (code == "9" && agentCommand=="codex" && !data.empty()) {
        // Numeric subcommands include progress (OSC 9;4); these are not notifications.
        auto prefix = data.substr(0,data.find(';'));
        if (prefix.empty() || prefix.find_first_not_of("0123456789")!=prefix.npos) {
            if (truncated) {
                // A capped preview may end partway through a UTF-8 scalar.
                size_t last = data.size()-1;
                while (last && (uint8_t(data[last])&0xc0)==0x80) --last;
                data = data.substr(0,last);
            }
            finishAgentTurn(false,data=="Agent turn complete" ? std::string_view{} : data);
        }
    } else if (code == "777" && !commandExitToken.empty()) {
        auto event = take(';');
        if (event=="yaaterm-turn") {
            auto agent = take(';');
            if (!agentCommand.empty() && agent==agentCommand && agent!="agy" && agent!="codex")
                finishAgentTurn(false,decodeNoticeText(data));
            return;
        }
        if (take(';') != commandExitToken) return;
        if (event=="yaaterm-begin") {
            awaitingPromptRedraw=false;
            if (!alternate && commandBegan) commandBegan(data);
            return;
        }
        if (event=="yaaterm-editor") {
            auto id=take(';');
            if (!alternate && agentEditor && id.size()==36 && (data=="ready" || data=="task" || data=="cancel" || data=="review" || data=="closed"))
                agentEditor(id,data);
            return;
        }
        if (event=="yaaterm-input") {
            auto id=take(';');
            if (inputAccepted && id.size()==36 && (data=="0" || data=="1")) inputAccepted(id,data=="1");
            return;
        }
        if (event=="yaaterm-end") {
            finishCode();
            auto status = take(';');
            if (status.empty()) return;
            int value = 0;
            auto end = status.data()+status.size();
            auto parsed = std::from_chars(status.data(),end,value);
            if (!alternate && promptReturned && parsed.ec==std::errc{} && parsed.ptr==end && value>=0 && value<=255)
                promptReturned(value,data);
            return;
        }
        if (event=="yaaterm-agent") {
            agentCommand = isAgentCommand(data) ? data : std::string_view{};
            reportedTurn = false;
            return;
        }
        if (event == "yaaterm-context") {
            auto kind = take(';');
            finishCode();
            if (showCode && !alternate) codePreview.begin(kind);
            updateWriteColumns();
            if (!alternate && outputContext) {
                context = outputContext(kind,data);
                active().link = 0; writeTag = context;
            }
            return;
        }
        if (event != "yaaterm-exit") return;
        auto name = take(';'), codeField = take(';');
        if (name.empty() || name.size()>64 || codeField.empty() || data.empty()) return;
        for (char c : name) {
            if (!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') ||
                  c=='_' || c=='-' || c=='+' || c=='.')) return;
        }
        auto integer = [](std::string_view field, int &value) {
            auto end = field.data()+field.size();
            auto result = std::from_chars(field.data(),end,value);
            return result.ec == std::errc{} && result.ptr == end && value>=0;
        };
        int status, seconds;
        if (integer(codeField,status) && status<=255 && integer(data,seconds)) {
            bool duplicate = reportedTurn && name==agentCommand && status==0;
            agentCommand.clear(); reportedTurn = false;
            if (commandExited && !duplicate) commandExited(name,status,seconds);
        }
    }
}

void Screen::byte(uint8_t c) {
    auto &b = active();
    if (state == Text && remaining) {
        if ((c & 0xc0) == 0x80) {
            scalar = (scalar << 6) | (c & 63);
            if (--remaining == 0)
                put(scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff) ? 0xfffd : scalar);
            return;
        }
        remaining = 0; put(0xfffd);
    }
    if (state == OSC || state == OSCExit || state == Ignore || state == IgnoreExit) {
        bool osc = state == OSC || state == OSCExit;
        if (c==24 || c==26) { state = Text; return; }
        if ((osc && c == 7) || (c == '\\' && (state == OSCExit || state == IgnoreExit))) {
            if (osc) finishOSC(); else state = Text;
        } else if (c == 27) state = osc ? OSCExit : IgnoreExit;
        else {
            state = osc ? OSC : Ignore;
            if (osc && c >= 32) {
                if (sequence.size()<2048 || (sequence.size()<4096 && agentCommand=="agy" && sequence.compare(0,5,"7501;")==0))
                    sequence += c;
                else truncated = true;
            }
        }
        return;
    }
    if (c == 27) { graphicAdjacent = false; state = Escape; return; }
    if (c < 32) {
        if (!c && codePreview.active()) { codePreview = {}; updateWriteColumns(); }
        graphicAdjacent = false;
        if (c == 13) { b.cursor.x = 0; b.cursor.wrapPending = false; }
        else if (c == 10 || c == 11 || c == 12) lineFeed();
        else if (c == 8) { b.cursor.x = std::max(0,b.cursor.x-1); b.cursor.wrapPending = false; }
        else if (c == 9) moveTabs(1,true);
        else if (c == 14 || c == 15) b.cursor.shift = c==14;
        else if (c == 24 || c == 26) state = Text;
        return;
    }
    if (c == 127) return;
    if (state == Charset) {
        if ((charsetTarget=='(' || charsetTarget==')') && (c=='0' || c=='A' || c=='B'))
            b.cursor.charsets[charsetTarget==')'] = c;
        state = Text; return;
    }
    if (state == Escape) {
        state = Text;
        sequence.clear(); truncated = false;
        switch (c) {
            case '[': state = CSI; break;
            case ']': state = OSC; break;
            case 'P': case '^': case '_': state = Ignore; break;
            case '(': case ')': case '#': case '%': charsetTarget = c; state = Charset; break;
            case 'H': tabs.set(b.cursor.x); break;
            case '7': control('s'); break;
            case '8': control('u'); break;
            case 'D': lineFeed(); break;
            case 'E': b.cursor.x = 0; lineFeed(); break;
            case 'M': if (b.cursor.y == b.top) scroll(b.top,b.bottom,false,false); else b.cursor.y = std::max(0,b.cursor.y-1); break;
        }
        return;
    }
    if (state == CSI) {
        if (c >= 0x40 && c <= 0x7e) {
            // Cursor-addressed output must use the width reported to the application.
            if (c != 'm' && codePreview.active()) finishCode();
            if (!truncated) control(c);
            state = Text;
        }
        else if (sequence.size() < 192) sequence += c; else truncated = true;
        return;
    }
    if (c < 127) {
        char charset = b.cursor.charsets[b.cursor.shift];
        static constexpr char32_t dec[] = U" ◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·";
        if (charset=='0' && c>=0x5f) put(dec[c-0x5f]);
        else if (charset=='A' && c=='#') put(U'£');
        else put(c);
    }
    else if (c >= 0xc2 && c <= 0xdf) { remaining=1; scalar=c&31; minimum=0x80; }
    else if (c >= 0xe0 && c <= 0xef) { remaining=2; scalar=c&15; minimum=0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { remaining=3; scalar=c&7; minimum=0x10000; }
    else if (c != 127) put(0xfffd);
}

void Screen::feed(std::string_view bytes) {
    if (frozen()) thaw();
    bufferChanged = false;
    dirtyFirst = dirtyLast = y();
    for (size_t pos=0; pos<bytes.size();) {
        uint8_t c = bytes[pos];
        if (c>=32 && c<127 && state==Text && !remaining && !insert) {
            auto &buffer = active();
            auto &cursor = buffer.cursor;
            auto &line = buffer.row(cursor.y);
            if (!cursor.wrapPending && cursor.x<writeColumns && cursor.charsets[cursor.shift]=='B') {
                const int start = cursor.x;
                const char *input = bytes.data()+pos;
                const int count = (int)printableRun(input,std::min(bytes.size()-pos,(size_t)(writeColumns-start)));
                const int end = start+count;
                if (writingCodeLine || !start || start<line.written) line.codeLine = writingCodeLine;
                // Let writeGlyph repair partial wide glyphs using the same erase
                // attributes and row metadata as individual character writes.
                if (line[start].width==0 || (end<cols && line[end].width==0) ||
                    (end==cols && line[end-1].width==2)) {
                    for (int i=0; i<count; ++i) put(input[i]);
                    pos += count;
                    continue;
                }
                const auto pen = cursor.pen;
                const auto tag = writeTag;
                for (int i=0; i<count; ++i) line[start+i] = Cell{pen,(uint8_t)input[i],0,1,tag};
                pos += count;
                cursor.x = end;
                line.written = std::max<int>(line.written,end);
                line.agentStamp = alternate ? 0 : agentStamp;
                if (cursor.x==writeColumns) { cursor.wrapPending = true; --cursor.x; }
                graphicAdjacent = true;
                damage(cursor.y,cursor.y);
                continue;
            }
        }
        if (state == CSI && c >= 0x40 && c <= 0x7e) damage(y(), y());
        byte(c); ++pos;
    }
    damage(y(), y());
}
}
