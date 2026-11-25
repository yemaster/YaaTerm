#include "Screen.hpp"
#include <chrono>
#include <clocale>
#include <cstdio>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>

// Replay the same varied block at each height. Timing excludes the producer and
// covers UTF-8/SGR parsing, screen scrolling and the compressed disk archive.
int main() {
    using Clock = std::chrono::steady_clock;
    std::setlocale(LC_CTYPE,"en_US.UTF-8");
    std::string block;
    for (int i=0; i<1000; ++i) {
        block += "\033[32mINFO\033[0m ";
        block += std::to_string(i);
        block += i%2 ? u8" 已完成 src/terminal/render.cpp " : " reading src/terminal/input.cpp ";
        block.append(i%37,'x');
        block += "\r\n";
    }
    for (int height : {32,120,300}) {
        yaa::Screen screen(100,height);
        auto start = Clock::now();
        for (int batch=1; batch<=1000; ++batch) {
            screen.feed(block);
            if (batch!=100 && batch!=1000) continue;
            double seconds = std::chrono::duration<double>(Clock::now()-start).count();
            auto &oldest = screen.lineAt(0);
            if (screen.historySize()!=batch*1000-height+1 || screen.archiveFailed() ||
                oldest.empty() || oldest.front().ch!='I' || oldest.front().style.fg!=yaa::Indexed+2 ||
                screen.row(height-2).front().ch!='I') return 1;
            rusage_info_v0 usage{};
            if (proc_pid_rusage(getpid(),RUSAGE_INFO_V0,(rusage_info_t *)&usage)!=0) return 1;
            std::printf("%3d rows | %7d lines | %6.1f MiB/s | %5.2f MiB process footprint\n",
                        height,batch*1000,block.size()*batch/(1048576.*seconds),usage.ri_phys_footprint/1048576.);
        }
    }
}
