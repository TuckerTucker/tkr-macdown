//
//  MPRendererTests.m
//  MacDownTests
//
//  Unit and integration coverage for MPRenderer (findings TEST-1, TEST-13).
//
//  MPRenderer shipped with zero tests. These exercise the markdown -> HTML
//  pipeline driven entirely through the configurable data-source / delegate
//  stubs in Stubs/MPRendererStubs.{h,m}.
//
//  Two layers of coverage:
//    1. Unit tests against -parseMarkdown: , asserting on the renderer's
//       -currentHtml (the body fragment). This path depends only on the
//       delegate's extension/flag toggles and -rendererFlags, never on the
//       app bundle, so it is fully deterministic.
//    2. One end-to-end round-trip (TEST-13): parse + -render through a real
//       MPRenderer, asserting on the HTML handed to the delegate's
//       -renderer:didProduceHTMLOutput:.
//
//  Wave 0 set HOEDOWN_HTML_ESCAPE on MPDocument's rendererFlags, but the
//  renderer's flags here come from -rendererFlags which we set explicitly per
//  test, so these assertions are independent of that app default.
//

#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import <hoedown/document.h>
#import <hoedown/html.h>
#import "hoedown_html_patch.h"
#import "MPRenderer.h"
#import "MPPreferences.h"
#import "MPRendererStubs.h"


// -parseMarkdown: is declared in MPRenderer's private class extension. The
// production header stays clean; this test-only category re-declares the
// selector so the tests can drive parsing synchronously (the public
// -parseAndRenderNow runs on a background queue and is non-deterministic to
// assert against).
@interface MPRenderer (Testing)
- (void)parseMarkdown:(NSString *)markdown;
@end


@interface MPRendererTests : XCTestCase
@property (nonatomic, strong) MPRenderer *renderer;
@property (nonatomic, strong) MPTestRendererDataSource *dataSource;
@property (nonatomic, strong) MPTestRendererDelegate *delegate;
@end


@implementation MPRendererTests

- (void)setUp
{
    [super setUp];
    self.renderer = [[MPRenderer alloc] init];
    self.dataSource = [[MPTestRendererDataSource alloc] init];
    self.delegate = [[MPTestRendererDelegate alloc] init];
    self.renderer.dataSource = self.dataSource;
    self.renderer.delegate = self.delegate;
}

- (void)tearDown
{
    self.renderer = nil;
    self.dataSource = nil;
    self.delegate = nil;
    [super tearDown];
}

#pragma mark - Helpers

/// Parse @c markdown with the current stub configuration and return the body
/// HTML fragment produced by the renderer.
- (NSString *)bodyHTMLForMarkdown:(NSString *)markdown
{
    [self.renderer parseMarkdown:markdown];
    return self.renderer.currentHtml;
}

/// Guarantee the document template name is @c "Default" for a round-trip
/// -render, without crashing or polluting the user's real defaults.
///
/// @c htmlTemplateName is a PAPreferences @c \@dynamic property whose accessors
/// are resolved lazily by @c +resolveInstanceMethod:. The dynamic getter that
/// -render relies on (MPRenderer.m: @c preferences.htmlTemplateName) simply
/// reads the @c "htmlTemplateName" NSUserDefaults key, so writing that key
/// directly is equivalent and never depends on the setter resolving. We prefer
/// the setter only when it is actually available, and otherwise write the key
/// through NSUserDefaults. The previous value is snapshotted and restored in a
/// teardown block so real defaults are left untouched.
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

#pragma mark - Plain paragraph

- (void)testPlainParagraphProducesParagraphTag
{
    self.renderer.rendererFlags = 0;
    NSString *html = [self bodyHTMLForMarkdown:@"Just some text."];

    XCTAssertTrue([html containsString:@"<p>Just some text.</p>"],
                  @"A plain line must render as a paragraph. Got: %@", html);
}

#pragma mark - ATX headings

- (void)testATXHeadingProducesHeaderTag
{
    self.renderer.rendererFlags = 0;
    NSString *html = [self bodyHTMLForMarkdown:@"# Heading"];

    // hoedown is created with a TOC nesting level of 6, so headers carry an
    // anchor id (id="toc_0") in addition to the level tag.
    XCTAssertTrue([html containsString:@"<h1 id=\"toc_0\">Heading</h1>"],
                  @"An ATX '#' heading must render as <h1>. Got: %@", html);
}

