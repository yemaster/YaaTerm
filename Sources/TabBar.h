#import <AppKit/AppKit.h>

@class TabWorkspace;
@interface TabBar : NSView
@property (weak) TabWorkspace *workspace;
- (NSRect)selectedTabScreenRect;
- (NSInteger)insertionSlotAtX:(CGFloat)x;
- (void)indicateSlot:(NSInteger)slot;
@property (copy) void (^onSelect)(NSInteger);
@property (copy) void (^onClose)(NSInteger);
@property (copy) void (^onMove)(NSInteger, NSInteger);
@property (copy) void (^onAdd)(void);
- (void)groupsChanged;
- (void)updateAssistantState;
- (void)insertTitle:(NSString *)title atIndex:(NSInteger)index;
- (void)removeAtIndex:(NSInteger)index;
- (void)moveFrom:(NSInteger)from to:(NSInteger)to;
- (void)setTitle:(NSString *)title atIndex:(NSInteger)index;
- (void)selectIndex:(NSInteger)index;
@end
