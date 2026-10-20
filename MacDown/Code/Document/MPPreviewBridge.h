//
//  MPPreviewBridge.h
//  MacDown
//
//  The only channel between the preview page and native code. It lives in an
//  isolated content world, so scripts running in the page itself cannot see
//  or call it (TB-5).
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MPPreviewBridgeEvent)
{
    MPPreviewBridgeEventMathJaxEnd,     // MathJax finished (or gave up).
    MPPreviewBridgeEventScroll,         // The page scrolled; value is scrollY.
};

@protocol MPPreviewBridgeDelegate <NSObject>
- (void)previewBridgeDidReceiveEvent:(MPPreviewBridgeEvent)event
                               value:(CGFloat)value;
@end


@interface MPPreviewBridge : NSObject

// The world every native-issued script runs in.
@property (class, readonly) WKContentWorld *contentWorld;

// Held weakly; the user content controller only retains the bridge.
@property (weak) id<MPPreviewBridgeDelegate> delegate;

- (instancetype)initWithUserContentController:(WKUserContentController *)c
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Re-installs the bridge scripts; the next page load scrolls to `scrollTop`
// as soon as its content is parsed, so a re-render does not jump to the top.
- (void)prepareForLoadRestoringScrollTop:(CGFloat)scrollTop;

// Detaches from the user content controller. Call before the web view goes.
- (void)invalidate;

// Parses a message body posted by the bridge script. Returns NO for anything
// the bridge did not send. Exposed for testing.
+ (BOOL)parseMessageBody:(id)body event:(MPPreviewBridgeEvent *)event
                   value:(CGFloat *)value;

@end

NS_ASSUME_NONNULL_END
