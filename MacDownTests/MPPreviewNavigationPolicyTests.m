//
//  MPPreviewNavigationPolicyTests.m
//  MacDownTests
//
//  Covers the preview navigation policy (#1050, TM-1/TB-1). Logic tests
//  inject the code-bearing predicate; the default predicate is tested
//  against real files on disk.
//

#import <XCTest/XCTest.h>
#import "MPPreviewNavigationPolicy.h"


static NSString * const kDocURL = @"x-macdown-file:///Users/a/Notes/doc.md";
static NSString * const kPoCBackslash =
    @"file:\\\\\\Applications\\Calculator.app";
static NSString * const kPoCFile = @"file:///Applications/Calculator.app";
static NSString * const kPoCPreview =
    @"x-macdown-file:///Applications/Calculator.app";

static const WKNavigationType kNonLinkTypes[] = {
    WKNavigationTypeOther, WKNavigationTypeFormSubmitted,
    WKNavigationTypeBackForward, WKNavigationTypeReload,
    WKNavigationTypeFormResubmitted,
};


@interface MPPreviewNavigationPolicyTests : XCTestCase
@property (strong) NSMutableArray<NSURL *> *checkedURLs;
@property (strong) MPPreviewNavigationPolicy *yesPolicy;
@property (strong) MPPreviewNavigationPolicy *noPolicy;
@property (strong) MPPreviewNavigationPolicy *defaultPolicy;
@property (strong) NSURL *tempDirectory;
@end


@implementation MPPreviewNavigationPolicyTests

- (void)setUp
{
    [super setUp];
    NSMutableArray *checked = [NSMutableArray array];
    self.checkedURLs = checked;
    self.yesPolicy = [[MPPreviewNavigationPolicy alloc]
        initWithCodeBearingPredicate:^BOOL(NSURL *url) {
            [checked addObject:url];
            return YES;
        }];
    self.noPolicy = [[MPPreviewNavigationPolicy alloc]
        initWithCodeBearingPredicate:^BOOL(NSURL *url) {
            [checked addObject:url];
            return NO;
        }];
    self.defaultPolicy = [[MPPreviewNavigationPolicy alloc] init];

    NSString *name = [NSString stringWithFormat:@"MPNavPolicy-%@",
                      [NSUUID UUID].UUIDString];
    self.tempDirectory = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                                    isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.tempDirectory
                             withIntermediateDirectories:YES attributes:nil
                                                   error:NULL];
}

- (void)tearDown
{
    [[NSFileManager defaultManager] removeItemAtURL:self.tempDirectory
                                              error:NULL];
    [super tearDown];
}


#pragma mark - Helpers

- (MPPreviewNavigationDecision *)decide:(MPPreviewNavigationPolicy *)policy
                                    url:(NSString *)string
                                   type:(WKNavigationType)type
                              mainFrame:(BOOL)mainFrame
{
    NSURL *url = string ? [NSURL URLWithString:string] : nil;
    return [policy decisionForURL:url navigationType:type
                      isMainFrame:mainFrame
                       sourceIsMainFrame:YES
                       currentURL:[NSURL URLWithString:kDocURL]];
}

- (MPPreviewNavigationDecision *)click:(MPPreviewNavigationPolicy *)policy
                                   url:(NSString *)string
{
    return [self decide:policy url:string type:WKNavigationTypeLinkActivated
              mainFrame:YES];
}

