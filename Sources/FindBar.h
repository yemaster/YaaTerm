#import <AppKit/AppKit.h>

@interface FindBar : NSView
@property (readonly) NSTextField *field;
- (instancetype)initWithTarget:(id)target;
- (void)queryDidChange;
- (void)showStatus:(NSString *)text hasMatch:(BOOL)hasMatch;
- (void)applyPalette;
- (void)refreshShortcuts;
- (CGFloat)heightForWidth:(CGFloat)width;
@end
