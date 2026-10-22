//
//  MPPreviewHostTests.m
//  MacDownTests
//
//  Drives a real WKWebView configured the way MPDocument configures the
//  preview: both custom-scheme handlers and the isolated-world bridge. These
//  are the boundaries the WebKitLegacy -> WKWebView migration relies on for
//  #1050 (document scripts never run) and TB-5 (page scripts cannot reach
//  native code).
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "MPPreviewBridge.h"
#import "MPPreviewSchemeHandler.h"


// The handler's collaborator is the task WebKit hands it; this one records
// what the handler answers so responses can be asserted directly.
@interface MPRecordingSchemeTask : NSObject <WKURLSchemeTask>
@property (readonly, copy) NSURLRequest *request;
@property (strong) NSHTTPURLResponse *response;
@property (strong) NSMutableData *data;
@property (strong) XCTestExpectation *finished;
- (instancetype)initWithRequest:(NSURLRequest *)request;
@end

@implementation MPRecordingSchemeTask
- (instancetype)initWithRequest:(NSURLRequest *)request
{
    self = [super init];
    _request = [request copy];
    _data = [NSMutableData data];
    return self;
}
- (void)didReceiveResponse:(NSURLResponse *)response
{
    self.response = (NSHTTPURLResponse *)response;
}
- (void)didReceiveData:(NSData *)data
{
    [self.data appendData:data];
}
- (void)didFinish
{
    [self.finished fulfill];
}
- (void)didFailWithError:(NSError *)error
{
    [self.finished fulfill];
}
@end


@interface MPPreviewHostTests : XCTestCase
    <WKNavigationDelegate, MPPreviewBridgeDelegate>
@property (strong) NSURL *root;
@property (strong) NSURL *assetRoot;
@property (strong) NSURL *documentRoot;
@property (strong) MPPreviewSchemeHandler *assetHandler;
@property (strong) MPPreviewSchemeHandler *fileHandler;
@property (strong) MPPreviewBridge *bridge;
@property (strong) WKWebView *webView;
@property (strong) NSWindow *window;
@property (strong) XCTestExpectation *loaded;
@property (strong) XCTestExpectation *mathJaxEnded;
@property (strong) NSMutableArray<NSNumber *> *scrollValues;
@property (strong) NSMutableArray<NSNumber *> *userScrollValues;
@property (strong) NSMutableArray<NSURL *> *requestedURLs;
@end


@implementation MPPreviewHostTests

- (void)setUp
{
    [super setUp];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *name = [NSString stringWithFormat:@"MPPreviewHostTests-%@",
                      [NSUUID UUID].UUIDString];
    self.root = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                           isDirectory:YES];
    self.assetRoot = [self.root URLByAppendingPathComponent:@"assets"
                                                isDirectory:YES];
    self.documentRoot = [self.root URLByAppendingPathComponent:@"docs"
                                                   isDirectory:YES];
    for (NSURL *url in @[self.assetRoot, self.documentRoot])
    {
        [manager createDirectoryAtURL:url withIntermediateDirectories:YES
                           attributes:nil error:NULL];
    }
    [self write:@"window.assetScriptRan = true;" to:self.assetRoot
           name:@"asset.js"];
    [self write:@"window.documentScriptRan = true;" to:self.documentRoot
           name:@"evil.js"];
    [self write:@"body { color: rgb(1, 2, 3); }" to:self.documentRoot
           name:@"local.css"];
    [self write:@"secret" to:self.root name:@"secret.txt"];

    NSArray *assetRoots =
        @[self.assetRoot, [NSBundle mainBundle].resourceURL];
    self.assetHandler = [[MPPreviewSchemeHandler alloc]
        initWithAllowedRoots:assetRoots];
    self.fileHandler = [[MPPreviewSchemeHandler alloc]
        initWithAllowedRoots:nil];

    WKWebViewConfiguration *configuration =
        [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore =
        [WKWebsiteDataStore nonPersistentDataStore];
    [configuration setURLSchemeHandler:self.assetHandler
                          forURLScheme:kMPPreviewAssetScheme];
    [configuration setURLSchemeHandler:self.fileHandler
                          forURLScheme:kMPPreviewFileScheme];
    self.bridge = [[MPPreviewBridge alloc]
        initWithUserContentController:configuration.userContentController];
    self.bridge.delegate = self;

    NSRect frame = NSMakeRect(0.0, 0.0, 400.0, 300.0);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    // ARC owns the window; -close must not release it a second time.
    self.window.releasedWhenClosed = NO;
    self.webView = [[WKWebView alloc] initWithFrame:frame
                                      configuration:configuration];
    self.webView.navigationDelegate = self;
    self.window.contentView = self.webView;
    self.scrollValues = [NSMutableArray array];
    self.userScrollValues = [NSMutableArray array];
    self.requestedURLs = [NSMutableArray array];
}

