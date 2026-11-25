#pragma once
#include <cstdint>
#include <vector>

namespace yaa {
constexpr int32_t Default = -1;
constexpr int32_t Indexed = 1 << 24;
enum Attribute : uint8_t { Bold = 1, Underline = 2, Inverse = 4, Italic = 8 };
struct Style {
    // A color is either RGB, a palette index, or the default sentinel.
    int32_t fg : 26;
    uint32_t flags : 6;
    int32_t bg;
    constexpr Style() : fg(Default), flags(0), bg(Default) {}
    bool operator==(const Style &s) const { return fg == s.fg && bg == s.bg && flags == s.flags; }
};
struct Cell {
    Style style;
    uint64_t ch : 21;
    uint64_t mark : 21;
    uint64_t tag : 20; // Session-local reference, shared by a whole listing or hyperlink.
    uint64_t width : 2; // Zero denotes the continuation of a wide glyph.
    constexpr Cell(Style s = {}, char32_t c = U' ', char32_t m = 0, unsigned w = 1, uint32_t reference = 0)
        : style(s), ch(c), mark(m), tag(reference), width(w) {}
};
static_assert(sizeof(Cell) == 16);
struct Row : std::vector<Cell> {
    using std::vector<Cell>::vector;
    // Nonzero when the next row continues this one. A wide glyph can wrap one column early.
    uint16_t wrapAt = 0; // Screen width is limited to 1000 columns.
    uint16_t agentStamp = 0; // Nonzero block ID in the upper bits, output (vs. echo) in bit zero.
    int written = 0; // Includes explicit trailing spaces, excludes untouched padding.
    int used() const {
        int n = (int)size();
        while (n > written && (*this)[n-1].ch == U' ' && !(*this)[n-1].mark && (*this)[n-1].style == Style{}) --n;
        return n;
    }
};
}