- (void)testNestedATXHeadingLevels
{
    self.renderer.rendererFlags = 0;
    NSString *html = [self bodyHTMLForMarkdown:@"# One\n\n## Two\n\n### Three"];

    XCTAssertTrue([html containsString:@"One</h1>"], @"Got: %@", html);
    XCTAssertTrue([html containsString:@"Two</h2>"], @"Got: %@", html);
    XCTAssertTrue([html containsString:@"Three</h3>"], @"Got: %@", html);
}

#pragma mark - Fenced code blocks

- (void)testFencedCodeBlockWithExtension
{
    self.renderer.rendererFlags = 0;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;

    NSString *markdown = @"```\nlet x = 1;\n```";
    NSString *html = [self bodyHTMLForMarkdown:markdown];

    XCTAssertTrue([html containsString:@"<pre>"],
                  @"A fenced code block must render inside <pre>. Got: %@", html);
    XCTAssertTrue([html containsString:@"<code"],
                  @"A fenced code block must render a <code> element. Got: %@",
                  html);
    XCTAssertTrue([html containsString:@"let x = 1;"],
                  @"The code content must survive rendering. Got: %@", html);
}

- (void)testFencedCodeBlockIgnoredWithoutExtension
{
    self.renderer.rendererFlags = 0;
    self.delegate.extensions = 0;   // No fenced-code extension.

    NSString *markdown = @"```\nlet x = 1;\n```";
    NSString *html = [self bodyHTMLForMarkdown:markdown];

    XCTAssertFalse([html containsString:@"<pre>"],
                   @"Without the fenced-code extension the backticks must not "
                   @"produce a code block. Got: %@", html);
}

#pragma mark - Tables

- (void)testTableWithExtension
{
    self.renderer.rendererFlags = 0;
    self.delegate.extensions = HOEDOWN_EXT_TABLES;

    NSString *markdown =
        @"| A | B |\n"
        @"|---|---|\n"
        @"| 1 | 2 |\n";
    NSString *html = [self bodyHTMLForMarkdown:markdown];

    XCTAssertTrue([html containsString:@"<table>"],
                  @"With the tables extension, pipe syntax must render a "
                  @"<table>. Got: %@", html);
    XCTAssertTrue([html containsString:@"<th>A</th>"],
                  @"Table header cells must render. Got: %@", html);
    XCTAssertTrue([html containsString:@"<td>1</td>"],
                  @"Table body cells must render. Got: %@", html);
}

- (void)testTableIgnoredWithoutExtension
{
    self.renderer.rendererFlags = 0;
    self.delegate.extensions = 0;   // No tables extension.

    NSString *markdown =
        @"| A | B |\n"
        @"|---|---|\n"
        @"| 1 | 2 |\n";
    NSString *html = [self bodyHTMLForMarkdown:markdown];

    XCTAssertFalse([html containsString:@"<table>"],
                   @"Without the tables extension, pipe syntax must not render "
                   @"a table. Got: %@", html);
}

#pragma mark - SmartyPants

- (void)testSmartyPantsEnabledSubstitutesEllipsis
{
    self.renderer.rendererFlags = 0;
    self.delegate.hasSmartyPants = YES;

    NSString *html = [self bodyHTMLForMarkdown:@"Wait..."];

    XCTAssertTrue([html containsString:@"&hellip;"],
                  @"SmartyPants must convert '...' to an ellipsis entity. "
                  @"Got: %@", html);
}

- (void)testSmartyPantsDisabledLeavesLiteralPunctuation
{
    self.renderer.rendererFlags = 0;
    self.delegate.hasSmartyPants = NO;

    NSString *html = [self bodyHTMLForMarkdown:@"Wait..."];

    XCTAssertFalse([html containsString:@"&hellip;"],
                   @"With SmartyPants off, '...' must stay literal. Got: %@",
                   html);
    XCTAssertTrue([html containsString:@"Wait..."],
                  @"The literal punctuation must survive. Got: %@", html);
}

#pragma mark - Front matter

