//
//  MPMathJaxOfflineTests.m
//  MacDownTests
//
//  End-to-end proof that the preview HTML MPRenderer produces typesets math
//  with the vendored MathJax 3, fully offline, under the preview's
//  Content-Security-Policy (findings TB-7, TM-7; Wave 3c "MathJax resources
//  local").
//
//  A real WKWebView (non-persistent data store) loads the renderer's own
//  -render output. The preview's production WKURLSchemeHandler is written
//  elsewhere, so this file carries a minimal test-only handler with the same
//  contract: the page is served at x-macdown-file:///<path> with the CSP as an
//  HTTP header, and x-macdown-asset:///<absolute path> serves files from the
//  host app bundle's Resources only. Nothing is mocked: the renderer, the
//  vendored MathJax, WebKit and its CSP enforcement are all real.
//
//  Completion is observed the way the app will observe it: init.js dispatches
//  a `macdown:mathjax-end` DOM event, and a user script in a private
//  WKContentWorld forwards it to a script message handler registered in that
//  same world. Page scripts therefore have no handle on native messaging.
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <hoedown/document.h>
#import "MPAsset.h"
#import "MPRenderer.h"
#import "MPPreferences.h"
#import "MPRendererStubs.h"
#import "MPPreviewSchemeHandler.h"


static NSString * const kMPTestWorldName = @"MacDownTest";
static NSString * const kMPTestHandlerName = @"macdown";

static NSTimeInterval const kMPTestTimeout = 30.0;


@interface MPRenderer (OfflineTesting)
- (void)parseMarkdown:(NSString *)markdown;
@end


#pragma mark - Test-only scheme handler

/**
 *  Serves one page at a fixed x-macdown-file: URL, and x-macdown-asset: files
 *  from beneath a single root directory. Every request it sees is recorded.
 */
@interface MPTestPreviewSchemeHandler : NSObject <WKURLSchemeHandler>
- (instancetype)initWithPageURL:(NSURL *)pageURL
                       pageHTML:(NSString *)pageHTML
                 policyForPage:(NSString *)policy
                      assetRoot:(NSString *)assetRoot;
@property (readonly) NSMutableArray<NSURL *> *requestedURLs;
@property (readonly) NSMutableArray<NSURL *> *refusedURLs;
@end

@implementation MPTestPreviewSchemeHandler
{
    NSURL *_pageURL;
    NSData *_pageData;
    NSString *_policy;
    NSString *_assetRoot;
}

- (instancetype)initWithPageURL:(NSURL *)pageURL
                       pageHTML:(NSString *)pageHTML
                 policyForPage:(NSString *)policy
                      assetRoot:(NSString *)assetRoot
{
    self = [super init];
    if (!self)
        return nil;
    _pageURL = [pageURL copy];
    _pageData = [pageHTML dataUsingEncoding:NSUTF8StringEncoding];
    _policy = [policy copy];
    _assetRoot =
        assetRoot.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    _requestedURLs = [NSMutableArray array];
    _refusedURLs = [NSMutableArray array];
    return self;
}

static NSString *MPTestMIMETypeForExtension(NSString *extension)
{
    NSDictionary *types = @{
        @"js": @"text/javascript", @"css": @"text/css",
        @"woff": @"font/woff", @"html": @"text/html",
    };
    NSString *type = types[extension.lowercaseString];
    return type ? type : @"application/octet-stream";
}

- (void)respond:(id<WKURLSchemeTask>)task status:(NSInteger)status
        headers:(NSDictionary *)headers body:(NSData *)body
{
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:task.request.URL
                                    statusCode:status HTTPVersion:@"HTTP/1.1"
                                  headerFields:headers];
    [task didReceiveResponse:response];
    if (body.length)
        [task didReceiveData:body];
    [task didFinish];
}