- (void)tearDown
{
    [self.bridge invalidate];
    self.webView.navigationDelegate = nil;
    self.webView = nil;
    [self.window close];
    self.window = nil;
    [[NSFileManager defaultManager] removeItemAtURL:self.root error:NULL];
    [super tearDown];
}


#pragma mark - Helpers

- (void)write:(NSString *)content to:(NSURL *)directory name:(NSString *)name
{
    NSURL *url = [directory URLByAppendingPathComponent:name];
    [content writeToURL:url atomically:YES encoding:NSUTF8StringEncoding
                  error:NULL];
}

- (NSURL *)pageURL
{
    NSURL *url = [self.documentRoot URLByAppendingPathComponent:@"page.md"];
    return MPPreviewURLForPath(kMPPreviewFileScheme, url.path);
}

- (NSString *)assetURLStringForName:(NSString *)name
{
    NSURL *url = [self.assetRoot URLByAppendingPathComponent:name];
    return MPPreviewURLForPath(kMPPreviewAssetScheme, url.path).absoluteString;
}

- (void)loadPageWithBody:(NSString *)body head:(NSString *)head
{
    NSString *html = [NSString stringWithFormat:
        @"<!DOCTYPE html><html><head>%@</head><body>%@</body></html>",
        head ? head : @"", body];
    [self.fileHandler setPageHTML:html forURL:self.pageURL];
    self.loaded = [self expectationWithDescription:@"page loaded"];
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.pageURL]];
    [self waitForExpectations:@[self.loaded] timeout:10.0];
}

