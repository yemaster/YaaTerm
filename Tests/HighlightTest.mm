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
        NSDictionary *rc = @{@".zshenv":@"startup=e\n", @".zprofile":@"startup+=p\n",
            @".zshrc":@"startup+=r\nPROMPT='yt> '\nRPROMPT=''\nHISTFILE=/dev/null\n",
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