- (void)testFrontMatterDetectedAndTabularized
{
    self.renderer.rendererFlags = 0;
    self.delegate.detectsFrontMatter = YES;

    NSString *markdown =
        @"---\n"
        @"title: Hello\n"
        @"---\n"
        @"\n"
        @"# Body\n";
    NSString *html = [self bodyHTMLForMarkdown:markdown];

    // Parsed front matter is rendered as an HTML table prepended to the body.
    XCTAssertTrue([html containsString:@"<table>"],
                  @"Detected front matter must be tabularized. Got: %@", html);
    XCTAssertTrue([html containsString:@"title"],
                  @"The front-matter key must appear in the table. Got: %@",
                  html);
    XCTAssertTrue([html containsString:@"Body</h1>"],
                  @"The body after the front matter must still render. "
                  @"Got: %@", html);
}

- (void)testFrontMatterNotDetectedWhenDisabled
{
    self.renderer.rendererFlags = 0;
    self.delegate.detectsFrontMatter = NO;

    NSString *markdown =
        @"---\n"
        @"title: Hello\n"
        @"---\n"
        @"\n"
        @"# Body\n";
    NSString *html = [self bodyHTMLForMarkdown:markdown];

    XCTAssertFalse([html containsString:@"<table>"],
                   @"With front-matter detection off, the leading block must "
                   @"not be tabularized. Got: %@", html);
}

#pragma mark - rendererFlags (HTML escape)

- (void)testRendererFlagsControlHTMLEscaping
{
    // With HOEDOWN_HTML_ESCAPE, raw inline HTML must be escaped rather than
    // passed through. This proves the flag is sourced from -rendererFlags and
    // is independent of any app-level default.
    self.renderer.rendererFlags = HOEDOWN_HTML_ESCAPE;
    NSString *escaped = [self bodyHTMLForMarkdown:@"<b>hi</b>"];
    XCTAssertTrue([escaped containsString:@"&lt;b&gt;"],
                  @"HOEDOWN_HTML_ESCAPE must escape raw HTML. Got: %@", escaped);

    self.renderer.rendererFlags = 0;
    NSString *passed = [self bodyHTMLForMarkdown:@"<b>hi</b>"];
    XCTAssertTrue([passed containsString:@"<b>hi</b>"],
                  @"Without the escape flag, raw HTML must pass through. "
                  @"Got: %@", passed);
}

#pragma mark - TEST-13: end-to-end round-trip

- (void)testRoundTripDeliversFullDocumentToDelegate
{
    // Keep all asset toggles off and the style name nil so -render does not
    // depend on Prism/MathJax/mermaid resources or a named CSS file; the
    // handlebars document template is resolved from the app TEST_HOST bundle.
    self.renderer.rendererFlags = 0;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE | HOEDOWN_EXT_TABLES;
    self.delegate.styleName = nil;
    // Pin a known-good document template so the first -render in the test
    // process resolves the handlebars template from the host bundle. Done
    // defensively (see -pinDefaultHTMLTemplate) so the lazily-resolved dynamic
    // setter can never throw an unrecognized-selector exception.
    [self pinDefaultHTMLTemplate];
    self.dataSource.htmlTitle = @"Round Trip";
    self.dataSource.markdown =
        @"# Title\n"
        @"\n"
        @"A paragraph.\n"
        @"\n"
        @"| A | B |\n"
        @"|---|---|\n"
        @"| 1 | 2 |\n";

    // Drive the real pipeline synchronously: parse the markdown the data
    // source supplies, then render the full document to the delegate.
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertTrue(self.delegate.didProduceHTML,
                  @"The delegate must receive the produced HTML output.");
    XCTAssertEqual(self.delegate.produceCount, (NSUInteger)1,
                   @"render must call the delegate exactly once.");

    NSString *html = self.delegate.capturedHTML;
    XCTAssertNotNil(html, @"Captured HTML must not be nil.");

    // Full document wrapper from the handlebars template.
    XCTAssertTrue([html containsString:@"<html"],
                  @"Output must be a full HTML document. Got: %@", html);
    XCTAssertTrue([html containsString:@"<title>Round Trip</title>"],
                  @"The document title must come from the data source. "
                  @"Got: %@", html);

    // The rendered body structures must be embedded in the document.
    XCTAssertTrue([html containsString:@"Title</h1>"],
                  @"Heading must be present in the round-trip output.");
    XCTAssertTrue([html containsString:@"<p>A paragraph.</p>"],
                  @"Paragraph must be present in the round-trip output.");
    XCTAssertTrue([html containsString:@"<table>"],
                  @"Table must be present in the round-trip output.");
}

