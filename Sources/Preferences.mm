#import "Preferences.h"
#import "Palette.h"
#include "Screen.hpp"

NSString *const CloseEndedSessions = @"CloseEndedSessions";
NSString *const ScrollbackLines = @"ScrollbackLines";
NSString *const TerminalColorScheme = @"TerminalColorScheme";
NSString *const AppearanceModeKey = @"AppearanceMode";
NSString *const LightSchemeKey = @"LightColorScheme";
NSString *const DarkSchemeKey = @"DarkColorScheme";
NSString *const TerminalFontSize = @"TerminalFontSize";
NSString *const TerminalFontFamily = @"TerminalFontFamily";
NSString *const BundledFontFamily = @"JetBrains Mono";
NSString *const SystemMonospaceFamily = @"system-monospace";
NSString *const BackgroundOpacity = @"BackgroundOpacity";
NSString *const BackgroundMaterialKey = @"BackgroundMaterial";
NSString *const BackgroundImageOpacity = @"BackgroundImageOpacity";
NSString *const BackgroundImagePath = @"BackgroundImagePath";
NSString *const CommandNoticesKey = @"CommandNotices";
NSString *const SleepIdleTabs = @"SleepIdleTabs";
NSString *const PrettyTables = @"PrettyTables";
NSString *const OpenWebLinks = @"OpenWebLinks";
NSString *const RevealFileLinks = @"RevealFileLinks";
NSString *const AnimateTabSelection = @"AnimateTabSelection";
NSNotificationName const TerminalPreferenceChanged = @"TerminalPreferenceChanged";

NSUserDefaults *TerminalPreferences(void) {
    static NSUserDefaults *defaults = [] {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        // Version 8 saved only an explicit palette choice (0/1 dark, 2 light).
        NSNumber *legacy = [store objectForKey:TerminalColorScheme];
        NSInteger mode = !legacy ? FollowSystem : (legacy.integerValue==2 ? AlwaysLight : AlwaysDark);
        [store registerDefaults:@{CloseEndedSessions:@YES, ScrollbackLines:@(yaa::Screen::defaultHistoryLimit),
                                  AppearanceModeKey:@(mode), LightSchemeKey:@(CatppuccinLatte),
                                  DarkSchemeKey:@(CatppuccinMocha), BackgroundOpacity:@100, BackgroundImageOpacity:@25,
                                  BackgroundMaterialKey:@(PlainBackground),
                                  PrettyTables:@YES, OpenWebLinks:@YES, RevealFileLinks:@YES,
                                  TerminalFontSize:@14, TerminalFontFamily:BundledFontFamily,
                                  SleepIdleTabs:@NO, AnimateTabSelection:@YES, CommandNoticesKey:@(AllCommands)}];
        return store;
    }();
    return defaults;
}
NSInteger PreferredOpacity(NSString *key) {
    return std::clamp([TerminalPreferences() integerForKey:key],0L,100L);
}
static BOOL reducedTransparency = NO;
NSInteger EffectiveBackgroundOpacity(void) {
    return reducedTransparency ? 100 : PreferredOpacity(BackgroundOpacity);
}
void UpdateReducedTransparency(BOOL reduced) {
    if (reduced == reducedTransparency) return;
    reducedTransparency = reduced;
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:BackgroundOpacity];
}
BOOL SupportsLiquidGlass(void) {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) return YES;
#endif
    return NO;
}
TerminalBackgroundMaterial PreferredBackgroundMaterial(void) {
    NSInteger stored = [TerminalPreferences() integerForKey:BackgroundMaterialKey];
    if (stored == LiquidGlassBackground && SupportsLiquidGlass()) return LiquidGlassBackground;
    if (stored == FrostedBackground || stored == LiquidGlassBackground) return FrostedBackground;
    return PlainBackground;
}
NSString *PreferredBackgroundImagePath(void) {
    return [TerminalPreferences() stringForKey:BackgroundImagePath];
}
NSInteger PreferredFontSize(void) {
    return std::clamp([TerminalPreferences() integerForKey:TerminalFontSize],9L,28L);
}
static NSFont *installedMonospaceFont(NSString *family, CGFloat size) {
    if (!family.length) return nil;
    NSDictionary *traits = @{NSFontSymbolicTrait:@(NSFontDescriptorTraitMonoSpace)};
    NSFontDescriptor *query = [NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute:family, NSFontTraitsAttribute:traits}];
    NSFontDescriptor *match = [query matchingFontDescriptorWithMandatoryKeys:[NSSet setWithObjects:NSFontFamilyAttribute,NSFontTraitsAttribute,nil]];
    return match ? [NSFont fontWithDescriptor:match size:size] : nil;
}
NSString *PreferredFontFamily(void) {
    NSString *family = [TerminalPreferences() stringForKey:TerminalFontFamily];
    if ([family isEqual:BundledFontFamily] || [family isEqual:SystemMonospaceFamily]) return family;
    return installedMonospaceFont(family,14) ? family : BundledFontFamily;
}
NSFont *PreferredTerminalFont(CGFloat size, BOOL bold) {
    NSString *family = [TerminalPreferences() stringForKey:TerminalFontFamily];
    NSFontWeight weight = bold ? NSFontWeightMedium : NSFontWeightLight;
    if ([family isEqual:SystemMonospaceFamily]) return [NSFont monospacedSystemFontOfSize:size weight:weight];
    NSFont *font = [family isEqual:BundledFontFamily] ? nil : installedMonospaceFont(family,size);
    if (!font) {
        return [NSFont fontWithName:bold ? @"JetBrainsMono-Medium" : @"JetBrainsMono-Light" size:size]
               ?: [NSFont monospacedSystemFontOfSize:size weight:weight];
    }
    if (!bold) return font;
    NSFont *strong = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSBoldFontMask];
    return strong.isFixedPitch && [strong.familyName isEqual:family] ? strong : font;
}
void SetTerminalFontFamily(NSString *family) {
    NSUserDefaults *defaults = TerminalPreferences();
    if ([[defaults stringForKey:TerminalFontFamily] isEqual:family]) return;
    if (![family isEqual:BundledFontFamily] && ![family isEqual:SystemMonospaceFamily] && !installedMonospaceFont(family,14)) return;
    [defaults setObject:family forKey:TerminalFontFamily];
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:TerminalFontFamily];
}
BOOL TabAnimationsEnabled(void) {
    return [TerminalPreferences() boolForKey:AnimateTabSelection] && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}