- (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSURL *url = task.request.URL;
    [self.requestedURLs addObject:url];

    if ([url.scheme isEqualToString:kMPPreviewFileScheme]
        && [url isEqual:_pageURL])
    {
        [self respond:task status:200 headers:@{
            @"Content-Type": @"text/html; charset=utf-8",
            @"Content-Security-Policy": _policy,
        } body:_pageData];
        return;
    }

    if ([url.scheme isEqualToString:kMPPreviewAssetScheme])
    {
        // url.path is percent-decoded. Resolve before the containment check
        // so ../ and symlinks cannot escape the root.
        NSString *path = url.path.stringByStandardizingPath
                                 .stringByResolvingSymlinksInPath;
        NSString *rootPrefix = [_assetRoot stringByAppendingString:@"/"];
        NSData *data = nil;
        if ([path hasPrefix:rootPrefix])
            data = [NSData dataWithContentsOfFile:path];
        if (data)
        {
            NSString *type = MPTestMIMETypeForExtension(path.pathExtension);
            [self respond:task status:200
                  headers:@{@"Content-Type": type} body:data];
            return;
        }
    }

    [self.refusedURLs addObject:url];
    [self respond:task status:404
          headers:@{@"Content-Type": @"text/plain"} body:nil];
}

- (void)webView:(WKWebView *)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
}

@end


#pragma mark - Navigation and message observers

/** Records every navigation; allows only MacDown's own schemes. */
@interface MPTestNavigationRecorder : NSObject <WKNavigationDelegate>
@property (readonly) NSMutableArray<NSURL *> *navigationURLs;
@property (readonly) NSMutableArray<NSURL *> *blockedNavigationURLs;
@property (strong) XCTestExpectation *finished;
@end

@implementation MPTestNavigationRecorder

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;
    _navigationURLs = [NSMutableArray array];
    _blockedNavigationURLs = [NSMutableArray array];
    return self;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))handler
{
    NSURL *url = action.request.URL;
    [self.navigationURLs addObject:url];
    if ([url.scheme isEqualToString:kMPPreviewFileScheme]
        || [url.scheme isEqualToString:kMPPreviewAssetScheme])
    {
        handler(WKNavigationActionPolicyAllow);
        return;
    }
    [self.blockedNavigationURLs addObject:url];
    handler(WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation
{
    [self.finished fulfill];
}

@end


/** Receives messages posted from the private content world. */
@interface MPTestMessageRecorder : NSObject <WKScriptMessageHandler>
@property (readonly) NSMutableArray<NSDictionary *> *messages;
@property (strong) XCTestExpectation *mathjaxEnded;
@end

@implementation MPTestMessageRecorder

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;
    _messages = [NSMutableArray array];
    return self;
}

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    if (![message.body isKindOfClass:[NSDictionary class]])
        return;
    [self.messages addObject:message.body];
    if ([message.body[@"event"] isEqualToString:@"mathjax-end"])
        [self.mathjaxEnded fulfill];
}

- (NSArray<NSDictionary *> *)messagesForEvent:(NSString *)event
{
    NSPredicate *predicate =
        [NSPredicate predicateWithFormat:@"event == %@", event];
    return [self.messages filteredArrayUsingPredicate:predicate];
}

@end


#pragma mark - Tests

@interface MPMathJaxOfflineTests : XCTestCase
@property (strong) WKWebView *webView;
@property (strong) MPTestPreviewSchemeHandler *schemeHandler;
@property (strong) MPTestNavigationRecorder *navigation;
@property (strong) MPTestMessageRecorder *recorder;
@property (strong) WKContentWorld *world;
@end


@implementation MPMathJaxOfflineTests

- (void)tearDown
{
    [self.webView stopLoading];
    [self.webView.configuration.userContentController
        removeAllScriptMessageHandlers];
    self.webView = nil;
    self.schemeHandler = nil;
    self.navigation = nil;
    self.recorder = nil;
    [super tearDown];
}

