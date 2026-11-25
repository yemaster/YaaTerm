#import <Foundation/Foundation.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Walk from the chosen directory one descriptor at a time. Never follow a model-supplied symlink.
static NSString *projectObservation(NSString *path, BOOL list, BOOL &ok) {
    if (path.length>512 || [path hasPrefix:@"/"] ||
        [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return @"路径不可用。";
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    int fd = open(".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (fd<0) return @"目录不可用。";
    for (NSUInteger i=0; i<parts.count; ++i) {
        NSString *part = parts[i];
        if (!part.length || [part isEqual:@"."]) continue;
        if ([part hasPrefix:@"."]) { close(fd); return @"只能查看当前目录下的普通项目文件。"; }
        BOOL directory = list || i+1<parts.count;
        int next = openat(fd,part.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK|(directory ? O_DIRECTORY : 0));
        close(fd); fd = next;
        if (fd<0) return @"无法打开该路径。";
    }
    if (list) {
        DIR *dir = fdopendir(fd);
        if (!dir) { close(fd); return @"无法读取目录。"; }
        NSMutableArray *names = [NSMutableArray array];
        NSUInteger length = 0, scanned = 0;
        while (dirent *entry = readdir(dir)) {
            if (++scanned>1024) { [names addObject:@"…"]; break; }
            if (entry->d_name[0]=='.') continue;
            if (names.count>=96 || length>=3000) { [names addObject:@"…"]; break; }
            NSString *name = [NSString stringWithUTF8String:entry->d_name];
            if (name) { [names addObject:entry->d_type==DT_DIR ? [name stringByAppendingString:@"/"] : name]; length+=name.length+1; }
        }
        closedir(dir); ok=YES;
        return names.count ? [names componentsJoinedByString:@"\n"] : @"（空目录）";
    }
    struct stat info{};
    char bytes[6145];
    ssize_t n = -1;
    if (fstat(fd,&info)==0 && S_ISREG(info.st_mode)) n = read(fd,bytes,sizeof(bytes));
    close(fd);
    if (n<0 || memchr(bytes,0,(size_t)n)) return @"不是可读的文本文件。";
    size_t len = MIN((size_t)n,sizeof(bytes)-1);
    if (len<(size_t)n) while (len && (bytes[len]&0xc0)==0x80) --len;
    NSString *text = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    if (!text || [text containsString:@"PRIVATE KEY-----"]) return @"无法读取此文本。";
    ok=YES; return len<(size_t)n ? [text stringByAppendingString:@"\n…"] : text;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc!=3 || (strcmp(argv[1],"list") && strcmp(argv[1],"read"))) return 2;
        NSString *path=[NSString stringWithUTF8String:argv[2]];
        if (!path) return 2;
        BOOL ok=NO;
        NSString *output=projectObservation(path,!strcmp(argv[1],"list"),ok);
        // Quoted text from files and directory entries must not drive the terminal parser.
        static NSRegularExpression *controls=[NSRegularExpression regularExpressionWithPattern:@"[\\p{Cc}&&[^\\n\\t]]|[\\u202A-\\u202E\\u2066-\\u2069]" options:0 error:nil];
        NSString *plain=[controls stringByReplacingMatchesInString:output options:0 range:NSMakeRange(0,output.length) withTemplate:@"�"];
        puts(plain.UTF8String); return ok ? 0 : 1;
    }
}