- (NSURL *)writeFile:(NSString *)name contents:(NSString *)contents
{
    NSURL *url = [self.tempDirectory URLByAppendingPathComponent:name];
    BOOL ok = [contents writeToURL:url atomically:YES
                          encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertTrue(ok, @"Could not write fixture %@", name);
    return url;
}

- (void)setExecutable:(BOOL)executable atURL:(NSURL *)url
{
    NSDictionary *attributes =
        @{NSFilePosixPermissions: executable ? @0755 : @0644};
    BOOL ok = [[NSFileManager defaultManager] setAttributes:attributes
                                               ofItemAtPath:url.path
                                                      error:NULL];
    XCTAssertTrue(ok, @"Could not chmod %@", url.path);
}

- (NSURL *)writeAliasTo:(NSURL *)target named:(NSString *)name
{
    NSURL *alias = [self.tempDirectory URLByAppendingPathComponent:name];
    NSError *error = nil;
    NSData *data = [target
        bookmarkDataWithOptions:NSURLBookmarkCreationSuitableForBookmarkFile
 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    XCTAssertNotNil(data, @"%@", error);
    BOOL ok = [NSURL writeBookmarkData:data toURL:alias
        options:NSURLBookmarkCreationSuitableForBookmarkFile error:&error];
    XCTAssertTrue(ok, @"%@", error);
    return alias;
}


#pragma mark - #1050 proof of concept

- (void)testBackslashPoCAsParsedByNSURLHasNoPathAndCancels
{
    NSURL *url = [NSURL URLWithString:kPoCBackslash];
    XCTAssertNotNil(url);
    XCTAssertEqualObjects(url.scheme, @"file");
    XCTAssertNil(url.path, @"NSURL percent-encodes the backslashes");

    MPPreviewNavigationDecision *d = [self click:self.noPolicy
                                             url:kPoCBackslash];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);
    XCTAssertNil(d.targetURL);
}

- (void)testNormalizedPoCFileLinkRevealsWithDefaultPredicate
{
    MPPreviewNavigationDecision *d = [self click:self.defaultPolicy
                                             url:kPoCFile];
    XCTAssertEqual(d.action, MPPreviewNavigationActionReveal, @"%@", d);
    XCTAssertEqualObjects(d.targetURL,
        [NSURL fileURLWithPath:@"/Applications/Calculator.app"]);
}

- (void)testNormalizedPoCPreviewLinkRevealsWithDefaultPredicate
{
    MPPreviewNavigationDecision *d = [self click:self.defaultPolicy
                                             url:kPoCPreview];
    XCTAssertEqual(d.action, MPPreviewNavigationActionReveal, @"%@", d);
    XCTAssertTrue(d.targetURL.isFileURL);
    XCTAssertEqualObjects(d.targetURL.path, @"/Applications/Calculator.app");
}

- (void)testExistingSystemAppLinkReveals
{
    NSString *string = @"file:///System/Applications/Calculator.app";
    MPPreviewNavigationDecision *d = [self click:self.defaultPolicy
                                             url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionReveal, @"%@", d);
}

- (void)testPoCWithNonLinkNavigationCancelsWithoutConsultingPredicate
{
    for (size_t i = 0; i < sizeof(kNonLinkTypes) / sizeof(*kNonLinkTypes); i++)
    {
        for (NSString *string in @[kPoCFile, kPoCPreview])
        {
            MPPreviewNavigationDecision *d = [self decide:self.noPolicy
                url:string type:kNonLinkTypes[i] mainFrame:YES];
            XCTAssertEqual(d.action, MPPreviewNavigationActionCancel,
                           @"type %ld %@ -> %@", (long)kNonLinkTypes[i],
                           string, d);
        }
    }
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}


#pragma mark - Rule 1: malformed

- (void)testNilURLCancels
{
    MPPreviewNavigationDecision *d = [self click:self.noPolicy url:nil];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel);
}

- (void)testSchemelessURLCancels
{
    MPPreviewNavigationDecision *d = [self click:self.noPolicy
                                             url:@"other.md"];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel);
}

- (void)testLocalURLWithRemoteHostCancels
{
    NSString *string = @"file://evil.example/Users/a/other.md";
    MPPreviewNavigationDecision *d = [self click:self.noPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);

    string = @"x-macdown-file://evil.example/Users/a/other.md";
    d = [self click:self.noPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);
}

- (void)testLocalhostFileURLOpens
{
    NSString *string = @"file://localhost/Users/a/other.md";
    MPPreviewNavigationDecision *d = [self click:self.noPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionOpen, @"%@", d);
    XCTAssertEqualObjects(d.targetURL.path, @"/Users/a/other.md");
}


#pragma mark - Rule 2: subframes