- (id)evaluate:(NSString *)script inWorld:(WKContentWorld *)world
{
    __block id value = nil;
    XCTestExpectation *done = [self expectationWithDescription:script];
    [self.webView evaluateJavaScript:script inFrame:nil inContentWorld:world
                   completionHandler:^(id result, NSError *error) {
        value = error ? error : result;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:10.0];
    return value;
}

- (id)evaluateInPage:(NSString *)script
{
    return [self evaluate:script inWorld:WKContentWorld.pageWorld];
}

// Waits until condition is true in the page, or timeout passes; the
// assertions that follow say what was missing.
- (void)pollPage:(NSString *)condition timeout:(NSTimeInterval)timeout
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0
            && ![[self evaluateInPage:condition] isEqual:@YES])
    {
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

- (NSHTTPURLResponse *)fetch:(NSURL *)url
                     handler:(MPPreviewSchemeHandler *)handler
                        data:(NSData **)data
{
    return [self fetchRequest:[NSURLRequest requestWithURL:url]
                      handler:handler data:data];
}

- (NSHTTPURLResponse *)fetchRequest:(NSURLRequest *)request
                            handler:(MPPreviewSchemeHandler *)handler
                               data:(NSData **)data
{
    MPRecordingSchemeTask *task =
        [[MPRecordingSchemeTask alloc] initWithRequest:request];
    task.finished = [self expectationWithDescription:
                     request.URL.absoluteString];
    [handler webView:self.webView startURLSchemeTask:task];
    [self waitForExpectations:@[task.finished] timeout:10.0];
    if (data)
        *data = task.data;
    return task.response;
}


#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
        decidePolicyForNavigationAction:(WKNavigationAction *)action
        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    [self.requestedURLs addObject:action.request.URL];
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
        didFinishNavigation:(WKNavigation *)navigation
{
    [self.loaded fulfill];
}


#pragma mark - MPPreviewBridgeDelegate

- (void)previewBridgeDidReceiveEvent:(MPPreviewBridgeEvent)event
                               value:(CGFloat)value
{
    switch (event)
    {
        case MPPreviewBridgeEventMathJaxEnd:
            [self.mathJaxEnded fulfill];
            break;
        case MPPreviewBridgeEventScroll:
            [self.scrollValues addObject:@(value)];
            break;
        case MPPreviewBridgeEventUserScroll:
            [self.userScrollValues addObject:@(value)];
            break;
    }
}


#pragma mark - URL construction

- (void)testPreviewURLIsPercentEncodedAndRoundTrips
{
    NSString *path = @"/Users/me/My Notes/日本語 #1.md";
    NSURL *url = MPPreviewURLForPath(kMPPreviewFileScheme, path);
    XCTAssertEqualObjects(url.scheme, kMPPreviewFileScheme);
    XCTAssertEqualObjects(url.path, path);
    XCTAssertNil(url.fragment, @"'#' in a file name must not become a fragment");
}


#pragma mark - Content-Security-Policy

- (void)testDocumentScriptsDoNotRunButAssetScriptsDo
{
    NSString *head = [NSString stringWithFormat:
        @"<script src=\"%@\"></script>",
        [self assetURLStringForName:@"asset.js"]];
    NSString *body =
        @"<script>window.inlineScriptRan = true;</script>"
        @"<script src=\"evil.js\"></script>"
        @"<img src=\"missing.png\" onerror=\"window.handlerRan = true\">";
    [self loadPageWithBody:body head:head];

    NSDictionary *ran = [self evaluateInPage:
        @"({asset: !!window.assetScriptRan,"
        @"  inline: !!window.inlineScriptRan,"
        @"  document: !!window.documentScriptRan,"
        @"  handler: !!window.handlerRan})"];
    XCTAssertEqualObjects(ran[@"asset"], @YES,
                          @"MacDown's own assets must still run");
    XCTAssertEqualObjects(ran[@"inline"], @NO, @"inline <script> ran");
    XCTAssertEqualObjects(ran[@"document"], @NO,
                          @"a script beside the document ran (#1050)");
    XCTAssertEqualObjects(ran[@"handler"], @NO,
                          @"an event-handler attribute ran");
}

- (void)testDocumentRelativeResourcesLoadIncludingParentDirectories
{
    NSString *body =
        @"<p id=\"p\">styled</p>"
        @"<iframe id=\"f\" src=\"../secret.txt\"></iframe>";
    NSString *head = @"<link rel=\"stylesheet\" href=\"local.css\">";
    [self loadPageWithBody:body head:head];

    NSString *color = [self evaluateInPage:
        @"getComputedStyle(document.getElementById('p')).color"];
    XCTAssertEqualObjects(color, @"rgb(1, 2, 3)",
                          @"a stylesheet beside the document must load");

    // frame-src admits only https:, so a document cannot frame (and read)
    // other local files.
    id frameText = [self evaluateInPage:
        @"(function () { try {"
        @"  var d = document.getElementById('f').contentDocument;"
        @"  return d && d.body ? d.body.textContent : '';"
        @"} catch (e) { return ''; } })()"];
    XCTAssertFalse([frameText isKindOfClass:[NSString class]]
                       && [frameText containsString:@"secret"],
                   @"a local file was framed into the page");
}


#pragma mark - Scheme handler

- (void)testAssetHandlerRefusesFilesOutsideItsRoots
{
    NSURL *inside = MPPreviewURLForPath(
        kMPPreviewAssetScheme,
        [self.assetRoot URLByAppendingPathComponent:@"asset.js"].path);
    NSData *data = nil;
    NSHTTPURLResponse *response =
        [self fetch:inside handler:self.assetHandler data:&data];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertTrue([[[NSString alloc] initWithData:data
        encoding:NSUTF8StringEncoding] containsString:@"assetScriptRan"]);

    NSString *escaping = [self.assetRoot.path
        stringByAppendingPathComponent:@"../secret.txt"];
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = kMPPreviewAssetScheme;
    components.host = @"";
    components.percentEncodedPath = escaping;
    response = [self fetch:components.URL handler:self.assetHandler data:&data];
    XCTAssertEqual(response.statusCode, 404,
                   @"'..' must not escape the asset roots");

    NSString *linked = [self.assetRoot.path
        stringByAppendingPathComponent:@"link.txt"];
    [[NSFileManager defaultManager]
        createSymbolicLinkAtPath:linked
             withDestinationPath:[self.root.path
                 stringByAppendingPathComponent:@"secret.txt"]
                           error:NULL];
    response = [self fetch:MPPreviewURLForPath(kMPPreviewAssetScheme, linked)
                   handler:self.assetHandler data:&data];
    XCTAssertEqual(response.statusCode, 404,
                   @"a symlink must not escape the asset roots");
}

- (void)testResponsesAreNeverCachedAndCarryTypes
{
    NSURL *url = MPPreviewURLForPath(
        kMPPreviewFileScheme,
        [self.documentRoot URLByAppendingPathComponent:@"local.css"].path);
    NSHTTPURLResponse *response =
        [self fetch:url handler:self.fileHandler data:NULL];
    XCTAssertEqual(response.statusCode, 200);
    NSDictionary *headers = response.allHeaderFields;
    XCTAssertEqualObjects(headers[@"Cache-Control"], @"no-store",
                          @"stale images after editing them (#931)");
    XCTAssertTrue([headers[@"Content-Type"] hasPrefix:@"text/css"]);

    NSURL *missing = MPPreviewURLForPath(
        kMPPreviewFileScheme,
        [self.documentRoot URLByAppendingPathComponent:@"nope.png"].path);
    XCTAssertEqual([self fetch:missing handler:self.fileHandler
                          data:NULL].statusCode, 404);
    NSURL *directory = MPPreviewURLForPath(kMPPreviewFileScheme,
                                           self.documentRoot.path);
    XCTAssertEqual([self fetch:directory handler:self.fileHandler
                          data:NULL].statusCode, 404);
}

- (NSURL *)documentFileNamed:(NSString *)name data:(NSData *)data
{
    NSURL *file = [self.documentRoot URLByAppendingPathComponent:name];
    XCTAssertTrue([data writeToURL:file atomically:YES]);
    return MPPreviewURLForPath(kMPPreviewFileScheme, file.path);
}

- (NSHTTPURLResponse *)fetch:(NSURL *)url range:(NSString *)range
                        data:(NSData **)data
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:range forHTTPHeaderField:@"Range"];
    return [self fetchRequest:request handler:self.fileHandler data:data];
}

