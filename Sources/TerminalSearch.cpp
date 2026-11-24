#include "TerminalSearch.hpp"
#include "Emoji.hpp"
#include <climits>
#include <cwctype>

namespace yaa {
static char32_t folded(char32_t c) {
    if (c < 128) return c >= U'A' && c <= U'Z' ? c+32 : c;
    return std::towlower(c);
}
TerminalSearch::TerminalSearch(std::u32string query, bool backwards, TextPoint from, int64_t rows, int64_t firstRow)
    : pattern(std::move(query)), prefix(pattern.size()), recent(pattern.size()), count(rows),
      row(from.row), lower(firstRow), column(from.column), reverse(backwards),
      canWrap(reverse ? row != count-1 || column != INT_MAX : row != lower || column != 0) {
    for (auto &ch : pattern) ch = folded(ch);
    if (reverse) std::reverse(pattern.begin(),pattern.end());
    for (size_t i=1, j=0; i<pattern.size(); ++i) {
        while (j && pattern[i] != pattern[j]) j = prefix[j-1];
        if (pattern[i] == pattern[j]) ++j;
        prefix[i] = j;
    }
}
bool TerminalSearch::accept(char32_t ch, Glyph glyph) {
    ch = folded(ch);
    if (!matched && pattern.front() != ch) return false;
    recent[head] = glyph;
    if (++head == recent.size()) head = 0;
    while (matched && pattern[matched] != ch) matched = prefix[matched-1];
    if (pattern[matched] == ch) ++matched;
    if (matched != pattern.size()) return false;
    Glyph first = recent[head], last = glyph;
    if (reverse) std::swap(first,last);
    match = {first.point,{last.point.row,last.point.column+last.width-1}};
    return true;
}
TerminalSearch::Result TerminalSearch::step(const Screen &screen, int rowBudget) {
    if (pattern.empty() || !count || count > screen.historySize()+screen.height) return NotFound;
    while (rowBudget-- > 0) {
        if (row < lower || row >= count) {
            if (!canWrap || wrapped) return NotFound;
            wrapped = true; matched = 0;
            row = reverse ? count-1 : lower; column = reverse ? INT_MAX : 0;
        }
        const Row &cells = screen.lineAt(row);
        int end = cells.wrapAt ? cells.wrapAt : cells.used();
        if (reverse && !cells.wrapAt) matched = 0;
        int x = reverse ? std::min(column,end-1) : std::max(0,column);
        for (; x>=0 && x<end; x += reverse ? -1 : 1) {
            const auto &c = cells[x];
            if (!c.width) continue;
            Glyph glyph{{row,x},(int)c.width};
            if (!reverse && accept(c.ch,glyph)) return Found;
            if (c.mark) {
                char32_t buffer[emoji::maxScalars];
                auto tail = emoji::suffix(c.mark,buffer);
                for (size_t i=0; i<tail.size(); ++i)
                    if (accept(tail[reverse ? tail.size()-1-i : i],glyph)) return Found;
            }
            if (reverse && accept(c.ch,glyph)) return Found;
        }
        if (!reverse && !cells.wrapAt) matched = 0;
        row += reverse ? -1 : 1; column = reverse ? INT_MAX : 0;
    }
    return Searching;
}

int fragmentEnd(const Row &row, int start, int columns) {
    int used = row.wrapAt ? row.wrapAt : row.used();
    int end = std::min(start+columns,used);
    if (end < used && row[end].width == 0) --end;
    return std::max(start,end);
}
int fragmentStart(const Row &row, int column, int columns) {
    int start = 0;
    while (start+columns <= column || (start+columns-1 == column && column+1<(int)row.size() && !row[column+1].width)) {
        int end = fragmentEnd(row,start,columns);
        if (end <= start || end > column) break;
        start = end;
    }
    return start;
}
TextPoint moveDisplayRow(const Screen &screen, TextPoint point, bool forward) {
    if (forward) {
        if (point.row < screen.historySize()) {
            const auto &cells = screen.lineAt(point.row);
            if ((int)cells.size() > screen.cols) {
                int end = fragmentEnd(cells,point.column,screen.cols);
                if (end < (cells.wrapAt ? cells.wrapAt : cells.used())) return {point.row,end};
            }
        }
        return {point.row+1,0};
    }
    if (!point.column && !point.row) return point;
    if (point.column) return {point.row,fragmentStart(screen.lineAt(point.row),point.column-1,screen.cols)};
    const Row &cells = screen.lineAt(--point.row);
    int width = cells.wrapAt ? cells.wrapAt : cells.used();
    point.column = fragmentStart(cells,std::max(0,width-1),screen.cols);
    return point;
}
}
