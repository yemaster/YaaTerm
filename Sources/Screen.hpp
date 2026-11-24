#pragma once
#include "History.hpp"
#include <memory>
#include <algorithm>
#include <array>
#include <bitset>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include <wchar.h>

namespace yaa {
struct Cursor {
    int x = 0, y = 0;
    Style pen;
    char charsets[2] = {'B','B'};
    bool shift = false;
    bool wrapPending = false, autoWrap = true, origin = false;
};
struct Buffer {
    std::vector<Row> rows;
    Cursor cursor, saved;
    int top = 0, bottom = 0;
    uint32_t link = 0;
};
enum class MouseAction { Press, Release, Motion };
enum class MouseEncoding { Classic, Utf8 = 1005, Sgr = 1006, Urxvt = 1015, SgrPixels = 1016 };

class Screen {
public:
    static constexpr size_t defaultHistoryLimit = 1500;
    int cols = 0, height = 0;
    bool alternate = false, cursorVisible = true, applicationCursor = false, bracketPaste = false;
    uint64_t linesScrolled = 0;
    bool focusReporting = false;
    int mouseTracking = 0;
    MouseEncoding mouseEncoding = MouseEncoding::Classic;
    bool alternateScroll = true;
    size_t mouseReport(char (&out)[48], int button, MouseAction action, int modifiers,
                       int col, int row, int pixelX, int pixelY) const;
    size_t wheelReport(char (&out)[48], bool up, int modifiers, int col, int row, int pixelX, int pixelY) const;
    bool bufferChanged = false; // Set on any screen switch in the most recent feed.
    int dirtyFirst = 0, dirtyLast = 0;
    void damage(int a, int b) { dirtyFirst = std::min(dirtyFirst, a); dirtyLast = std::max(dirtyLast, b); }
    std::function<void(std::string_view)> title, reply;
    std::string commandExitToken;
    // Callbacks are installed only for enabled presentation features.
    std::function<uint32_t(std::string_view kind, std::string_view directory)> outputContext;
    std::function<uint32_t(std::string_view uri, uint32_t parent)> hyperlink;
    void setOutputContext(uint32_t tag) {
        context = tag;
        if (!alternate && !main.link) writeTag = tag;
    }
    void resetPresentation() { context = writeTag = main.link = alt.link = 0; }
    static bool isAgentCommand(std::string_view name);
    std::function<void(std::string_view,int,int)> commandExited;
    std::function<void(std::string_view,bool)> agentFinished;
    explicit Screen(int w, int h) {
        for (size_t col=8; col<tabs.size(); col+=8) tabs.set(col);
        resize(w,h);
    }
    void resize(int w, int h);
    void setHistoryLimit(size_t limit);
    void feed(std::string_view bytes);
    int64_t historySize() const { return alternate ? 0 : history.size() + archivedRows(); }
    int64_t archivedRows() const { return archive ? archive->size() : 0; }
    bool archiveFailed() const { return archive && archive->failed(); }
    const Row &lineAt(int64_t index) const;
    uint64_t historyGeneration = 0;
    const Row &row(int y, int64_t offset = 0) const;
    int x() const { return active().cursor.x; }
    int y() const { return active().cursor.y; }
    void clearHistory();
    void freeze();
    void thaw();
    bool frozen() const { return !packedRows.empty(); }
private:
    // Row metadata stays in place. Only cell storage is packed during idle sleep.
    std::vector<uint8_t> packedRows;
    template<typename F> void visitRows(F visit) {
        for (auto &r : history) visit(r);
        for (auto &r : main.rows) visit(r);
        for (auto &r : alt.rows) visit(r);
    }
    Buffer main, alt;
    uint32_t context = 0, writeTag = 0;
    std::deque<Row> history;
    std::unique_ptr<HistoryArchive> archive;
    Row remember(Row &&row);
    void spillOldest();
    void reflowMain(int w, int h);
    size_t hotBytes = 0;
    size_t historyLimit = defaultHistoryLimit;
    bool insert = false, graphicAdjacent = false;
    std::bitset<1000> tabs;
    char charsetTarget = 0;
    void moveTabs(int count, bool forward);
    int modeStatus(int n, bool priv) const;
    void writeGlyph(char32_t ch, int width, uint32_t mark);
    enum State { Text, Escape, CSI, OSC, OSCExit, Ignore, IgnoreExit, Charset } state = Text;
    std::string sequence;
    bool truncated = false;
    uint32_t scalar = 0, minimum = 0;
    int remaining = 0;
    Buffer &active() { return alternate ? alt : main; }
    const Buffer &active() const { return alternate ? alt : main; }
    Cell blank() const { return Cell{active().cursor.pen}; }
    void resizeBuffer(Buffer &b, int w, int h);
    void scroll(int first, int last, bool up, bool save);
    void lineFeed(int wrapAt = 0);
    void erase(Row &r, int first, int end);
    bool extendEmoji(char32_t ch);
    void put(char32_t ch);
    void byte(uint8_t c);
    void control(char c);
    std::string agentCommand;
    bool reportedTurn = false;
    void finishAgentTurn(bool failed);
    void finishOSC();
    void mode(int n, bool enabled, bool priv);
};
}
