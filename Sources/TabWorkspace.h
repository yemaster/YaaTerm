#import "TabBar.h"
#import "TerminalView.h"

@class TerminalTab, TabWorkspace;
@interface TabGroup : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger colorIndex;
@property (nonatomic) BOOL collapsed;
@end

@protocol WorkspaceWindow <NSObject>
@property (readonly) TabWorkspace *workspace;
@end

// Each window owns one workspace. A tab retains its pane tree even while detached.
@interface TabWorkspace : NSView <NSSplitViewDelegate>
@property (readonly) TabBar *tabBar;
@property (readonly) TerminalView *focused;
@property (readonly) NSInteger count;
@property (readonly) NSInteger selectedIndex;
@property (copy) void (^onEmpty)(void);
@property (copy) TabWorkspace *(^onDetach)(TerminalTab *, NSRect);
- (TerminalTab *)tabAtIndex:(NSInteger)index;
- (NSInteger)indexOfTab:(TerminalTab *)tab;
- (TabGroup *)groupAtIndex:(NSInteger)index;
- (NSRange)rangeOfGroup:(TabGroup *)group;
- (NSArray<TabGroup *> *)groups;
- (TabGroup *)createGroupForTab:(TerminalTab *)tab name:(NSString *)name;
- (void)putTab:(TerminalTab *)tab inGroup:(TabGroup *)group;
- (void)ungroup:(TabGroup *)group;
- (void)toggleGroup:(TabGroup *)group;
- (void)addTabInGroup:(TabGroup *)group;
- (BOOL)transferTab:(TerminalTab *)tab to:(TabWorkspace *)destination atSlot:(NSInteger)slot group:(TabGroup *)group;
- (BOOL)transferTab:(TerminalTab *)tab to:(TabWorkspace *)destination atSlot:(NSInteger)slot;
@property (readonly) BOOL showingSettings;
@property (copy) void (^onSettingsVisibilityChange)(void);
- (void)setLinkModifierDown:(BOOL)down;
- (void)showSettings;
- (void)dismissSettings;
- (void)addTab;
- (void)selectIndex:(NSInteger)index;
- (void)closeTabAt:(NSInteger)index;
- (void)moveFrom:(NSInteger)from to:(NSInteger)to;
- (void)cycleTab:(NSInteger)step;
- (void)splitVertical:(BOOL)vertical;
- (void)closePane;
- (void)nextPane:(NSInteger)direction;
- (void)stopAll;
@end
