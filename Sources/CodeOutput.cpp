#include "CodeOutput.hpp"
#include <array>
#include <iterator>

namespace yaa {
void CodePreview::begin(std::string_view kind) {
    *this = {};
    numbered = kind.substr(0,9) == "numbered:";
    if (!numbered && kind.substr(0,5) != "code:") return;
    auto family = kind.substr(numbered ? 9 : 5);
    if (family == "text") language = Plain;
    else if (family == "c") language = CLike;
    else if (family == "js") language = JavaScript;
    else if (family == "python") language = Python;
    else if (family == "shell") language = Shell;
    else if (family == "json") language = Json;
    else if (family == "config") language = Config;
    else if (family == "sql") language = Sql;
}

static bool digit(char32_t c) { return c >= '0' && c <= '9'; }
static bool letter(char32_t c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; }
namespace {
constexpr std::string_view words[] = {
    // Literals take the first seven slots and use the number color.
    "true","false","null","nil","True","False","None",
    "and","as","async","await","bool","break","case","catch","char","class","const","continue","create",
    "def","default","defer","delete","do","double","elif","else","end","enum","except","export","extends",
    "fi","finally","float","fn","for","from","func","function","go","guard","if","impl","import","in",
    "include","insert","int","interface","into","join","let","local","long","match","new","not","or",
    "package","pass","private","protected","protocol","pub","public","raise","range","return","select",
    "self","static","string","struct","switch","then","this","throw","throws","trait","try","type",
    "typedef","union","unsigned","update","use","using","values","var","void","where","while","with","yield"
};
static_assert(std::size(words)<256);
constexpr uint32_t wordHash(uint32_t hash, char c) { return hash*33u+uint8_t(c); }
// Byte indices into a static vocabulary. The hot loop hashes each identifier while reading it.
constexpr auto wordIndex = [] {
    std::array<uint8_t,256> table{};
    for (unsigned i=0; i<std::size(words); ++i) {
        uint32_t hash = 0;
        for (char c : words[i]) hash = wordHash(hash,c);
        uint8_t bucket = hash;
        while (table[bucket]) ++bucket;
        table[bucket] = i+1;
    }
    return table;
}();
int wordColor(std::string_view word, uint32_t hash) {
    for (uint8_t bucket=hash; wordIndex[bucket]; ++bucket) {
        unsigned i = wordIndex[bucket]-1;
        if (words[i] == word) return CodeColor + (i<7 ? 3 : 5);
    }
    return Default;
}
}
void CodePreview::finishRow(Row &row, int end, bool wraps) {
    if (!numbered) row.codeLine = continued ? ContinuedCodeLine : line;
    auto ch = [&](int x) -> char32_t { return x < end ? row[x].ch : 0; };
    auto paint = [&](int start, int stop, int color) {
        for (int x=start; x<stop; ++x)
            if (row[x].style.fg == Default && !(row[x].style.flags & Inverse)) row[x].style.fg = color;
    };
    int x = 0;
    if (numbered && !continued) {
        while (x < end && ch(x) == ' ') ++x;
        int start = x;
        if (ch(x) == '-') ++x;
        int digits = x;
        while (digit(ch(x))) ++x;
        if (x > digits && (x == end || ch(x) == ' ')) paint(start,x,CodeMuted);
        else x = start;
    }
    // An extensionless script often identifies its interpreter on the first line.
    if (language == Plain && line == 1 && !continued) {
        while (x < end && ch(x) == ' ') ++x;
        if (ch(x) == '#' && ch(x+1) == '!') {
            char header[96];
            int len = 0;
            for (int i=x+2; i<end && len<(int)sizeof(header) && ch(i)<128; ++i) header[len++] = ch(i);
            std::string_view interpreter(header,len);
            if (interpreter.find("python") != interpreter.npos) language = Python;
            else if (interpreter.find("node") != interpreter.npos) language = JavaScript;
            else if (interpreter.find("sh") != interpreter.npos || interpreter.find("ruby") != interpreter.npos) language = Shell;
        }
    }
    const bool slash = language == CLike || language == JavaScript || language == Json;
    const bool hash = language == Python || language == Shell || language == Config;
    // Delimiters may straddle two physical grid rows of the same source line.
    if (pendingDelimiter == '*' && ch(x) == '/') {
        paint(x,x+1,CodeMuted); ++x; mode = Normal;
    } else if (pendingDelimiter == '/' && ((slash && ch(x) == '/') || ch(x) == '*')) {
        mode = ch(x) == '/' ? LineComment : BlockComment;
        paint(x,x+1,CodeMuted); ++x;
    } else if (pendingDelimiter == '-' && ch(x) == '-') mode = LineComment;
    pendingDelimiter = 0;
    while (language != Plain && x < end) {
        int start = x;
        char32_t c = ch(x);
        if (mode == Normal) {
            if ((hash && c == '#') || (slash && c == '/' && ch(x+1) == '/') ||
                (language == Sql && c == '-' && ch(x+1) == '-')) mode = LineComment;
            else if ((slash || language == Sql) && c == '/' && ch(x+1) == '*') { mode = BlockComment; x += 2; }
            else if (c == '"' || (c == '\'' && language != Json) || (c == '`' && language == JavaScript)) {
                mode = String; quote = c; escaped = false;
                triple = language == Python && ch(x+1) == c && ch(x+2) == c;
                x += triple ? 3 : 1;
            } else if (letter(c)) {
                char word[24];
                uint32_t hash = 0;
                while (x < end && (letter(ch(x)) || digit(ch(x)))) {
                    char32_t v = ch(x);
                    if (x-start < (int)sizeof(word)) {
                        char c = language == Sql && v >= 'A' && v <= 'Z' ? v+32 : v;
                        word[x-start] = c; hash = wordHash(hash,c);
                    }
                    ++x;
                }
                if (x-start <= (int)sizeof(word)) {
                    int color = wordColor({word,(size_t)(x-start)},hash);
                    if (language == Config && (ch(x) == ':' || ch(x) == '=')) color = CodeColor+6;
                    else if ((language == Json || language == Config) && color == CodeColor+5) color = Default;
                    if (color != Default) paint(start,x,color);
                }
                continue;
            } else if (digit(c)) {
                do { ++x; } while (digit(ch(x)) || ch(x) == '.' || ch(x) == '_');
                paint(start,x,CodeColor+3); continue;
            } else {
                if (wraps && x+1 == end && (((slash || language == Sql) && c == '/') || (language == Sql && c == '-')))
                    pendingDelimiter = c;
                ++x; continue;
            }
        }
        if (mode == LineComment) { paint(start,end,CodeMuted); break; }
        if (mode == BlockComment) {
            while (x < end) {
                if (ch(x++) == '*') {
                    if (ch(x) == '/') { ++x; mode = Normal; break; }
                    if (wraps && x == end) pendingDelimiter = '*';
                }
            }
            paint(start,x,CodeMuted);
        } else {
            while (x < end) {
                char32_t v = ch(x++);
                if (escaped) { escaped = false; continue; }
                if (v == '\\') { escaped = true; continue; }
                if (v == quote && (!triple || (ch(x) == quote && ch(x+1) == quote))) {
                    if (triple) x += 2;
                    mode = Normal; break;
                }
            }
            int after = x;
            if (language == Json) while (after < end && ch(after) == ' ') ++after;
            paint(start,x,language == Json && ch(after) == ':' ? CodeColor+6 : CodeColor+2);
        }
    }
    continued = wraps;
    if (!wraps) {
        if (mode == LineComment || (mode == String && !triple && quote != '`' && language != Shell &&
            language != Sql && !escaped)) mode = Normal;
        escaped = false;
        if (line < ContinuedCodeLine-1) ++line;
    }
}
}
