#import "Session.h"
#include "Screen.hpp"
#include <cassert>
#include <clocale>

// Exercise stdin, terminal replies, SIGWINCH and screen switching through the real PTY.
static void waitFor(bool (^predicate)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!predicate() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    assert(predicate());
}
static bool startsWith(const yaa::Screen &s, int y, std::u32string_view text) {
    int x = 0;
    const auto &r = s.row(y);
    for (auto ch : text) {
        if (x >= (int)r.size() || r[x].ch != ch) return false;
        x += std::max(1,(int)r[x].width);
    }
    return true;
}
int main() {
    setlocale(LC_CTYPE,"en_US.UTF-8");
    setenv("SHELL","/bin/sh",1); setenv("ENV","/dev/null",1);
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *fm = NSFileManager.defaultManager;
        assert([fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *file = [dir stringByAppendingPathComponent:@"sample.txt"];
        NSMutableString *content = [@"First 中\n" mutableCopy];
        for (int i=0;i<30;++i) [content appendFormat:@"row %02d\n",i];
        [content appendString:@"Last line\n"];
        assert([content writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        Session *session = [Session new];
        __block yaa::Screen s(64,12);
        __weak Session *weak = session;
        s.reply = [weak](std::string_view reply) { [weak send:[NSData dataWithBytes:reply.data() length:reply.size()]]; };
        __block BOOL exited = NO;
        NSMutableString *title = [NSMutableString new];
        s.title = [title](std::string_view text) {
            [title setString:[[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @""];
        };
        session.onData = ^(const void *p,size_t n) { s.feed({(const char *)p,n}); };
        session.onExit = ^{ exited = YES; };
        assert([session startAt:dir cols:64 rows:12 error:nil]);
        auto send = [&](NSString *str) { [session send:[str dataUsingEncoding:NSUTF8StringEncoding]]; };
        send(@"printf '\\033[2J\\033[H\\033[3J%48sTAIL\\033[11;1Hbefore-vim'; /usr/bin/vim -Nu NONE -n -i NONE sample.txt; printf '\\033]2;shell-back\\007'; read -r finish; exit\r");
        waitFor(^bool{ return s.alternate && startsWith(s,0,U"First 中"); });
        assert(s.historySize() == 0);
        send(@"G");
        waitFor(^bool{ return startsWith(s,s.y(),U"Last line"); });
        s.resize(32,7); [session resizeCols:32 rows:7];
        send(@"gg"); waitFor(^bool{ return s.y()==0 && startsWith(s,0,U"First 中"); });
        s.resize(64,12); [session resizeCols:64 rows:12];
        send(@"G"); waitFor(^bool{ return startsWith(s,s.y(),U"Last line"); });
        send(@":q!\r"); waitFor(^bool{ return [title isEqualToString:@"shell-back"]; });
        assert(!s.alternate && s.row(0)[48].ch == 'T' && startsWith(s,10,U"before-vim"));
        assert(s.x()==10 && s.y()==10 && s.historySize()==0);
        send(@"done\r"); waitFor(^bool{ return exited; });
        assert([fm removeItemAtPath:dir error:nil]);
        puts("Vim PTY: enter, Unicode text, navigate, resize twice, quit and restore shell grid/cursor OK");
    }
}
