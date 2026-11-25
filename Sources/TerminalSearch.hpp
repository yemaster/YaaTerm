#pragma once
#include "Screen.hpp"

namespace yaa {
struct TextMatch { TextPoint first, last; }; // Inclusive cells, in display order.

// A resumable scan. Memory depends on the query length, never the number of hits.
class TerminalSearch {
public:
    enum Result { Searching, Found, NotFound };
    TerminalSearch(std::u32string query, bool backwards, TextPoint from, int64_t rows, int64_t firstRow = 0);
    Result step(const Screen &screen, int rowBudget);
    TextMatch match;
    bool wrapped = false;
private:
    struct Glyph { TextPoint point; int width; };
    bool accept(char32_t ch, Glyph glyph);
    std::u32string pattern;
    std::vector<size_t> prefix;
    std::vector<Glyph> recent;
    size_t matched = 0, head = 0;
    int64_t count, row, lower;
    int column;
    bool reverse, canWrap;
};
int fragmentEnd(const Row &row, int start, int columns);
TextPoint moveDisplayRow(const Screen &screen, TextPoint point, bool forward);
int fragmentStart(const Row &row, int column, int columns);
}
