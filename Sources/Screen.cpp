#include "Screen.hpp"
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
    if (!archive->append(history.front())) ++historyGeneration;
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
    if (!limit) { history.clear(); hotBytes = 0; archive.reset(); ++historyGeneration; return; }
    while (history.size() > limit) {
        hotBytes -= history.front().capacity()*sizeof(Cell);
        spillOldest(); history.pop_front();
    }
}

void Screen::clearHistory() {
    if (frozen()) thaw();
    if (!alternate) { history.clear(); hotBytes = 0; archive.reset(); ++historyGeneration; }
}

void Screen::resize(int w, int h) {
    w = std::clamp(w, 2, 1000);
    h = std::clamp(h, 1, 500);
    if (w == cols && h == height) return;
    if (frozen()) thaw();
    resizeBuffer(active(), w, h);
    cols = w; height = h;
}

void Screen::resizeBuffer(Buffer &b, int w, int h) {
    int oldHeight = (int)b.rows.size();
    int oldWidth = oldHeight ? (int)b.rows.front().size() : 0;
    if (oldHeight == h && oldWidth == w) return;
    ++historyGeneration;
    if (&b == &main && oldWidth && oldWidth != w) { reflowMain(w,h); return; }
    int bottom = b.cursor.y;
    if (&b == &main && h < oldHeight)
        for (int y=oldHeight-1; y>bottom; --y) if (b.rows[y].used()) { bottom = y; break; }
    int shift = std::max(0, bottom - h + 1);
    if (&b == &main && historyLimit)
        for (int i = 0; i < shift; ++i) remember(std::move(b.rows[i]));
    b.rows.erase(b.rows.begin(), b.rows.begin()+shift);
    b.rows.resize(h);
    for (auto &r : b.rows) {
        r.resize(w); r.written = std::min(r.written,w);
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
    auto emit = [&](bool soft) {
        out.wrapAt = soft ? filled : 0; out.written = filled;
        visible.push_back(std::move(out)); ++emitted;
        if ((int)visible.size() > h) {
            if (historyLimit) out = remember(std::move(visible.front()));
            else out = std::move(visible.front());
            visible.pop_front();
        }
        out.assign(w,Cell{}); out.wrapAt = out.written = 0; filled = 0;
    };
    for (int y=0; y<=last; ++y) {
        const Row &src = b.rows[y];
        int end = src.wrapAt ? src.wrapAt : src.used();
        auto insertion = [&](const Cursor &c) { return c.x + (c.wrapPending ? 1 : 0); };
        if (b.cursor.y == y) end = std::max(end,insertion(b.cursor));
        if (b.saved.y == y) end = std::max(end,insertion(b.saved));
        end = std::min(end,(int)src.size());
        auto place = [&](int col) {
            auto map = [&](const Cursor &c,Cursor &dest) {
                if (c.y == y && insertion(c) == col) {
                    dest.y = emitted; dest.x = std::min(w-1,filled); dest.wrapPending = filled == w;
                }
            };
            map(b.cursor,next); map(b.saved,saved);
        };
        for (int x=0; x<end;) {
            int width = src[x].width == 2 && x+1<end ? 2 : 1;
            if (filled+width > w) emit(true);
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
    return active().rows[i];
}
const Row &Screen::row(int y, int64_t offset) const {
    if (!offset) return active().rows[y];
    return lineAt(historySize()-std::clamp<int64_t>(offset,0,historySize())+y);
}

void Screen::scroll(int first, int last, bool up, bool save) {
    damage(first, last);
    auto &rows = active().rows;
    Row spare;
    if (up) {
        if (save && !alternate && historyLimit && first == 0 && last == height - 1) {
            spare = remember(std::move(rows[first]));
        } else spare = std::move(rows[first]);
        std::move(rows.begin() + first + 1, rows.begin() + last + 1, rows.begin() + first);
        spare.assign(cols, blank()); spare.wrapAt = spare.written = 0;
        rows[last] = std::move(spare);
    } else {
        spare = std::move(rows[last]);
        std::move_backward(rows.begin() + first, rows.begin() + last, rows.begin() + last + 1);
        spare.assign(cols, blank()); spare.wrapAt = spare.written = 0;
        rows[first] = std::move(spare);
    }
}

void Screen::lineFeed(int wrapAt) {
    auto &b = active();
    b.rows[b.cursor.y].wrapAt = wrapAt;
    b.cursor.wrapPending = false;
    if (b.cursor.y == b.bottom) scroll(b.top, b.bottom, true, true);
    else b.cursor.y = std::min(b.cursor.y + 1, height - 1);
}
void Screen::erase(Row &r, int first, int end) {
    if (first >= end) return;
    if (end == cols) r.wrapAt = 0;
    if (first > 0 && r[first].width == 0) --first;
    if (end < cols && r[end].width == 0) ++end;
    if (end >= r.written) r.written = std::min(r.written,first);
    std::fill(r.begin() + first, r.begin() + end, blank());
}
void Screen::put(char32_t ch) {
    auto &b = active();
    int width = ch < 127 ? 1 : wcwidth(static_cast<wchar_t>(ch));
    if (width == 0) {
        int prev = b.cursor.wrapPending ? b.cursor.x : b.cursor.x - 1;
        if (prev >= 0 && b.rows[b.cursor.y][prev].width == 0) --prev;
        if (prev >= 0) { b.rows[b.cursor.y][prev].mark = ch; damage(b.cursor.y, b.cursor.y); }
        return;
    }
    width = width == 2 ? 2 : 1;
    if (b.cursor.autoWrap && (b.cursor.wrapPending || b.cursor.x + width > cols)) {
        lineFeed(b.cursor.wrapPending ? cols : b.cursor.x); b.cursor.x = 0;
    }
    if (width + b.cursor.x > cols) width = 1;
    damage(b.cursor.y, b.cursor.y);
    auto &r = b.rows[b.cursor.y];
    if (insert) {
        std::move_backward(r.begin() + b.cursor.x, r.end() - width, r.end());
        if (r.written > b.cursor.x) r.written = std::min(cols,r.written+width);
    }
    if (r[b.cursor.x].width != 1 || (b.cursor.x + width < cols && r[b.cursor.x + width].width == 0))
        erase(r, b.cursor.x, b.cursor.x + width);
    r.written = std::max(r.written,b.cursor.x+width);
    r[b.cursor.x] = Cell{b.cursor.pen, ch, 0, (uint8_t)width, writeTag};
    if (width == 2) r[b.cursor.x + 1] = Cell{b.cursor.pen, 0, 0, 0, writeTag};
    b.cursor.wrapPending = b.cursor.x + width >= cols;
    b.cursor.x = std::min(cols - 1, b.cursor.x + width);
}

// Wheel presses have no release event. Coordinates from the view are one-based.
size_t Screen::wheelReport(char (&out)[48], bool up, int modifiers, int col, int row, int pixelX, int pixelY) const {
    if (!mouseTracking) return 0;
    int button = (up ? 64 : 65) + (mouseTracking == 9 ? 0 : modifiers);
    switch (mouseEncoding) {
        case MouseEncoding::SgrPixels: return snprintf(out,sizeof(out),"\033[<%d;%d;%dM",button,pixelX,pixelY);
        case MouseEncoding::Sgr: return snprintf(out,sizeof(out),"\033[<%d;%d;%dM",button,col,row);
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
        case 2004: bracketPaste = on; break;
        case 47: case 1047: case 1049:
            if (on == alternate) break;
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

void Screen::control(char c) {
    bool priv = !sequence.empty() && sequence[0] == '?';
    // Vim's CSI ? 4 m is a keyboard-protocol query, not underline SGR.
    if (priv && c != 'h' && c != 'l' && c != 'n' && c != 'J' && c != 'K') return;
    std::array<int, 32> args{};
    int count = 1;
    for (size_t i = priv; i < sequence.size(); ++i) {
        char k = sequence[i];
        if (k >= '0' && k <= '9') args[count-1] = std::min(9999, args[count-1]*10 + k-'0');
        else if (k == ';' && count < (int)args.size()) ++count;
        else return;
    }
    auto &b = active();
    int a = args[0], n = std::max(1, a);
    if (c != 's' && c != 'u' && c != 'm' && c != 'h' && c != 'l' && c != 'n' && c != 'c') b.cursor.wrapPending = false;
    switch (c) {
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
            damage(0, height-1);
            if (a == 3) { clearHistory(); break; }
            for (int i = 0; i < height; ++i) {
                if (a == 2 || (a == 0 && i > b.cursor.y) || (a == 1 && i < b.cursor.y)) erase(b.rows[i], 0, cols);
                else if (i == b.cursor.y && a <= 1) erase(b.rows[i], a == 0 ? b.cursor.x : 0, a == 0 ? cols : b.cursor.x+1);
            }
            break;
        case 'K': if (a <= 2) erase(b.rows[b.cursor.y], a == 0 ? b.cursor.x : 0, a == 1 ? b.cursor.x+1 : cols); break;
        case 'X': erase(b.rows[b.cursor.y], b.cursor.x, std::min(cols,b.cursor.x+n)); break;
        case 'P': case '@': {
            auto &r = b.rows[b.cursor.y];
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
        case 'c': if (reply) reply("\033[?1;2c"); break;
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

void Screen::finishOSC() {
    state = Text;
    if (truncated) return;
    std::string_view data(sequence);
    auto take = [&](char delimiter) {
        size_t end = data.find(delimiter);
        auto value = data.substr(0,end);
        data = end == data.npos ? std::string_view{} : data.substr(end+1);
        return value;
    };
    auto code = take(';');
    if (code == "0" || code == "2") {
        if (title) title(data);
    } else if (code == "7" && !alternate && outputContext && data.substr(0,7) == "file://") {
        setOutputContext(outputContext("osc7",data));
    } else if (code == "8") {
        take(';'); // Optional OSC 8 parameters.
        active().link = hyperlink && !data.empty() ? hyperlink(data,alternate ? 0 : context) : 0;
        writeTag = active().link ? active().link : (alternate ? 0 : context);
    } else if (code == "777" && !commandExitToken.empty()) {
        auto event = take(';');
        if (take(';') != commandExitToken) return;
        if (event == "yaaterm-context") {
            auto kind = take(';');
            if (!alternate && outputContext) {
                context = outputContext(kind,data);
                active().link = 0; writeTag = context;
            }
            return;
        }
        if (event != "yaaterm-exit" || !commandExited) return;
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
        if (integer(codeField,status) && status<=255 && integer(data,seconds))
            commandExited(name,status,seconds);
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
        if (c == 7 || (c == '\\' && (state == OSCExit || state == IgnoreExit))) {
            if (osc) finishOSC(); else state = Text;
        } else if (c == 27) state = osc ? OSCExit : IgnoreExit;
        else {
            state = osc ? OSC : Ignore;
            if (osc && c >= 32) {
                if (sequence.size() < 2048) sequence += c; else truncated = true;
            }
        }
        return;
    }
    if (c == 27) { state = Escape; return; }
    if (c < 32) {
        if (c == 13) { b.cursor.x = 0; b.cursor.wrapPending = false; }
        else if (c == 10 || c == 11 || c == 12) lineFeed();
        else if (c == 8) { b.cursor.x = std::max(0,b.cursor.x-1); b.cursor.wrapPending = false; }
        else if (c == 9) { b.cursor.x = std::min(cols-1,(b.cursor.x/8+1)*8); b.cursor.wrapPending = false; }
        else if (c == 24 || c == 26) state = Text;
        return;
    }
    if (state == Charset) { state = Text; return; }
    if (state == Escape) {
        state = Text;
        sequence.clear(); truncated = false;
        switch (c) {
            case '[': state = CSI; break;
            case ']': state = OSC; break;
            case 'P': case '^': case '_': state = Ignore; break;
            case '(': case ')': case '#': case '%': state = Charset; break;
            case '7': control('s'); break;
            case '8': control('u'); break;
            case 'D': lineFeed(); break;
            case 'E': b.cursor.x = 0; lineFeed(); break;
            case 'M': if (b.cursor.y == b.top) scroll(b.top,b.bottom,false,false); else b.cursor.y = std::max(0,b.cursor.y-1); break;
        }
        return;
    }
    if (state == CSI) {
        if (c >= 0x40 && c <= 0x7e) { if (!truncated) control(c); state = Text; }
        else if (sequence.size() < 192) sequence += c; else truncated = true;
        return;
    }
    if (c < 127) put(c);
    else if (c >= 0xc2 && c <= 0xdf) { remaining=1; scalar=c&31; minimum=0x80; }
    else if (c >= 0xe0 && c <= 0xef) { remaining=2; scalar=c&15; minimum=0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { remaining=3; scalar=c&7; minimum=0x10000; }
    else if (c != 127) put(0xfffd);
}

void Screen::feed(std::string_view bytes) {
    if (frozen()) thaw();
    bufferChanged = false;
    dirtyFirst = dirtyLast = y();
    for (uint8_t c : bytes) {
        if (state == CSI && c >= 0x40 && c <= 0x7e) damage(y(), y());
        byte(c);
    }
    damage(y(), y());
}
}
