//
//  MPAssetTests.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 13/7.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import <XCTest/XCTest.h>
#import "MPAsset.h"


@interface MPAsset ()
@property (readonly, nonatomic) NSString *typeName;
@end


@interface MPAssetTests : XCTestCase
@property (strong) NSBundle *bundle;
@end


@implementation MPAssetTests

- (void)setUp
{
    [super setUp];
    self.bundle = [NSBundle bundleForClass:[self class]];
}

- (void)testDefaultAssetType
{
    MPAsset *asset = [[MPAsset alloc] init];
    XCTAssertEqualObjects(asset.typeName, @"text/plain");

    MPStyleSheet *css = [[MPStyleSheet alloc] init];
    XCTAssertEqualObjects(css.typeName, @"text/css");

    MPScript *script = [[MPScript alloc] init];
    XCTAssertEqualObjects(script.typeName, @"text/javascript");
}

- (void)testAssetNone
{
    XCTAssertNil([[[MPScript alloc] init] htmlForOption:MPAssetNone],
                 @"Init and NULL rendering");
}

- (void)testAssetConvinienceAndEmbedded
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"txt"];
    MPScript *script = [MPScript assetWithURL:url andType:@"text/plain"];

    NSString *expected =
        @"<script type=\"text/plain\">\nFoobar\n</script>";
    XCTAssertEqualObjects([script htmlForOption:MPAssetEmbedded], expected,
                          @"Convinience and embedded");
}

- (void)testAssetInitAndFullLink
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"txt"];
    MPScript *script = [[MPScript alloc] initWithURL:url
                                             andType:@"text/plain"];
    NSString *expected = @"<script type=\"text/plain\" src=\"%@\"></script>";
    expected = [NSString stringWithFormat:expected, url.absoluteString];
    XCTAssertEqualObjects([script htmlForOption:MPAssetFullLink], expected,
                          @"Convinience and full link");

}

- (void)testCSS
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"css"];
    MPStyleSheet *ss = [MPStyleSheet CSSWithURL:url];

    NSString *linkTag =
        @"<link rel=\"stylesheet\" type=\"text/css\" href=\"%@\">";
    linkTag = [NSString stringWithFormat:linkTag, url.absoluteString];
    NSString *styleTag =
        @"<style type=\"text/css\">\nbody { font-size: 15px; }\n</style>";
    XCTAssertNil([ss htmlForOption:MPAssetNone], @"CSS, NULL rendering");
    XCTAssertEqualObjects([ss htmlForOption:MPAssetEmbedded], styleTag,
                          @"CSS, embedded");
    XCTAssertEqualObjects([ss htmlForOption:MPAssetFullLink], linkTag,
                          @"CSS, full link");
}

- (void)testJavaScript
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"js"];
    MPScript *script = [MPScript javaScriptWithURL:url];

    NSString *linkedTag =
        @"<script type=\"text/javascript\" src=\"%@\"></script>";
    linkedTag = [NSString stringWithFormat:linkedTag, url.absoluteString];
    NSString *embeddedTag =
        @"<script type=\"text/javascript\">\nconsole.log('test');\n</script>";
    XCTAssertNil([script htmlForOption:MPAssetNone], @"JS, NULL rendering");
    XCTAssertEqualObjects([script htmlForOption:MPAssetEmbedded], embeddedTag,
                          @"JS, embedded");
    XCTAssertEqualObjects([script htmlForOption:MPAssetFullLink], linkedTag,
                          @"JS, full link");
}

- (void)testEmbedded
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"js"];
    MPEmbeddedScript *script =
        [MPEmbeddedScript assetWithURL:url andType:kMPJavaScriptType];

    NSString *tag = @"<script type=\"text/javascript\">\n"
                    @"console.log('test');\n</script>";
    XCTAssertNil([script htmlForOption:MPAssetNone], @"JS, NULL rendering");
    XCTAssertEqualObjects([script htmlForOption:MPAssetEmbedded], tag,
                          @"Embedded");
    XCTAssertEqualObjects([script htmlForOption:MPAssetFullLink], tag,
                          @"Forced embedded");
}

#pragma mark - Preview links (WKWebView asset scheme)

- (void)testPreviewLinkEmitsAssetSchemeForFileURL
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"js"];
    MPScript *script = [MPScript javaScriptWithURL:url];

    NSString *html = [script htmlForOption:MPAssetPreviewLink];
    NSURL *previewURL = [MPAsset previewURLForURL:url];
    NSString *expected = [NSString stringWithFormat:
        @"<script type=\"text/javascript\" src=\"%@\"></script>",
        previewURL.absoluteString];
    XCTAssertEqualObjects(html, expected);
    XCTAssertTrue([previewURL.absoluteString hasPrefix:@"x-macdown-asset:///"],
                  @"%@", previewURL);
    XCTAssertEqualObjects(previewURL.path, url.path,
                          @"The preview URL must carry the absolute path.");
    XCTAssertFalse([html containsString:@"file:"], @"%@", html);
}

