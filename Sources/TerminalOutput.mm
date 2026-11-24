#import "TerminalOutput.h"
#include <mutex>

@implementation OutputReference
@end

@implementation OutputReferences {
    std::vector<OutputReference *> _recent[4];
    uint32_t _serial[4], _cwd;
}
- (OutputReference *)record:(uint32_t)tag {
    auto &slots = _recent[tag & 3];
    if (!tag || slots.empty()) return nil;
    OutputReference *record = slots[(tag >> 2) % slots.size()];
    return record.tag == tag ? record : nil;
}
- (OutputReference *)append:(OutputKind)kind {
    // Never reuse an ID. Evicted cells can only fall back to plain output.
    if (_serial[kind] == 0x3ffff) return nil;
    uint32_t number = ++_serial[kind];
    auto &slots = _recent[kind];
    if (slots.empty()) slots.resize(kind == ExplicitLink ? 128 : 64);
    OutputReference *record = [OutputReference new];
    record.tag = (number << 2) | kind;
    slots[number % slots.size()] = record;
    return record;
}
- (uint32_t)context:(OutputKind)kind directory:(NSString *)directory {
    OutputReference *cwd = [self record:_cwd];
    if (kind == DirectoryContext && cwd && (cwd.directory == directory || [cwd.directory isEqual:directory])) return _cwd;
    OutputReference *record = [self append:kind];
    record.directory = [cwd.directory isEqual:directory] ? cwd.directory : directory;
    if (kind == DirectoryContext) _cwd = record.tag;
    return record.tag;
}
- (uint32_t)listing:(ListingFormat)format directory:(NSString *)directory {
    uint32_t tag = [self context:format == ListingFormat::Files ? FileListing : CommandListing directory:directory];
    [self record:tag].format = format;
    return tag;
}
- (uint32_t)link:(NSURL *)url parent:(uint32_t)parent {
    OutputReference *record = [self append:ExplicitLink];
    record.url = url; record.parent = parent;
    return record.tag;
}
- (void)discardTables:(BOOL)tables web:(BOOL)web files:(BOOL)files {
    for (unsigned k=0; k<4; ++k) {
        auto &slots = _recent[k];
        if ((k == DirectoryContext && files) || ((k == FileListing || k == CommandListing) && tables && files) ||
            (k == ExplicitLink && files && web)) {
            std::vector<OutputReference *>().swap(slots);
        } else for (auto &entry : slots) {
            if (!entry) continue;
            if (files) entry.directory = nil;
            if (k == ExplicitLink && (entry.url.fileURL ? files : web)) entry = nil;
        }
    }
}
@end

static void appendUnit(std::vector<unichar> &out, uint32_t scalar) {
    if (scalar <= 0xffff) out.push_back(scalar);
    else { scalar -= 0x10000; out.push_back(0xd800+(scalar>>10)); out.push_back(0xdc00+(scalar&1023)); }
}

