#pragma once
#include <cstdint>
#include <string_view>

namespace yaa::emoji {
// Scalar values fit below this range in Cell::mark. Larger marks index a shared,
// immutable prefix tree and survive memcpy, scrollback compression and reflow.
constexpr uint32_t firstMark = 0x110000;
constexpr unsigned maxScalars = 16;
uint32_t extend(char32_t base, uint32_t mark, char32_t next);
bool wideBase(char32_t base);
bool wideMark(uint32_t mark);
std::u32string_view suffix(uint32_t mark, char32_t (&buffer)[maxScalars]);
}