- (void)testPreviewURLPercentEncodesSpacesAndUnicode
{
    // Need not exist: the URL is built, never read.
    NSString *path = @"/Users/Shared/Mac Down/ünïcöde #1?.css";
    NSURL *url = [NSURL fileURLWithPath:path];

    NSURL *previewURL = [MPAsset previewURLForURL:url];
    // File URLs carry the file-system representation, which is decomposed
    // (NFD): u + U+0308 COMBINING DIAERESIS rather than precomposed U+00FC.
    XCTAssertEqualObjects(
        previewURL.absoluteString,
        @"x-macdown-asset:///Users/Shared/Mac%20Down/"
        @"u%CC%88ni%CC%88co%CC%88de%20%231%3F.css");
    XCTAssertEqualObjects(previewURL.scheme, @"x-macdown-asset");
    XCTAssertEqualObjects(previewURL.path, url.path,
                          @"Decoding must round-trip to the file URL's path.");
    XCTAssertEqualObjects(previewURL.path.precomposedStringWithCanonicalMapping,
                          path.precomposedStringWithCanonicalMapping);

    MPStyleSheet *css = [MPStyleSheet CSSWithURL:url];
    NSString *expected = [NSString stringWithFormat:
        @"<link rel=\"stylesheet\" type=\"text/css\" href=\"%@\">",
        previewURL.absoluteString];
    XCTAssertEqualObjects([css htmlForOption:MPAssetPreviewLink], expected);
}

- (void)testPreviewLinkPassesNonFileURLsThrough
{
    NSURL *url = [NSURL URLWithString:@"https://example.com/a.js?x=1&y=2"];
    XCTAssertEqualObjects([MPAsset previewURLForURL:url], url);

    MPScript *script = [MPScript javaScriptWithURL:url];
    XCTAssertEqualObjects([script htmlForOption:MPAssetPreviewLink],
                          [script htmlForOption:MPAssetFullLink]);
    XCTAssertEqualObjects(
        [script htmlForOption:MPAssetPreviewLink],
        @"<script type=\"text/javascript\" "
        @"src=\"https://example.com/a.js?x=1&amp;y=2\"></script>");
    XCTAssertNil([MPAsset previewURLForURL:nil]);
}

- (void)testFullLinkUnchangedByPreviewSupport
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"js"];
    MPScript *script = [MPScript javaScriptWithURL:url];
    XCTAssertTrue([[script htmlForOption:MPAssetFullLink]
                      containsString:url.absoluteString],
                  @"Export links must keep their file: URL.");
}

- (void)testEmbeddedScriptIsInlinedEvenForPreviewLink
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"js"];
    MPEmbeddedScript *script =
        [MPEmbeddedScript assetWithURL:url andType:kMPJavaScriptType];
    XCTAssertEqualObjects([script htmlForOption:MPAssetPreviewLink],
                          [script htmlForOption:MPAssetEmbedded]);
}

#pragma mark - Subresource Integrity

- (void)testIntegrityRendersOnLinkedScripts
{
    NSURL *url = [NSURL URLWithString:@"https://cdn.example/x.js"];
    MPScript *script =
        [MPScript javaScriptWithURL:url integrity:@"sha384-ab+c/d=="];
    XCTAssertEqualObjects(script.integrity, @"sha384-ab+c/d==");

    NSString *expected =
        @"<script type=\"text/javascript\" src=\"https://cdn.example/x.js\" "
        @"integrity=\"sha384-ab+c/d==\" crossorigin=\"anonymous\"></script>";
    XCTAssertEqualObjects([script htmlForOption:MPAssetFullLink], expected);
    XCTAssertEqualObjects([script htmlForOption:MPAssetPreviewLink], expected);
    // Export embeds scripts; a remote script falls back to a link and must
    // keep its integrity.
    XCTAssertEqualObjects([script htmlForOption:MPAssetEmbedded], expected);
}

- (void)testIntegrityAbsentWithoutValue
{
    NSURL *url = [NSURL URLWithString:@"https://cdn.example/x.js"];
    MPScript *script = [MPScript javaScriptWithURL:url integrity:nil];
    XCTAssertNil(script.integrity);
    XCTAssertFalse([[script htmlForOption:MPAssetFullLink]
                       containsString:@"integrity"]);
    XCTAssertFalse([[script htmlForOption:MPAssetFullLink]
                       containsString:@"crossorigin"]);
}

- (void)testIntegrityNotEmittedOnInlinedContent
{
    NSURL *url = [self.bundle URLForResource:@"test" withExtension:@"js"];
    MPScript *script = [MPScript javaScriptWithURL:url integrity:@"sha384-x"];
    XCTAssertEqualObjects(
        [script htmlForOption:MPAssetEmbedded],
        @"<script type=\"text/javascript\">\nconsole.log('test');\n</script>");
}

@end
