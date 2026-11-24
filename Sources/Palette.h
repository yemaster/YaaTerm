#import <AppKit/AppKit.h>

enum SchemeColor { SchemeBackground=16, SchemeText, SchemeCursor, SchemeSelection, SchemeSelectedText, SchemeColorCount };
NSAppearance *SchemeAppearance(NSInteger scheme);
// The IDs are saved in user preferences. Append new schemes without reordering these.
enum TerminalScheme : NSInteger { CatppuccinLatte, CatppuccinMocha, OneHalfLight, OneHalfDark,
                                  SolarizedLight, SolarizedDark, GitHubLight, GitHubDark,
                                  VSLight, VSDark, Tomorrow, TomorrowNight, SchemeCount };
BOOL SchemeIsLight(NSInteger scheme);
NSString *SchemeName(NSInteger scheme);
// SchemeSelectedText is nil for palettes that retain the glyph's own foreground.
NSColor *SchemeInk(NSInteger scheme, NSInteger color);
NSColor *TerminalIndexedColor(NSInteger scheme, int index);

struct InterfacePalette {
    NSColor *background, *chrome, *text, *secondaryText, *separator, *accent, *selectionFill;
    NSColor *splitRule, *findFill, *findText;
};
const InterfacePalette &CurrentInterfacePalette(void);