- (void)testSubframeWebAndBlankAllowed
{
    NSArray *allowed = @[
        @"https://example.com/embed", @"http://example.com/x",
        @"about:blank", @"about:srcdoc",
    ];
    for (NSString *string in allowed)
    {
        MPPreviewNavigationDecision *d = [self decide:self.noPolicy
            url:string type:WKNavigationTypeOther mainFrame:NO];
        XCTAssertEqual(d.action, MPPreviewNavigationActionAllow,
                       @"%@ -> %@", string, d);
    }
}

- (void)testSubframeEverythingElseCancelled
{
    NSArray *cancelled = @[
        kPoCFile, kPoCPreview, kDocURL, @"file:///Users/a/other.md",
        @"x-macdown-asset:///Applications/MacDown.app/x.js",
        @"data:text/html,<b>x</b>", @"javascript:alert(1)",
        @"about:config", @"vscode://file/etc/passwd",
    ];
    for (NSString *string in cancelled)
    {
        for (NSNumber *type in @[@(WKNavigationTypeOther),
                                 @(WKNavigationTypeLinkActivated)])
        {
            MPPreviewNavigationDecision *d = [self decide:self.noPolicy
                url:string type:type.integerValue mainFrame:NO];
            XCTAssertEqual(d.action, MPPreviewNavigationActionCancel,
                           @"%@ -> %@", string, d);
        }
    }
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}


#pragma mark - Rule 3: same document

- (void)testInitialLoadOfCurrentDocumentAllowed
{
    MPPreviewNavigationDecision *d = [self decide:self.yesPolicy url:kDocURL
        type:WKNavigationTypeOther mainFrame:YES];
    XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);
}

- (void)testReloadAndBackForwardOfCurrentDocumentAllowed
{
    for (NSNumber *type in @[@(WKNavigationTypeReload),
                             @(WKNavigationTypeBackForward)])
    {
        MPPreviewNavigationDecision *d = [self decide:self.yesPolicy
            url:[kDocURL stringByAppendingString:@"#top"]
            type:type.integerValue mainFrame:YES];
        XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);
    }
}

- (void)testSameDocumentFragmentLinkAllowed
{
    NSString *string = [kDocURL stringByAppendingString:@"#section-2"];
    MPPreviewNavigationDecision *d = [self click:self.yesPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}

- (void)testSameDocumentQueryIgnored
{
    NSString *string = [kDocURL stringByAppendingString:@"?x=1#a"];
    MPPreviewNavigationDecision *d = [self click:self.yesPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);
}

- (void)testSameDocumentComparesDecodedPath
{
    NSURL *current =
        [NSURL URLWithString:@"x-macdown-file:///Users/a/My%20Notes.md"];
    NSURL *url = [NSURL URLWithString:
        @"x-macdown-file:///Users/a/./My%20Notes.md#h"];
    MPPreviewNavigationDecision *d = [self.yesPolicy decisionForURL:url
        navigationType:WKNavigationTypeLinkActivated isMainFrame:YES
        sourceIsMainFrame:YES
        currentURL:current];
    XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);
}

- (void)testIdenticalURLLinkCancelled
{
    MPPreviewNavigationDecision *d = [self click:self.yesPolicy url:kDocURL];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}

- (void)testUnsavedDocumentDirectoryBase
{
    NSURL *base = [NSURL URLWithString:@"x-macdown-file:///Users/a/Documents/"];
    NSURL *url = [NSURL URLWithString:
        @"x-macdown-file:///Users/a/Documents/#intro"];
    MPPreviewNavigationDecision *d = [self.noPolicy decisionForURL:base
        navigationType:WKNavigationTypeOther isMainFrame:YES
                    sourceIsMainFrame:YES currentURL:base];
    XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);

    d = [self.noPolicy decisionForURL:url
                       navigationType:WKNavigationTypeLinkActivated
                          isMainFrame:YES
                    sourceIsMainFrame:YES currentURL:base];
    XCTAssertEqual(d.action, MPPreviewNavigationActionAllow, @"%@", d);

    url = [NSURL URLWithString:@"x-macdown-file:///Users/a/Documents/b.md"];
    d = [self.noPolicy decisionForURL:url
                       navigationType:WKNavigationTypeLinkActivated
                          isMainFrame:YES
                    sourceIsMainFrame:YES currentURL:base];
    XCTAssertEqual(d.action, MPPreviewNavigationActionOpen, @"%@", d);
}

