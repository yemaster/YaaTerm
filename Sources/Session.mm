#import "Session.h"
#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <pwd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>
#include <string>
#include <vector>

@implementation Session {
    int _fd;
    pid_t _pid;
    dispatch_source_t _reader, _writer;
    NSMutableData *_pending;
    NSUInteger _sent;
    NSString *_shellName;
}
- (instancetype)init {
    if ((self = [super init])) _fd = -1;
    return self;
}
- (NSString *)shellName { return _shellName; }
- (BOOL)startAt:(NSString *)directory cols:(int)cols rows:(int)rows error:(NSError **)error {
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *shell = env[@"SHELL"];
    if (![shell hasPrefix:@"/"] || ![NSFileManager.defaultManager isExecutableFileAtPath:shell]) {
        struct passwd *account = getpwuid(getuid());
        shell = account && account->pw_shell[0] ? [NSString stringWithUTF8String:account->pw_shell] : @"/bin/zsh";
    }
    env[@"SHELL"] = shell;
    _shellName = shell.lastPathComponent;
    env[@"TERM"] = @"xterm-256color"; env[@"COLORTERM"] = @"truecolor"; env[@"TERM_PROGRAM"] = @"YaaTerm";
    if (!env[@"LANG"]) env[@"LANG"] = @"en_US.UTF-8";
    _commandExitToken = nil;
    if ([_shellName isEqualToString:@"zsh"]) {
        NSString *bootstrap = [NSBundle.mainBundle pathForResource:@".zshenv" ofType:nil inDirectory:@"Shell/zsh"];
        if (bootstrap) {
            _commandExitToken = NSUUID.UUID.UUIDString;
            env[@"YAATERM_EXIT_TOKEN"] = _commandExitToken;
            env[@"YAATERM_ORIGINAL_ZDOTDIR"] = env[@"ZDOTDIR"];
            env[@"ZDOTDIR"] = bootstrap.stringByDeletingLastPathComponent;
        }
    }
    // Materialize strings before fork. The child only uses POSIX calls.
    std::vector<std::string> entries;
    for (NSString *key in env) entries.emplace_back([[NSString stringWithFormat:@"%@=%@", key, env[key]] UTF8String]);
    std::vector<char *> envp;
    for (auto &e : entries) envp.push_back(e.data());
    envp.push_back(nullptr);
    std::string executable(shell.fileSystemRepresentation), cwd(directory.fileSystemRepresentation);
    std::string name = std::string("-") + _shellName.UTF8String;
    char *argv[] = { name.data(), nullptr };
    winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
    _pid = forkpty(&_fd, nullptr, nullptr, &ws);
    if (_pid < 0) {
        int code = errno; _fd = -1;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return NO;
    }
    if (_pid == 0) {
        if (chdir(cwd.c_str()) != 0) _exit(126);
        execve(executable.c_str(), argv, envp.data());
        const char msg[] = "YaaTerm: could not start shell\r\n";
        (void)write(STDERR_FILENO, msg, sizeof(msg)-1);
        _exit(127);
    }
    fcntl(_fd, F_SETFD, FD_CLOEXEC);
    fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL) | O_NONBLOCK);
    int ownedFD = _fd;
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, dispatch_get_main_queue());
    __weak Session *weak = self;
    dispatch_source_set_event_handler(_reader, ^{ [weak drain]; });
    dispatch_source_set_cancel_handler(_reader, ^{ close(ownedFD); });
    dispatch_resume(_reader);
    return YES;
}
- (void)drain {
    char buf[16384];
    // Yield between batches so a noisy process cannot monopolize the UI.
    for (int i = 0; i < 4 && _fd >= 0; ++i) {
        ssize_t n = read(_fd, buf, sizeof(buf));
        if (n > 0) { if (_onData) _onData(buf, (size_t)n); continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) break;
        [self close];
        if (_onExit) _onExit();
        break;
    }
}
- (void)resizeCols:(int)cols rows:(int)rows {
    if (_fd < 0) return;
    winsize ws = {(unsigned short)rows, (unsigned short)cols, 0, 0};
    ioctl(_fd, TIOCSWINSZ, &ws);
}
- (void)send:(NSData *)data {
    [self sendBytes:data.bytes length:data.length];
}
- (void)sendBytes:(const void *)bytes length:(size_t)length {
    if (_fd < 0 || !length) return;
    if (length > 4*1024*1024 - (_pending.length - _sent)) { NSBeep(); return; }
    if (!_pending) {
        ssize_t n;
        do { n = write(_fd,bytes,length); } while (n < 0 && errno == EINTR);
        if (n == (ssize_t)length || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) return;
        if (n > 0) { bytes = (const uint8_t *)bytes+n; length -= n; }
        _pending = [NSMutableData dataWithBytes:bytes length:length];
        [self flush];
        return;
    }
    if (_sent && (_sent >= _pending.length/2 || _pending.length + length > 4*1024*1024)) {
        [_pending replaceBytesInRange:NSMakeRange(0,_sent) withBytes:nullptr length:0];
        _sent = 0;
    }
    [_pending appendBytes:bytes length:length];
    if (!_writer) [self flush];
}
- (void)flush {
    while (_fd >= 0 && _sent < _pending.length) {
        ssize_t n = write(_fd,(const char *)_pending.bytes+_sent,_pending.length-_sent);
        if (n > 0) { _sent += n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) {
            if (!_writer) {
                _writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE,_fd,0,dispatch_get_main_queue());
                __weak Session *weak = self;
                dispatch_source_set_event_handler(_writer, ^{ [weak flush]; });
                dispatch_resume(_writer);
            }
            return;
        }
        break;
    }
    _pending = nil; _sent = 0;
    if (_writer) { dispatch_source_cancel(_writer); _writer = nil; }
}
- (NSString *)workingDirectory {
    struct proc_vnodepathinfo paths{};
    if (_pid <= 0 || proc_pidinfo(_pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths)) != sizeof(paths)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:paths.pvi_cdir.vip_path length:strlen(paths.pvi_cdir.vip_path)];
}
- (BOOL)shellIsForeground {
    return _fd >= 0 && _pid > 0 && !_pending && tcgetpgrp(_fd) == _pid;
}
- (void)close {
    _pending = nil; _sent = 0;
    if (_writer) { dispatch_source_cancel(_writer); _writer = nil; }
    if (_reader) { dispatch_source_cancel(_reader); _reader = nil; }
    _fd = -1;
    if (_pid > 0) {
        pid_t child = _pid; _pid = 0;
        kill(child, SIGHUP);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            while (waitpid(child, nullptr, 0) < 0 && errno == EINTR) {}
        });
    }
}
- (void)dealloc { [self close]; }
@end
