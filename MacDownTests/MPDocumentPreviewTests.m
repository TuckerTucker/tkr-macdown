//
//  MPDocumentPreviewTests.m
//  MacDownTests
//
//  End-to-end checks of the WKWebView preview through the real document
//  path: NSDocumentController opens a file, MPDocument loads its nib, the
//  renderer produces HTML and the preview displays it. Nothing is stubbed.
//

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <PDFKit/PDFKit.h>
#import "MPDocument.h"

// MPDocument keeps its preview private; these are its existing accessors.
@interface MPDocument (PreviewTesting)
- (WKWebView *)preview;
- (BOOL)isPreviewReady;
@end


@interface MPDocumentPreviewTests : XCTestCase
@property (strong) NSURL *directory;
@property (strong) MPDocument *document;
@property (strong) XCTestExpectation *printed;
@property BOOL printSucceeded;
@end


@implementation MPDocumentPreviewTests

- (void)setUp
{
    [super setUp];
    NSString *name = [NSString stringWithFormat:@"MPDocumentPreviewTests-%@",
                      [NSUUID UUID].UUIDString];
    self.directory = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                                isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:self.directory
                             withIntermediateDirectories:YES
                                              attributes:nil error:NULL];
}

- (void)tearDown
{
    [self.document close];
    self.document = nil;
    [[NSFileManager defaultManager] removeItemAtURL:self.directory error:NULL];
    [super tearDown];
}

- (void)openMarkdown:(NSString *)markdown
{
    NSURL *url = [self.directory URLByAppendingPathComponent:@"doc.md"];
    [markdown writeToURL:url atomically:YES encoding:NSUTF8StringEncoding
                   error:NULL];

    XCTestExpectation *opened = [self expectationWithDescription:@"opened"];
    NSDocumentController *controller =
        [NSDocumentController sharedDocumentController];
    [controller openDocumentWithContentsOfURL:url display:YES
                            completionHandler:
        ^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
            XCTAssertNil(error);
            self.document = (MPDocument *)document;
            [opened fulfill];
        }];
    [self waitForExpectations:@[opened] timeout:10.0];

    NSPredicate *ready = [NSPredicate predicateWithBlock:
        ^BOOL(MPDocumentPreviewTests *test, NSDictionary *bindings) {
            return test.document.isPreviewReady
                && !test.document.preview.loading;
        }];
    [self waitForExpectations:@[[self expectationForPredicate:ready
                                          evaluatedWithObject:self
                                                      handler:nil]]
                      timeout:20.0];
}

- (id)evaluateInPage:(NSString *)script
{
    __block id value = nil;
    XCTestExpectation *done = [self expectationWithDescription:script];
    [self.document.preview evaluateJavaScript:script inFrame:nil
                               inContentWorld:WKContentWorld.pageWorld
                            completionHandler:^(id result, NSError *error) {
        value = error ? error : result;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:10.0];
    return value;
}

- (void)document:(NSDocument *)document didPrint:(BOOL)ok
     contextInfo:(void *)contextInfo
{
    self.printSucceeded = ok;
    [self.printed fulfill];
}


#pragma mark - Tests

- (void)testRawHTMLRendersButDocumentScriptsDoNotRun
{
    // The #1050 proof of concept, plus legitimate raw HTML.
    [self openMarkdown:
        @"# Title\n\n"
        @"<div id=\"raw\"><kbd>Raw</kbd> HTML</div>\n\n"
        @"<a href=\"file:\\\\\\Applications\\Calculator.app\" id=exploit>x</a>"
        @"\n\n<script>window.pwned = true;"
        @" document.getElementById('exploit').click();</script>\n"];

    NSDictionary *state = [self evaluateInPage:
        @"({raw: !!document.querySelector('#raw > kbd'),"
        @"  pwned: !!window.pwned,"
        @"  url: location.href})"];
    XCTAssertEqualObjects(state[@"raw"], @YES,
                          @"raw HTML must render, not be escaped");
    XCTAssertEqualObjects(state[@"pwned"], @NO,
                          @"a document script ran in the preview (#1050)");
    XCTAssertTrue([state[@"url"] hasPrefix:@"x-macdown-file:"],
                  @"the preview must stay on the document it rendered");
    XCTAssertEqualObjects(self.document.html.length ? @YES : @NO, @YES);
}

- (void)testExportedPDFContainsTheWholeDocument
{
    NSMutableString *markdown = [NSMutableString stringWithString:@"# Long\n\n"];
    for (int i = 0; i < 150; i++)
        [markdown appendFormat:@"Paragraph %d of a long document.\n\n", i];
    [markdown appendString:@"The final paragraph.\n"];
    [self openMarkdown:markdown];

    NSURL *pdfUrl = [self.directory URLByAppendingPathComponent:@"out.pdf"];
    NSDictionary *settings = @{
        NSPrintJobDisposition: NSPrintSaveJob,
        NSPrintJobSavingURL: pdfUrl,
    };
    self.printed = [self expectationWithDescription:@"printed"];
    [self.document printDocumentWithSettings:settings showPrintPanel:NO
                                    delegate:self
                            didPrintSelector:
        @selector(document:didPrint:contextInfo:)
                                 contextInfo:NULL];
    [self waitForExpectations:@[self.printed] timeout:30.0];
    XCTAssertTrue(self.printSucceeded);

    PDFDocument *pdf = [[PDFDocument alloc] initWithURL:pdfUrl];
    XCTAssertNotNil(pdf, @"no PDF was written");
    XCTAssertGreaterThan(pdf.pageCount, 1,
                         @"a long document must paginate");
    XCTAssertTrue([pdf.string containsString:@"The final paragraph."],
                  @"the PDF is missing the end of the document");
    XCTAssertTrue([pdf.string containsString:@"Paragraph 0 of"]);
}

@end
