#import <AppKit/AppKit.h>
@class TerminalView;

// Main-thread inbox. Only the short display strings outlive the emitting callback.
extern NSNotificationName const TaskNoticesChanged;
NSString *AgentNoticeSummary(NSString *reply);
@interface TaskNotice : NSObject
@property (readonly, weak) TerminalView *source;
@property (readonly, weak) NSWindow *originWindow;
@property (readonly) NSString *title, *summary;
@property (readonly) BOOL unread;
+ (NSArray<TaskNotice *> *)recent;
+ (NSUInteger)unreadCount;
+ (void)postFrom:(TerminalView *)source window:(NSWindow *)window title:(NSString *)title summary:(NSString *)summary;
+ (void)discardFor:(TerminalView *)source;
- (void)open;
@end

// One presenter per bell, created on first use. The list and banner exist only while visible.
@interface TaskNoticePresenter : NSObject
- (void)toggleFrom:(NSButton *)bell;
- (void)show:(TaskNotice *)notice inContent:(NSView *)content top:(CGFloat)top;
- (void)refresh;
@end