- (void)testSamePathUnderOtherSchemeIsNotSameDocument
{
    MPPreviewNavigationDecision *d = [self decide:self.noPolicy
        url:@"file:///Users/a/Notes/doc.md" type:WKNavigationTypeOther
        mainFrame:YES];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);
}


#pragma mark - Rule 4: non-link navigation elsewhere

- (void)testMetaRefreshToWebCancelled
{
    MPPreviewNavigationDecision *d = [self decide:self.noPolicy
        url:@"https://evil.example/payload" type:WKNavigationTypeOther
        mainFrame:YES];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);
    XCTAssertNil(d.targetURL);
}

- (void)testEveryNonLinkTypeToOtherTargetsCancelled
{
    NSArray *targets = @[
        @"https://example.com", @"mailto:a@example.com",
        @"x-macdown-file:///Users/a/other.md", @"vscode://file/x",
    ];
    for (size_t i = 0; i < sizeof(kNonLinkTypes) / sizeof(*kNonLinkTypes); i++)
    {
        for (NSString *string in targets)
        {
            MPPreviewNavigationDecision *d = [self decide:self.noPolicy
                url:string type:kNonLinkTypes[i] mainFrame:YES];
            XCTAssertEqual(d.action, MPPreviewNavigationActionCancel,
                           @"type %ld %@ -> %@", (long)kNonLinkTypes[i],
                           string, d);
        }
    }
}

- (void)testNilCurrentURLStillCancelsNonLink
{
    NSURL *url = [NSURL URLWithString:kDocURL];
    MPPreviewNavigationDecision *d = [self.noPolicy decisionForURL:url
        navigationType:WKNavigationTypeOther isMainFrame:YES
        sourceIsMainFrame:YES currentURL:nil];
    XCTAssertEqual(d.action, MPPreviewNavigationActionCancel, @"%@", d);
}


#pragma mark - Rule 5: link activation elsewhere

- (void)testLocalLinkOpensWhenNotCodeBearing
{
    NSString *string = @"x-macdown-file:///Users/a/Notes/other.md#part";
    MPPreviewNavigationDecision *d = [self click:self.noPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionOpen, @"%@", d);
    XCTAssertEqualObjects(d.targetURL,
        [NSURL fileURLWithPath:@"/Users/a/Notes/other.md" isDirectory:NO]);
    XCTAssertEqualObjects(self.checkedURLs, @[d.targetURL],
                          @"Predicate sees the translated file URL");
}

- (void)testLocalLinkRevealsWhenCodeBearing
{
    for (NSString *string in @[@"x-macdown-file:///Users/a/Notes/other.md",
                               @"file:///Users/a/Notes/other.md"])
    {
        MPPreviewNavigationDecision *d = [self click:self.yesPolicy
                                                 url:string];
        XCTAssertEqual(d.action, MPPreviewNavigationActionReveal, @"%@", d);
        XCTAssertEqualObjects(d.targetURL.path, @"/Users/a/Notes/other.md");
        XCTAssertTrue(d.targetURL.isFileURL);
    }
}

- (void)testFileLinkWithNilCurrentURLStillChecked
{
    NSURL *url = [NSURL URLWithString:kPoCFile];
    MPPreviewNavigationDecision *d = [self.defaultPolicy decisionForURL:url
        navigationType:WKNavigationTypeLinkActivated isMainFrame:YES
        sourceIsMainFrame:YES
        currentURL:nil];
    XCTAssertEqual(d.action, MPPreviewNavigationActionReveal, @"%@", d);
}

