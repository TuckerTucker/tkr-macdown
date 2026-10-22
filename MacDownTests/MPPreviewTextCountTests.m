//
//  MPPreviewTextCountTests.m
//  MacDownTests
//
//  Coverage for MPPreviewTextCount (Wave 3c word count in JS).
//
//  Three layers:
//    1. Unit tests for MPPreviewTextCountFromPayload(), including malformed
//       payloads.
//    2. Integration tests that load HTML into a real WKWebView, evaluate the
//       bundled text-count.js through MPPreviewEvaluateTextCount(), and
//       assert exact counts. The expected numbers were measured from the
//       legacy DOMNode+Text implementation at commit 826bae7, so they hold
//       after WebKitLegacy is removed. (A parity test that compared both
//       engines side by side produced them and was removed with WebKitLegacy.)
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import "MPPreviewTextCount.h"

static const NSTimeInterval kMPTextCountTimeout = 20.0;

// Legacy-measured expectations: {words, characters, charactersWithoutSpaces}
// computed by -[DOMDocument textCount] (DOMNode+Text) on a WebKitLegacy
// WebView at commit 826bae7, recorded by a since-removed parity test. They are the
// contract the WKWebView path must keep once the legacy WebView is gone; do
// not regenerate them from MPPreviewTextCount.
#define LEGACY_FIXTURE_WORDS 67
#define LEGACY_FIXTURE_CHARACTERS 475
#define LEGACY_FIXTURE_NO_SPACES 397
#define LEGACY_SNIPPET_COUNTS { \
    {2, 6, 6},    /* foo<b>bar</b> */ \
    {3, 18, 15},  /* inline code is one word */ \
    {0, 3, 0},    /* whitespace-only inline code */ \
    {1, 2, 2},    /* nested inline code */ \
    {0, 18, 16},  /* pre > code block */ \
    {4, 23, 20},  /* pre without code */ \
    {1, 7, 7},    /* script and style skipped */ \
    {3, 6, 6},    /* CJK */ \
    {6, 26, 23},  /* LF and CRLF excluded */ \
    {2, 17, 9},   /* whitespace runs */ \
}


// Small documents, each isolating one counting rule. Shared by the WKWebView
// tests, which hold them to legacy-measured expectations.
static NSArray<NSString *> *MPTextCountSnippets(void)
{
    return @[
        @"<p>foo<b>bar</b></p>",
        @"<p>one <code>two three</code> four</p>",
        @"<p><code>   </code></p>",
        @"<p><code>a<code>b</code></code></p>",
        @"<pre><code>skipped words here</code></pre>",
        @"<pre>pre without code counts</pre>",
        [@"<p>visible</p><script>var hidden = 'a b c';</script>"
         stringByAppendingString:@"<style>p { color: red; }</style>"],
        @"<p>中文字符测试</p>",
        @"<p>line one\nline two\r\nline three</p>",
        @"<p>  spaced \t  out  </p>",
    ];
}


@interface MPPreviewTextCountTests : XCTestCase <WKNavigationDelegate>
@property (nonatomic, strong) XCTestExpectation *loadExpectation;
@property (nonatomic, strong) NSWindow *window;
@end


@implementation MPPreviewTextCountTests

- (void)setUp
{
    [super setUp];
    NSRect frame = NSMakeRect(0.0, 0.0, 800.0, 600.0);
    self.window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:NSWindowStyleMaskBorderless
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    self.window.releasedWhenClosed = NO;
}

- (void)tearDown
{
    [self.window close];
    self.window = nil;
    self.loadExpectation = nil;
    [super tearDown];
}


#pragma mark - Helpers

- (NSString *)fixtureHTML
{
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:@"text-count-fixture"
                          withExtension:@"html"];
    XCTAssertNotNil(url, @"Fixture must be bundled with the test target.");
    NSString *html = [NSString stringWithContentsOfURL:url
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    XCTAssertGreaterThan(html.length, 0u);
    return html;
}

- (WKWebView *)loadedWKWebViewWithHTML:(NSString *)html
{
    WKWebView *webView =
        [[WKWebView alloc] initWithFrame:self.window.contentView.bounds
                           configuration:[[WKWebViewConfiguration alloc] init]];
    webView.navigationDelegate = self;
    [self.window.contentView addSubview:webView];

    self.loadExpectation = [self expectationWithDescription:@"WKWebView load"];
    [webView loadHTMLString:html baseURL:nil];
    [self waitForExpectationsWithTimeout:kMPTextCountTimeout handler:nil];
    return webView;
}

