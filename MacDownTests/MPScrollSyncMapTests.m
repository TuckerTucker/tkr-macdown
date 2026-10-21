//
//  MPScrollSyncMapTests.m
//  MacDownTests
//
//  Covers the editor <-> preview scroll mapping (#114, #287, #1023). The
//  geometry is a long document with evenly spaced headers, the preview
//  laid out at twice the editor's scale with a header offset of its own, so
//  no mapping can pass by returning its input.
//

#import <XCTest/XCTest.h>
#import "MPScrollSyncMap.h"


static const CGFloat kEditorVisible = 400.0;
static const CGFloat kEditorContent = 5000.0;
static const CGFloat kPreviewVisible = 600.0;
static const CGFloat kPreviewContent = 10200.0;
static const NSUInteger kHeaderCount = 12;


@interface MPScrollSyncMapTests : XCTestCase
@property (strong) MPScrollSyncMap *map;
@property (copy) NSArray<NSNumber *> *editorAnchors;
@property (copy) NSArray<NSNumber *> *previewAnchors;
@end


@implementation MPScrollSyncMapTests

- (void)setUp
{
    [super setUp];
    NSMutableArray *editor = [NSMutableArray array];
    NSMutableArray *preview = [NSMutableArray array];
    for (NSUInteger i = 0; i < kHeaderCount; i++)
    {
        CGFloat y = 200.0 + 350.0 * i;
        // Like -updateHeaderLocations, leave out the editor's last screen.
        if (y <= kEditorContent - kEditorVisible)
            [editor addObject:@(y)];
        [preview addObject:@(100.0 + 2.0 * y)];
    }
    self.editorAnchors = editor;
    self.previewAnchors = preview;
    self.map = [[MPScrollSyncMap alloc]
        initWithEditorAnchors:editor
                       editor:MPScrollSyncPaneMake(kEditorContent,
                                                   kEditorVisible)
               previewAnchors:preview
                      preview:MPScrollSyncPaneMake(kPreviewContent,
                                                   kPreviewVisible)];
}

- (CGFloat)editorLimit
{
    return kEditorContent - kEditorVisible;
}

- (CGFloat)previewLimit
{
    return kPreviewContent - kPreviewVisible;
}

- (void)testTopsAndEndsCoincide
{
    XCTAssertEqual([self.map previewOffsetForEditorOffset:0.0], 0.0);
    XCTAssertEqual([self.map previewOffsetForEditorOffset:self.editorLimit],
                   self.previewLimit);
    XCTAssertEqual([self.map editorOffsetForPreviewOffset:0.0], 0.0);
    XCTAssertEqual([self.map editorOffsetForPreviewOffset:self.previewLimit],
                   self.editorLimit);
}

- (void)testMidDocumentHeadersAlignHalfAScreenDown
{
    // With an editor header half a screen below the top of the editor, the
    // matching preview header is the same distance below the preview's top.
    CGFloat half = kEditorVisible / 2.0;
    for (NSUInteger i = 3; i < 8; i++)
    {
        CGFloat editorY = self.editorAnchors[i].doubleValue - half;
        CGFloat previewY = self.previewAnchors[i].doubleValue - half;
        XCTAssertEqualWithAccuracy(
            [self.map previewOffsetForEditorOffset:editorY], previewY, 1.0,
            @"header %lu", (unsigned long)i);
        XCTAssertEqualWithAccuracy(
            [self.map editorOffsetForPreviewOffset:previewY], editorY, 1.0,
            @"header %lu", (unsigned long)i);
    }
}

- (void)testForwardMapNeverMovesBackwards
{
    CGFloat previous = -1.0;
    for (CGFloat y = 0.0; y <= self.editorLimit; y += 1.0)
    {
        CGFloat mapped = [self.map previewOffsetForEditorOffset:y];
        XCTAssertGreaterThanOrEqual(mapped, previous, @"at editor %f", y);
        previous = mapped;
    }
}

- (void)testInverseRoundTripsEveryReachablePreviewOffset
{
    for (CGFloat y = 0.0; y <= self.previewLimit; y += 7.0)
    {
        CGFloat editorY = [self.map editorOffsetForPreviewOffset:y];
        XCTAssertGreaterThanOrEqual(editorY, 0.0);
        XCTAssertLessThanOrEqual(editorY, self.editorLimit);
        XCTAssertEqualWithAccuracy(
            [self.map previewOffsetForEditorOffset:editorY], y, 2.0,
            @"at preview %f", y);
    }
}

- (void)testOutOfRangeOffsetsClampToTheEditor
{
    XCTAssertEqual([self.map editorOffsetForPreviewOffset:-50.0], 0.0);
    XCTAssertEqual([self.map editorOffsetForPreviewOffset:1e6],
                   self.editorLimit);
}

- (void)testDocumentWithoutHeadersMapsProportionally
{
    MPScrollSyncMap *map = [[MPScrollSyncMap alloc]
        initWithEditorAnchors:@[]
                       editor:MPScrollSyncPaneMake(kEditorContent,
                                                   kEditorVisible)
               previewAnchors:@[]
                      preview:MPScrollSyncPaneMake(kPreviewContent,
                                                   kPreviewVisible)];
    CGFloat ratio = self.previewLimit / self.editorLimit;
    // Away from the tapered first and last screens the map is linear.
    for (CGFloat y = kEditorVisible; y <= self.editorLimit - kEditorVisible;
            y += 100.0)
    {
        CGFloat mapped = [map previewOffsetForEditorOffset:y];
        XCTAssertGreaterThan(mapped, 0.0);
        XCTAssertEqualWithAccuracy([map editorOffsetForPreviewOffset:mapped],
                                   y, 1.0);
    }
    XCTAssertEqualWithAccuracy([map previewOffsetForEditorOffset:
                                    self.editorLimit],
                               self.editorLimit * ratio, 1.0);
}

- (void)testPaneThatCannotScrollDoesNotProduceNaN
{
    MPScrollSyncMap *map = [[MPScrollSyncMap alloc]
        initWithEditorAnchors:@[]
                       editor:MPScrollSyncPaneMake(300.0, 400.0)
               previewAnchors:@[]
                      preview:MPScrollSyncPaneMake(300.0, 600.0)];
    CGFloat mapped = [map previewOffsetForEditorOffset:0.0];
    XCTAssertFalse(isnan(mapped));
    XCTAssertEqual([map editorOffsetForPreviewOffset:120.0], 0.0);
}

@end
