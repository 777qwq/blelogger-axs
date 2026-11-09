#pragma once
#include <Foundation/Foundation.h>

typedef struct CGPoint { CGFloat x; CGFloat y; } CGPoint;
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;

static inline CGPoint CGPointMake(CGFloat x, CGFloat y) { CGPoint p; p.x = x; p.y = y; return p; }
static inline CGSize  CGSizeMake(CGFloat w, CGFloat h)  { CGSize s; s.width = w; s.height = h; return s; }
static inline CGRect  CGRectMake(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r; r.origin.x = x; r.origin.y = y; r.size.width = w; r.size.height = h; return r;
}
static inline CGRect  CGRectInset(CGRect r, CGFloat dx, CGFloat dy) {
    return CGRectMake(r.origin.x + dx, r.origin.y + dy, r.size.width - dx * 2, r.size.height - dy * 2);
}
#define CGRectZero CGRectMake(0, 0, 0, 0)

typedef NSUInteger UIControlState;
enum { UIControlStateNormal = 0, UIControlStateHighlighted = 1 };
typedef NSUInteger UIControlEvents;
enum {
    UIControlEventTouchDown       = 1 << 0,
    UIControlEventTouchUpInside   = 1 << 6,
};
typedef NSUInteger UIButtonType;
enum { UIButtonTypeCustom = 0, UIButtonTypeSystem = 1 };
typedef NSInteger NSTextAlignment;
enum { NSTextAlignmentLeft = 0, NSTextAlignmentCenter = 1, NSTextAlignmentRight = 2 };
typedef NSInteger NSLineBreakMode;
enum { NSLineBreakByWordWrapping = 0, NSLineBreakByTruncatingTail = 4 };

@class CALayer, UIColor, UIFont, UIImage, UIViewController;

@interface CALayer : NSObject
@property CGFloat cornerRadius;
@property CGFloat borderWidth;
@property BOOL masksToBounds;
@end

@interface UIColor : NSObject
+ (UIColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a;
+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (UIColor *)clearColor;
+ (UIColor *)blackColor;
+ (UIColor *)whiteColor;
+ (UIColor *)systemBlueColor;
+ (UIColor *)systemRedColor;
+ (UIColor *)systemGreenColor;
+ (UIColor *)labelColor;
+ (UIColor *)secondaryLabelColor;
+ (UIColor *)systemBackgroundColor;
@end

@interface UIFont : NSObject
+ (UIFont *)systemFontOfSize:(CGFloat)s;
+ (UIFont *)boldSystemFontOfSize:(CGFloat)s;
+ (UIFont *)monospacedSystemFontOfSize:(CGFloat)s weight:(CGFloat)w;
@end

@interface UIResponder : NSObject
@end

@interface UIView : UIResponder
- (instancetype)initWithFrame:(CGRect)f;
@property CGRect frame;
@property (strong) UIColor *backgroundColor;
@property BOOL hidden;
@property CGFloat alpha;
@property NSInteger tag;
@property BOOL userInteractionEnabled;
@property BOOL clipsToBounds;
@property (readonly) CALayer *layer;
- (void)addSubview:(UIView *)v;
- (void)removeFromSuperview;
- (void)bringSubviewToFront:(UIView *)v;
- (UIView *)viewWithTag:(NSInteger)t;
- (UIView *)superview;
- (UIView *)hitTest:(CGPoint)p withEvent:(id)e;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
@end

@interface UIWindow : UIView
@property CGFloat windowLevel;
@property (strong) UIViewController *rootViewController;
- (void)makeKeyAndVisible;
@end

@interface UIScreen : NSObject
+ (UIScreen *)mainScreen;
@property (readonly) CGRect bounds;
@property (readonly) CGFloat scale;
@end

@interface UIViewController : UIResponder
@property (strong) UIView *view;
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion;
@end

typedef NSInteger UIAlertControllerStyle;
enum { UIAlertControllerStyleActionSheet = 0, UIAlertControllerStyleAlert = 1 };
typedef NSInteger UIAlertActionStyle;
enum { UIAlertActionStyleDefault = 0, UIAlertActionStyleCancel = 1, UIAlertActionStyleDestructive = 2 };

@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title
                          style:(UIAlertActionStyle)style
                        handler:(void (^)(UIAlertAction *action))handler;
@end

@interface UIAlertController : UIViewController
+ (instancetype)alertControllerWithTitle:(NSString *)title
                                 message:(NSString *)message
                          preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end

@interface UILabel : UIView
@property (copy) NSString *text;
@property (strong) UIFont *font;
@property (strong) UIColor *textColor;
@property NSInteger numberOfLines;
@property NSTextAlignment textAlignment;
@end

@interface UIButton : UIView
+ (instancetype)buttonWithType:(UIButtonType)t;
- (void)addTarget:(id)t action:(SEL)a forControlEvents:(UIControlEvents)e;
- (void)setTitle:(NSString *)t forState:(UIControlState)s;
- (void)setTitleColor:(UIColor *)c forState:(UIControlState)s;
- (NSString *)titleForState:(UIControlState)s;
@property (readonly) UILabel *titleLabel;
@end

@interface UIScrollView : UIView
@property CGSize contentSize;
@property BOOL showsVerticalScrollIndicator;
@property BOOL alwaysBounceVertical;
@end

@interface UIPasteboard : NSObject
+ (UIPasteboard *)generalPasteboard;
- (void)setString:(NSString *)s;
- (NSString *)string;
@end

typedef NSInteger UIGestureRecognizerState;
enum {
    UIGestureRecognizerStatePossible = 0,
    UIGestureRecognizerStateBegan    = 1,
    UIGestureRecognizerStateChanged  = 2,
    UIGestureRecognizerStateEnded    = 3,
    UIGestureRecognizerStateCancelled = 4,
};

@interface UIGestureRecognizer : NSObject
- (instancetype)initWithTarget:(id)t action:(SEL)a;
@property (readonly) UIGestureRecognizerState state;
@property BOOL enabled;
@end

@interface UIPanGestureRecognizer : UIGestureRecognizer
- (CGPoint)translationInView:(UIView *)v;
- (void)setTranslation:(CGPoint)t inView:(UIView *)v;
- (CGPoint)locationInView:(UIView *)v;
@end

@interface UITapGestureRecognizer : UIGestureRecognizer
@end

@interface UIView (Gesture)
- (void)addGestureRecognizer:(UIGestureRecognizer *)g;
@end

@interface UIApplication : NSObject
+ (UIApplication *)sharedApplication;
@end

@class UIWindowScene;

@interface UIWindow (BLEScene)
@property (readonly) UIWindowScene *windowScene;
- (instancetype)initWithWindowScene:(UIWindowScene *)scene;
@end

@interface UIApplication (BLEScene)
@property (readonly) UIWindow *keyWindow;
@end