- (MPPreviewTextCount)countWithWKWebViewHTML:(NSString *)html
{
    WKWebView *webView = [self loadedWKWebViewWithHTML:html];

    __block MPPreviewTextCount result = {0, 0, 0};
    XCTestExpectation *counted = [self expectationWithDescription:@"count"];
    MPPreviewEvaluateTextCount(webView, ^(MPPreviewTextCount count,
                                          NSError *error) {
        XCTAssertTrue([NSThread isMainThread]);
        XCTAssertNil(error);
        result = count;
        [counted fulfill];
    });
    [self waitForExpectationsWithTimeout:kMPTextCountTimeout handler:nil];

    [webView removeFromSuperview];
    return result;
}

- (void)assertCount:(MPPreviewTextCount)count
              words:(NSUInteger)words
         characters:(NSUInteger)characters
    charactersNoSpaces:(NSUInteger)noSpaces
            context:(NSString *)context
{
    XCTAssertEqual(count.words, words, @"words: %@", context);
    XCTAssertEqual(count.characters, characters, @"characters: %@", context);
    XCTAssertEqual(count.charactersWithoutSpaces, noSpaces,
                   @"characters without spaces: %@", context);
}


#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation
{
    [self.loadExpectation fulfill];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    XCTFail(@"WKWebView navigation failed: %@", error);
    [self.loadExpectation fulfill];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error
{
    XCTFail(@"WKWebView provisional navigation failed: %@", error);
    [self.loadExpectation fulfill];
}


#pragma mark - Payload (unit)

- (void)testPayloadEmptyDictionaryIsZero
{
    MPPreviewTextCount count = MPPreviewTextCountFromPayload(@{});
    [self assertCount:count words:0 characters:0 charactersNoSpaces:0
              context:@"empty dictionary"];
}

- (void)testPayloadMalformedTopLevelIsZero
{
    NSArray *payloads = @[[NSNull null], @"words", @42, @[@"a b"],
                          [NSData data]];
    for (id payload in payloads)
    {
        MPPreviewTextCount count = MPPreviewTextCountFromPayload(payload);
        [self assertCount:count words:0 characters:0 charactersNoSpaces:0
                  context:[payload description]];
    }
    MPPreviewTextCount count = MPPreviewTextCountFromPayload(nil);
    [self assertCount:count words:0 characters:0 charactersNoSpaces:0
              context:@"nil"];
}

- (void)testPayloadMalformedFieldsCountAsZero
{
    NSDictionary *payload = @{@"words": @"not an array",
                              @"characters": @{@"a": @"b"}};
    MPPreviewTextCount count = MPPreviewTextCountFromPayload(payload);
    [self assertCount:count words:0 characters:0 charactersNoSpaces:0
              context:@"fields of the wrong type"];
}

- (void)testPayloadIgnoresItemsOfTheWrongType
{
    NSDictionary *payload = @{
        @"words": @[@"one two", [NSNull null], @3, @{@"x": @"y z"}],
        @"characters": @[@"ab c", [NSNull null], @7, @[@"zzz"]],
    };
    MPPreviewTextCount count = MPPreviewTextCountFromPayload(payload);
    [self assertCount:count words:2 characters:4 charactersNoSpaces:3
              context:@"mixed item types"];
}

- (void)testPayloadFieldsAreIndependent
{
    MPPreviewTextCount count =
        MPPreviewTextCountFromPayload(@{@"words": @[@"a b c"]});
    [self assertCount:count words:3 characters:0 charactersNoSpaces:0
              context:@"words only"];

    count = MPPreviewTextCountFromPayload(@{@"characters": @[@"a b c"]});
    [self assertCount:count words:0 characters:5 charactersNoSpaces:3
              context:@"characters only"];
}

- (void)testPayloadWordsAreCountedPerSegment
{
    // "foo" + "bar" as separate text nodes is two words, not one.
    MPPreviewTextCount count =
        MPPreviewTextCountFromPayload(@{@"words": @[@"foo", @"bar"]});
    XCTAssertEqual(count.words, 2u);
}

- (void)testPayloadInlineCodeGroupCountsAsOneWord
{
    NSDictionary *payload = @{@"words": @[@"before",
                                          @[@"several words of code"],
                                          @"after"]};
    XCTAssertEqual(MPPreviewTextCountFromPayload(payload).words, 3u);
}

- (void)testPayloadInlineCodeGroupWithoutWordsCountsZero
{
    NSDictionary *payload = @{@"words": @[@[], @[@"   "], @[@"\n"],
                                          @[[NSNull null]]]};
    XCTAssertEqual(MPPreviewTextCountFromPayload(payload).words, 0u);
}

- (void)testPayloadNestedInlineCodeGroupCountsOnce
{
    NSDictionary *payload = @{@"words": @[@[@"a", @[@"b c"], @"d"]]};
    XCTAssertEqual(MPPreviewTextCountFromPayload(payload).words, 1u);
}

- (void)testPayloadCharactersExcludeNewlines
{
    NSDictionary *payload = @{@"characters": @[@"a\nb\r\nc d"]};
    MPPreviewTextCount count = MPPreviewTextCountFromPayload(payload);
    XCTAssertEqual(count.characters, 4u);
    XCTAssertEqual(count.charactersWithoutSpaces, 4u);
}

- (void)testPayloadCharactersWithoutSpacesExcludeWhitespace
{
    NSDictionary *payload = @{@"characters": @[@" a\tb  c ", @"d e"]};
    MPPreviewTextCount count = MPPreviewTextCountFromPayload(payload);
    XCTAssertEqual(count.characters, 11u);
    XCTAssertEqual(count.charactersWithoutSpaces, 5u);
}

- (void)testPayloadCJKWordsUseNSStringSegmentation
{
    NSString *text = @"中文字符测试";
    __block NSUInteger expected = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByWords
                                     | NSStringEnumerationSubstringNotRequired
                          usingBlock:
     ^(NSString *s, NSRange r, NSRange e, BOOL *stop) { expected++; }];
    XCTAssertGreaterThan(expected, 1u,
                         @"NSString should split CJK into several words.");

    MPPreviewTextCount count =
        MPPreviewTextCountFromPayload(@{@"words": @[text],
                                        @"characters": @[text]});
    XCTAssertEqual(count.words, expected);
    XCTAssertEqual(count.characters, text.length);
}


