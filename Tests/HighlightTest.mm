#import "Session.h"
#include "Screen.hpp"
#include <cassert>

static void waitFor(bool (^ready)(void), int line = __builtin_LINE()) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!ready() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    if (!ready()) { fprintf(stderr,"PTY expectation timed out at line %d\n",line); abort(); }
}

int main() {
    @autoreleasepool {
        // Exercise the app-bundle lookup and the normal Session startup path with an isolated login profile.
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        assert([files createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
        // Provider fixtures use the same argv, hook file and PTY as an interactive launch.
        NSString *fixture = @R"SH(#!/bin/sh
tool=${0##*/}
case "$tool" in
    agy) printf '\033]7501;state=working\007\033]7501;state=done:app=antigravity:msg=VGVzdHMgcGFzc2Vk\007' ;;
    codex)
        [ "$1" = -c ] && [ "$2" = 'tui.notifications=["agent-turn-complete"]' ] || exit 31
        printf '\033]9;Tests passed\007' ;;
    omp)
        [ "$1" = --extension ] && [ -f "$2" ] || exit 32
        printf '\033]777;yaaterm-turn;omp;VGVzdHMgcGFzc2Vk\007' ;;
    *)
        [ "$1" = --plugin-dir ] && [ "$YAATERM_NOTICE_AGENT" = "$tool" ] || exit 33
        hook=$(/usr/bin/plutil -extract hooks.Stop.0.hooks.0.command raw "$2/hooks/hooks.json") || exit 34
        printf '%s' '{"last_assistant_message":"Tests passed","transcript_path":"/missing"}' | /bin/sh -c "$hook" || exit 35 ;;
esac
printf '\033]2;waiting-%s\007' "$tool"
read -r reply
)SH";
        for (NSString *tool in @[@"agy",@"codex",@"omp",@"claude",@"qodercn"]) {
            NSString *path = [dir stringByAppendingPathComponent:tool];
            assert([fixture writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
            assert([files setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:path error:nil]);
        }
        NSDictionary *rc = @{@".zshenv":@"startup=e\n", @".zprofile":@"startup+=p\n",
            @".zshrc":@"startup+=r\npath=(\"$ZDOTDIR\" $path)\nPROMPT='yt> '\nRPROMPT=''\nHISTFILE=/dev/null\n",
            @".zlogin":@"startup+=l\n"};
        for (NSString *name in rc)
            assert([rc[name] writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        setenv("ZDOTDIR",dir.fileSystemRepresentation,1);
        setenv("SHELL","/bin/zsh",1);
        setenv("SHELL_SESSIONS_DISABLE","1",1);
        setenv("TERM","xterm-256color",1);
        __block yaa::Screen screen(100,24);
        __block BOOL exited = NO;
        NSMutableData *output = [NSMutableData data];
        Session *session = [Session new];
        session.onData = ^(const void *p, size_t n) {
            screen.feed(std::string_view((const char *)p,n)); [output appendBytes:p length:n];
        };
        session.onExit = ^{exited = YES;};
        assert([session startAt:dir cols:100 rows:24 error:nil]);
        auto send = [&](NSString *s) { [session send:[s dataUsingEncoding:NSUTF8StringEncoding]]; };
        auto contains = ^bool(NSString *s) {
            NSData *pattern = [s dataUsingEncoding:NSUTF8StringEncoding];
            return [output rangeOfData:pattern options:0 range:NSMakeRange(0,output.length)].location != NSNotFound;
        };
        waitFor(^bool{ return contains(@"yt> "); });
        int row = screen.y(), start = screen.x();
        send(@"print -r \"hello\"");
        waitFor(^bool {
            const auto &r = screen.row(row);
            return r[start].ch == 'p' && r[start].style.fg == yaa::Indexed+2 &&
                   r[start+6].style.fg == yaa::Indexed+4 && r[start+9].style.fg == yaa::Indexed+3;
        });
        send(@"\r");
        waitFor(^bool{ return contains(@"hello\r\n"); });
        // ZDOTDIR is restored before the user's .zshenv, and login startup files run once, in order.
        send(@"print -r -- \"START[$startup|${ZDOTDIR:t}|$ZSH_HIGHLIGHT_MAXLENGTH]\"\r");
        NSString *marker = [NSString stringWithFormat:@"START[eprl|%@|512]\r\n",dir.lastPathComponent];
        // Wait for ZLE to re-enable bracketed paste before sending terminal paste delimiters.
        waitFor(^bool{ return contains(marker) && screen.bracketPaste; });
        NSString *longValue = [@"" stringByPaddingToLength:2048 withString:@"x" startingAtIndex:0];
        send([NSString stringWithFormat:@"\033[200~value='%@'; print -r -- \"LONG[${#value}]\"\033[201~\r",longValue]);
        waitFor(^bool{ return contains(@"LONG[2048]\r\n"); });
        screen.commandExitToken = session.commandExitToken.UTF8String;
        int terminations = 0;
        int *count = &terminations;
        screen.commandExited = [&](std::string_view name,int status,int seconds) {
            assert(name=="sh" && status==7 && seconds>=0);
            ++terminations;
        };
        int turns = 0;
        for (NSString *tool in @[@"agy",@"codex",@"omp",@"claude",@"qodercn"]) {
            screen.agentFinished = [&](std::string_view agent,bool failed,std::string_view detail) {
                assert(agent==tool.UTF8String && !failed && detail=="Tests passed"); ++turns;
            };
            int previous = turns;
            send([tool stringByAppendingString:@"\r"]);
            NSString *waiting = [NSString stringWithFormat:@"\033]2;waiting-%@\007",tool];
            waitFor(^bool{ return contains(waiting); });
            assert(turns==previous+1 && terminations==0);
            send(@"next\r");
            waitFor(^bool{ return screen.bracketPaste; });
        }
        screen.agentFinished = {};
        // The child emits turn notifications, suspends itself, then exits after fg.
        send(@"/bin/sh -c 'printf \"\\033]9;Done\\007\\033]777;notify;Agent;Done\\007\\033]2;starting-job\\007\"; kill -STOP $$; exit 7'\r");
        waitFor(^bool{ return contains(@"\033]2;starting-job\007") && screen.bracketPaste; });
        assert(terminations==0);
        send(@"fg\r");
        waitFor(^bool{ return *count==1 && screen.bracketPaste; });
        send(@"exit\r"); waitFor(^bool{return (bool)exited;});

        // A highlighter provided by .zshrc must win even when the app bundles its own copy.
        NSString *customRC = [rc[@".zshrc"] stringByAppendingString:@"_zsh_highlight() { :; }\n"];
        assert([customRC writeToFile:[dir stringByAppendingPathComponent:@".zshrc"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        exited = NO;
        [output setLength:0];
        assert([session startAt:dir cols:100 rows:24 error:nil]);
        waitFor(^bool{ return contains(@"yt> "); });
        send(@"print -r -- \"PLUGIN[$+functions[_zsh_highlight],$+parameters[ZSH_HIGHLIGHT_VERSION]]\"\r");
        waitFor(^bool{ return contains(@"PLUGIN[1,0]\r\n"); });
        send(@"exit\r"); waitFor(^bool{return (bool)exited;});
        assert([files removeItemAtPath:dir error:nil]);
        puts("Real zsh PTY: live colors, login startup order, long paste, foreground process exit, suspended job filtering and existing highlighter OK");
    }
}
