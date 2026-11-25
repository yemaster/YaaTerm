#include "TerminalSearch.hpp"
#include <climits>
#include <cassert>
#include <chrono>
#include <clocale>
#include <iostream>

using namespace yaa;
using namespace std::string_view_literals;
static void checkScrollOrder() {
    Screen s(8,5);
    auto expect = [&](std::string_view firstColumn) {
        assert((int)firstColumn.size()==s.height);
        for (int y=0; y<s.height; ++y) assert(s.row(y)[0].ch==(uint32_t)firstColumn[y]);
    };
    s.feed("A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG");
    expect("CDEFG");
    s.feed("\033[2;4r\033[4;1H\033D"); expect("CEF G");
    s.feed("\033[2;1H\033M"); expect("C EFG");
    s.feed("\033[r\033[H\033M"); expect(" C EF");
    s.freeze(); s.thaw(); expect(" C EF");
    s.resize(12,5); expect(" C EF");
    assert(s.historySize()==2 && s.lineAt(0)[0].ch=='A' && s.lineAt(1)[0].ch=='B');
    Screen single(8,1); single.feed("A\r\nB\033M");
    assert(single.historySize()==1 && single.lineAt(0)[0].ch=='A' && single.row(0)[0].ch==' ');
}
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

static void checkAgentFrames() {
    static_assert(sizeof(Row)==sizeof(std::vector<Cell>)+8);
    Screen s(12,5);
    s.setHistoryLimit(1);
    s.feed("ordinary\r\n");
    s.beginAgentEcho(); s.feed("$ list\r\n"); s.beginAgentOutput();
    s.feed("one\r\n\r\nabcdefghijklmnop\r\n");
    auto output=s.agentOutputStamp();
    s.resize(8,8);
    s.feed("\033[?1049h\033[Halt");
    assert(!s.row(0).agentStamp);
    s.feed("\033[?1049l");
    for (int i=0;i<80;++i) s.feed("row\r\n");
    s.endAgentBlock(); s.feed("Agent > ");
    s.freeze(); s.thaw();
    assert(s.archivedRows()>32 && !s.lineAt(0).agentStamp && s.lineAt(1).agentStamp==(output & ~1));
    int64_t prompt=s.historySize()+s.y();
    for (int64_t i=2;i<prompt;++i) assert(s.lineAt(i).agentStamp==output);
    assert(!s.lineAt(prompt).agentStamp);
    s.feed("\033[2J");
    for (int y=0;y<s.height;++y) assert(!s.row(y).agentStamp);
}

