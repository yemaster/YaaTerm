#import <AppKit/AppKit.h>

// The fields use the same row layout as Appearance and General. This view is their action row.
@interface LLMSettingsForm : NSView
@property (readonly) NSTextField *endpoint, *model;
@property (readonly) NSSecureTextField *apiKey;
@property (readonly) NSPopUpButton *format;
@property (copy) void (^onHeightChange)(void);
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)cancelTest;
- (void)applyPalette;
@end
