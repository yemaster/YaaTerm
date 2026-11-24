#import "Palette.h"
#import "Preferences.h"

// Terminal RGB values come from the sources listed in Resources/ThemeCredits.txt.
static constexpr unsigned inheritedText = 0x1000000;
static const struct {
    NSString *name;
    BOOL light;
    unsigned colors[SchemeColorCount];
} palettes[SchemeCount] = {
    {@"Catppuccin Latte", YES, {
        0xbcc0cc,0xd20f39,0x40a02b,0xdf8e1d,0x1e66f5,0xea76cb,0x179299,0x5c5f77,
        0xacb0be,0xe7103f,0x46b02f,0xe49931,0x3878f6,0xef95d7,0x19a1a8,0x6c6f85,
        0xeff1f5,0x4c4f69,0xdc8a78,0xdc8a78,0xeff1f5}},
    {@"Catppuccin Mocha", NO, {
        0x45475a,0xf38ba8,0xa6e3a1,0xf9e2af,0x89b4fa,0xf5c2e7,0x94e2d5,0xbac2de,
        0x585b70,0xf7aec2,0xc2ecbf,0xfcd682,0xaeccfc,0xf398da,0xb1eae1,0xa6adc8,
        0x1e1e2e,0xcdd6f4,0xf5e0dc,0xf5e0dc,0x1e1e2e}},
    {@"One Half Light", YES, {
        0x383a42,0xe45649,0x50a14f,0xc18401,0x0184bc,0xa626a4,0x0997b3,0xbababa,
        0x4f525e,0xe06c75,0x98c379,0xd8b36e,0x61afef,0xc678dd,0x56b6c2,0xffffff,
        0xfafafa,0x383a42,0xa5b4e5,0xbfceff,0x383a42}},
    {@"One Half Dark", NO, {
        0x282c34,0xe06c75,0x98c379,0xe5c07b,0x61afef,0xc678dd,0x56b6c2,0xdcdfe4,
        0x5d677a,0xe06c75,0x98c379,0xe5c07b,0x61afef,0xc678dd,0x56b6c2,0xdcdfe4,
        0x282c34,0xdcdfe4,0xa3b3cc,0x474e5d,0xdcdfe4}},
    {@"Solarized Light", YES, {
        0x073642,0xdc322f,0x859900,0xb58900,0x268bd2,0xd33682,0x2aa198,0xbbb5a2,
        0x002b36,0xcb4b16,0x586e75,0x657b83,0x839496,0x6c71c4,0x93a1a1,0xfdf6e3,
        0xfdf6e3,0x657b83,0x657b83,0xeee8d5,0x586e75}},
    {@"Solarized Dark", NO, {
        0x073642,0xdc322f,0x859900,0xb58900,0x268bd2,0xd33682,0x2aa198,0xeee8d5,
        0x335e69,0xcb4b16,0x586e75,0x657b83,0x839496,0x6c71c4,0x93a1a1,0xfdf6e3,
        0x002b36,0x839496,0x839496,0x073642,0x93a1a1}},
    {@"GitHub Light", YES, {
        0x24292f,0xcf222e,0x116329,0x4d2d00,0x0969da,0x8250df,0x1b7c83,0x6e7781,
        0x57606a,0xa40e26,0x1a7f37,0x633c01,0x218bff,0xa475f9,0x3192aa,0x8c959f,
        0xffffff,0x1f2328,0x0969da,0x1f2328,0xffffff}},
    {@"GitHub Dark", NO, {
        0x484f58,0xff7b72,0x3fb950,0xd29922,0x58a6ff,0xbc8cff,0x39c5cf,0xb1bac4,
        0x6e7681,0xffa198,0x56d364,0xe3b341,0x79c0ff,0xd2a8ff,0x56d4dd,0xffffff,
        0x0d1117,0xe6edf3,0x2f81f7,0xe6edf3,0x0d1117}},
    {@"VS Light", YES, {
        0x000000,0xcd3131,0x107c10,0x949800,0x0451a5,0xbc05bc,0x0598bc,0x555555,
        0x666666,0xf14c4c,0x14ce14,0xb5ba00,0x3b8eea,0xd670d6,0x29b8db,0xa5a5a5,
        0xffffff,0x333333,0x333333,0xadd6ff,inheritedText}},
    {@"VS Dark", NO, {
        0x000000,0xcd3131,0x0dbc79,0xe5e510,0x2472c8,0xbc3fbc,0x11a8cd,0xe5e5e5,
        0x666666,0xf14c4c,0x23d18b,0xf5f543,0x3b8eea,0xd670d6,0x29b8db,0xe5e5e5,
        0x1e1e1e,0xcccccc,0xcccccc,0x264f78,inheritedText}},
    {@"Tomorrow", YES, {
        0x000000,0xc82829,0x718c00,0xeab700,0x4271ae,0x8959a8,0x3e999f,0xbfbfbf,
        0x000000,0xc82829,0x718c00,0xeab700,0x4271ae,0x8959a8,0x3e999f,0xffffff,
        0xffffff,0x4d4d4c,0x4d4d4c,0xd6d6d6,0x4d4d4c}},
    {@"Tomorrow Night", NO, {
        0x000000,0xcc6666,0xb5bd68,0xf0c674,0x81a2be,0xb294bb,0x8abeb7,0xffffff,
        0x4c4c4c,0xcc6666,0xb5bd68,0xf0c674,0x81a2be,0xb294bb,0x8abeb7,0xffffff,
        0x1d1f21,0xc5c8c6,0xc5c8c6,0x373b41,0xc5c8c6}},
};
static NSColor *srgb(unsigned value) {
    return [NSColor colorWithSRGBRed:(value>>16)/255. green:((value>>8)&255)/255. blue:(value&255)/255. alpha:1];
}
NSString *SchemeName(NSInteger scheme) { return palettes[scheme].name; }
BOOL SchemeIsLight(NSInteger scheme) { return palettes[scheme].light; }
NSColor *SchemeInk(NSInteger scheme, NSInteger color) {
    static NSColor *cache[SchemeCount][SchemeColorCount];
    if (!cache[scheme][color]) {
        unsigned rgb = palettes[scheme].colors[color];
        if (rgb == inheritedText) return nil;
        cache[scheme][color] = srgb(rgb);
    }
    return cache[scheme][color];
}
NSAppearance *SchemeAppearance(NSInteger scheme) {
    return [NSAppearance appearanceNamed:SchemeIsLight(scheme) ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
}
NSColor *TerminalIndexedColor(NSInteger scheme, int index) {
    if (index<16) return SchemeInk(scheme,index);
    static NSColor *extended[240];
    NSColor *__strong &entry = extended[index-16];
    if (!entry) {
        int k=index-16, levels[]={0,95,135,175,215,255};
        int value = index>=232 ? (8+10*(index-232))*0x010101 :
            levels[k/36]*65536+levels[(k/6)%6]*256+levels[k%6];
        entry = srgb(value);
    }
    return entry;
}

const InterfacePalette &CurrentInterfacePalette(void) {
    static InterfacePalette cache[SchemeCount];
    NSInteger scheme = PreferredColorScheme();
    InterfacePalette &colors = cache[scheme];
    if (!colors.background) {
        NSColor *bg = SchemeInk(scheme,SchemeBackground), *text = SchemeInk(scheme,SchemeText);
        colors.background = bg;
        colors.chrome = [bg blendedColorWithFraction:.04 ofColor:text];
        colors.text = text;
        // Mix in sRGB so secondary labels also have a visible hierarchy on dark backgrounds.
        // Solarized's base text is already muted and needs its original contrast.
        CGFloat fade = scheme == SolarizedLight || scheme == SolarizedDark ? .02 : (SchemeIsLight(scheme) ? .17 : .28);
        colors.secondaryText = [NSColor colorWithSRGBRed:text.redComponent+(bg.redComponent-text.redComponent)*fade
            green:text.greenComponent+(bg.greenComponent-text.greenComponent)*fade
            blue:text.blueComponent+(bg.blueComponent-text.blueComponent)*fade alpha:1];
        colors.separator = [bg blendedColorWithFraction:.24 ofColor:text];
        colors.accent = SchemeInk(scheme,4);
        colors.selectionFill = [colors.accent colorWithAlphaComponent:.15];
        // A neutral hairline also blends with translucent windows and wallpaper.
        colors.splitRule = [text colorWithAlphaComponent:SchemeIsLight(scheme) ? .15 : .20];
        NSColor *warm = SchemeInk(scheme,3);
        colors.findFill = [warm blendedColorWithFraction:.38 ofColor:NSColor.whiteColor];
        colors.findText = [NSColor colorWithSRGBRed:.10 green:.09 blue:.07 alpha:1];
    }
    return colors;
}
