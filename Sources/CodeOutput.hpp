#pragma once
#include "TerminalRow.hpp"
#include <string_view>

namespace yaa {
// A single streaming lexer per pane; no token lists or retained source text.
class CodePreview {
public:
    void begin(std::string_view kind);
    void finishRow(Row &row, int end, bool wraps);
    bool active() const { return language != None; }
private:
    enum Language : uint8_t { None, Plain, CLike, JavaScript, Python, Shell, Json, Config, Sql };
    enum Mode : uint8_t { Normal, LineComment, BlockComment, String };
    Language language = None;
    Mode mode = Normal;
    char32_t quote = 0, pendingDelimiter = 0;
    bool triple = false, escaped = false, continued = false, numbered = false;
    uint32_t line = 1;
};
}