- (void)testPercentEncodedLocalLinkDecoded
{
    NSString *string = @"x-macdown-file:///Users/a/My%20Notes/b%23c.md";
    MPPreviewNavigationDecision *d = [self click:self.noPolicy url:string];
    XCTAssertEqual(d.action, MPPreviewNavigationActionOpen, @"%@", d);
    XCTAssertEqualObjects(d.targetURL.path, @"/Users/a/My Notes/b#c.md");
}

- (void)testWebAndMailLinksOpen
{
    for (NSString *string in @[@"https://example.com/a#b",
                               @"http://example.com", @"HTTPS://EXAMPLE.COM",
                               @"mailto:a@example.com"])
    {
        MPPreviewNavigationDecision *d = [self click:self.yesPolicy
                                                 url:string];
        XCTAssertEqual(d.action, MPPreviewNavigationActionOpen,
                       @"%@ -> %@", string, d);
        XCTAssertEqualObjects(d.targetURL, [NSURL URLWithString:string]);
    }
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}

- (void)testInertSchemeLinksCancelled
{
    for (NSString *string in @[
            @"x-macdown-asset:///Applications/MacDown.app/a.css",
            @"X-MACDOWN-ASSET:///a.js", @"javascript:alert(1)",
            @"data:text/html,<script>1</script>", @"blob:null/1234",
            @"about:blank", @"about:srcdoc"])
    {
        MPPreviewNavigationDecision *d = [self click:self.noPolicy
                                                 url:string];
        XCTAssertEqual(d.action, MPPreviewNavigationActionCancel,
                       @"%@ -> %@", string, d);
    }
}

- (void)testAppSchemeLinksOpen
{
    for (NSString *string in @[@"vscode://file/Users/a/x.md",
                               @"x-macdown://open?url=file:///tmp/a.md"])
    {
        MPPreviewNavigationDecision *d = [self click:self.yesPolicy
                                                 url:string];
        XCTAssertEqual(d.action, MPPreviewNavigationActionOpen,
                       @"%@ -> %@", string, d);
        XCTAssertEqualObjects(d.targetURL, [NSURL URLWithString:string]);
    }
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}


#pragma mark - fileURLForPreviewURL:

- (void)testFileURLTranslation
{
    NSURL *url = [NSURL URLWithString:@"x-macdown-file:///a/b%20c.md?q#f"];
    NSURL *fileURL = [MPPreviewNavigationPolicy fileURLForPreviewURL:url];
    XCTAssertEqualObjects(fileURL.absoluteString, @"file:///a/b%20c.md");

    url = [NSURL URLWithString:@"x-macdown-file:///a/dir/"];
    fileURL = [MPPreviewNavigationPolicy fileURLForPreviewURL:url];
    XCTAssertTrue(fileURL.hasDirectoryPath);
    XCTAssertEqualObjects(fileURL.path, @"/a/dir");
}

- (void)testFileURLTranslationRejects
{
    for (NSString *string in @[@"https://example.com/a.md",
                               @"x-macdown-asset:///a.css",
                               @"x-macdown-file://host/a.md",
                               @"x-macdown-file:a.md",
                               @"x-macdown-file:///a%00b.md"])
    {
        NSURL *url = [NSURL URLWithString:string];
        XCTAssertNil([MPPreviewNavigationPolicy fileURLForPreviewURL:url],
                     @"%@", string);
    }
}


#pragma mark - Default code-bearing predicate (real files)

- (void)testDefaultPredicateApplications
{
    MPCodeBearingPredicate p =
        MPPreviewNavigationPolicyDefaultCodeBearingPredicate();
    XCTAssertTrue(p([NSURL fileURLWithPath:
                     @"/System/Applications/Calculator.app"]));
    XCTAssertTrue(p([NSURL fileURLWithPath:@"/Applications/Calculator.app"]),
                  @"Nonexistent .app is judged by its extension");
    NSURL *missing = [self.tempDirectory
                      URLByAppendingPathComponent:@"foo.app"];
    XCTAssertTrue(p(missing));
    missing = [self.tempDirectory URLByAppendingPathComponent:@"foo.pkg"];
    XCTAssertTrue(p(missing));
}