static void checkCodeOutput() {
    Screen screen(24,5);
    screen.commandExitToken = "test";
    auto context = [&](std::string_view kind) {
        screen.feed("\033]777;yaaterm-context;test;" + std::string(kind) + ";/tmp\a");
    };
    context("code:python"); screen.feed("def nope\r\n");
    assert(!screen.row(0).codeLine && screen.row(0)[0].style.fg == Default);
    screen.setCodeOutput(true);
    context("code:python");
    for (char c : "def f(): # note\r\n\r\n   return \"x\" + 42\r\n"sv) screen.feed({&c,1});
    assert(screen.row(1).codeLine == 1 && screen.row(2).codeLine == 2 && screen.row(3).codeLine == 3);
    assert(screen.row(1)[0].style.fg == CodeColor+5 && screen.row(1)[9].style.fg == CodeMuted);
    assert(screen.row(3)[11].style.fg == CodeColor+2 && screen.row(3)[17].style.fg == CodeColor+3);
    screen.setHistoryLimit(1);
    context("code:c");
    screen.feed("/* abcdefghijklmnopqrstuvwxyz\r\nstill a comment */\r\n");
    assert(screen.lineAt(4).codeLine == 1 && screen.lineAt(5).codeLine == (CodeContinuation|1));
    assert(screen.lineAt(5)[1].style.fg == CodeMuted && screen.lineAt(6)[1].style.fg == CodeMuted);
    context("numbered:python");
    screen.feed("    11\treturn 2\r\n");
    assert(!screen.lineAt(7).codeLine && screen.lineAt(7)[4].style.fg == CodeMuted &&
           screen.lineAt(7)[8].style.fg == CodeColor+5 && screen.lineAt(7)[4].ch == '1');
    context("code:c"); screen.feed("\033[31mreturn\033[0m");
    context("cwd"); assert(screen.row(screen.y()).codeLine == 1 && screen.row(screen.y())[0].style.fg == Indexed+1);
    screen.feed("\r\n");
    for (int i=0;i<85;++i) screen.feed("ordinary\r\n");
    screen.freeze(); screen.thaw();
    assert(screen.archivedRows()>64 && screen.lineAt(2).codeLine == 2 && screen.lineAt(5).codeLine == (CodeContinuation|1));
    context("code:text");
    screen.feed("12345678901234567890\r\n"); context("cwd");
    screen.resize(8,9); screen.resize(28,9);
    int end = screen.y();
    assert(end > 0 && screen.row(end-1).codeLine == 1 && screen.row(end-1).written == 20);
    screen.feed("\033[2J"); assert(!screen.row(end-1).codeLine);
    Screen narrow(12,5);
    narrow.setCodeOutput(true); narrow.commandExitToken = "ok";
    narrow.feed("\033]777;yaaterm-context;ok;code:c;/tmp\a12345/* abc*/int x\r\n");
    assert(narrow.row(1)[2].style.fg == CodeMuted && narrow.row(2)[1].style.fg == CodeColor+5);
    narrow.feed("\033]777;yaaterm-context;ok;code:text;/tmp\a");
    narrow.feed(std::string_view("\0AB\r\n",5));
    assert(!narrow.row(3).codeLine);

    Screen source(18,7);
    source.setCodeOutput(true); source.commandExitToken = "ok";
    source.feed("\033]777;yaaterm-context;ok;code:text;/tmp\a");
    for (int i=1;i<1000;++i) source.feed("\r\n");
    source.feed("12345678901中-end\r\n\033]133;D\a");
    int first = source.y()-2;
    assert(source.row(first).codeLine == 1000 && source.row(first).wrapAt == 11);
    assert(source.row(first+1).codeLine == (CodeContinuation|1000) && source.row(first+1)[0].width == 2);
    TerminalSearch match(U"1中-end",false,{source.historySize()+first,0},source.historySize()+source.height);
    assert(match.step(source,8) == TerminalSearch::Found);
    source.feed("123456789012345678");
    assert(!source.row(source.y()).codeLine && source.x() == 17);
    source.resize(26,10);
    bool merged = false;
    for (int y=0;y<source.height;++y) if (source.row(y).codeLine == 1000) {
        assert(!source.row(y).wrapAt && source.row(y).written == 17); merged = true;
    }
    assert(merged);
}

static void checkFailureAnchor() {
    Screen screen(16,4);
    screen.feed("bad 路径!\r\n");
    screen.failureCell={0,8};
    auto anchored=[&] {
        TextPoint p=screen.failureCell;
        return p.row>=0 && p.column<(int)screen.lineAt(p.row).size() && screen.lineAt(p.row)[p.column].ch=='!';
    };
    assert(anchored());
    screen.resize(5,4); assert(anchored());
    screen.resize(12,3); assert(anchored());
    screen.feed("\033[?1049hother"); screen.resize(4,3); screen.feed("\033[?1049l"); assert(anchored());
    screen.setHistoryLimit(1);
    for (int i=0;i<40;++i) screen.feed("x\r\n");
    assert(screen.archivedRows()>1 && anchored());
    screen.clearHistory(); assert(screen.failureCell.row<0);
    screen.setHistoryLimit(0); screen.feed("\033[2J\033[H\r\n!"); screen.failureCell={1,0};
    screen.feed("\033[1S"); assert(screen.failureCell.row==0 && anchored());
    screen.feed("\033[1S"); assert(screen.failureCell.row<0);
}