- (void)testRoundTripCurrentHtmlMatchesDeliveredBody
{
    self.renderer.rendererFlags = 0;
    [self pinDefaultHTMLTemplate];
    self.dataSource.markdown = @"Hello world.";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *body = self.renderer.currentHtml;
    [self.renderer render];

    XCTAssertTrue([body containsString:@"<p>Hello world.</p>"],
                  @"Body fragment must contain the paragraph. Got: %@", body);
    XCTAssertTrue([self.delegate.capturedHTML containsString:body],
                  @"The delivered document must embed the parsed body fragment.");
}

#pragma mark - Preview vs export assets (Wave 3c; TB-7, TM-7)

/// Every <script ...> opening tag in @c html.
- (NSArray<NSString *> *)scriptTagsInHTML:(NSString *)html
{
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"<script\\b[^>]*>"
                                                  options:0 error:NULL];
    NSMutableArray *tags = [NSMutableArray array];
    for (NSTextCheckingResult *match in
         [regex matchesInString:html options:0
                          range:NSMakeRange(0, html.length)])
        [tags addObject:[html substringWithRange:match.range]];
    return tags;
}

- (void)configureMathJaxDocument
{
    self.renderer.rendererFlags = 0;
    self.delegate.extensions = HOEDOWN_EXT_MATH | HOEDOWN_EXT_MATH_EXPLICIT;
    self.delegate.hasMathJax = YES;
    [self pinDefaultHTMLTemplate];
    self.dataSource.markdown = @"Inline $E=mc^2$.\n\n$$x^2$$\n";
    [self.renderer parseMarkdown:self.dataSource.markdown];
}

- (void)testPreviewWithMathJaxHasNoInlineScriptAndLocalMathJax
{
    [self configureMathJaxDocument];
    // Exercise every script source the preview can include.
    self.delegate.hasSyntaxHighlighting = YES;
    self.delegate.hasMermaid = YES;
    self.delegate.hasGraphviz = YES;
    self.renderer.rendererFlags = HOEDOWN_HTML_USE_TASK_LIST;
    [self.renderer render];
    NSString *html = self.delegate.capturedHTML;

    NSArray *tags = [self scriptTagsInHTML:html];
    XCTAssertGreaterThan(tags.count, (NSUInteger)2, @"%@", html);
    for (NSString *tag in tags)
    {
        XCTAssertTrue([tag containsString:@" src=\"x-macdown-asset:///"],
                      @"Preview scripts must be external, local assets "
                      @"(the CSP blocks inline and remote scripts): %@", tag);
    }

    NSString *initTag = nil;
    NSString *mathjaxTag = nil;
    for (NSString *tag in tags)
    {
        if ([tag containsString:@"/MathJax/init.js\""])
            initTag = tag;
        if ([tag containsString:@"/MathJax/es5/tex-mml-chtml.js\""])
            mathjaxTag = tag;
    }
    XCTAssertNotNil(initTag, @"%@", html);
    XCTAssertNotNil(mathjaxTag, @"%@", html);
    XCTAssertLessThan([tags indexOfObject:initTag],
                      [tags indexOfObject:mathjaxTag],
                      @"The configuration must load before MathJax.");

    XCTAssertFalse([html containsString:@"file:"], @"%@", html);
    XCTAssertFalse([html containsString:@"cdnjs"], @"%@", html);
    XCTAssertFalse([html containsString:@"jsdelivr"], @"%@", html);
    XCTAssertFalse([html containsString:@"x-mathjax-config"], @"%@", html);
    XCTAssertTrue([html containsString:@"\\(E=mc^2\\)"], @"%@", html);
    XCTAssertTrue([html containsString:@"\\[x^2\\]"], @"%@", html);
}

- (void)testPreviewStylesheetsUseAssetScheme
{
    self.renderer.rendererFlags = 0;
    self.delegate.hasSyntaxHighlighting = YES;
    self.delegate.highlightingThemeName = @"tomorrow";
    [self pinDefaultHTMLTemplate];
    [self.renderer parseMarkdown:@"text"];
    [self.renderer render];
    NSString *html = self.delegate.capturedHTML;

    XCTAssertTrue([html containsString:@"<link rel=\"stylesheet\""], @"%@",
                  html);
    XCTAssertTrue([html containsString:@"href=\"x-macdown-asset:///"], @"%@",
                  html);
    XCTAssertFalse([html containsString:@"file:"], @"%@", html);
}