// WebKit's media loader reads local audio and video in byte ranges; a file
// only ever served whole cannot be played or seeked.
- (void)testByteRangesAreServed
{
    NSMutableData *bytes = [NSMutableData dataWithLength:1000];
    for (NSUInteger i = 0; i < bytes.length; i++)
        ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)(i % 251);
    NSURL *url = [self documentFileNamed:@"clip.mp4" data:bytes];

    NSData *data = nil;
    NSHTTPURLResponse *response = [self fetch:url handler:self.fileHandler data:&data];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertEqualObjects(response.allHeaderFields[@"Accept-Ranges"],
                          @"bytes");
    XCTAssertEqualObjects(data, bytes);

    NSDictionary<NSString *, NSArray *> *cases = @{
        @"bytes=100-199": @[@100, @100, @"bytes 100-199/1000"],
        @"bytes=900-": @[@900, @100, @"bytes 900-999/1000"],
        @"bytes=-50": @[@950, @50, @"bytes 950-999/1000"],
        @"bytes=990-5000": @[@990, @10, @"bytes 990-999/1000"],
    };
    for (NSString *range in cases)
    {
        NSArray *expected = cases[range];
        response = [self fetch:url range:range data:&data];
        XCTAssertEqual(response.statusCode, 206, @"%@", range);
        XCTAssertEqualObjects(response.allHeaderFields[@"Content-Range"],
                              expected[2], @"%@", range);
        NSRange slice = NSMakeRange([expected[0] unsignedIntegerValue],
                                    [expected[1] unsignedIntegerValue]);
        XCTAssertEqualObjects(data, [bytes subdataWithRange:slice],
                              @"%@", range);
        XCTAssertEqualObjects(response.allHeaderFields[@"Content-Length"],
                              [expected[1] stringValue], @"%@", range);
    }

    response = [self fetch:url range:@"bytes=1000-" data:&data];
    XCTAssertEqual(response.statusCode, 416);
    XCTAssertEqualObjects(response.allHeaderFields[@"Content-Range"],
                          @"bytes */1000");

    // Several ranges at once are allowed to be answered whole.
    response = [self fetch:url range:@"bytes=0-1,5-6" data:&data];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertEqualObjects(data, bytes);
}

