#import <AppKit/AppKit.h>

enum ShortcutID : NSInteger {
    NewWindowKey, NewTabKey, PreviousTabKey, NextTabKey, ClosePaneKey,
    SplitRightKey, SplitDownKey, PreviousPaneKey, NextPaneKey,
    CopyKey, PasteKey, FindKey, TerminalFindKey, FindNextKey, FindPreviousKey,
    SearchNextKey, SearchPreviousKey, SearchCloseKey,
    AgentKey, ExplainKey, ApproveKey, StopAgentKey,
    LargerKey, SmallerKey, NormalSizeKey, SettingsKey, MinimizeKey, FullScreenKey, QuitKey, ShortcutCount
};

struct ShortcutInfo { NSString *identifier, *title, *group; NSUInteger standard; };
extern NSString *const ShortcutPreferences;
const ShortcutInfo &Shortcut(ShortcutID index);
NSUInteger ShortcutValue(ShortcutID index);
NSString *ShortcutLabel(ShortcutID index);
NSString *ShortcutTip(NSString *title, ShortcutID index);
BOOL MatchesShortcut(NSEvent *event, ShortcutID index);
void AddShortcutItem(NSMenu *menu, ShortcutID index);
void UpdateShortcutItems(NSMenu *menu);
void RestoreShortcuts(void);

// Settings owns these buttons only while the shortcuts page is visible.
@interface ShortcutRecorder : NSButton
- (instancetype)initWithShortcut:(ShortcutID)index;
- (void)refresh;
@end