/// Same defensive template pin MPRendererTests uses; see the rationale there.
- (void)pinDefaultHTMLTemplate
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = @"htmlTemplateName";
    id previous = [defaults objectForKey:key];
    [self addTeardownBlock:^{
        if (previous)
            [defaults setObject:previous forKey:key];
        else
            [defaults removeObjectForKey:key];
    }];
    MPPreferences *preferences = [MPPreferences sharedInstance];
    if ([preferences respondsToSelector:@selector(setHtmlTemplateName:)])
        preferences.htmlTemplateName = @"Default";
    else
        [defaults setObject:@"Default" forKey:key];
}

/// The preview HTML MPRenderer -render produces for @c markdown, with MathJax
/// and hoedown's explicit math extension on (as MPDocument configures them).
- (NSString *)previewHTMLForMarkdown:(NSString *)markdown
{
    [self pinDefaultHTMLTemplate];
    MPRenderer *renderer = [[MPRenderer alloc] init];
    MPTestRendererDataSource *dataSource =
        [[MPTestRendererDataSource alloc] init];
    MPTestRendererDelegate *delegate = [[MPTestRendererDelegate alloc] init];
    renderer.dataSource = dataSource;
    renderer.delegate = delegate;
    renderer.rendererFlags = 0;
    delegate.extensions = HOEDOWN_EXT_MATH | HOEDOWN_EXT_MATH_EXPLICIT;
    delegate.hasMathJax = YES;
    dataSource.markdown = markdown;
    dataSource.htmlTitle = @"Offline MathJax";

    [renderer parseMarkdown:markdown];
    [renderer render];
    return delegate.capturedHTML;
}

/// A user script for the private world: forwards the page's completion
/// event and every CSP violation to the native recorder.
- (NSString *)observerScriptSource
{
    return
        @"(function () {"
        @"  var post = function (m) {"
        @"    window.webkit.messageHandlers.macdown.postMessage(m);"
        @"  };"
        @"  document.addEventListener('macdown:mathjax-end', function () {"
        @"    post({event: 'mathjax-end'});"
        @"  });"
        @"  document.addEventListener('securitypolicyviolation', function (e) {"
        @"    post({event: 'csp-violation',"
        @"          directive: String(e.violatedDirective),"
        @"          blocked: String(e.blockedURI),"
        @"          sample: String(e.sample || '')});"
        @"  });"
        @"})();";
}

/// Loads @c html at an x-macdown-file: URL in a fresh, non-persistent
/// WKWebView under the preview CSP, and waits for mathjax-end.
- (void)loadPreviewHTML:(NSString *)html
{
    NSString *resources = [NSBundle mainBundle].resourcePath;
    XCTAssertNotNil(resources);
    NSURL *pageURL = [NSURL URLWithString:
        @"x-macdown-file:///private/tmp/MacDownTests/offline-math.md"];

    self.schemeHandler =
        [[MPTestPreviewSchemeHandler alloc] initWithPageURL:pageURL
                                                   pageHTML:html
                                             policyForPage:kMPPreviewContentSecurityPolicy
                                                  assetRoot:resources];
    self.navigation = [[MPTestNavigationRecorder alloc] init];
    self.recorder = [[MPTestMessageRecorder alloc] init];
    self.world = [WKContentWorld worldWithName:kMPTestWorldName];

    WKWebViewConfiguration *configuration =
        [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [configuration setURLSchemeHandler:self.schemeHandler
                          forURLScheme:kMPPreviewFileScheme];
    [configuration setURLSchemeHandler:self.schemeHandler
                          forURLScheme:kMPPreviewAssetScheme];

    WKUserContentController *content = configuration.userContentController;
    [content addScriptMessageHandler:self.recorder contentWorld:self.world
                                name:kMPTestHandlerName];
    WKUserScript *observer = [[WKUserScript alloc]
              initWithSource:self.observerScriptSource
               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
            forMainFrameOnly:YES
              inContentWorld:self.world];
    [content addUserScript:observer];

    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)
                                      configuration:configuration];
    self.webView.navigationDelegate = self.navigation;

    self.navigation.finished = [self expectationWithDescription:@"load"];
    self.recorder.mathjaxEnded =
        [self expectationWithDescription:@"mathjax-end"];
    [self.webView loadRequest:[NSURLRequest requestWithURL:pageURL]];
    [self waitForExpectations:@[self.navigation.finished,
                                self.recorder.mathjaxEnded]
                      timeout:kMPTestTimeout];
}

