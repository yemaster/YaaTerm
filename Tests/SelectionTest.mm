#import "TerminalView.h"
#import "Preferences.h"
#import "Palette.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <array>
#include <cassert>
#include <cmath>
#include <clocale>
#include <string_view>
#include <vector>

@interface TerminalView (RenderTest)
- (void)consume:(std::string_view)bytes;
- (NSRange)selectedColumnsInRow:(int)y;
@end

@interface ScaledTestView : TerminalView
@property CGFloat testScale;
@end
@implementation ScaledTestView
- (CGFloat)gridScale { return self.testScale ?: 1; }
@end

static void renderTest(int scale) {
    NSRect frame = NSMakeRect(0,0,320,110);
    ScaledTestView *view = [[ScaledTestView alloc] initWithFrame:frame];
    view.testScale = scale;
    [view adjustFont:0];
    [view consume:"a\033[48;5;4m中\033[0mB\033[1mC\033[0m文xyz\r\n\033[44m             \033[0m"];
    double cw = [[view valueForKey:@"cw"] doubleValue];
    double lh = [[view valueForKey:@"lh"] doubleValue];
    NSFont *font = [view valueForKey:@"regular"];
    NSDictionary *variation = CFBridgingRelease(CTFontCopyVariation((__bridge CTFontRef)font));
    assert([font.familyName isEqualToString:@"JetBrains Mono"] && font.pointSize == 14);
    assert([variation[@(0x77676874)] intValue] == 300); // OpenType wght axis
    assert(lh == std::round((font.ascender-font.descender+font.leading)*scale)/scale);
    int cols = (int)((320-32)/cw);
    // Backwards selection starting inside a wide glyph and ending inside an ANSI background run.
    [view setValue:@(cols+8) forKey:@"anchor"]; [view setValue:@2 forKey:@"extent"];
    assert(NSEqualRanges([view selectedColumnsInRow:0],NSMakeRange(1,cols-1)));
    assert(NSEqualRanges([view selectedColumnsInRow:1],NSMakeRange(0,9)));
    const int width = 320*scale, height=110*scale;
    std::vector<unsigned char> data(width*height*4);
    auto space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto ctx = CGBitmapContextCreate(data.data(),width,height,8,width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextTranslateCTM(ctx,0,height); CGContextScaleCTM(ctx,scale,-scale);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [view drawRect:frame];
    [NSGraphicsContext restoreGraphicsState];
    CGContextFlush(ctx);
    auto pixel = [&](int x,int y) {
        auto p = data.data()+4*(y*width+x);
        return std::array<int,3>{p[0],p[1],p[2]};
    };
    const std::array<int,3> selected{245,224,220};
    auto sample = [&](double x,double y) {return pixel((int)(x*scale),(int)(y*scale));};
    assert(sample(18,12)!=selected);
    for (int x=(int)ceil((16+cw)*scale); x<(int)floor((16+cols*cw)*scale); ++x)
        assert(pixel(x,12*scale)==selected);
    for (int y=(int)((12+lh)*scale)-1;y<=(int)((12+lh)*scale);++y)
        for (int x=(int)ceil((16+cw)*scale);x<(int)floor((16+9*cw)*scale);++x)
            assert(pixel(x,y)==selected);
    assert(sample(16+10*cw,12+lh)!=selected);
    // Asymmetric pane placement can leave the drawing origin between device pixels.
    // Check every raster row across three lines, with and without a selection.
    [view consume:"\033[2J\033[H█│\033[44m \033[0m\r\n█│\033[44m \033[0m\r\n█│\033[44m \033[0m"];
    CGContextConcatCTM(ctx,CGAffineTransformMakeTranslation(.25,.25));
    for (int anchor : {-1,0}) {
        [view setValue:@(anchor) forKey:@"anchor"];
        [view setValue:@(anchor < 0 ? -1 : 2*cols+2) forKey:@"extent"];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
        [view drawRect:frame];
        [NSGraphicsContext restoreGraphicsState];
        CGContextFlush(ctx);
        auto blockColor = sample(16+.5*cw,15);
        auto bgColor = sample(16+2.5*cw,15);
        assert((blockColor == (anchor < 0 ? std::array<int,3>{205,214,244} : std::array<int,3>{30,30,46})));
        assert((bgColor == (anchor < 0 ? std::array<int,3>{137,180,250} : selected)));
        int barX = (int)std::round((16+.25+1.5*cw-.5)*scale);
        for (int y = 13*scale; y < (12+3*lh-1)*scale; ++y) {
            assert(pixel((int)((16+.5*cw)*scale),y)==blockColor);
            assert(pixel(barX,y)==blockColor);
            assert(pixel((int)((16+2.5*cw)*scale),y)==bgColor);
        }
    }
    // Desktop and wallpaper show through empty cells. Explicit ANSI backgrounds and selected glyphs stay opaque.
    SetTerminalPreference(BackgroundOpacity,60); assert(!view.isOpaque);
    CGContextClearRect(ctx,frame);
    [view consume:"\033[2J\033[H\033[44m \033[0m █ "];
    [view setValue:@2 forKey:@"anchor"]; [view setValue:@3 forKey:@"extent"];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [view drawRect:frame]; [NSGraphicsContext restoreGraphicsState]; CGContextFlush(ctx);
    auto alpha = [&](double x) { return data[4*(15*scale*width+(int)(x*scale))+3]; };
    assert(alpha(5)==0 && alpha(16+.5*cw)==255 && alpha(16+1.5*cw)==0);
    assert(alpha(16+2.5*cw)==255 && alpha(16+3.5*cw)==255);
    SetTerminalPreference(BackgroundOpacity,100); assert(view.isOpaque);
    // The Visual Studio palettes keep the original ANSI foreground inside a selection.
    SetTerminalPreference(DarkSchemeKey,VSDark);
    [view consume:"\033[2J\033[H\033[31m█ \033[0m"];
    [view setValue:@0 forKey:@"anchor"]; [view setValue:@1 forKey:@"extent"];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [view drawRect:frame];
    [NSGraphicsContext restoreGraphicsState];
    CGContextFlush(ctx);
    assert((sample(16+.5*cw,15) == std::array<int,3>{205,49,49}));
    assert((sample(16+1.5*cw,15) == std::array<int,3>{38,79,120}));
    SetTerminalPreference(DarkSchemeKey,CatppuccinMocha);
    [view setValue:@(-1) forKey:@"anchor"]; [view setValue:@(-1) forKey:@"extent"];
    // A multiline shell prompt puts a font-sized rounded corner next to a grid rule.
    // Both sides of each joint must have the same center and stroke thickness.
    for (int size : {14,9,21}) {
        [view adjustFont:0]; [view adjustFont:size-14];
        [view consume:"\033[2J\033[H\033[90m╭─ ~ ─╮\r\n╰─❯  ─╯\033[0m"];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
        [view drawRect:frame];
        [NSGraphicsContext restoreGraphicsState];
        CGContextFlush(ctx);
        double w = [[view valueForKey:@"cw"] doubleValue], h = [[view valueForKey:@"lh"] doubleValue];
        // Quartz snaps in device space before the view's vertical flip.
        auto px = [&](double x) { return (int)std::round((16.25+x*w)*scale); };
        auto py = [&](double y) { return height-(int)std::round(height-(12.25+y*h)*scale); };
        for (int row = 0; row < 2; ++row) {
            for (int y = py(row); y < py(row+1); ++y) {
                for (int joint : {1,6}) {
                    auto reference = pixel(px(joint == 1 ? 1.5 : 5.5),y);
                    assert(pixel(px(joint)-1,y) == reference);
                    assert(pixel(px(joint),y) == reference);
                }
            }
        }
        for (int col : {0,6}) {
            bool hasStroke = false;
            for (int x = px(col); x < px(col+1); ++x) {
                auto reference = pixel(x,py(1)-2);
                assert(pixel(x,py(1)-1) == reference && pixel(x,py(1)) == reference);
                hasStroke |= reference == std::array<int,3>{88,91,112};
            }
            assert(hasStroke);
        }
    }
    CGColorSpaceRelease(space); CGContextRelease(ctx);
    printf("%dx: JetBrains Mono 14 pt, %.1f pt rows; selection, ANSI background and prompt corner joins OK\n",scale,lh);
}
int main() {
    @autoreleasepool {
        setlocale(LC_CTYPE,"en_US.UTF-8");
        // CLI tests have no app bundle; AppKit loads the same font via ATSApplicationFontsPath in YaaTerm.
        NSURL *url = [NSURL fileURLWithPath:@"Resources/Fonts/JetBrainsMono-Regular.ttf"];
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,kCTFontManagerScopeProcess,nullptr);
        SetTerminalPreference(AppearanceModeKey,AlwaysDark);
        SetTerminalPreference(DarkSchemeKey,CatppuccinMocha);
        renderTest(1); renderTest(2);
        TerminalView *v = [[TerminalView alloc] initWithFrame:NSMakeRect(0,0,300,120)];
        [v adjustFont:0];
        [v consume:"\033[999;1Hshell\033[?1049h\033[H\033[2Jeditor"];
        // Zsh can print its multiline prompt in the same PTY read as rmcup.
        [v consume:"\033[?1049l\r\nfirst\r\n> "];
        assert([[v valueForKey:@"offset"] intValue] == 0);
    }
}