NSUInteger PreferredScrollbackLines(void) {
    return std::clamp([TerminalPreferences() integerForKey:ScrollbackLines],0L,3000L);
}
static BOOL systemDark = NO;
static NSInteger effectiveScheme = NSNotFound;

NSInteger PreferredSchemeForStyle(BOOL light) {
    NSInteger value = [TerminalPreferences() integerForKey:light ? LightSchemeKey : DarkSchemeKey];
    if (value >= 0 && value < SchemeCount && SchemeIsLight(value)==light) return value;
    return light ? CatppuccinLatte : CatppuccinMocha;
}
static NSInteger resolveScheme() {
    NSInteger mode = [TerminalPreferences() integerForKey:AppearanceModeKey];
    BOOL dark = mode == AlwaysDark || (mode != AlwaysLight && systemDark);
    return PreferredSchemeForStyle(!dark);
}
NSInteger PreferredColorScheme(void) {
    if (effectiveScheme == NSNotFound) effectiveScheme = resolveScheme();
    return effectiveScheme;
}
static void refreshScheme() {
    NSInteger resolved = resolveScheme();
    if (effectiveScheme == resolved) return;
    effectiveScheme = resolved;
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:TerminalColorScheme];
}
void UpdateSystemAppearance(NSAppearance *appearance) {
    NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]];
    BOOL dark = [match isEqual:NSAppearanceNameDarkAqua];
    if (systemDark == dark) return;
    systemDark = dark;
    refreshScheme();
}
void SetTerminalPreference(NSString *key, NSInteger value) {
    if ([key isEqual:BackgroundMaterialKey] && (value < PlainBackground || value > LiquidGlassBackground)) return;
    if ([key isEqual:BackgroundOpacity] || [key isEqual:BackgroundImageOpacity])
        value = std::clamp(value,0L,100L);
    BOOL light = [key isEqual:LightSchemeKey];
    BOOL palette = light || [key isEqual:DarkSchemeKey];
    BOOL mode = [key isEqual:AppearanceModeKey];
    if (palette && (value < 0 || value >= SchemeCount || SchemeIsLight(value) != light)) return;
    if (mode && (value < FollowSystem || value > AlwaysDark)) return;
    NSUserDefaults *defaults = TerminalPreferences();
    if ([defaults integerForKey:key] == value) return;
    [defaults setInteger:value forKey:key];
    if (palette || mode) refreshScheme();
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:key];
}