- (void)testDefaultPredicateCommandFile
{
    NSURL *url = [self writeFile:@"run.command" contents:@"#!/bin/sh\n"];
    [self setExecutable:NO atURL:url];
    XCTAssertTrue(MPPreviewNavigationPolicyDefaultCodeBearingPredicate()(url));
}

// Files that make another app install or run what is in them are revealed,
// like code, even though their types do not say so.
- (void)testDefaultPredicateImporters
{
    MPCodeBearingPredicate p =
        MPPreviewNavigationPolicyDefaultCodeBearingPredicate();
    for (NSString *name in @[@"do.shortcut", @"flow.wflow", @"vpn.mobileconfig",
                             @"mdm.configprofile", @"app.jnlp"])
    {
        NSURL *url = [self writeFile:name contents:@"<plist/>"];
        XCTAssertTrue(p(url), @"%@", name);
    }
}

- (void)testDefaultPredicateExecutableBit
{
    MPCodeBearingPredicate p =
        MPPreviewNavigationPolicyDefaultCodeBearingPredicate();
    NSURL *url = [self writeFile:@"runme" contents:@"#!/bin/sh\necho hi\n"];
    [self setExecutable:NO atURL:url];
    XCTAssertFalse(p(url), @"Same file without the x bit is not code");
    [self setExecutable:YES atURL:url];
    XCTAssertTrue(p(url));
}

