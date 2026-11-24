#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <cmath>

namespace yaa {
// Both sides of a shared edge resolve to the same device pixel, including in split views.
inline CGRect alignedGridRect(CGContextRef ctx, CGRect rect) {
    CGRect p = CGContextConvertRectToDeviceSpace(ctx, rect);
    CGFloat left = std::round(CGRectGetMinX(p)), bottom = std::round(CGRectGetMinY(p));
    p = CGRectMake(left, bottom, std::round(CGRectGetMaxX(p))-left, std::round(CGRectGetMaxY(p))-bottom);
    return CGContextConvertRectToUserSpace(ctx, p);
}

inline void fillGridRect(CGContextRef ctx, CGRect rect) {
    CGContextFillRect(ctx, alignedGridRect(ctx, rect));
}

inline void drawRoundedCorner(CGContextRef ctx, CGRect cell, CGFloat stroke, bool right, bool down) {
    const CGRect ink = alignedGridRect(ctx, CGRectMake(CGRectGetMidX(cell)-stroke/2,
                                                       CGRectGetMidY(cell)-stroke/2,stroke,stroke));
    if (CGRectIsEmpty(ink)) return;
    const CGRect bounds = alignedGridRect(ctx,cell);
    CGFloat cx = CGRectGetMidX(ink), cy = CGRectGetMidY(ink);
    CGFloat dx = (right ? 1 : -1)*ink.size.width, dy = (down ? 1 : -1)*ink.size.height;
    CGFloat endX = ((right ? CGRectGetMaxX(bounds) : CGRectGetMinX(bounds))-cx)/dx;
    CGFloat endY = ((down ? CGRectGetMaxY(bounds) : CGRectGetMinY(bounds))-cy)/dy;

    // Work in stroke widths. Mirror one quarter turn for all four corners.
    // Straight tails meet the exact snapped edges used by the adjoining rules.
    CGFloat radius = std::max(.5, std::min(endX,endY)-1);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx,cx,cy);
    CGContextScaleCTM(ctx,dx,dy);
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx,-.5,endY);
    CGContextAddArcToPoint(ctx,-.5,-.5,endX,-.5,radius+.5);
    CGContextAddLineToPoint(ctx,endX,-.5);
    CGContextAddLineToPoint(ctx,endX,.5);
    CGContextAddArcToPoint(ctx,.5,.5,.5,endY,radius-.5);
    CGContextAddLineToPoint(ctx,.5,endY);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

// The terminal view is flipped. Block fractions and box segments refer to the full cell.
inline bool drawCellGraphic(CGContextRef ctx, char32_t ch, CGRect r, CGFloat stroke) {
    auto fill = [&](CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
        fillGridRect(ctx, CGRectMake(r.origin.x+x*r.size.width, r.origin.y+y*r.size.height,
                                     w*r.size.width, h*r.size.height));
    };
    if (ch >= U'▁' && ch <= U'█') {
        CGFloat height = (ch-U'▁'+1)/8.0;
        fill(0,1-height,1,height); return true;
    }
    if (ch >= U'▉' && ch <= U'▏') { fill(0,0,(U'▏'-ch+1)/8.0,1); return true; }
    switch (ch) {
        case U'╭': case U'╮': case U'╰': case U'╯':
            drawRoundedCorner(ctx,r,stroke,ch == U'╭' || ch == U'╰',ch == U'╭' || ch == U'╮');
            return true;
        case U'▀': fill(0,0,1,.5); return true;
        case U'▔': fill(0,0,1,.125); return true;
        case U'▐': fill(.5,0,.5,1); return true;
        case U'▕': fill(.875,0,.125,1); return true;
    }
    if (ch >= U'▖' && ch <= U'▟') {
        // Bits in reading order: upper left/right, then lower left/right.
        constexpr unsigned quadrants[] = {4,8,1,13,9,7,11,2,6,14};
        for (unsigned q = 0; q < 4; ++q)
            if (quadrants[ch-U'▖'] & (1u<<q)) fill((q%2)*.5,(q/2)*.5,.5,.5);
        return true;
    }

    enum { left = 1, right = 2, up = 4, down = 8 };
    int segments;
    switch (ch) {
        case U'─': segments = left|right; break;
        case U'│': segments = up|down; break;
        case U'┃': segments = up|down; stroke *= 2; break;
        case U'━': segments = left|right; stroke *= 2; break;
        case U'┌': segments = right|down; break;
        case U'┐': segments = left|down; break;
        case U'└': segments = right|up; break;
        case U'┘': segments = left|up; break;
        case U'├': segments = right|up|down; break;
        case U'┤': segments = left|up|down; break;
        case U'┬': segments = left|right|down; break;
        case U'┴': segments = left|right|up; break;
        case U'┼': segments = left|right|up|down; break;
        default: return false;
    }
    CGFloat x = CGRectGetMidX(r)-stroke/2, y = CGRectGetMidY(r)-stroke/2;
    if (segments & (left|right)) {
        CGFloat start = segments & left ? CGRectGetMinX(r) : x;
        CGFloat end = segments & right ? CGRectGetMaxX(r) : x+stroke;
        fillGridRect(ctx, CGRectMake(start,y,end-start,stroke));
    }
    if (segments & (up|down)) {
        CGFloat start = segments & up ? CGRectGetMinY(r) : y;
        CGFloat end = segments & down ? CGRectGetMaxY(r) : y+stroke;
        fillGridRect(ctx, CGRectMake(x,start,stroke,end-start));
    }
    return true;
}
}