/// Runs an async function body in the page world and returns its result.
- (id)pageValueOfAsyncJavaScript:(NSString *)body
{
    XCTestExpectation *done = [self expectationWithDescription:body];
    __block id value = nil;
    __block NSError *failure = nil;
    [self.webView callAsyncJavaScript:body arguments:nil inFrame:nil
                       inContentWorld:WKContentWorld.pageWorld
                    completionHandler:^(id result, NSError *error) {
        value = result;
        failure = error;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:kMPTestTimeout];
    XCTAssertNil(failure, @"JavaScript failed: %@", body);
    return value;
}

- (BOOL)isMacDownScheme:(NSString *)urlString
{
    return [urlString hasPrefix:@"x-macdown-file:"]
        || [urlString hasPrefix:@"x-macdown-asset:"];
}

- (void)testPreviewTypesetsOfflineUnderPreviewCSP
{
    NSString *markdown =
        @"Inline $E=mc^2$ math.\n\n$$\\int_0^1 x\\,dx$$\n";
    NSString *html = [self previewHTMLForMarkdown:markdown];

    // The page is exactly what the brief requires: hoedown's delimiters.
    XCTAssertTrue([html containsString:@"\\(E=mc^2\\)"], @"%@", html);
    XCTAssertTrue([html containsString:@"\\[\\int_0^1 x\\,dx\\]"], @"%@", html);

    [self loadPreviewHTML:html];

    // Typesetting produced one container per formula, one of them display.
    NSNumber *count = [self pageValueOfAsyncJavaScript:
        @"return document.querySelectorAll('mjx-container').length;"];
    XCTAssertEqualObjects(count, @2);
    NSNumber *display = [self pageValueOfAsyncJavaScript:
        @"return document.querySelectorAll("
        @"'mjx-container[display=\"true\"]').length;"];
    XCTAssertEqualObjects(display, @1);
    NSNumber *errors = [self pageValueOfAsyncJavaScript:
        @"return document.querySelectorAll('mjx-merror').length;"];
    XCTAssertEqualObjects(errors, @0);

    // The page world has no route to the native handler; MathJax completed
    // without one, which is the point of init.js's DOM-event contract.
    NSString *pageBridge = [self pageValueOfAsyncJavaScript:
        @"return typeof (window.webkit && window.webkit.messageHandlers"
        @"  && window.webkit.messageHandlers.macdown);"];
    XCTAssertEqualObjects(pageBridge, @"undefined");

    // Web fonts are requested by glyph use; wait for them, then require that
    // none failed and at least one CHTML font came from the bundle.
    NSArray *fontStatuses = [self pageValueOfAsyncJavaScript:
        @"await document.fonts.ready;"
        @"var s = []; document.fonts.forEach(function (f) {"
        @"  s.push(f.status); }); return s;"];
    XCTAssertFalse([fontStatuses containsObject:@"error"], @"%@", fontStatuses);
    XCTAssertTrue([fontStatuses containsObject:@"loaded"], @"%@", fontStatuses);

    // Every resource the page fetched used MacDown's schemes.
    NSArray *resources = [self pageValueOfAsyncJavaScript:
        @"return performance.getEntriesByType('resource')"
        @"  .map(function (e) { return e.name; });"];
    for (NSString *name in resources)
        XCTAssertTrue([self isMacDownScheme:name], @"Left the app: %@", name);

    // ... and every request reached the scheme handler and was served.
    NSArray<NSURL *> *requested = self.schemeHandler.requestedURLs;
    XCTAssertEqual(self.schemeHandler.refusedURLs.count, (NSUInteger)0,
                   @"Refused: %@", self.schemeHandler.refusedURLs);
    NSPredicate *mathjaxScript =
        [NSPredicate predicateWithFormat:
            @"absoluteString ENDSWITH '/MathJax/es5/tex-mml-chtml.js'"];
    NSPredicate *noerrors =
        [NSPredicate predicateWithFormat:
            @"absoluteString ENDSWITH '/input/tex/extensions/noerrors.js'"];
    NSPredicate *font =
        [NSPredicate predicateWithFormat:
            @"absoluteString CONTAINS '/output/chtml/fonts/woff-v2/'"];
    XCTAssertEqual([requested filteredArrayUsingPredicate:mathjaxScript].count,
                   (NSUInteger)1, @"%@", requested);
    XCTAssertEqual([requested filteredArrayUsingPredicate:noerrors].count,
                   (NSUInteger)1, @"Lazy extension not loaded locally: %@",
                   requested);
    XCTAssertGreaterThan([requested filteredArrayUsingPredicate:font].count,
                         (NSUInteger)0, @"Fonts not loaded locally: %@",
                         requested);
    for (NSURL *url in requested)
        XCTAssertTrue([self isMacDownScheme:url.absoluteString], @"%@", url);
    for (NSURL *url in self.navigation.navigationURLs)
        XCTAssertTrue([self isMacDownScheme:url.absoluteString], @"%@", url);
    XCTAssertEqual(self.navigation.blockedNavigationURLs.count, (NSUInteger)0);

    // MathJax ran under the policy as given: not one violation, so it needs
    // no 'unsafe-eval' or any other relaxation.
    NSArray *violations = [self.recorder messagesForEvent:@"csp-violation"];
    XCTAssertEqual(violations.count, (NSUInteger)0, @"%@", violations);
    XCTAssertEqual([self.recorder messagesForEvent:@"mathjax-end"].count,
                   (NSUInteger)1, @"mathjax-end must fire exactly once.");

    // Discriminating check that the policy was in force at all: an inline
    // script injected now is blocked and reported.
    XCTestExpectation *reported =
        [self expectationWithDescription:@"inline script blocked"];
    NSUInteger before = violations.count;
    NSNumber *ran = [self pageValueOfAsyncJavaScript:
        @"var s = document.createElement('script');"
        @"s.textContent = 'window.__macdownInlineRan = true;';"
        @"document.body.appendChild(s);"
        @"return window.__macdownInlineRan === true;"];
    XCTAssertEqualObjects(ran, @NO, @"The preview CSP must block inline JS.");
    [self pollUntil:^BOOL{
        return [self.recorder messagesForEvent:@"csp-violation"].count
            > before;
    } fulfilling:reported];
    [self waitForExpectations:@[reported] timeout:kMPTestTimeout];
}

- (void)testMathJaxEndFiresWhenMathJaxFailsToLoad
{
    // init.js followed by a MathJax script the handler cannot serve: the host
    // must still be told loading is over.
    NSURL *init = [[NSBundle mainBundle] URLForResource:@"init"
                                          withExtension:@"js"
                                           subdirectory:@"MathJax"];
    XCTAssertNotNil(init);
    NSString *html = [NSString stringWithFormat:
        @"<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>"
        @"<p>\\(x\\)</p>"
        @"<script src=\"%@\"></script>"
        @"<script src=\"x-macdown-asset:///nonexistent/MathJax/es5/"
        @"tex-mml-chtml.js\"></script>"
        @"</body></html>", [MPAsset previewURLForURL:init].absoluteString];

    [self loadPreviewHTML:html];

    XCTAssertEqual([self.recorder messagesForEvent:@"mathjax-end"].count,
                   (NSUInteger)1);
    XCTAssertEqual(self.schemeHandler.refusedURLs.count, (NSUInteger)1,
                   @"%@", self.schemeHandler.refusedURLs);
}

- (void)pollUntil:(BOOL (^)(void))condition
       fulfilling:(XCTestExpectation *)expectation
{
    if (condition())
    {
        [expectation fulfill];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [self pollUntil:condition fulfilling:expectation];
    });
}

@end
