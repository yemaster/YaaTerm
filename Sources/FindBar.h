#import <AppKit/AppKit.h>

@interface FindBar : NSView
@property (readonly) NSTextField *field;
- (instancetype)initWithTarget:(id)target;
- (void)queryDidChange;
- (void)showStatus:(NSString *)text hasMatch:(BOOL)hasMatch;
- (void)applyPalette;
- (CGFloat)heightForWidth:(CGFloat)width;
@end