- (void)testVendoredMathJaxIsInTheAppBundle
{
    NSBundle *bundle = [NSBundle mainBundle];
    XCTAssertNotNil([bundle URLForResource:@"tex-mml-chtml" withExtension:@"js"
                              subdirectory:@"MathJax/es5"]);
    XCTAssertNotNil([bundle URLForResource:@"init" withExtension:@"js"
                              subdirectory:@"MathJax"]);
    XCTAssertNotNil([bundle URLForResource:@"MathJax_Main-Regular"
                             withExtension:@"woff"
                              subdirectory:@"MathJax/es5/output/chtml/fonts/"
                                           @"woff-v2"]);
    XCTAssertNotNil([bundle URLForResource:@"noerrors" withExtension:@"js"
                              subdirectory:@"MathJax/es5/input/tex/"
                                           @"extensions"]);
    XCTAssertNil([bundle URLForResource:@"MathJax" withExtension:@"js"
                           subdirectory:@"MathJax"],
                 @"MathJax 2 must be gone.");
}

- (void)testExportWithMathJaxUsesPinnedCDNWithIntegrity
{
    [self configureMathJaxDocument];
    NSString *html = [self.renderer HTMLForExportWithStyles:YES
                                               highlighting:NO];

    NSString *expected =
        @"<script type=\"text/javascript\" "
        @"src=\"https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/"
        @"tex-mml-chtml.js\" integrity=\"sha384-Wuix6BuhrWbjDBs24bXrjf4ZQ5aF"
        @"eFWBuKkFekO2t8xFU0iNaLQfp2K6/1Nxveei\" crossorigin=\"anonymous\">"
        @"</script>";
    XCTAssertTrue([html containsString:expected], @"%@", html);

    // The configuration is inlined (export must not depend on the bundle)
    // and precedes MathJax.
    NSRange config = [html rangeOfString:@"window.MathJax = {"];
    XCTAssertNotEqual(config.location, NSNotFound, @"%@", html);
    XCTAssertLessThan(config.location, [html rangeOfString:expected].location);
    XCTAssertFalse([html containsString:@"x-mathjax-config"], @"%@", html);
    // No attribute may reference the preview-only scheme (init.js's inlined
    // comments name it, which is harmless).
    XCTAssertFalse([html containsString:@"=\"x-macdown-asset:"], @"%@", html);
    XCTAssertFalse([html containsString:@"cdnjs"], @"%@", html);
}

- (void)testIntegrityMatchesVendoredMathJax
{
    // The export's SRI value must describe the file that is vendored; this
    // fails when one is updated without the other.
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"tex-mml-chtml"
                                         withExtension:@"js"
                                          subdirectory:@"MathJax/es5"];
    NSData *data = [NSData dataWithContentsOfURL:url];
    XCTAssertNotNil(data);
    unsigned char digest[CC_SHA384_DIGEST_LENGTH];
    CC_SHA384(data.bytes, (CC_LONG)data.length, digest);
    NSData *hash = [NSData dataWithBytes:digest length:sizeof(digest)];
    NSString *sri = [@"sha384-" stringByAppendingString:
                     [hash base64EncodedStringWithOptions:0]];

    [self configureMathJaxDocument];
    NSString *html = [self.renderer HTMLForExportWithStyles:NO
                                               highlighting:NO];
    NSString *attribute =
        [NSString stringWithFormat:@"integrity=\"%@\"", sri];
    XCTAssertTrue([html containsString:attribute], @"%@ not in %@", sri, html);
}

- (void)testNoCdnjsInAnyOutput
{
    [self configureMathJaxDocument];
    self.delegate.hasSyntaxHighlighting = YES;
    [self.renderer render];
    XCTAssertFalse([self.delegate.capturedHTML containsString:@"cdnjs"]);
    XCTAssertFalse([[self.renderer HTMLForExportWithStyles:YES
                                              highlighting:YES]
                    containsString:@"cdnjs"]);
}

@end