// A declared charset overrides a stylesheet's BOM and @charset rule.
- (void)testOnlyUTF8TextIsDeclaredUTF8
{
    NSURL *utf8 = [self documentFileNamed:@"utf8.css"
        data:[@"p::after { content: \"é\"; }"
              dataUsingEncoding:NSUTF8StringEncoding]];
    NSURL *latin1 = [self documentFileNamed:@"latin1.css"
        data:[@"@charset \"iso-8859-1\"; p::after { content: \"é\"; }"
              dataUsingEncoding:NSISOLatin1StringEncoding]];

    XCTAssertEqualObjects([self fetch:utf8 handler:self.fileHandler data:NULL]
                          .allHeaderFields[@"Content-Type"],
                          @"text/css; charset=utf-8");
    XCTAssertEqualObjects([self fetch:latin1 handler:self.fileHandler
                                 data:NULL].allHeaderFields[@"Content-Type"],
                          @"text/css");
}

- (void)testVirtualPageCarriesThePolicyAndCanBeRemoved
{
    NSURL *page = MPPreviewURLForPath(kMPPreviewFileScheme,
        [self.documentRoot URLByAppendingPathComponent:@"virtual.md"].path);
    [self.fileHandler setPageHTML:@"<p>virtual</p>" forURL:page];
    NSData *data = nil;
    NSHTTPURLResponse *response =
        [self fetch:page handler:self.fileHandler data:&data];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertEqualObjects(response.allHeaderFields[@"Content-Security-Policy"],
                          kMPPreviewContentSecurityPolicy);
    XCTAssertEqualObjects([[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding],
                          @"<p>virtual</p>");

    [self.fileHandler setPageHTML:nil forURL:page];
    XCTAssertEqual([self fetch:page handler:self.fileHandler
                          data:NULL].statusCode, 404,
                   @"a removed page must not keep being served");
}


#pragma mark - Bundled extensions under the policy

- (NSString *)bundleScriptTag:(NSString *)relativePath
{
    NSString *path = [[NSBundle mainBundle].resourcePath
        stringByAppendingPathComponent:relativePath];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path],
                  @"missing bundled script %@", relativePath);
    return [NSString stringWithFormat:@"<script src=\"%@\"></script>",
            MPPreviewURLForPath(kMPPreviewAssetScheme, path).absoluteString];
}