- (void)testDefaultPredicateDocuments
{
    MPCodeBearingPredicate p =
        MPPreviewNavigationPolicyDefaultCodeBearingPredicate();
    NSURL *md = [self writeFile:@"note.md" contents:@"# Hi\n"];
    NSURL *html = [self writeFile:@"page.html" contents:@"<p>x</p>"];
    NSURL *txt = [self writeFile:@"plain.txt" contents:@"x"];
    NSURL *pdf = [self.tempDirectory URLByAppendingPathComponent:@"doc.pdf"];
    NSData *pdfData =
        [@"%PDF-1.4\n%%EOF\n" dataUsingEncoding:NSASCIIStringEncoding];
    XCTAssertTrue([pdfData writeToURL:pdf atomically:YES]);
    NSURL *png = [self.tempDirectory URLByAppendingPathComponent:@"img.png"];
    const unsigned char sig[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    XCTAssertTrue([[NSData dataWithBytes:sig length:sizeof(sig)]
                   writeToURL:png atomically:YES]);
    for (NSURL *url in @[md, html, txt, pdf, png])
        XCTAssertFalse(p(url), @"%@", url.lastPathComponent);

    NSURL *missing = [self.tempDirectory
                      URLByAppendingPathComponent:@"foo.md"];
    XCTAssertFalse(p(missing));
    XCTAssertFalse(p(self.tempDirectory), @"Plain folder opens in Finder");
}

- (void)testDefaultPredicateFollowsSymlink
{
    NSURL *link = [self.tempDirectory
                   URLByAppendingPathComponent:@"notes.md"];
    NSURL *app = [NSURL fileURLWithPath:@"/System/Applications/Calculator.app"];
    BOOL ok = [[NSFileManager defaultManager]
               createSymbolicLinkAtURL:link withDestinationURL:app error:NULL];
    XCTAssertTrue(ok);
    XCTAssertTrue(MPPreviewNavigationPolicyDefaultCodeBearingPredicate()(link));
}

- (void)testDefaultPredicateFollowsAlias
{
    MPCodeBearingPredicate p =
        MPPreviewNavigationPolicyDefaultCodeBearingPredicate();
    NSURL *app = [NSURL fileURLWithPath:@"/System/Applications/Calculator.app"];
    NSURL *appAlias = [self writeAliasTo:app named:@"readme"];
    XCTAssertTrue(p(appAlias));

    NSURL *md = [self writeFile:@"target.md" contents:@"x"];
    NSURL *mdAlias = [self writeAliasTo:md named:@"target alias"];
    XCTAssertFalse(p(mdAlias));
}

#pragma mark - Link targets (#1050)

- (NSString *)previewURLStringForName:(NSString *)name
{
    NSURL *url = [self.tempDirectory URLByAppendingPathComponent:name];
    return MPPreviewURLForPath(kMPPreviewFileScheme, url.path).absoluteString;
}

// `[Install](setup)` with `setup.md` a symlink to a script: the Markdown
// fallback must be what the predicate checks, or the script launches.
- (void)testExtensionlessLinkChecksTheMarkdownFileItOpens
{
    NSURL *payload = [self writeFile:@"payload.command"
                            contents:@"#!/bin/sh\necho pwned\n"];
    [self setExecutable:YES atURL:payload];
    NSURL *link = [self.tempDirectory URLByAppendingPathComponent:@"setup.md"];
    BOOL ok = [[NSFileManager defaultManager]
               createSymbolicLinkAtURL:link withDestinationURL:payload
                                 error:NULL];
    XCTAssertTrue(ok);

    MPPreviewNavigationDecision *d =
        [self click:self.defaultPolicy
                url:[self previewURLStringForName:@"setup"]];
    XCTAssertEqual(d.action, MPPreviewNavigationActionReveal, @"%@", d);
    XCTAssertEqualObjects(d.targetURL.lastPathComponent, @"setup.md");
}

- (void)testExtensionlessLinkOpensItsMarkdownFile
{
    [self writeFile:@"notes.md" contents:@"# Notes"];
    MPPreviewNavigationDecision *d =
        [self click:self.noPolicy url:[self previewURLStringForName:@"notes"]];
    XCTAssertEqual(d.action, MPPreviewNavigationActionOpen, @"%@", d);
    XCTAssertEqualObjects(d.targetURL.lastPathComponent, @"notes.md");
    XCTAssertEqualObjects(self.checkedURLs, @[d.targetURL],
                          @"the predicate must see the URL that is opened");
}

- (void)testExistingOrMissingTargetsAreNotSubstituted
{
    [self writeFile:@"Makefile" contents:@"all:"];
    [self writeFile:@"Makefile.md" contents:@"# Make"];
    MPPreviewNavigationDecision *d =
        [self click:self.noPolicy url:[self previewURLStringForName:@"Makefile"]];
    XCTAssertEqualObjects(d.targetURL.lastPathComponent, @"Makefile");

    // Nothing to fall back to: the target stays as linked, so the host can
    // offer to create it.
    d = [self click:self.noPolicy url:[self previewURLStringForName:@"new"]];
    XCTAssertEqual(d.action, MPPreviewNavigationActionOpen, @"%@", d);
    XCTAssertEqualObjects(d.targetURL.lastPathComponent, @"new");
}

// A remote iframe runs its own scripts outside the preview's CSP, and WebKit
// reports a scripted click as a link activation.
- (void)testLinksFromSubframesNeverOpenOrReveal
{
    NSArray<NSString *> *targets = @[
        @"https://example.com/", @"smb://attacker/share", @"vscode://x",
        @"file:///Applications/Calculator.app",
        [self previewURLStringForName:@"doc.md"],
    ];
    for (NSString *target in targets)
    {
        for (NSNumber *targetsMainFrame in @[@YES, @NO])
        {
            MPPreviewNavigationDecision *d = [self.noPolicy
                decisionForURL:[NSURL URLWithString:target]
                navigationType:WKNavigationTypeLinkActivated
                   isMainFrame:targetsMainFrame.boolValue
             sourceIsMainFrame:NO
                    currentURL:[NSURL URLWithString:kDocURL]];
            XCTAssertNotEqual(d.action, MPPreviewNavigationActionOpen,
                              @"%@ %@", target, d);
            XCTAssertNotEqual(d.action, MPPreviewNavigationActionReveal,
                              @"%@ %@", target, d);
        }
    }
    XCTAssertEqual(self.checkedURLs.count, (NSUInteger)0);
}

- (void)testDefaultPredicateFailsClosedForNonFileURL
{
    NSURL *url = [NSURL URLWithString:@"https://example.com/a.md"];
    XCTAssertTrue(MPPreviewNavigationPolicyDefaultCodeBearingPredicate()(url));
}

@end
