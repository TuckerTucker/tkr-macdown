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
#import "MPPreferences.h"

// MPDocument keeps its panes private; these are its existing accessors.
@interface MPDocument (PreviewTesting)
- (WKWebView *)preview;
- (BOOL)isPreviewReady;
- (NSTextView *)editor;
- (NSArray<NSNumber *> *)webViewHeaderLocations;
- (void)refreshPreviewMetrics:(void (^)(MPDocument *document))completion;
- (IBAction)render:(id)sender;
- (IBAction)togglePreviewPane:(id)sender;
- (BOOL)previewVisible;
- (NSArray<NSNumber *> *)editorHeaderLocations;
- (void)updateHeaderLocations;
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

- (void)waitUntil:(BOOL (^)(MPDocumentPreviewTests *test))condition
{
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(MPDocumentPreviewTests *test, NSDictionary *bindings) {
            return condition(test);
        }];
    [self waitForExpectations:@[[self expectationForPredicate:predicate
                                          evaluatedWithObject:self
                                                      handler:nil]]
                      timeout:10.0];
}

- (NSClipView *)editorClipView
{
    return self.document.editor.enclosingScrollView.contentView;
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

- (PDFDocument *)exportPDF
{
    NSURL *pdfUrl = [self.directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.pdf", [NSUUID UUID].UUIDString]];
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
    return [[PDFDocument alloc] initWithURL:pdfUrl];
}

- (NSString *)longMarkdown
{
    NSMutableString *markdown = [NSMutableString stringWithString:@"# Long\n\n"];
    for (int i = 0; i < 150; i++)
        [markdown appendFormat:@"Paragraph %d of a long document.\n\n", i];
    [markdown appendString:@"The final paragraph.\n"];
    return markdown;
}

- (void)testExportedPDFContainsTheWholeDocument
{
    [self openMarkdown:[self longMarkdown]];

    PDFDocument *pdf = [self exportPDF];
    XCTAssertNotNil(pdf, @"no PDF was written");
    XCTAssertGreaterThan(pdf.pageCount, 1,
                         @"a long document must paginate");
    XCTAssertTrue([pdf.string containsString:@"The final paragraph."],
                  @"the PDF is missing the end of the document");
    XCTAssertTrue([pdf.string containsString:@"Paragraph 0 of"]);
}

// The print view takes the preview pane's size, which is zero wide while the
// pane is collapsed; the export must still be complete.
- (void)testExportedPDFIsCompleteWithThePreviewHidden
{
    [self openMarkdown:[self longMarkdown]];
    [self.document togglePreviewPane:nil];
    XCTAssertFalse(self.document.previewVisible);

    PDFDocument *pdf = [self exportPDF];
    XCTAssertNotNil(pdf, @"no PDF was written");
    XCTAssertGreaterThan(pdf.pageCount, 1);
    XCTAssertTrue([pdf.string containsString:@"Paragraph 0 of"]);
    XCTAssertTrue([pdf.string containsString:@"The final paragraph."]);
}

// A reply from the web process can arrive after the window has closed; the
// document's completion work reads the editor, which is gone by then.
- (void)testPreviewRepliesAfterCloseAreDropped
{
    [self openMarkdown:@"# Title\n\nText.\n"];
    WKWebView *preview = self.document.preview;

    __block BOOL completed = NO;
    [self.document refreshPreviewMetrics:^(MPDocument *document) {
        completed = YES;
    }];
    // Replies come back in the order the scripts were sent, so once this
    // one arrives the metrics reply has been handled.
    XCTestExpectation *drained = [self expectationWithDescription:@"drained"];
    [preview evaluateJavaScript:@"0" completionHandler:^(id r, NSError *e) {
        [drained fulfill];
    }];
    [self.document close];
    [self waitForExpectations:@[drained] timeout:10.0];

    XCTAssertFalse(completed, @"a preview reply ran after the document closed");
}

// Scroll sync pairs the editor's headers with the preview's by index; a
// `# comment` inside a code block is code, not a header, in both.
- (void)testHeadersInsideCodeBlocksAreNotScrollAnchors
{
    NSMutableString *markdown = [NSMutableString string];
    for (int i = 0; i < 40; i++)
        [markdown appendFormat:@"## Section %d\n\n```sh\n# comment %d\n"
                               @"echo %d\n```\n\n~~~\n# tilde %d\n~~~\n\n",
                               i, i, i, i];
    [self openMarkdown:markdown];
    [self waitUntil:^BOOL(MPDocumentPreviewTests *test) {
        return test.document.webViewHeaderLocations.count == 40;
    }];
    NSTextView *editor = self.document.editor;
    [editor.layoutManager ensureLayoutForTextContainer:editor.textContainer];
    [self.document updateHeaderLocations];

    NSUInteger anchors = self.document.editorHeaderLocations.count;
    XCTAssertGreaterThan(anchors, 0u);
    XCTAssertLessThanOrEqual(anchors, 40u,
        @"code-block comments were taken for headers");
}

- (NSNumber *)pollPage:(NSString *)script until:(BOOL (^)(NSNumber *))done
{
    NSNumber *value = nil;
    for (int attempt = 0; attempt < 100; attempt++)
    {
        value = [self evaluateInPage:script];
        if ([value isKindOfClass:[NSNumber class]] && done(value))
            break;
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return value;
}

// With scroll syncing off, a re-render must leave the preview where the
// reader put it, even when images make the page grow after it has parsed.
- (void)testRerenderKeepsThePreviewWhereTheReaderLeftIt
{
    MPPreferences *preferences = [MPPreferences sharedInstance];
    BOOL wasSyncing = preferences.editorSyncScrolling;
    preferences.editorSyncScrolling = NO;
    [self addTeardownBlock:^{
        preferences.editorSyncScrolling = wasSyncing;
    }];

    // Images without declared sizes are 0 tall until they load.
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:20 pixelsHigh:600
        bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                    properties:@{}];
    [png writeToURL:[self.directory URLByAppendingPathComponent:@"tall.png"]
         atomically:YES];
    // Images that grow the page as they load, with enough text that the
    // page is taller than the window before they do.
    NSMutableString *markdown = [NSMutableString string];
    for (int i = 0; i < 12; i++)
    {
        [markdown appendFormat:@"![](tall.png)\n\n"];
        for (int j = 0; j < 6; j++)
            [markdown appendFormat:@"Paragraph %d.%d of text.\n\n", i, j];
    }
    [self openMarkdown:markdown];

    NSString *loaded = @"Array.from(document.images).every("
                       @"function (i) { return i.complete; }) ? 1 : 0";
    [self pollPage:loaded until:^BOOL(NSNumber *v) { return v.intValue; }];
    double limit = [[self evaluateInPage:
        @"document.documentElement.scrollHeight - window.innerHeight"]
        doubleValue];
    NSNumber *top = @(round(limit * 0.8));
    [self evaluateInPage:[NSString stringWithFormat:
        @"window.scrollTo(0, %@); window.macdownTestPage = 1; 0", top]];

    [self.document render:nil];
    [self pollPage:@"window.macdownTestPage ? 0 : 1"
             until:^BOOL(NSNumber *v) { return v.intValue; }];
    [self pollPage:loaded until:^BOOL(NSNumber *v) { return v.intValue; }];
    NSNumber *settled = [self pollPage:@"window.scrollY"
        until:^BOOL(NSNumber *v) { return v.doubleValue == top.doubleValue; }];
    XCTAssertEqualObjects(settled, top,
        @"the re-render moved the preview from where the reader left it");
}

// #114, #287, #1023: with scroll syncing on, either pane drives the other.
- (void)testScrollingEitherPaneSyncsTheOther
{
    MPPreferences *preferences = [MPPreferences sharedInstance];
    BOOL wasSyncing = preferences.editorSyncScrolling;
    preferences.editorSyncScrolling = YES;
    [self addTeardownBlock:^{
        preferences.editorSyncScrolling = wasSyncing;
    }];

    NSMutableString *markdown = [NSMutableString string];
    for (int i = 0; i < 60; i++)
        [markdown appendFormat:@"## Section %d\n\nParagraph %d of a long "
                               @"document.\n\n", i, i];
    [self openMarkdown:markdown];
    [self waitUntil:^BOOL(MPDocumentPreviewTests *test) {
        return test.document.webViewHeaderLocations.count == 60;
    }];
    // On a cold launch the editor lays its text out in the background, and
    // each time that grows its frame NSTextView keeps the insertion point in
    // view, which can move the editor. Finish layout before the reader acts.
    NSTextView *editor = self.document.editor;
    [editor.layoutManager ensureLayoutForTextContainer:editor.textContainer];
    [editor.window layoutIfNeeded];
    CGFloat settledY = NSMinY(self.editorClipView.bounds);

    // The window keeps the size it was last given, so aim at fractions of
    // whatever the preview can scroll rather than at fixed offsets.
    double limit = [[self evaluateInPage:
        @"document.documentElement.scrollHeight - window.innerHeight"]
        doubleValue];
    XCTAssertGreaterThan(limit, 0.0, @"the preview must be scrollable");
    NSNumber *firstTop = @(round(limit * 0.3));
    NSNumber *secondTop = @(round(limit * 0.6));

    // The reader scrolls the preview: the editor follows, and the preview
    // stays where the reader left it rather than being synced back.
    [self evaluateInPage:[NSString stringWithFormat:
        @"window.scrollTo(0, %@); 0", firstTop]];
    [self waitUntil:^BOOL(MPDocumentPreviewTests *test) {
        return NSMinY(test.editorClipView.bounds) > settledY;
    }];
    CGFloat editorY = NSMinY(self.editorClipView.bounds);
    XCTAssertEqualObjects([self evaluateInPage:@"window.scrollY"], firstTop);

    // Scrolling further down the preview moves the editor further down.
    [self evaluateInPage:[NSString stringWithFormat:
        @"window.scrollTo(0, %@); 0", secondTop]];
    [self waitUntil:^BOOL(MPDocumentPreviewTests *test) {
        return NSMinY(test.editorClipView.bounds) > editorY;
    }];
    XCTAssertEqualObjects([self evaluateInPage:@"window.scrollY"], secondTop);

    // The editor drives the preview, as it always has.
    NSClipView *clipView = self.editorClipView;
    [clipView scrollToPoint:NSMakePoint(0.0, 0.0)];
    [self.document.editor.enclosingScrollView reflectScrolledClipView:clipView];
    NSNumber *previewTop = nil;
    for (int attempt = 0; attempt < 100; attempt++)
    {
        previewTop = [self evaluateInPage:@"window.scrollY"];
        if (previewTop.doubleValue == 0.0)
            break;
        [[NSRunLoop currentRunLoop] runUntilDate:
            [NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    XCTAssertEqualObjects(previewTop, @0);
}

@end
