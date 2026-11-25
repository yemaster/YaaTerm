#import <AppKit/AppKit.h>

enum SettingsSection : NSInteger { GeneralSection, AppearanceSection, TerminalSection, PerformanceSection, APISection, ShortcutsSection, AboutSection, SectionCount };
NSString *SettingsSectionTitle(NSInteger section);
@interface SettingsView : NSView
@property (copy) void (^onClose)(void);
- (void)selectSection:(NSInteger)section;
- (NSView *)navigationButton;
@end