OutputLine ReadOutputLine(const yaa::Screen &screen, yaa::TextPoint point) {
    constexpr int maxCells = 8192, maxRows = 128;
    int64_t first = point.row, limit = screen.historySize()+screen.height;
    if (first < 0 || first >= limit) return {};
    int cells = 0;
    while (first > 0) {
        int wrap = screen.lineAt(first-1).wrapAt;
        if (!wrap) break;
        if ((cells += wrap) > maxCells || point.row-first >= maxRows) return {};
        --first;
    }
    // Most command rows fit on one line. ASCII can go straight from the grid
    // into NSString without allocating a UTF-16 scratch buffer.
    const auto &startRow = screen.lineAt(first);
    int used = startRow.wrapAt ? startRow.wrapAt : startRow.used();
    if (!startRow.wrapAt && used <= 256) {
        char bytes[256];
        int i = 0;
        while (i < used && startRow[i].ch < 128 && startRow[i].width == 1 && !startRow[i].mark) {
            bytes[i] = (char)startRow[i].ch; ++i;
        }
        if (i == used) {
            OutputLine line;
            line.text = [[NSString alloc] initWithBytes:bytes length:used encoding:NSASCIIStringEncoding];
            line.first = line.last = first;
            line.index = point.column >= 0 && point.column < used ? (NSUInteger)point.column : NSNotFound;
            return line;
        }
    }
    std::vector<unichar> units;
    units.reserve(used);
    OutputLine line; line.first = first; line.index = NSNotFound;
    cells = 0;
    for (int64_t i=first; i<limit; ++i) {
        line.last = i;
        const auto &r = screen.lineAt(i);
        int n = r.wrapAt ? r.wrapAt : r.used();
        if ((cells += n) > maxCells || i-first >= maxRows) return {};
        for (int x=0; x<n; ++x) {
            if (!r[x].width) continue;
            if (i == point.row && point.column >= x && point.column < x+(int)r[x].width) line.index = units.size();
            appendUnit(units,r[x].ch);
            if (r[x].mark) appendUnit(units,r[x].mark);
        }
        if (!r.wrapAt) break;
    }
    line.text = units.empty() ? @"" : [NSString stringWithCharacters:units.data() length:units.size()];
    return line;
}