#pragma mark - Script and evaluation errors

- (void)testScriptIsBundledUnderScripts
{
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"text-count"
                                         withExtension:@"js"
                                          subdirectory:@"Scripts"];
    XCTAssertNotNil(url, @"text-count.js must be at Resources/Scripts/.");
    NSString *script = MPPreviewTextCountScript();
    XCTAssertGreaterThan(script.length, 0u);
    XCTAssertTrue([script containsString:@"characters"]);
}

- (void)testEvaluateWithoutWebViewReportsErrorOnMainThread
{
    XCTestExpectation *done = [self expectationWithDescription:@"error"];
    __block BOOL returned = NO;
    MPPreviewEvaluateTextCount(nil, ^(MPPreviewTextCount count,
                                      NSError *error) {
        XCTAssertTrue(returned, @"Completion must be asynchronous.");
        XCTAssertTrue([NSThread isMainThread]);
        XCTAssertEqualObjects(error.domain, MPPreviewTextCountErrorDomain);
        XCTAssertEqual(error.code, MPPreviewTextCountErrorNoWebView);
        XCTAssertEqual(count.words, 0u);
        [done fulfill];
    });
    returned = YES;
    [self waitForExpectationsWithTimeout:kMPTextCountTimeout handler:nil];
}

- (void)testEvaluateEmptyDocumentCountsZero
{
    WKWebView *webView =
        [self loadedWKWebViewWithHTML:@"<html><body></body></html>"];
    XCTestExpectation *done = [self expectationWithDescription:@"count"];
    MPPreviewEvaluateTextCount(webView, ^(MPPreviewTextCount count,
                                          NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(count.words, 0u);
        XCTAssertEqual(count.characters, 0u);
        [done fulfill];
    });
    [self waitForExpectationsWithTimeout:kMPTextCountTimeout handler:nil];
}


#pragma mark - WKWebView integration

// Expectations are the LEGACY_* values measured from DOMNode+Text at commit
// 826bae7 (see the definitions at the top of this file).

- (void)testFixtureCountsMatchLegacyMeasurement
{
    MPPreviewTextCount count = [self countWithWKWebViewHTML:[self fixtureHTML]];
    [self assertCount:count words:LEGACY_FIXTURE_WORDS
           characters:LEGACY_FIXTURE_CHARACTERS
    charactersNoSpaces:LEGACY_FIXTURE_NO_SPACES
              context:@"text-count-fixture.html"];
}

- (void)testSnippetCountsMatchLegacyMeasurement
{
    NSArray<NSString *> *snippets = MPTextCountSnippets();
    NSUInteger expected[][3] = LEGACY_SNIPPET_COUNTS;
    XCTAssertEqual(sizeof(expected) / sizeof(expected[0]), snippets.count);
    for (NSUInteger i = 0; i < snippets.count; i++)
    {
        MPPreviewTextCount count = [self countWithWKWebViewHTML:snippets[i]];
        [self assertCount:count words:expected[i][0]
               characters:expected[i][1]
        charactersNoSpaces:expected[i][2]
                  context:snippets[i]];
    }
}



@end