- (void)testBundledHighlightingAndDiagramsRunWithoutPolicyViolations
{
    // Record violations from a world of our own: the event is dispatched on
    // the document, which every world shares.
    WKUserScript *recorder = [[WKUserScript alloc]
        initWithSource:@"document.addEventListener('securitypolicyviolation',"
                       @" function (e) { var n = document.documentElement;"
                       @" n.dataset.violations = (n.dataset.violations || '')"
                       @" + e.violatedDirective + ' ' + e.blockedURI + ';'; });"
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:YES
        inContentWorld:[WKContentWorld worldWithName:@"MPPreviewHostTests"]];
    [self.webView.configuration.userContentController addUserScript:recorder];

    NSString *body = [@[
        @"<div id=\"python\"><pre><code class=\"language-python\">"
        @"def f(x):\n    return x</code></pre></div>",
        @"<div id=\"mermaid\"><pre><code class=\"language-mermaid\">"
        @"graph TD; A-->B;</code></pre></div>",
        @"<div id=\"dot\"><pre><code class=\"language-dot\">"
        @"digraph { a -> b }</code></pre></div>",
        [self bundleScriptTag:@"Prism/components/prism-core.min.js"],
        [self bundleScriptTag:@"Prism/components/prism-python.min.js"],
        [self bundleScriptTag:@"Extensions/mermaid.min.js"],
        [self bundleScriptTag:@"Extensions/mermaid.init.js"],
        [self bundleScriptTag:@"Extensions/viz.js"],
        [self bundleScriptTag:@"Extensions/viz.init.js"],
    ] componentsJoinedByString:@"\n"];
    [self loadPageWithBody:body head:nil];

    // Diagrams render on window load, which can trail navigation finishing.
    // The fixture wraps code blocks in <div><pre><code> as the renderer does;
    // the diagram scripts replace that wrapper with their output.
    [self pollPage:@"document.querySelectorAll('#mermaid svg, #dot svg')"
                   @".length >= 2" timeout:30.0];

    NSDictionary *state = [self evaluateInPage:
        @"({prism: document.querySelectorAll('#python .token').length,"
        @"  mermaid: document.querySelectorAll('#mermaid svg').length,"
        @"  graphviz: document.querySelectorAll('#dot svg').length,"
        @"  violations: document.documentElement.dataset.violations || ''})"];
    XCTAssertGreaterThan([state[@"prism"] integerValue], 0,
                         @"Prism did not highlight the code block");
    XCTAssertEqual([state[@"mermaid"] integerValue], 1,
                   @"Mermaid did not render its diagram");
    XCTAssertEqual([state[@"graphviz"] integerValue], 1,
                   @"Graphviz did not render its graph");
    XCTAssertEqualObjects(state[@"violations"], @"",
                          @"bundled extensions tripped the preview policy");
}


#pragma mark - Bridge

- (void)testPageScriptsCannotSeeTheBridge
{
    NSString *head = [NSString stringWithFormat:
        @"<script src=\"%@\"></script>",
        [self assetURLStringForName:@"probe.js"]];
    [self write:@"window.bridgeVisible = !!(window.webkit"
                @" && window.webkit.messageHandlers"
                @" && window.webkit.messageHandlers.macdown);"
             to:self.assetRoot name:@"probe.js"];
    [self loadPageWithBody:@"<p>x</p>" head:head];

    XCTAssertEqualObjects([self evaluateInPage:@"window.bridgeVisible"], @NO,
                          @"page scripts can reach native code (TB-5)");
    XCTAssertEqualObjects(
        [self evaluate:@"!!window.webkit.messageHandlers.macdown"
               inWorld:MPPreviewBridge.contentWorld], @YES);
}

- (void)testMathJaxDOMEventIsForwardedFromThePage
{
    [self write:@"document.dispatchEvent("
                @"new CustomEvent('macdown:mathjax-end'));"
             to:self.assetRoot name:@"end.js"];
    self.mathJaxEnded = [self expectationWithDescription:@"mathjax end"];
    NSString *body = [NSString stringWithFormat:
        @"<p>x</p><script src=\"%@\"></script>",
        [self assetURLStringForName:@"end.js"]];
    [self loadPageWithBody:body head:nil];
    [self waitForExpectations:@[self.mathJaxEnded] timeout:10.0];
}

- (void)waitForLastValueIn:(NSString *)keyPath toBe:(double)expected
{
    NSPredicate *reported = [NSPredicate predicateWithBlock:
        ^BOOL(MPPreviewHostTests *test, NSDictionary *bindings) {
            NSArray *values = [test valueForKey:keyPath];
            return [[values lastObject] doubleValue] == expected;
        }];
    [self waitForExpectations:@[[self expectationForPredicate:reported
                                          evaluatedWithObject:self
                                                      handler:nil]]
                      timeout:10.0];
}

- (NSString *)longPageBody
{
    NSMutableString *body = [NSMutableString string];
    for (int i = 0; i < 200; i++)
        [body appendFormat:@"<p>line %d</p>", i];
    return body;
}

- (void)testScrollPositionIsReportedAndRestoredOnReload
{
    NSString *body = [self longPageBody];
    [self loadPageWithBody:body head:nil];

    [self evaluate:[MPPreviewBridge scriptScrollingToTop:500.0]
           inWorld:MPPreviewBridge.contentWorld];
    [self waitForLastValueIn:@"scrollValues" toBe:500.0];

    [self.bridge prepareForLoadRestoringScrollTop:500.0];
    [self loadPageWithBody:body head:nil];
    XCTAssertEqualObjects([self evaluateInPage:@"window.scrollY"], @500);
}

