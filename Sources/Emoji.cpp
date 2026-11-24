#include "Emoji.hpp"
#include <algorithm>

namespace yaa::emoji {
struct Node { char32_t scalar; uint16_t parentFlags, firstChild; };
static constexpr Node nodes[] = {
#include "EmojiData.inc"
};
static uint16_t child(uint16_t index, char32_t scalar) {
    auto begin = nodes + nodes[index].firstChild, end = nodes + nodes[index+1].firstChild;
    auto it = std::lower_bound(begin,end,scalar,[](Node n,char32_t c){ return n.scalar < c; });
    return it != end && it->scalar == scalar ? static_cast<uint16_t>(it-nodes) : 0;
}
bool wideBase(char32_t base) { return (nodes[child(0,base)].parentFlags & 0x8000) != 0; }
bool wideMark(uint32_t mark) { return (nodes[mark-firstMark].parentFlags & 0x8000) != 0; }
uint32_t extend(char32_t base, uint32_t mark, char32_t next) {
    uint16_t node;
    if (mark >= firstMark) node = mark-firstMark;
    else {
        if (mark || !(next==0x200d || next==0xfe0f || next==0x20e3 ||
                      (next>=0x1f1e6 && next<=0x1f1ff) || (next>=0x1f3fb && next<=0x1f3ff) ||
                      (next>=0xe0020 && next<=0xe007e))) return 0;
        node = child(0,base);
        if (!node) return 0;
    }
    uint16_t result = child(node,next);
    return result ? firstMark+result : 0;
}
std::u32string_view suffix(uint32_t mark, char32_t (&buffer)[maxScalars]) {
    if (mark < firstMark) {
        buffer[0] = mark;
        return {buffer, mark ? 1u : 0u};
    }
    unsigned start = maxScalars;
    uint16_t index = mark-firstMark;
    while (nodes[index].parentFlags & 0x7fff) {
        buffer[--start] = nodes[index].scalar;
        index = nodes[index].parentFlags & 0x7fff;
    }
    return {buffer+start, maxScalars-start};
}
}
