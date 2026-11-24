#import "Wallpaper.h"
#import "Preferences.h"
#import <ImageIO/ImageIO.h>
#include <atomic>

static CGImageRef createThumbnail(NSURL *url) {
    NSDictionary *sourceOptions = @{(__bridge NSString *)kCGImageSourceShouldCache:@NO};
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,(__bridge CFDictionaryRef)sourceOptions);
    if (!source) return nullptr;
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                              (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                              (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@2048,
                              (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES,
                              (__bridge NSString *)kCGImageSourceShouldAllowFloat:@NO};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

@implementation Wallpaper {
    id _bitmap;
    std::atomic_uint64_t _generation;
    dispatch_queue_t _queue;
}
+ (instancetype)shared {
    static Wallpaper *store = [Wallpaper new];
    return store;
}
- (instancetype)init {
    if ((self = [super init])) {
        _generation.store(0);
        NSString *path = PreferredBackgroundImagePath();
        if (path.length) [self loadURL:[NSURL fileURLWithPath:path] restoring:YES completion:nil];
    }
    return self;
}
- (CGImageRef)image { return (__bridge CGImageRef)_bitmap; }
- (void)chooseURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    [self loadURL:url restoring:NO completion:completion];
}
- (void)loadURL:(NSURL *)url restoring:(BOOL)restoring completion:(void (^)(BOOL))completion {
    uint64_t request = ++_generation;
    if (!_queue) _queue = dispatch_queue_create("dev.yaaterm.wallpaper",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    dispatch_async(_queue,^{
        @autoreleasepool {
            if (request != self->_generation.load()) return;
            id bitmap = CFBridgingRelease(createThumbnail(url));
            if (request != self->_generation.load()) return;
            dispatch_async(dispatch_get_main_queue(),^{
                if (request != self->_generation.load()) return;
                if (bitmap || restoring) {
                    self->_bitmap = bitmap; self->_missingFile = !bitmap;
                    if (bitmap && !restoring) [TerminalPreferences() setObject:url.path forKey:BackgroundImagePath];
                    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:BackgroundImagePath];
                } else if (!self->_bitmap && PreferredBackgroundImagePath().length && !self->_missingFile) {
                    // A failed pick can supersede the still-pending startup read.
                    [self loadURL:[NSURL fileURLWithPath:PreferredBackgroundImagePath()] restoring:YES completion:nil];
                }
                if (completion) completion(bitmap != nil);
            });
        }
    });
}
- (void)removeImage {
    ++_generation; _bitmap = nil; _missingFile = NO;
    [TerminalPreferences() removeObjectForKey:BackgroundImagePath];
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalPreferenceChanged object:BackgroundImagePath];
}
@end

CGImageRef VisibleWallpaperImage(void) {
    if (!PreferredBackgroundImagePath().length || PreferredOpacity(BackgroundImageOpacity)==0) return nullptr;
    return Wallpaper.shared.image;
}
BOOL UsesTerminalBackdrop(void) {
    return EffectiveBackgroundOpacity()<100 || VisibleWallpaperImage()!=nullptr;
}
