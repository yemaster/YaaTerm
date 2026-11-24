#import "Session.h"
#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>

static void checkBackpressure() {
    Session *session = [Session new];
    NSMutableData *output = [NSMutableData data];
    __block BOOL exited = NO;
    session.onData = ^(const void *p,size_t n) { [output appendBytes:p length:n]; };
    session.onExit = ^{ exited = YES; };
    assert([session startAt:@"/" cols:80 rows:24 error:nil]);
    [session send:[@"stty raw -echo; printf '\\036'; sleep .15; head -c 262144; exit\n" dataUsingEncoding:NSUTF8StringEncoding]];
    const uint8_t start = 30;
    NSData *marker = [NSData dataWithBytes:&start length:1];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    auto markerRange = [&] { return [output rangeOfData:marker options:0 range:NSMakeRange(0,output.length)]; };
    while (markerRange().location == NSNotFound && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    size_t offset = NSMaxRange(markerRange());
    assert(markerRange().location != NSNotFound);
    NSMutableData *expected = [NSMutableData dataWithLength:262144];
    auto *p = (uint8_t *)expected.mutableBytes;
    for (size_t i=0; i<expected.length; ++i) p[i] = (uint8_t)((i*137)^(i>>9));
    [session sendBytes:p length:220000];
    assert([session valueForKey:@"pending"]);
    [session sendBytes:p+220000 length:42144];
    while (!exited && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    assert(exited && output.length >= offset+expected.length);
    assert(!memcmp((const uint8_t *)output.bytes+offset,p,expected.length));
    assert(![session valueForKey:@"pending"]);
}

// Use a clean interactive system shell so personal shell startup files do not affect the test.
int main() {
    setenv("SHELL","/bin/sh",1);
    setenv("ENV","/dev/null",1);
    @autoreleasepool {
        checkBackpressure();
        Session *a = [Session new], *b = [Session new];
        NSMutableData *outA = [NSMutableData data], *outB = [NSMutableData data];
        __block BOOL exitA = NO, exitB = NO;
        a.onData = ^(const void *p, size_t n) { [outA appendBytes:p length:n]; };
        b.onData = ^(const void *p, size_t n) { [outB appendBytes:p length:n]; };
        a.onExit = ^{exitA=YES;}; b.onExit = ^{exitB=YES;};
        NSError *error = nil;
        assert([a startAt:@"/" cols:72 rows:18 error:&error]);
        assert([b startAt:@"/private/tmp" cols:90 rows:25 error:&error]);
        [a resizeCols:87 rows:29];
        for (Session *s in @[a,b]) {
            NSString *command = @"printf 'RESULT[%s|%s]\\n' \"$(pwd)\" \"$(stty size)\"; exit\n";
            [s send:[command dataUsingEncoding:NSUTF8StringEncoding]];
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
        while ((!exitA || !exitB) && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.015]];
        assert(exitA && exitB);
        NSString *first = [[NSString alloc] initWithData:outA encoding:NSUTF8StringEncoding];
        NSString *second = [[NSString alloc] initWithData:outB encoding:NSUTF8StringEncoding];
        assert([first containsString:@"RESULT[/|29 87]"]);
        assert([second containsString:@"RESULT[/private/tmp|25 90]"]);
        puts("Two PTYs: independent shells, working directories, resize, 256 KiB ordered backpressure, output and exit OK");
    }
}
