#import <AppKit/AppKit.h>

extern NSString *const CloseEndedSessions;
extern NSString *const ScrollbackLines;
extern NSString *const TerminalFontSize;
extern NSString *const TerminalFontWeight;
extern NSString *const TerminalFontFamily;
extern NSString *const BundledFontFamily;
extern NSString *const SystemMonospaceFamily;
// TerminalColorScheme signals a change to the resolved palette.
extern NSString *const TerminalColorScheme;
extern NSString *const AppearanceModeKey;
extern NSString *const LightSchemeKey;
extern NSString *const DarkSchemeKey;
enum TerminalAppearanceMode : NSInteger { FollowSystem, AlwaysLight, AlwaysDark };
void UpdateSystemAppearance(NSAppearance *appearance);
NSInteger PreferredSchemeForStyle(BOOL light);
NSInteger PreferredColorScheme(void);
extern NSString *const BackgroundOpacity;
extern NSString *const BackgroundMaterialKey;
enum TerminalBackgroundMaterial : NSInteger { PlainBackground, FrostedBackground, LiquidGlassBackground };
BOOL SupportsLiquidGlass(void);
TerminalBackgroundMaterial PreferredBackgroundMaterial(void);
NSInteger EffectiveBackgroundOpacity(void);
void UpdateReducedTransparency(BOOL reduced);
extern NSString *const BackgroundImageOpacity;
extern NSString *const BackgroundImagePath;
NSInteger PreferredOpacity(NSString *key);
NSString *PreferredBackgroundImagePath(void);
extern NSString *const SleepIdleTabs;
extern NSString *const AIErrorExplanations, *const BuiltInAgent, *const LocalAgentLauncher;
extern NSString *const PrettyTables;
extern NSString *const OpenWebLinks;
extern NSString *const RevealFileLinks;
extern NSString *const AnimateTabSelection;
extern NSString *const CommandNoticesKey;
enum CommandNoticePolicy : NSInteger { AllCommands, LongCommands, AgentOnly };
BOOL TabAnimationsEnabled(void);
extern NSNotificationName const TerminalPreferenceChanged;

NSUserDefaults *TerminalPreferences(void);
NSInteger PreferredFontSize(void);
NSInteger PreferredFontWeight(void);
NSString *PreferredFontFamily(void);
NSFont *PreferredTerminalFont(CGFloat size, BOOL bold);
void SetTerminalFontFamily(NSString *family);
NSUInteger PreferredScrollbackLines(void);
void SetTerminalPreference(NSString *key, NSInteger value);
