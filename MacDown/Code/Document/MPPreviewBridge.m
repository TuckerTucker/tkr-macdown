//
//  MPPreviewBridge.m
//  MacDown
//

#import "MPPreviewBridge.h"

static NSString * const kMPPreviewBridgeHandlerName = @"macdown";

// Runs at document start in the isolated world. DOM events cross worlds, so
// the page's MathJax configuration announces completion with a DOM event and
// never touches a native handler itself. The zero-specificity root font size
// keeps the 12px default the legacy preview had, for styles that set none.
// Scroll events are already coalesced to one per frame, and an extra
// requestAnimationFrame throttle would stall in windows that are not visible.
//
// Native code scrolls the page only through macdownScrollTo, which remembers
// where it left the page. The scroll event that lands there is reported as
// 'scroll'; any other is the reader's and is reported as 'user-scroll', so
// syncing the editor to the preview never echoes a sync the other way.
static NSString * const kMPPreviewBridgeScript =
    @"(function () {\n"
    @"  var style = document.createElement('style');\n"
    @"  style.textContent = ':where(:root) { font-size: 12px; }';\n"
    @"  document.documentElement.appendChild(style);\n"
    @"  var post = function (event, value) {\n"
    @"    window.webkit.messageHandlers.macdown.postMessage(\n"
    @"        {event: event, value: value || 0});\n"
    @"  };\n"
    @"  var nativeTop = null;\n"
    @"  window.macdownScrollTo = function (top) {\n"
    @"    var before = window.scrollY;\n"
    @"    window.scrollTo(0, top);\n"
    @"    if (window.scrollY !== before)\n"
    @"      nativeTop = window.scrollY;\n"
    @"  };\n"
    @"  document.addEventListener('macdown:mathjax-end', function () {\n"
    @"    post('mathjax-end');\n"
    @"  });\n"
    @"  window.addEventListener('scroll', function () {\n"
    @"    var top = window.scrollY;\n"
    @"    var fromNative = nativeTop !== null && Math.abs(top - nativeTop) < 1;\n"
    @"    nativeTop = null;\n"
    @"    post(fromNative ? 'scroll' : 'user-scroll', top);\n"
    @"  }, {passive: true});\n"
    @"})();\n";


@interface MPPreviewBridge () <WKScriptMessageHandler>
@property (weak) WKUserContentController *userContentController;
@end


@implementation MPPreviewBridge

+ (WKContentWorld *)contentWorld
{
    static WKContentWorld *world = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        world = [WKContentWorld worldWithName:@"MacDown"];
    });
    return world;
}

- (instancetype)initWithUserContentController:(WKUserContentController *)c
{
    self = [super init];
    if (!self)
        return nil;
    self.userContentController = c;
    [c addScriptMessageHandler:self contentWorld:[self.class contentWorld]
                          name:kMPPreviewBridgeHandlerName];
    [self prepareForLoadRestoringScrollTop:0.0];
    return self;
}

- (void)prepareForLoadRestoringScrollTop:(CGFloat)scrollTop
{
    WKUserContentController *controller = self.userContentController;
    WKContentWorld *world = [self.class contentWorld];
    [controller removeAllUserScripts];

    WKUserScript *bridge = [[WKUserScript alloc]
        initWithSource:kMPPreviewBridgeScript
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES inContentWorld:world];
    [controller addUserScript:bridge];

    if (scrollTop > 0.0)
    {
        WKUserScript *restore = [[WKUserScript alloc]
            initWithSource:[self.class scriptScrollingToTop:scrollTop]
             injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
          forMainFrameOnly:YES inContentWorld:world];
        [controller addUserScript:restore];
    }
}

+ (NSString *)scriptScrollingToTop:(CGFloat)top
{
    return [NSString stringWithFormat:@"macdownScrollTo(%f);", (double)top];
}

- (void)invalidate
{
    WKUserContentController *controller = self.userContentController;
    [controller removeAllUserScripts];
    [controller removeScriptMessageHandlerForName:kMPPreviewBridgeHandlerName
                                     contentWorld:[self.class contentWorld]];
    self.userContentController = nil;
}

+ (BOOL)parseMessageBody:(id)body event:(MPPreviewBridgeEvent *)event
                   value:(CGFloat *)value
{
    if (![body isKindOfClass:[NSDictionary class]])
        return NO;
    id name = body[@"event"];
    id number = body[@"value"];
    if (![name isKindOfClass:[NSString class]]
            || ![number isKindOfClass:[NSNumber class]])
        return NO;

    if ([name isEqualToString:@"mathjax-end"])
        *event = MPPreviewBridgeEventMathJaxEnd;
    else if ([name isEqualToString:@"scroll"])
        *event = MPPreviewBridgeEventScroll;
    else if ([name isEqualToString:@"user-scroll"])
        *event = MPPreviewBridgeEventUserScroll;
    else
        return NO;
    *value = [number doubleValue];
    return YES;
}


#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    // Only the main frame's isolated world can reach this handler, but check
    // anyway so a future configuration change cannot widen it silently.
    if (!message.frameInfo.isMainFrame
            || message.world != [self.class contentWorld])
        return;

    MPPreviewBridgeEvent event;
    CGFloat value = 0.0;
    if (![self.class parseMessageBody:message.body event:&event value:&value])
        return;
    [self.delegate previewBridgeDidReceiveEvent:event value:value];
}

@end
