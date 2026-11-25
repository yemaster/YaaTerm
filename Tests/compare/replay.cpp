#include <chrono>
#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>

#ifdef BENCH_GHOSTTY
#include <ghostty/vt.h>
static void check(GhosttyResult result) {
    if (result != GHOSTTY_SUCCESS) std::abort();
}
#else
#include "Screen.hpp"
#endif

int main(int argc, char **argv) {
    if (argc != 3) return 1;
    std::setlocale(LC_CTYPE, "en_US.UTF-8");
    std::ifstream file(argv[1], std::ios::binary);
    std::string input{std::istreambuf_iterator<char>(file), {}};
    int repeats = std::stoi(argv[2]);
    if (input.empty() || repeats <= 0) return 1;

#ifdef BENCH_GHOSTTY
    GhosttyTerminal term;
    check(ghostty_terminal_new(nullptr, &term, 100, 32));
    size_t history = 0;
    check(ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &history));
#else
    yaa::Screen term(100, 32);
    term.setHistoryLimit(0);
#endif
    auto start = std::chrono::steady_clock::now();
    for (int n = 0; n < repeats; ++n) {
#ifdef BENCH_GHOSTTY
        ghostty_terminal_vt_write(term, reinterpret_cast<const uint8_t *>(input.data()), input.size());
#else
        term.feed(input);
#endif
    }
    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("%.9f\n", seconds);
    // Emit the visible base characters outside the timed section for independent validation.
    for (uint32_t y = 0; y < 32; ++y) {
        for (uint16_t x = 0; x < 100; ++x) {
#ifdef BENCH_GHOSTTY
            GhosttyGridRef ref{};
            GhosttyPoint point{};
            point.tag = GHOSTTY_POINT_TAG_ACTIVE;
            point.value.coordinate = {x, y};
            GhosttyCell cell;
            uint32_t ch;
            check(ghostty_terminal_grid_ref(term, point, &ref));
            check(ghostty_grid_ref_cell(&ref, &cell));
            check(ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &ch));
#else
            uint32_t ch = term.row(y)[x].ch;
#endif
            std::printf("%x ", ch ? ch : 32);
        }
        std::putchar('\n');
    }
#ifdef BENCH_GHOSTTY
    ghostty_terminal_free(term);
#endif
}