static NSRegularExpression *pattern(NSString *source) {
    return [NSRegularExpression regularExpressionWithPattern:source options:0 error:nil];
}
// Each shape owns its capture order and column widths. Expressions are compiled
// on first use, only for formats actually drawn in this process.
static const ListingSpec *listingSpecs() {
    static const ListingSpec specs[] = {
        {"ls", @[@"名称",@"大小",@"修改时间",@"权限",@"所有者",@"群组"],
            @"^\\p{L}[\\p{L} ]{0,24} +[0-9]+ *$",
            @"^([bcdlpsw-][rwsStTx-]{9}[@+.]?) +[0-9]+ +(\\S+) +(\\S+) +([0-9][0-9.,A-Za-z]*) +((?:\\S+ +\\S+ +(?:[0-9]{1,2}:[0-9]{2}|[0-9]{4}))|(?:[0-9]{4}-[0-9]{2}-[0-9]{2} +[0-9]{2}:[0-9]{2})) (.+)$",
            {6,4,5,1,2,3}, {17,-7,14,11,9,7}},
        {"docker", @[@"容器",@"镜像",@"状态",@"端口",@"容器 ID",@"启动命令",@"创建时间"],
            @"^CONTAINER ID +IMAGE +COMMAND +CREATED +STATUS +PORTS +NAMES *$",
            @"^([0-9a-f]{12,64}) {2,}(\\S+) {2,}(\".*\") {2,}(\\S+(?: \\S+)*) {2,}(\\S+(?: \\S+)*) {2,}(?:(\\S+(?: \\S+)*) {2,})?([A-Za-z0-9_.-]+) *$",
            {7,2,5,6,1,3,4}, {12,14,11,18,12,22,12}},
        {"images", @[@"镜像",@"标签",@"大小",@"镜像 ID",@"创建时间"],
            @"^REPOSITORY +TAG +IMAGE ID +CREATED +SIZE *$",
            @"^(\\S+) +(\\S+) +((?:sha256:)?[0-9a-f]{12,64}) +(.+?) {2,}(\\d[\\d.]* *[kKMGTPE]?B) *$",
            {1,2,5,3,4}, {18,10,-9,13,15}},
        {"networks", @[@"网络",@"驱动",@"范围",@"网络 ID"],
            @"^NETWORK ID +NAME +DRIVER +SCOPE *$",
            @"^([0-9a-f]{12,64}) +(\\S+) +(\\S+) +(\\S+) *$",
            {2,3,4,1}, {17,10,9,14}},
        {"volumes", @[@"卷名",@"驱动"],
            @"^DRIVER +VOLUME NAME *$",
            @"^([\\w.-]+) {2,}([\\w.-]+) *$",
            {2,1}, {25,10}},
        {"df", @[@"挂载点",@"可用",@"已用",@"使用率",@"容量",@"文件系统"],
            @"^Filesystem +\\S+ +Used +(?:Avail(?:able)?) +(?:Capacity|Use%)(?: +iused +ifree +%iused)? +Mounted (?:on|On) *$",
            @"^(.+?) +(\\d[\\d.,]*[A-Za-z]*) +(\\d[\\d.,]*[A-Za-z]*) +(\\d[\\d.,]*[A-Za-z]*) +(\\d+%)(?: +\\S+ +\\S+ +(?:\\d+%|-))? +(/.*)$",
            {6,4,3,5,2,1}, {17,-8,-8,-7,-8,19}},
        {"ps", @[@"命令",@"PID",@"终端",@"CPU 时间",@"状态"],
            @"^ *PID +(?:TT|TTY) +(?:STAT +)?TIME +(?:CMD|COMMAND) *$",
            @"^ *(\\d+) +(\\S+) +(?:(\\S+) +)?([\\d:.-]+) +(.+)$",
            {5,1,2,4,3}, {22,-7,8,-11,7}},
        {"ps-user", @[@"命令",@"PID",@"CPU %",@"内存 %",@"用户",@"状态",@"CPU 时间"],
            @"^ *USER +PID +%CPU +%MEM +VSZ +RSS +(?:TT|TTY) +STAT +START(?:ED)? +TIME +(?:COMMAND|CMD) *$",
            @"^ *(\\S+) +(\\d+) +([\\d.,]+) +([\\d.,]+) +\\d+ +\\d+ +\\S+ +(\\S+) +\\S+ +([\\d:.-]+) +(.+)$",
            {7,2,3,4,1,5,6}, {24,-7,-7,-7,10,6,-10}},
        {"ps-full", @[@"命令",@"PID",@"父 PID",@"用户",@"CPU 时间",@"终端"],
            @"^ *UID +PID +PPID +C +STIME +TTY +TIME +(?:CMD|COMMAND) *$",
            @"^ *(\\S+) +(\\d+) +(\\d+) +\\d+ +\\S+ +(\\S+) +([\\d:.-]+) +(.+)$",
            {6,2,3,1,5,4}, {24,-7,-8,10,-11,7}},
        {"jobs", @[@"服务",@"PID",@"退出状态"],
            @"^PID +Status +Label *$",
            @"^ *(\\d+|-) +(-?\\d+) +(\\S+) *$",
            {3,1,2}, {28,-7,-9}},
        {"packages", @[@"软件包",@"版本",@"可编辑项目路径"],
            @"^Package +Version(?: +Editable project location)? *$",
            @"^([\\w][\\w.-]*) +(\\d\\S*|[A-Za-z]\\S*\\d\\S*)(?: +(.+))? *$",
            {1,2,3}, {21,14,24}},
        {"remotes", @[@"远程仓库",@"地址",@"用途"],
            nil,
            @"^(\\S+) +(\\S.+?) +\\((fetch|push)\\) *$",
            {1,2,3}, {12,32,7}},
        {"worktrees", @[@"工作目录",@"分支",@"提交"],
            nil,
            @"^(.+?) {1,}([0-9a-f]{4,64}) +(\\[.+\\]|\\(detached HEAD\\))(?: +(?:locked|prunable).*)? *$",
            {1,3,2}, {27,15,10}},
        {"pods", @[@"Pod",@"状态",@"就绪",@"重启",@"运行时间",@"命名空间"],
            @"^(?:NAMESPACE +)?NAME +READY +STATUS +RESTARTS +AGE *$",
            @"^(?:(\\S+) +)?(\\S+) +(\\d+/\\d+) +(\\S+) +(\\d+(?: +\\([^)]+\\))?) +([\\w<>-]+) *$",
            {2,4,3,5,6,1}, {19,15,-6,-10,-8,13}},
        {"services", @[@"服务",@"类型",@"集群 IP",@"端口",@"外部 IP",@"运行时间",@"命名空间"],
            @"^(?:NAMESPACE +)?NAME +TYPE +CLUSTER-IP +EXTERNAL-IP +PORT\\(S\\) +AGE *$",
            @"^(?:(\\S+) +)?(\\S+) +(ClusterIP|NodePort|LoadBalancer|ExternalName) +(\\S+) +(\\S+) +(\\S+) +(\\S+) *$",
            {2,3,4,6,5,7,1}, {16,13,14,14,13,-8,13}},
        {"deployments", @[@"部署",@"就绪",@"最新副本",@"可用副本",@"运行时间",@"命名空间"],
            @"^(?:NAMESPACE +)?NAME +READY +UP-TO-DATE +AVAILABLE +AGE *$",
            @"^(?:(\\S+) +)?(\\S+) +(\\d+/\\d+) +(\\d+) +(\\d+) +(\\S+) *$",
            {2,3,4,5,6,1}, {18,-7,-9,-9,-8,13}},
        {"namespaces", @[@"命名空间",@"状态",@"运行时间"],
            @"^NAME +STATUS +AGE *$",
            @"^(\\S+) +(Active|Terminating) +(\\S+) *$",
            {1,2,3}, {20,13,-9}},
        {"", @[@"镜像",@"磁盘占用",@"内容大小",@"镜像 ID",@"标记"],
            @"^IMAGE +ID +DISK USAGE +CONTENT SIZE +EXTRA *$",
            @"^(\\S+) +((?:sha256:)?[0-9a-f]{12,64}) +([0-9][0-9.,]* *[kKMGTPE]?B) +([0-9][0-9.,]* *[kKMGTPE]?B)(?: +(\\S.*?))? *$",
            {1,3,4,2,5}, {21,-10,-10,14,7}},
    };
    static_assert(std::size(specs) == (size_t)ListingFormat::Count);
    return specs;
}
const ListingSpec &SpecForListing(ListingFormat format) { return listingSpecs()[(size_t)format]; }
std::optional<ListingFormat> FormatForOutput(std::string_view key) {
    for (size_t i=0;i<(size_t)ListingFormat::Count;++i)
        if (!key.empty() && key == listingSpecs()[i].key) return (ListingFormat)i;
    return std::nullopt;
}
struct ListingPatterns {
    NSRegularExpression *header, *row;
    std::once_flag initialized;
};
static const ListingPatterns &patterns(ListingFormat format) {
    static ListingPatterns compiled[(size_t)ListingFormat::Count];
    auto &p = compiled[(size_t)format];
    std::call_once(p.initialized,[&] {
        const auto &spec = SpecForListing(format);
        p.header = spec.headerPattern ? pattern(spec.headerPattern) : nil;
        p.row = pattern(spec.rowPattern);
    });
    return p;
}
bool IsListingHeader(ListingFormat format, NSString *line) {
    if (!line.length || !SpecForListing(format).headerPattern) return false;
    if (format != ListingFormat::Files) {
        NSUInteger first = 0;
        while (first < line.length && [line characterAtIndex:first] == ' ') ++first;
        if (first == line.length) return false;
        unichar ch = [line characterAtIndex:first];
        if (ch < 'A' || ch > 'Z') return false;
    }
    return [patterns(format).header firstMatchInString:line options:0 range:NSMakeRange(0,line.length)] != nil;
}
NSArray<NSString *> *ListingFields(ListingFormat format, NSString *line) {
    if (!line.length) return nil;
    const auto &spec = SpecForListing(format);
    NSTextCheckingResult *m = [patterns(format).row firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
    if (!m) return nil;
    NSString *fields[8];
    for (NSUInteger i=0;i<spec.labels.count;++i) {
        NSRange r = [m rangeAtIndex:spec.capture[i]];
        fields[i] = r.location == NSNotFound ? @"" : [line substringWithRange:r];
    }
    return [NSArray arrayWithObjects:fields count:spec.labels.count];
}

ParsedListing ParseListing(ListingFormat format, NSString *text, bool includeData) {
    auto parse = [&](ListingFormat shape) -> ParsedListing {
        if (IsListingHeader(shape,text)) return {shape,true,SpecForListing(shape).labels};
        return {shape,false,includeData ? ListingFields(shape,text) : nil};
    };
    auto result = parse(format);
    // Newer Docker versions show disk and content size when stdout is a TTY.
    return (!result.fields && format == ListingFormat::Images) ? parse(ListingFormat::ImageUsage) : result;
}

NSURL *TerminalURI(NSString *text, BOOL web, BOOL files) {
    if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:text];
    NSString *scheme = c.scheme.lowercaseString;
    if (web && ([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) && c.host.length) return c.URL;
    if (!files || ![scheme isEqual:@"file"] || ![c.path hasPrefix:@"/"]) return nil;
    NSString *host = c.host.lowercaseString;
    if (host.length && ![host isEqual:@"localhost"] && ![host isEqual:NSProcessInfo.processInfo.hostName.lowercaseString]) return nil;
    return [NSURL fileURLWithPath:c.path isDirectory:NO];
}

static NSURL *existingPath(NSString *path, NSString *directory) {
    if (!path.length || [path containsString:@"://"]) return nil;
    if ([path hasPrefix:@"~/"] || [path isEqual:@"~"]) path = path.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath) {
        if (!directory.length) return nil;
        path = [directory stringByAppendingPathComponent:path];
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path];
}
NSURL *ExistingListingFile(NSString *name, NSString *directory) {
    return existingPath(name,directory);
}
NSURL *LinkInOutput(NSString *line, NSUInteger index, NSString *directory, BOOL web, BOOL files) {
    if ((!web && !files) || index >= line.length) return nil;
    static NSRegularExpression *links = pattern(@"(?i)(?:https?://|file://|\\bwww\\.)[^\\s<>\"\\x00-\\x1F]+");
    for (NSTextCheckingResult *m in [links matchesInString:line options:0 range:NSMakeRange(0,line.length)]) {
        if (!NSLocationInRange(index,m.range)) continue;
        NSString *value = [line substringWithRange:m.range];
        while (value.length) {
            unichar last = [value characterAtIndex:value.length-1];
            if (last == ')' || last == ']') {
                unichar open = last == ')' ? '(' : '[';
                int balance = 0;
                for (NSUInteger i=0;i<value.length;++i) {
                    unichar c = [value characterAtIndex:i];
                    balance += (c == open) - (c == last);
                }
                if (balance >= 0) break;
            }
            if (![@".,;!?)'’]}>，。" containsString:[value substringFromIndex:value.length-1]]) break;
            value = [value substringToIndex:value.length-1];
        }
        if (index >= m.range.location+value.length) return nil;
        if ([value.lowercaseString hasPrefix:@"www."]) value = [@"https://" stringByAppendingString:value];
        return TerminalURI(value,web,files);
    }
    if (!files) return nil;
    // Quoted shell paths preserve whitespace. Backslash-space is also common in pasted paths.
    static NSRegularExpression *paths = pattern(@"'([^']+)'|\"([^\"]+)\"|(?:\\\\ |[^\\s<>()\\[\\]{}\"'])+");
    for (NSTextCheckingResult *m in [paths matchesInString:line options:0 range:NSMakeRange(0,line.length)]) {
        if (!NSLocationInRange(index,m.range)) continue;
        NSRange r = m.range;
        for (int i=1; i<=2; ++i) if ([m rangeAtIndex:i].location != NSNotFound) r = [m rangeAtIndex:i];
        NSString *s = [[line substringWithRange:r] stringByReplacingOccurrencesOfString:@"\\ " withString:@" "];
        NSURL *url = existingPath(s,directory);
        if (url) return url;
        static NSRegularExpression *location = pattern(@":(?:[0-9]+(?::[0-9]+)?)?:?$");
        s = [location stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0,s.length) withTemplate:@""];
        return existingPath(s,directory);
    }
    return nil;
}
