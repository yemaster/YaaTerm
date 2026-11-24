#import <AppKit/AppKit.h>

// Main-thread model. Every window references the same decoded first frame.
@interface Wallpaper : NSObject
+ (instancetype)shared;
@property (readonly) CGImageRef image;
@property (readonly) BOOL missingFile;
- (void)chooseURL:(NSURL *)url completion:(void (^)(BOOL loaded))completion;
- (void)removeImage;
@end

CGImageRef VisibleWallpaperImage(void);
BOOL UsesTerminalBackdrop(void);
