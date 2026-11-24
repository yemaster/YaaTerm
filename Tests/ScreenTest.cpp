#include "TerminalSearch.hpp"
#include <climits>
#include <cassert>
#include <chrono>
#include <clocale>
#include <iostream>

using namespace yaa;
using namespace std::string_view_literals;
// Cover multiple blocks, on-disk history, saved alternate contents and incomplete UTF-8.
static void checkFreeze() {
    Screen s(100,30), reference(100,30);
    auto feedBoth = [&](std::string_view bytes) { s.feed(bytes); reference.feed(bytes); };
    feedBoth("\033[?47h\033[Hsaved alternate\033[?47l");
    for (int i=0; i<1550; ++i)
        feedBoth("\033[34m" + std::to_string(i) + " 中e\xcc\x81   " + std::string(i%130,'x') + "\033[0m\r\n");
    feedBoth("\033[38;2;9;8;7m partial \xe4");
    assert(s.archivedRows()>32 && s.lineAt(0).size()==100);
    auto check = [&] {
        assert(!s.frozen() && s.historySize()==reference.historySize() && s.x()==reference.x() && s.y()==reference.y());
        for (int64_t i=0; i<s.historySize()+s.height; ++i) {
            const Row &a = s.lineAt(i), &b = reference.lineAt(i);
            assert(a.size()==b.size() && a.written==b.written && a.wrapAt==b.wrapAt);
            for (size_t j=0; j<a.size(); ++j)
                assert(a[j].ch==b[j].ch && a[j].mark==b[j].mark && a[j].width==b[j].width && a[j].style==b[j].style);
        }
    };
    s.freeze(); assert(s.frozen()); s.freeze();
    feedBoth("\xb8\xad!");
    check();
    s.freeze(); s.thaw(); check();
    feedBoth("\033[?47h"); check();
    s.freeze(); s.resize(72,24); reference.resize(72,24); check();
    feedBoth("\033[?47l"); check();
}