int main() {
    setlocale(LC_CTYPE,"en_US.UTF-8");
    checkFreeze();
    checkScrollOrder();
    checkFailureAnchor();
    checkAgentFrames();
    checkCodeOutput();
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
    mouse.feed("\033[?1002;1006h");
    auto pointer = [&](int button,MouseAction action) {
        size_t n = mouse.mouseReport(report,button,action,0,4,2,30,22);
        return std::string(report,n);
    };
    assert(pointer(0,MouseAction::Press)=="\033[<0;4;2M" && pointer(0,MouseAction::Release)=="\033[<0;4;2m");
    assert(pointer(2,MouseAction::Motion)=="\033[<34;4;2M" && pointer(3,MouseAction::Motion).empty());
    mouse.feed("\033[?1003h"); assert(pointer(3,MouseAction::Motion)=="\033[<35;4;2M");
    Screen vt(24,3);
    vt.feed("\033)0\016lqk\017x"); assert(vt.row(0)[0].ch==U'┌' && vt.row(0)[1].ch==U'─' && vt.row(0)[3].ch=='x');
    vt.feed("\033[1;38:2::1:2:3;48:5:42mC"); assert(vt.row(0)[4].style.fg==0x010203 && vt.row(0)[4].style.bg==(Indexed+42) && (vt.row(0)[4].style.flags & Bold));
    vt.feed("\033[3g\033[5G\033H\033[12G\033H\r\t"); assert(vt.x()==4);
    vt.feed("\033[I"); assert(vt.x()==11);
    vt.feed("\033[Z\033[g\r\t"); assert(vt.x()==11);
    vt.reply = [&](std::string_view data){response=data;};
    vt.feed("\033[?2004h\033[?2004$p"); assert(response=="\033[?2004;1$y");
    vt.feed("\033[?7777$p"); assert(response=="\033[?7777;0$y");
    vt.feed("\033[>0c"); assert(response=="\033[>0;0;0c");
    vt.feed(u8"\r👨‍👩‍👦\033[2b");
    assert(vt.x()==6 && vt.row(0)[0].mark==vt.row(0)[4].mark && vt.row(0)[4].width==2);
    vt.feed("\033]2;never\030X"); assert(vt.row(0)[6].ch=='X');
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
    Screen clusters(7,2);
    std::string emojiLine = u8"👩🏽‍💻🇨🇳1️⃣";
    for (char c : emojiLine) clusters.feed(std::string_view(&c,1));
    assert(clusters.x()==6 && sizeof(Cell)==16);
    for (int x=0;x<6;x+=2) assert(clusters.row(0)[x].width==2 && !clusters.row(0)[x+1].width);
    clusters.feed(u8"❤️"); // A text-width base widens at the right edge.
    assert(clusters.row(0).wrapAt==6 && clusters.row(1)[0].width==2 && clusters.x()==2);
    clusters.setHistoryLimit(1);
    clusters.feed("\r\n");
    for (int i=0;i<40;++i) clusters.feed("next\r\n");
    clusters.freeze(); clusters.thaw(); clusters.resize(5,3);
    for (bool reverse : {false,true}) {
        TextMatch hit;
        assert(find(clusters,U"👩🏽‍💻🇨🇳1️⃣❤️",reverse,
                    reverse ? TextPoint{clusters.historySize()+2,INT_MAX} : TextPoint{},&hit));
        assert(hit.first.column==0 && hit.last.column==1);
    }

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
    std::string detail;
    events.agentFinished = [&](std::string_view, bool error, std::string_view body) { ++turns; failed = error; detail = body; };
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

    events.feed("\033]777;yaaterm-agent;test-session;agy\a\033]7501;msg=VGVzdHMgcGFzc2Vk:state=done\a");
    assert(turns==5 && detail=="Tests passed");
    events.feed("\033]7501;state=working\a\033]7501;state=error:msg=$bad\a");
    assert(turns==6 && failed && detail.empty());
    events.feed("\033]777;yaaterm-agent;test-session;claude\a\033]777;yaaterm-turn;omp;d3Jvbmc=\a");
    assert(turns==6);
    events.feed("\033]777;yaaterm-turn;claude;5a6M5oiQ77ybT0s=\a");
    assert(turns==7 && detail==u8"完成；OK");
    events.feed("\033]777;yaaterm-turn;claude\a");
    assert(turns==8 && detail.empty());
    events.feed("\033]777;yaaterm-agent;test-session;codex\a\033]9;Fixed; tested\a");
    assert(turns==9 && detail=="Fixed; tested");
    events.feed("\033]9;" + std::string(2045,'x') + u8"✅more\a");
    assert(turns==10 && detail==std::string(2045,'x'));

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
