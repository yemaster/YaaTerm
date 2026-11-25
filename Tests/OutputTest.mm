#import "TerminalView.h"
#import "LLMConfiguration.h"
#import <objc/runtime.h>
#import "TerminalOutput.h"
#import "Preferences.h"
#import "Session.h"
#include <cassert>
#include <sys/ioctl.h>
#import <CoreText/CoreText.h>

@interface TerminalView (OutputTest)
- (NSURL *)linkAtPoint:(NSPoint)p;
- (void)consume:(std::string_view)bytes;
- (void)toggleListing:(NSButton *)sender;
- (const yaa::Row &)displayRow:(int)y;
@end

@interface HoverTestWindow : NSWindow
@property NSPoint pointerLocation;
@end
@implementation HoverTestWindow
- (NSPoint)mouseLocationOutsideOfEventStream { return self.pointerLocation; }
@end

// Substitute only the provider. Input, prompt hooks, shell execution and rendering are real.
@interface PromptFixture : LLMConfiguration
+ (void)loadFixture:(void (^)(LLMConfiguration *,NSString *))completion;
@end
static dispatch_block_t firstAgentReply;
@implementation PromptFixture
+ (void)loadFixture:(void (^)(LLMConfiguration *,NSString *))completion { completion([PromptFixture new],nil); }
- (NSURLSessionDataTask *)ask:(NSString *)input instruction:(NSString *)instruction completion:(void (^)(NSString *,NSString *))reply {
    NSDictionary *task=[NSJSONSerialization JSONObjectWithData:[input dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSArray *steps=task[@"steps"]; NSString *json=nil;
    if ([task[@"goal"] isEqual:@"interrupt-read"]) {
        assert(!steps.count); reply(@"{\"command\":\"sleep 30\"}",nil); return nil;
    }
    if ([task[@"goal"] isEqual:@"syntax-check"]) {
        if (!steps.count) reply(@"{\"command\":\")\"}",nil);
        else {
            assert(steps.count==1 && [steps[0][@"status"] intValue]!=0 && [steps[0][@"output"] containsString:@"parse error"]);
            reply(@"{\"text\":\"SYNTAX-REPORTED\"}",nil);
        }
        return nil;
    }
    assert([task[@"goal"] isEqual:@"print 仅作任务 > \"$ZDOTDIR/accidental-execution\""]);
    switch (steps.count) {
        case 0: { firstAgentReply=^{ reply(@"{\"command\":\"pwd\"}",nil); }; return nil; }
        case 1: assert([steps[0][@"command"] isEqual:@"pwd"] && [steps[0][@"status"] intValue]==0);
            json=@"{\"command\":\"ls\"}"; break;
        case 2: assert([steps[1][@"output"] containsString:@"confirmed.txt"]);
            json=@"{\"command\":\"print APPROVED-RESULT; read -r answer; print -- $answer; cd -- 'build %n'; false\"}"; break;
        default: assert(steps.count==3 && [steps.lastObject[@"output"] containsString:@"APPROVED-RESULT"] &&
                        [steps.lastObject[@"output"] containsString:@"from-stdin"] && [steps.lastObject[@"status"] intValue]==1);
            assert(![steps.lastObject[@"output"] containsString:@"read -r"]);
            json=@"{\"text\":\"INLINE-TASK-COMPLETE\"}"; break;
    }
    dispatch_async(dispatch_get_main_queue(),^{ reply(json,nil); }); return nil;
}
@end

static void until(BOOL (^predicate)(void), int line = __builtin_LINE()) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!predicate() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    if (!predicate()) { fprintf(stderr,"output fixture timed out on line %d\n",line); abort(); }
}

static NSBitmapImageRep *paint(TerminalView *pane, NSString *name) {
    NSSize size = pane.bounds.size;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:size.width pixelsHigh:size.height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextRef cg = context.CGContext;
    CGContextTranslateCTM(cg,0,size.height); CGContextScaleCTM(cg,1,-1);
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES];
    [pane drawRect:pane.bounds];
    for (NSView *view in pane.subviews)
        if ([view isKindOfClass:NSButton.class]) [[(NSButton *)view cell] drawWithFrame:view.frame inView:pane];
        else if ([view isKindOfClass:NSProgressIndicator.class]) {
            [NSGraphicsContext saveGraphicsState];
            CGContextTranslateCTM(cg,NSMinX(view.frame),NSMinY(view.frame));
            [view drawRect:view.bounds];
            [NSGraphicsContext restoreGraphicsState];
        }
    [NSGraphicsContext restoreGraphicsState];
    NSString *dir = NSProcessInfo.processInfo.environment[@"YAATERM_TEST_PREVIEW"];
    if (name && dir) [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                      writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    return rep;
}

static void checkListingFormats() {
    struct Sample { const char *key; NSString *header, *row, *first, *second; };
    Sample samples[] = {
        {"images",@"REPOSITORY   TAG   IMAGE ID   CREATED   SIZE",
            @"redis   latest   787a1c330bdd   2 weeks ago   84.5 MB",@"redis",@"latest"},
        {"images",@"IMAGE   ID   DISK USAGE   CONTENT SIZE   EXTRA",
            @"redis:7   787a1c330bdd   84.5MB   24MB   U",@"redis:7",@"84.5MB"},
        {"networks",@"NETWORK ID   NAME   DRIVER   SCOPE",
            @"43b7fcac3a9a   project_default   bridge   local",@"project_default",@"bridge"},
        {"volumes",@"DRIVER   VOLUME NAME",@"local     my_data",@"my_data",@"local"},
        {"df",@"Filesystem  Size  Used Avail Capacity iused ifree %iused  Mounted on",
            @"/dev/disk7s1  2.0Ti  1.1Ti  900Gi  55%  1.2M  3.4G  0%   /Volumes/Build Data",@"/Volumes/Build Data",@"900Gi"},
        {"df",@"Filesystem     Size  Used Avail Use% Mounted on",
            @"/dev/mapper/root  200G  30G  170G  15% /",@"/",@"170G"},
        {"ps",@"  PID TTY          TIME CMD",@"  175 pts/0    00:01:02 /bin/zsh -l",@"/bin/zsh -l",@"175"},
        {"ps",@"  PID TT  STAT      TIME COMMAND",@"  314 ??  Ss     0:00.12 /bin/zsh -l",@"/bin/zsh -l",@"314"},
        {"ps-user",@"USER  PID  %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND",
            @"alex  175  3.5  0.2  10000  1000  ??  S  8:10AM  0:02.14  /bin/zsh -l",@"/bin/zsh -l",@"175"},
        {"ps-full",@"  UID   PID  PPID C STIME TTY TIME CMD",
            @"  501   175     1 0 08:10 ?? 0:02.14 /bin/zsh -l",@"/bin/zsh -l",@"175"},
        {"jobs",@"PID   Status   Label",@"-    -15    local.example.worker",@"local.example.worker",@"-"},
        {"packages",@"Package Version Editable project location",
            @"my-package   2.3.0rc1    /tmp/path with spaces",@"my-package",@"2.3.0rc1"},
        {"remotes",nil,@"origin    https://example.org/team/project.git (fetch)",@"origin",@"https://example.org/team/project.git"},
        {"worktrees",nil,@"/Volumes/Dev Space/feature   1234567 [feature/layout]",@"/Volumes/Dev Space/feature",@"[feature/layout]"},
        {"pods",@"NAMESPACE   NAME   READY   STATUS   RESTARTS   AGE",
            @"staging   web-abc   1/1   Running   2 (3h ago)   7d",@"web-abc",@"Running"},
        {"services",@"NAME  TYPE  CLUSTER-IP  EXTERNAL-IP  PORT(S)  AGE",
            @"web   ClusterIP   10.0.0.4   <none>   80/TCP,443/TCP   2d",@"web",@"ClusterIP"},
        {"deployments",@"NAME   READY   UP-TO-DATE   AVAILABLE   AGE",@"api  2/2  2  2  2d",@"api",@"2/2"},
        {"namespaces",@"NAME   STATUS   AGE",@"staging  Active   5d",@"staging",@"Active"},
    };
    for (auto &sample:samples) {
        auto format = FormatForOutput(sample.key);
        assert(format);
        auto data = ParseListing(*format,sample.row,true);
        assert(!data.header && [data.fields[0] isEqual:sample.first] && [data.fields[1] isEqual:sample.second]);
        assert(data.fields.count == SpecForListing(data.format).labels.count);
        if (sample.header) {
            auto header = ParseListing(*format,sample.header,false);
            assert(header.header && header.format == data.format);
        }
        assert(!ParseListing(*format,@"error: unavailable",true).fields);
    }
    assert(!FormatForOutput("unsupported"));
}

static void testTerminalOutput(NSString *directory) {
    NSString *file = [directory stringByAppendingPathComponent:@"spaced name.txt"];
    assert([@"content" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *docker = [directory stringByAppendingPathComponent:@"docker"];
    NSString *fixture = @"#!/bin/sh\ncat <<'LIST'\nCONTAINER ID   IMAGE          COMMAND                CREATED       STATUS       PORTS                  NAMES\na1b2c3d4e5f6   nginx:alpine   \"nginx -g daemon off\"  3 hours ago   Up 3 hours   127.0.0.1:80->80/tcp   web\n0123456789ab   redis:7        \"redis-server\"         2 hours ago   Up 2 hours                          cache\nLIST\n";
    assert([fixture writeToFile:docker atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:docker error:nil]);
    NSURL *base = [NSURL fileURLWithPath:file];
    assert([LinkInOutput(@"see 'spaced name.txt'",9,directory,NO,YES).path isEqual:base.path]);
    assert([LinkInOutput(@"spaced\\ name.txt:12:3",8,directory,NO,YES).path isEqual:base.path]);
    assert(!TerminalURI(@"file://other-host/etc/hosts",YES,YES) && !TerminalURI(@"javascript:alert(1)",YES,YES));
    assert([LinkInOutput(@"(https://example.org/a_(b)).",10,nil,YES,NO).absoluteString isEqual:@"https://example.org/a_(b)"]);
    assert(!LinkInOutput(@"https://example.org",10,nil,NO,YES));
    assert([LinkInOutput(@"https://[::1]",9,nil,YES,NO).absoluteString isEqual:@"https://[::1]"]);
    assert([LinkInOutput(@"www.example.org/path",2,nil,YES,NO).absoluteString isEqual:@"https://www.example.org/path"]);
    NSArray *emptyPorts = ListingFields(ListingFormat::Containers,@"0123456789ab   redis:7   \"redis-server\"   2 hours ago   Up 2 hours             cache");
    assert([emptyPorts[0] isEqual:@"cache"] && [emptyPorts[3] isEqual:@""] && [emptyPorts[6] isEqual:@"2 hours ago"]);
    OutputReferences *refs = [OutputReferences new];
    uint32_t old = [refs context:FileListing directory:directory];
    for (int i=0;i<64;++i) [refs context:FileListing directory:directory];
    assert(![refs record:old]);
    // Tagged cells have the same size and survive disk paging, reflow and idle compression.
    yaa::Screen history(18,4);
    history.commandExitToken = "fixture"; history.setHistoryLimit(2);
    history.outputContext = [](auto kind,auto dir){return 5u;};
    history.feed("\033]777;yaaterm-context;forged;ls;/tmp\007X");
    assert(!history.row(0)[0].tag);
    history.feed("\r\033]777;yaaterm-context;fixture;ls;/tmp\007visible\r\n");
    for(int i=0;i<80;++i) history.feed("data\r\n");
    history.freeze(); history.thaw(); history.resize(11,7);
    assert(history.archivedRows()>32 && history.lineAt(0)[0].tag==5 && sizeof(yaa::Cell)==16);

    TerminalView *pane = [[TerminalView alloc] initWithFrame:NSMakeRect(0,0,730,530)];
    HoverTestWindow *window = [[HoverTestWindow alloc] initWithContentRect:pane.bounds
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    [window.contentView addSubview:pane];
    auto hover = [&](NSPoint point) {
        window.pointerLocation = [pane convertPoint:point toView:nil];
        NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:window.pointerLocation
            modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:window.windowNumber
            context:nil eventNumber:1 clickCount:0 pressure:0];
        [pane mouseMoved:event];
    };
    auto hand = [&] { return [[pane valueForKey:@"linkCursorVisible"] boolValue]; };
    auto tracking = [&]() -> NSTrackingArea * { return [pane valueForKey:@"motionArea"]; };
    SetTerminalPreference(PrettyTables,YES); SetTerminalPreference(RevealFileLinks,YES); SetTerminalPreference(OpenWebLinks,YES);
    SetTerminalPreference(TerminalFontSize,14);
    [pane start];
    Session *session = [pane valueForKey:@"session"];
    auto send = [&](NSString *s){ [session send:[s dataUsingEncoding:NSUTF8StringEncoding]]; };
    send(@"cd -- \"$ZDOTDIR\"; export PATH=\"$PWD:$PATH\"; PROMPT='❯ '; printf '\\033]2;ready\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"ready"]; });
    send(@"clear\rls -la\rdocker ps\rcd /\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"done"]; });
    auto buttons = ^NSDictionary *{ return [pane valueForKey:@"listingButtons"]; };
    paint(pane,@"tables.png");
    assert(buttons().count == 2);
    NSButton *ls = nil, *ps = nil;
    for (NSButton *button in buttons().allValues) {
        if ((button.tag & 3) == FileListing) ls = button; else ps = button;
    }
    assert(ls && ps && [ls.title isEqual:@"原始数据"] && [ps.title isEqual:@"原始数据"]);
    NSFont *terminalFont = [pane valueForKey:@"regular"];
    assert([terminalFont.familyName isEqual:@"JetBrains Mono"] && [ls.font isEqual:terminalFont]);
    // A mouse-down followed by a mouse-up in the same cell never exposes raw data.
    NSPoint location = [pane convertPoint:NSMakePoint(24,NSMaxY(ls.frame)+4) toView:nil];
    auto event = [&](NSEventType type) {
        return [NSEvent mouseEventWithType:type location:location modifierFlags:0 timestamp:0 windowNumber:0
                                   context:nil eventNumber:1 clickCount:1 pressure:1];
    };
    [pane mouseDown:event(NSEventTypeLeftMouseDown)]; paint(pane,nil);
    assert(buttons().count == 2 && [ls.title isEqual:@"原始数据"]);
    [pane mouseUp:event(NSEventTypeLeftMouseUp)]; paint(pane,nil);
    assert(buttons().count == 2 && [ls.title isEqual:@"原始数据"]);
    auto rawListing = [&] {
        NSMutableString *text = [NSMutableString string];
        for (int y=0;y<18;++y) {
            const auto &r = [pane displayRow:y];
            for (auto &c:r) if (c.width && c.ch < 128) [text appendFormat:@"%c",(char)c.ch];
        }
        return text;
    };
    NSString *raw = rawListing(); assert([raw containsString:@"spaced name.txt"]);
    NSPoint hit{};
    CGFloat lh = [[pane valueForKey:@"lh"] doubleValue], cw = [[pane valueForKey:@"cw"] doubleValue];
    for (int y=0;y<18;++y) {
        NSPoint p = NSMakePoint(20,12+(y+.5)*lh);
        if ([[pane linkAtPoint:p].path isEqual:base.path]) { hit = p; break; }
    }
    assert(hit.x); // The shell has since changed to /.
    assert(!tracking());
    hover(NSMakePoint(NSWidth(pane.bounds)-100,hit.y));
    [pane setLinkModifierDown:YES]; assert(!hand());
    hover(hit); assert(hand() && NSCursor.currentCursor==NSCursor.pointingHandCursor);
    [pane setLinkModifierDown:NO]; assert(!hand() && !tracking() && NSCursor.currentCursor!=NSCursor.pointingHandCursor);
    [pane setLinkModifierDown:YES]; assert(hand()); // Pointer stayed on the file.
    [pane setLinkModifierDown:NO];
    [pane toggleListing:ls]; paint(pane,@"raw.png");
    assert([ls.title isEqual:@"表格"] && [ps.title isEqual:@"原始数据"] && [raw isEqual:rawListing()]);
    int fileY = (int)((hit.y-12)/lh);
    NSString *name = @"spaced name.txt";
    auto &rawRow = [pane displayRow:fileY];
    int nameStart = rawRow.used()-(int)name.length;
    assert([[pane linkAtPoint:NSMakePoint(16+(nameStart+3)*cw,hit.y)].path isEqual:base.path]);
    [pane toggleListing:ps]; paint(pane,nil);
    assert([ps.accessibilityLabel isEqual:@"显示表格"]);
    [pane toggleListing:ls]; [pane toggleListing:ps];
    [pane setFrameSize:NSMakeSize(390,540)]; paint(pane,@"narrow.png");
    assert(buttons().count >= 1);
    [pane setFrameSize:NSMakeSize(730,530)];
    send(@"clear\rcd -- \"$ZDOTDIR\"\rls -la | cat\rprintf '\\033]2;pipe\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"pipe"]; });
    paint(pane,nil); assert(!buttons().count);
    send(@"clear\rls -la .\rprintf '\\033]2;operand\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"operand"]; });
    paint(pane,nil); assert(buttons().count == 1);
    send(@"clear\rdf -h /\rprintf '\\033]2;disk-table\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"disk-table"]; });
    paint(pane,@"disk.png"); assert(buttons().count == 1);
    NSButton *disk = buttons().allValues.firstObject;
    [pane toggleListing:disk]; paint(pane,nil); assert([disk.accessibilityLabel isEqual:@"显示表格"]);
    send(@"git init -q && git remote add origin https://example.org/project.git\rclear\rgit remote -v\rprintf '\\033]2;remote-table\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"remote-table"]; });
    paint(pane,nil); assert(buttons().count == 1);
    [pane adjustFont:3]; paint(pane,nil);
    NSButton *remote = buttons().allValues.firstObject;
    assert([remote.font isEqual:[pane valueForKey:@"regular"]] && remote.font.pointSize==17);
    SetTerminalPreference(TerminalFontWeight,500); paint(pane,nil);
    assert([remote.font isEqual:PreferredTerminalFont(17,NO)]);
    SetTerminalPreference(TerminalFontWeight,0);
    SetTerminalFontFamily(@"Menlo"); paint(pane,nil);
    remote = buttons().allValues.firstObject;
    assert([remote.font.familyName isEqual:@"Menlo"] && [remote.font isEqual:[pane valueForKey:@"regular"]]);
    SetTerminalFontFamily(BundledFontFamily);
    [pane adjustFont:-3];
    SetTerminalPreference(PrettyTables,NO); assert(!buttons().count);
    send(@"printf '\\033[2J\\033[Hhttps://example.org/plain\\r\\n\\033]8;;https://example.org/target\\033\\\\label\\033]8;;\\033\\\\\\r\\n\\033]2;links\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"links"]; });
    assert([[[pane linkAtPoint:NSMakePoint(16+3*cw,12+lh*.5)] absoluteString] isEqual:@"https://example.org/plain"]);
    assert([[[pane linkAtPoint:NSMakePoint(16+2*cw,12+lh*1.5)] absoluteString] isEqual:@"https://example.org/target"]);
    NSPoint web = NSMakePoint(16+3*cw,12+lh*.5), label = NSMakePoint(16+2*cw,12+lh*1.5);
    hover(web); assert(!hand());
    [pane setLinkModifierDown:YES]; assert(hand());
    hover(label); assert(hand());
    hover(NSMakePoint(16+7*cw,label.y)); assert(!hand());
    NSView *overlay = [[NSView alloc] initWithFrame:NSMakeRect(web.x-2,web.y-2,5,5)];
    [pane addSubview:overlay]; hover(web); assert(!hand());
    [overlay removeFromSuperview]; hover(web); assert(hand());
    [pane consume:"\033[H\033[2Kplain"]; paint(pane,nil); assert(!hand());
    [pane consume:"\033[?1003h"]; [pane setLinkModifierDown:NO];
    assert(!hand() && (tracking().options & NSTrackingMouseMoved));
    [pane consume:"\033[?1003l"]; assert(!tracking());
    SetTerminalPreference(OpenWebLinks,NO);
    [pane setLinkModifierDown:YES]; hover(label); assert(!hand());
    SetTerminalPreference(RevealFileLinks,NO);
    [pane setLinkModifierDown:YES]; hover(label); assert(!hand() && !tracking());
    assert(![pane linkAtPoint:NSMakePoint(16+2*cw,12+lh*1.5)]);
    assert(![pane valueForKey:@"assistant"]);
    send(@"cd /yaaterm-no-such-directory\r");
    until(^BOOL{ return pane.hasFailedCommand; });
    NSDictionary *failure=[pane valueForKey:@"failure"];
    assert([failure[@"command"] isEqual:@"cd /yaaterm-no-such-directory"] && [failure[@"status"] intValue]!=0);
    assert([failure[@"output"] containsString:@"yaaterm-no-such-directory"] && ![failure[@"output"] containsString:@"example.org"]);
    send(@"yaaterm_no_such_executable\r");
    until(^BOOL{ return [[[pane valueForKey:@"failure"] objectForKey:@"status"] intValue]==127; });
    // The diagnostic correction remains an editable shell line until the user presses Return.
    NSString *proof=[directory stringByAppendingPathComponent:@"confirmed.txt"];
    NSString *suggestion=@"print -r verified > \"$ZDOTDIR/confirmed.txt\"";
    __block BOOL inserted=NO;
    until(^BOOL{ if (!inserted) inserted=[session submitLine:suggestion execute:NO acknowledged:nil]!=nil; return inserted; });
    until(^BOOL{ return ![session valueForKey:@"pendingID"]; });
    assert(![NSFileManager.defaultManager fileExistsAtPath:proof]);
    send(@"\r");
    until(^BOOL{ return !pane.hasFailedCommand && [NSFileManager.defaultManager fileExistsAtPath:proof]; });
    assert([[NSString stringWithContentsOfFile:proof encoding:NSUTF8StringEncoding error:nil] isEqual:@"verified\n"]);
    assert([NSFileManager.defaultManager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"build %n"]
        withIntermediateDirectories:NO attributes:nil error:nil]);
    send(@"HOME=$ZDOTDIR; repeat 48 print -r -- earlier-output; print -r -- VISIBLE-BEFORE-AGENT; PROMPT=$'THEME-TOP\\nLEFT> '; RPROMPT='THEME-RIGHT'; printf '\\033]2;before-agent\\007'\r");
    until(^BOOL{ return [pane.sessionTitle isEqual:@"before-agent"]; });
    NSUInteger subviews=pane.subviews.count;
    auto rowText=[&](int y) {
        std::string text;
        for (auto &cell : [pane displayRow:y]) text+=(cell.ch<128 ? (char)cell.ch : ' ');
        return text;
    };
    auto snapshot=[&]() {
        std::string text;
        int rows=(int)((NSHeight(pane.bounds)-24)/[[pane valueForKey:@"lh"] doubleValue]);
        for (int y=0;y<rows;++y) { text+=rowText(y); text+='\n'; }
        return text;
    };
    // Preserve an existing scrollback viewport even when the caret is outside it.
    CGEventRef wheel=CGEventCreateScrollWheelEvent(nullptr,kCGScrollEventUnitLine,1,1);
    [pane scrollWheel:[NSEvent eventWithCGEvent:wheel]]; CFRelease(wheel);
    NSInteger offset=[[pane valueForKey:@"offset"] integerValue]; assert(offset>0);
    auto before=snapshot();
    winsize originalSize{}, editingSize{};
    int terminalFD=[[session valueForKey:@"fd"] intValue];
    assert(ioctl(terminalFD,TIOCGWINSZ,&originalSize)==0);
    until(^BOOL{ if (!pane.assistantVisible) [pane toggleAssistant:nil]; return pane.assistantVisible; });
    until(^BOOL{ return ![session valueForKey:@"agentReady"]; });
    assert(session.agentInputID && ![pane valueForKeyPath:@"assistant.diagnosisView"]);
    assert([window firstResponder]==pane && pane.subviews.count==subviews);
    assert(ioctl(terminalFD,TIOCGWINSZ,&editingSize)==0 &&
           originalSize.ws_row==editingSize.ws_row && originalSize.ws_col==editingSize.ws_col);
    assert([[pane valueForKey:@"offset"] integerValue]==offset && before==snapshot());
    Method load=class_getClassMethod(LLMConfiguration.class,@selector(loadSaved:));
    IMP original=method_setImplementation(load,method_getImplementation(class_getClassMethod(PromptFixture.class,@selector(loadFixture:))));
    [pane insertText:@"print 仅作任务 > \"$ZDOTDIR/accidental-execution\"" replacementRange:NSMakeRange(NSNotFound,0)];
    [pane doCommandBySelector:@selector(insertNewline:)];
    auto shown=[&](const char *value){ return snapshot().find(value)!=std::string::npos; };
    auto stampOf=[&](const char *prefix) -> int {
        int rows=(NSHeight(pane.bounds)-24)/[[pane valueForKey:@"lh"] doubleValue];
        for (int y=rows-1;y>=0;--y) if (rowText(y).rfind(prefix,0)==0) return [pane displayRow:y].agentStamp;
        return -1;
    };
    auto idlePromptCount=[&] {
        int rows=(NSHeight(pane.bounds)-24)/[[pane valueForKey:@"lh"] doubleValue], count=0;
        for (int y=0;y<rows;++y) {
            std::string line=rowText(y);
            line.erase(line.find_last_not_of(' ')+1);
            if (line.size()>=7 && line.compare(line.size()-7,7,"Agent >")==0) ++count;
        }
        return count;
    };
    auto key=[&](BOOL cancel) {
        NSString *chars=cancel ? @"c" : @"\r";
        [pane keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:cancel ? NSEventModifierFlagControl : 0 timestamp:0 windowNumber:window.windowNumber
            context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:cancel ? 8 : 36]];
    };
    auto pending=[&](NSString *line) {
        return [[pane valueForKey:@"awaitingApproval"] boolValue] && [[pane valueForKeyPath:@"assistant.expectedCommand"] isEqual:line] && shown("Enter / Ctrl+C");
    };
    until(^BOOL{ return firstAgentReply && [pane valueForKey:@"agentProgress"] && stampOf("~ Agent > print")==0; });
    assert(!idlePromptCount() && !shown("THEME-TOP") && !shown("THEME-RIGHT"));
    paint(pane,@"agent-waiting.png");
    firstAgentReply(); firstAgentReply=nil;
    until(^BOOL{ return pending(@"pwd"); });
    assert(!idlePromptCount() && ![pane valueForKey:@"agentProgress"] && stampOf("$ pwd")>0);
    [pane insertText:@"\r" replacementRange:NSMakeRange(NSNotFound,0)];
    send(@"\r"); // Typeahead in the PTY is not approval for a staged command.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.04]];
    assert(pending(@"pwd")); key(NO);
    until(^BOOL{ return pending(@"ls"); });
    assert(!idlePromptCount() && stampOf("$ ls")>0);
    paint(pane,@"agent-command-review.png"); key(NO);
    until(^BOOL{ return [[pane valueForKey:@"awaitingApproval"] boolValue] && stampOf("$ print APPROVED")>0; });
    assert(!idlePromptCount() && shown("VISIBLE-BEFORE-AGENT") && pane.assistantVisible);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:@"accidental-execution"]]);
    key(NO);
    until(^BOOL{ return stampOf("APPROVED-RESULT")>0 && [pane valueForKey:@"agentProgress"]; });
    int echo=stampOf("$ print APPROVED"), output=stampOf("APPROVED-RESULT");
    assert(echo>0 && !(echo&1) && output==(echo|1) && stampOf("$ pwd")!=echo);
    NSSize paneSize=pane.frame.size;
    [pane setFrameSize:NSMakeSize(paneSize.width-42,paneSize.height)];
    assert(stampOf("APPROVED-RESULT")==output);
    paint(pane,@"agent-running.png");
    [pane insertText:@"from-stdin" replacementRange:NSMakeRange(NSNotFound,0)];
    [pane doCommandBySelector:@selector(insertNewline:)];
    until(^BOOL{ return shown("INLINE-TASK-COMPLETE"); });
    assert(![pane valueForKey:@"agentProgress"] && stampOf("INLINE-TASK-COMPLETE")==0);
    assert(shown("APPROVED-RESULT") && pane.subviews.count==subviews && window.firstResponder==pane);
    paint(pane,@"builtin-agent-in-terminal.png");
    until(^BOOL{ return stampOf("~/build %n Agent > ")==0; });
    send(@"syntax-check\r"); until(^BOOL{ return pending(@")"); });
    key(YES);
    until(^BOOL{ return ![[pane valueForKey:@"awaitingApproval"] boolValue] && idlePromptCount()==1; });
    assert(!shown("SYNTAX-REPORTED"));
    send(@"syntax-check\r"); until(^BOOL{ return pending(@")"); }); key(NO);
    until(^BOOL{ return shown("SYNTAX-REPORTED") && ![pane valueForKey:@"agentProgress"]; });
    send(@"print 仅作任务 > \"$ZDOTDIR/accidental-execution\"\r");
    until(^BOOL{ return firstAgentReply && [pane valueForKey:@"agentProgress"]; });
    key(YES);
    until(^BOOL{ return ![pane valueForKey:@"agentProgress"]; });
    firstAgentReply(); firstAgentReply=nil;
    assert(![pane valueForKeyPath:@"assistant.expectedCommand"]);
    until(^BOOL{ return idlePromptCount()==1; });
    send(@"interrupt-read\r"); until(^BOOL{ return pending(@"sleep 30"); }); key(NO);
    until(^BOOL{ return [[pane valueForKey:@"runningOwned"] boolValue] && ![session shellIsForeground]; });
    key(YES);
    until(^BOOL{ return ![[pane valueForKey:@"insideCommand"] boolValue] && idlePromptCount()==1 && ![pane valueForKey:@"agentProgress"]; });
    method_setImplementation(load,original);
    [pane insertText:@"/exit" replacementRange:NSMakeRange(NSNotFound,0)];
    [pane doCommandBySelector:@selector(insertNewline:)];
    until(^BOOL{ return !pane.assistantVisible; });
    until(^BOOL{ return stampOf("LEFT> ")==0 && shown("THEME-RIGHT") && shown("THEME-TOP"); });
    SetTerminalPreference(BuiltInAgent,NO);
    SetTerminalPreference(AIErrorExplanations,NO);
    SetTerminalPreference(LocalAgentLauncher,NO);
    [pane toggleAssistant:nil]; [pane showLocalAgent:@"codex"];
    assert(![pane valueForKey:@"assistant"] && !session.tracksCommands && ![pane valueForKey:@"fixButton"]);
    SetTerminalPreference(LocalAgentLauncher,YES);
    NSString *stub=[directory stringByAppendingPathComponent:@"claude"];
    NSString *events=@R"SH(#!/bin/sh
[ "$1" = --verbose ] && [ "$2" = --output-format ] && [ "$3" = stream-json ] && [ "$4" = -p ] && [ "$5" = -- ] && [ "$6" = "show progress" ] || exit 41
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pwd"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"WORKING-DIRECTORY"}]}}'
printf '%s\n' '{"type":"result","result":"TASK-FINISHED"}'
)SH";
    assert([events writeToFile:stub atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:stub error:nil]);
    __block NSString *detail=nil;
    pane.agentFinished=^(TerminalView *source,NSString *tool,BOOL failed,NSString *summary) {
        assert(source==pane && [tool isEqual:@"claude"] && !failed); detail=summary;
    };
    send(@"print -r -- saved-");
    [pane showLocalAgent:@"claude"];
    assert(pane.assistantVisible && session.tracksCommands && session==[pane valueForKey:@"session"]);
    [pane insertText:@"show progress" replacementRange:NSMakeRange(NSNotFound,0)];
    [pane doCommandBySelector:@selector(insertNewline:)];
    until(^BOOL{ return [[pane valueForKey:@"awaitingApproval"] boolValue] && shown("Enter / Ctrl+C"); });
    key(NO); until(^BOOL{ return detail!=nil; });
    assert([detail containsString:@"$ pwd"] && [detail containsString:@"WORKING-DIRECTORY"] && [detail containsString:@"TASK-FINISHED"]);
    assert(snapshot().find("TASK-FINISHED")!=std::string::npos);
    paint(pane,@"agent-in-terminal.png");
    pane.agentFinished=nil;
    SetTerminalPreference(LocalAgentLauncher,NO);
    assert(!pane.assistantVisible && !session.tracksCommands);
    send(@"draft > \"$ZDOTDIR/restored.txt\"\r");
    NSString *restored=[directory stringByAppendingPathComponent:@"restored.txt"];
    until(^BOOL{ return [NSFileManager.defaultManager fileExistsAtPath:restored]; });
    assert([[NSString stringWithContentsOfFile:restored encoding:NSUTF8StringEncoding error:nil] isEqual:@"saved-draft\n"]);
    for (NSString *key in @[AIErrorExplanations,BuiltInAgent,LocalAgentLauncher]) SetTerminalPreference(key,YES);
    [pane stop];
    puts("Output: listing formats, real ls/df/git, table toggles, reflow, historical cwd and Command-hover for file, plain and OSC 8 links OK");
}

int main() {
    @autoreleasepool {
        setlocale(LC_CTYPE,"en_US.UTF-8");
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        assert([files createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *profile = @"PROMPT='$ '; HISTFILE=/dev/null\nchpwd() { [[ $PWD != / ]] || printf '\\033]2;done\\007'; }\n";
        assert([profile writeToFile:[dir stringByAppendingPathComponent:@".zshrc"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        setenv("SHELL","/bin/zsh",1); setenv("ZDOTDIR",dir.fileSystemRepresentation,1);
        setenv("SHELL_SESSIONS_DISABLE","1",1);
        assert([NSBundle.mainBundle pathForResource:@".zshenv" ofType:nil inDirectory:@"Shell/zsh"]);
        NSURL *font = [NSURL fileURLWithPath:@"Resources/Fonts/JetBrainsMono-Regular.ttf"];
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)font,kCTFontManagerScopeProcess,nullptr);
        yaa::Screen text(12,2);
        text.feed(u8"X👨‍👩‍👧‍👦👍🏽🇨🇳Y");
        auto outputLine = ReadOutputLine(text,{0,2});
        assert([outputLine.text isEqual:@"X👨‍👩‍👧‍👦👍🏽🇨🇳Y"] && outputLine.index==1);
        checkListingFormats();
        testTerminalOutput(dir);
        assert([files removeItemAtPath:dir error:nil]);
    }
}