// Scroll sync runs both ways; a scroll native code made must never come back
// as the reader's, or each pane would keep re-syncing the other.
- (void)testReaderScrollsAreToldApartFromNativeScrolls
{
    NSString *body = [self longPageBody];
    [self loadPageWithBody:body head:nil];

    [self evaluate:[MPPreviewBridge scriptScrollingToTop:300.0]
           inWorld:MPPreviewBridge.contentWorld];
    [self waitForLastValueIn:@"scrollValues" toBe:300.0];

    // The page world stands in for the reader: it is not native code, and it
    // cannot reach the bridge's own scroll function.
    [self evaluateInPage:@"window.scrollTo(0, 700); 0"];
    [self waitForLastValueIn:@"userScrollValues" toBe:700.0];

    XCTAssertEqualObjects(self.scrollValues, @[@300]);
    XCTAssertEqualObjects(self.userScrollValues, @[@700]);
    XCTAssertEqualObjects([self evaluateInPage:@"typeof macdownScrollTo"],
                          @"undefined");

    // A restored position is native too, not something to sync the editor to.
    [self.bridge prepareForLoadRestoringScrollTop:400.0];
    [self loadPageWithBody:body head:nil];
    [self waitForLastValueIn:@"scrollValues" toBe:400.0];
    XCTAssertEqualObjects(self.userScrollValues, @[@700]);
}

// Document CSS may ask for smooth scrolling. Animated, a native scroll would
// land after the bridge checked it, and every frame would be reported as
// the reader's: the editor would follow, and sync the preview back.
- (void)testSmoothScrollingCSSDoesNotTurnNativeScrollsIntoTheReaders
{
    [self loadPageWithBody:[self longPageBody]
                      head:@"<style>html { scroll-behavior: smooth; }</style>"];

    [self evaluate:[MPPreviewBridge scriptScrollingToTop:600.0]
           inWorld:MPPreviewBridge.contentWorld];
    [self waitForLastValueIn:@"scrollValues" toBe:600.0];
    XCTAssertEqualObjects([self evaluateInPage:@"window.scrollY"], @600);
    XCTAssertEqualObjects(self.userScrollValues, @[]);
}

- (void)testRootFontSizeDefaultsToTheLegacyTwelvePixels
{
    [self loadPageWithBody:@"<p id=\"p\">x</p>" head:nil];
    XCTAssertEqualObjects([self evaluateInPage:
        @"getComputedStyle(document.getElementById('p')).fontSize"], @"12px");

    [self loadPageWithBody:@"<p id=\"p\">x</p>"
                      head:@"<style>html { font-size: 20px; }</style>"];
    XCTAssertEqualObjects([self evaluateInPage:
        @"getComputedStyle(document.getElementById('p')).fontSize"], @"20px",
        @"a style's own root size must win over the default");
}

- (void)testBridgeRejectsMalformedMessages
{
    MPPreviewBridgeEvent event;
    CGFloat value = 0.0;
    NSDictionary *unknown = @{@"event": @"open", @"value": @0};
    NSDictionary *mistyped = @{@"event": @"scroll", @"value": @"1"};
    NSDictionary *valid = @{@"event": @"scroll", @"value": @42};
    NSDictionary *user = @{@"event": @"user-scroll", @"value": @7};

    XCTAssertFalse([MPPreviewBridge parseMessageBody:@"mathjax-end"
                                               event:&event value:&value]);
    XCTAssertFalse([MPPreviewBridge parseMessageBody:unknown
                                               event:&event value:&value]);
    XCTAssertFalse([MPPreviewBridge parseMessageBody:mistyped
                                               event:&event value:&value]);
    XCTAssertTrue([MPPreviewBridge parseMessageBody:valid
                                              event:&event value:&value]);
    XCTAssertEqual(event, MPPreviewBridgeEventScroll);
    XCTAssertEqual(value, 42.0);
    XCTAssertTrue([MPPreviewBridge parseMessageBody:user
                                              event:&event value:&value]);
    XCTAssertEqual(event, MPPreviewBridgeEventUserScroll);
    XCTAssertEqual(value, 7.0);
}

@end