int main() {
    setlocale(LC_CTYPE,"en_US.UTF-8");
    checkFreeze();
    Screen s(6,3);
    s.feed("abc\033[2D!"); assert(s.row(0)[1].ch == '!');
    s.feed("\033[2J\033[H\033[38;2;11;22;33mA");
    assert(s.row(0)[0].style.fg == 0x0b1621);
    s.feed("\033[0m\xe4"); s.feed("\xb8\xad");
    assert(s.row(0)[1].ch == U'中' && s.row(0)[2].width == 0 && s.x()==3);
    s.feed("\r\n123456"); assert(s.y() == 1);
    s.feed("A"); assert(s.y() == 2 && s.x() == 1);
    s.feed("\033[?1049h\033[?1h\033[?2004h");
    assert(s.alternate && s.applicationCursor && s.bracketPaste && s.row(0)[0].ch == ' ');
    s.feed("alt\033[?1049l"); assert(!s.alternate && s.row(0)[0].ch == 'A' && s.x()==1);
    std::string title, response;
    s.title = [&](std::string_view t){title=t;}; s.reply = [&](std::string_view r){response=r;};
    s.feed("\033]2;session\033"); s.feed("\\");
    assert(title == "session");
    s.feed("\033[6n"); assert(response == "\033[3;2R");
    // Text that resembles a shell command in an OSC string is never executed.
    s.feed("\033]52;c;ignored\aZ"); assert(s.row(2)[1].ch == 'Z');
    s.feed("\033]2;" + std::string(3000,'a') + "\a"); assert(title == "session");
    s.resize(4,1); assert(s.y()==0 && s.historySize()==2);
    assert(s.row(0,1)[0].ch=='1');
    s.resize(16,8); s.feed("\033[10000;10000H!");
    assert(s.row(7)[15].ch=='!');
    s.feed("\033[2J\033[H\033[3J");
    assert(s.historySize()==0 && s.row(7)[15].ch==' ');

    Screen buffers(5,4);
    buffers.feed("one\r\ntwo\r\nthree\r\nfour\r\n\033[31mABCDE");
    buffers.feed("\033[?1049h\033[H\033[2J\033[3J\033[32mX\033[?1049l\033[?4mF");
    assert(buffers.bufferChanged && !buffers.alternate && buffers.historySize()==2);
    assert(buffers.row(2)[4].ch=='E' && buffers.row(3)[0].ch=='F');
    assert(buffers.row(3)[0].style.fg==Indexed+1 && !buffers.row(3)[0].style.flags);
    buffers.feed("\033[?47h\033[Halt\033[?47l\033[?47h");
    assert(buffers.row(0)[0].ch=='a');
    buffers.feed("\033[?47l\033[?1049h"); assert(buffers.row(0)[0].ch==' ');
    buffers.feed("\033[?1049l");

    Screen mouse(300,12);
    char report[48];
    auto wheel = [&](bool up) { size_t n = mouse.wheelReport(report,up,12,2,3,20,44); return std::string(report,n); };
    assert(wheel(true).empty() && mouse.alternateScroll);
    mouse.feed("\033[?1002;1006h"); assert(wheel(false)=="\033[<77;2;3M");
    mouse.feed("\033[?1016h"); assert(wheel(true)=="\033[<76;20;44M");
    mouse.feed("\033[?1015h"); assert(wheel(false)=="\033[109;2;3M");
    mouse.feed("\033[?1015l"); assert(wheel(true)==std::string("\033[Ml\"#",6));
    assert(mouse.wheelReport(report,true,0,224,3,20,44)==0);
    mouse.feed("\033[?1005h");
    assert(mouse.wheelReport(report,true,0,224,3,20,44)==7 && (unsigned char)report[4]==0xc4 && (unsigned char)report[5]==0x80);
    mouse.feed("\033[?1002;1007l"); assert(wheel(true).empty() && !mouse.alternateScroll);
    mouse.feed("\033[?1007h"); assert(mouse.alternateScroll);
    Screen resized(12,6);
    resized.feed("\033[6;5H\033[?1049h");
    resized.resize(8,3);
    resized.feed("\033[?1049lR");
    assert(resized.row(2)[4].ch=='R' && resized.historySize()==3);
    resized.feed("\033[2;3r\033[?6h\033[2;4H\0337\033[?6l\0338");
    resized.reply = [&](std::string_view r) { response = r; };
    resized.feed("\033[?6n"); assert(response=="\033[?2;4R");
    resized.feed("\033[6n"); assert(response=="\033[2;4R" && resized.y()==2);

    Screen limited(8,1);
    limited.setHistoryLimit(3);
    limited.feed("a\r\nb\r\nc\r\nd\r\ne");
    assert(limited.historySize()==4 && limited.row(0,4)[0].ch=='a' && limited.archivedRows()==1);
    limited.feed("\033[?1049h"); limited.setHistoryLimit(1); limited.feed("\033[?1049l");
    assert(limited.historySize()==4 && limited.row(0,1)[0].ch=='d' && limited.archivedRows()==3);
    limited.setHistoryLimit(0); limited.feed("\r\nf\r\ng");
    assert(!limited.historySize() && limited.row(0)[0].ch=='g');
    limited.resize(8,4); limited.feed("\033[4;1HZ"); limited.resize(8,1);
    assert(!limited.historySize() && limited.row(0)[0].ch=='Z');
    limited.setHistoryLimit(2); limited.feed("\r\nh");
    assert(limited.historySize()==1 && limited.row(0,1)[0].ch=='Z');

    // Archived pages, hot tail and live rows share one searchable coordinate space.
    auto find = [](const Screen &screen, std::u32string query, bool reverse, TextPoint from, TextMatch *hit = nullptr) {
        TerminalSearch search(std::move(query),reverse,from,screen.historySize()+screen.height);
        TerminalSearch::Result state;
        do { state = search.step(screen,1); } while (state == TerminalSearch::Searching);
        if (hit) *hit = search.match;
        return state == TerminalSearch::Found;
    };
    Screen paged(12,3);
    paged.setHistoryLimit(1);
    paged.feed("\033[31m1234567890中AbCe\xcc\x81-end\033[0m\r\n");
    for (int i=0; i<350; ++i) paged.feed("log-"+std::to_string(i)+"\r\n");
    assert(paged.archivedRows()>320 && !paged.archiveFailed());
    for (bool reverse : {false,true}) {
        TextMatch hit;
        TextPoint origin = reverse ? TextPoint{paged.historySize()+2,INT_MAX} : TextPoint{};
        assert(find(paged,U"0中abce\u0301",reverse,origin,&hit));
        assert(hit.first.row==0 && hit.first.column==9 && hit.last.row==1 && hit.last.column==3);
        assert(!find(paged,U"endlog",reverse,origin));
        assert(find(paged,U"LOG-211",reverse,origin,&hit) && hit.first.row==213);
    }
    assert(paged.lineAt(0)[10].style.fg==Indexed+1 && paged.lineAt(0)[11].width==0);
    paged.resize(5,3);
    TextPoint piece = moveDisplayRow(paged,{},true);
    assert(piece.row==0 && piece.column==5);
    piece = moveDisplayRow(paged,piece,true);
    assert(piece.row==0 && piece.column==10);
    assert(moveDisplayRow(paged,piece,false).column==5);
    assert(find(paged,U"中abce",true,{paged.historySize()+2,INT_MAX}));
    paged.feed("\033[?1049hEDITOR");
    assert(!find(paged,U"log-",false,{}) && find(paged,U"editor",false,{}));
    paged.feed("\033[?1049l\033[3J");
    assert(!paged.historySize() && !find(paged,U"中abc",false,{}));
    Screen longLine(19,4);
    std::string text = "An-oversized-line-without-newlines-0123456789";
    longLine.feed(text);
    auto needle = std::u32string(text.begin(),text.end());
    for (int width : {5,11,43,7,19}) {
        longLine.resize(width,4);
        assert(find(longLine,needle,false,{}));
    }
    longLine.feed("Z");
    assert(find(longLine,needle+U"Z",false,{}));
    Screen wide(5,2);
    wide.feed("abcd中-end");
    assert(wide.lineAt(0).wrapAt==4 && find(wide,U"d中-e",false,{}));
    Screen spaces(12,2);
    spaces.feed("literal   \r\n");
    assert(find(spaces,U"literal   ",false,{}));
    spaces.resize(4,2);
    assert(find(spaces,U"literal   ",false,{}));
    Screen events(20,4);
    events.commandExitToken = "test-session";
    int exits = 0;
    events.commandExited = [&](std::string_view name,int status,int seconds) {
        assert(name=="claude" && status==7 && seconds==120);
        ++exits;
    };
    events.feed("\033]9;Done\a\033]777;notify;Claude;Done\a\033]7501;state=done:app=omp\a");
    events.feed("\033]777;yaaterm;end;claude;0;3\a\033]777;yaaterm-exit;other-session;claude;7;120\a");
    events.feed("\033]777;yaaterm-exit;test-session;claude;bad;0\a");
    assert(exits==0);
    std::string completed = "\033]777;yaaterm-exit;test-session;claude;7;120\033\\";
    for (char c : completed) events.feed(std::string_view(&c,1));
    assert(exits==1 && events.x()==0 && events.y()==0);

    int turns = 0;
    bool failed = false;
    events.agentFinished = [&](std::string_view, bool error) { ++turns; failed = error; };
    events.feed("\033]777;yaaterm-turn;omp\a\033]7501;state=done\a");
    assert(turns==0);
    events.feed("\033]777;yaaterm-agent;test-session;agy\a");
    std::string probe;
    events.reply = [&](std::string_view bytes) { probe = bytes; };
    events.feed("\033]7501;?\a");
    assert(probe.find("?:states=")!=probe.npos);
    events.feed("\033]7501;state=working\a\033]7501;state=blocked:kind=permission\a");
    assert(turns==0);
    events.feed("\033]7501;state=done:app=antigravity\a\033]7501;state=done\033\\");
    assert(turns==1 && !failed);
    events.feed("\033]7501;state=working\a\033]7501;state=error\a");
    assert(turns==2 && failed);
    events.feed("\033]777;yaaterm-exit;test-session;agy;0;5\a");
    assert(exits==1);
    events.feed("\033]777;yaaterm-agent;test-session;codex\a\033]9;4;1;20\a\033]777;yaaterm-turn;claude\a");
    assert(turns==2);
    events.feed("\033]9;First turn\a\033]9;Second turn\033\\");
    assert(turns==4 && !failed);
    events.feed("\033]777;yaaterm-agent;test-session;\a\033]9;unrelated\a");
    assert(turns==4);

    Screen stress(100,32);
    std::string line = "\033[32m" + std::string(80,'x') + "\033[0m\r\n";
    std::string block;
    for (int i=0;i<1000;++i) block += line;
    auto start = std::chrono::steady_clock::now();
    for (int i=0;i<100;++i) stress.feed(block);
    auto secs = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    assert(stress.historySize()==100000-31 && stress.row(31)[0].ch==' ');
    assert(stress.archivedRows()>99000 && !stress.archiveFailed() && stress.lineAt(0)[0].style.fg==Indexed+2);
    assert(stress.row(0,1500)[0].ch=='x');
    std::cout << "100000 ANSI lines, 100 x 32, " << secs << " s, "
              << block.size()*100/secs/1048576 << " MiB/s (parser and compressed scrollback), "
              << stress.historySize() << " history rows, " << sizeof(Cell) << " bytes/cell\n";
}
