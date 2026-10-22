//
//  MPScrollSyncMap.m
//  MacDown
//

#import "MPScrollSyncMap.h"

// The inverse is found by bisection; half a point is below what either pane
// can show.
static const CGFloat kMPScrollSyncTolerance = 0.5;
static const NSUInteger kMPScrollSyncMaxIterations = 64;


@interface MPScrollSyncMap ()
@property (copy) NSArray<NSNumber *> *editorAnchors;
@property (copy) NSArray<NSNumber *> *previewAnchors;
@property CGFloat editorContentHeight;
@property CGFloat editorVisibleHeight;
@property CGFloat previewContentHeight;
@property CGFloat previewVisibleHeight;
@end


@implementation MPScrollSyncMap

- (instancetype)initWithEditorAnchors:(NSArray<NSNumber *> *)editorAnchors
                               editor:(MPScrollSyncPane)editor
                       previewAnchors:(NSArray<NSNumber *> *)previewAnchors
                              preview:(MPScrollSyncPane)preview
{
    self = [super init];
    if (!self)
        return nil;
    // Anchors pair up by index. Should one pane find a node the other does
    // not, pair only as many as both have: past the last pair the map
    // interpolates to the end, rather than indexing past the shorter list.
    NSUInteger paired = MIN(editorAnchors.count, previewAnchors.count);
    self.editorAnchors =
        [editorAnchors subarrayWithRange:NSMakeRange(0, paired)];
    self.previewAnchors =
        [previewAnchors subarrayWithRange:NSMakeRange(0, paired)];
    self.editorContentHeight = ceil(editor.contentHeight);
    self.editorVisibleHeight = ceil(editor.visibleHeight);
    self.previewContentHeight = ceil(preview.contentHeight);
    self.previewVisibleHeight = ceil(preview.visibleHeight);
    return self;
}

- (CGFloat)editorScrollLimit
{
    return MAX(0.0, self.editorContentHeight - self.editorVisibleHeight);
}

- (CGFloat)previewOffsetForEditorOffset:(CGFloat)offset
{
    CGFloat editorContentHeight = self.editorContentHeight;
    CGFloat editorVisibleHeight = self.editorVisibleHeight;
    NSInteger relativeHeaderIndex = -1; // -1 is start of document, before any other header
    CGFloat currY = offset;
    CGFloat minY = 0;
    CGFloat maxY = 0;

    // align the documents at the middle of the screen, except at top/bottom of document
    CGFloat topTaper = MAX(0, MIN(1.0, currY / editorVisibleHeight));
    CGFloat bottomTaper = 1.0 - MAX(0, MIN(1.0, (currY - editorContentHeight + 2 * editorVisibleHeight) / editorVisibleHeight));
    CGFloat adjustmentForScroll = topTaper * bottomTaper * editorVisibleHeight / 2;

    for (NSNumber *headerYNum in self.editorAnchors)
    {
        CGFloat headerY = headerYNum.doubleValue - adjustmentForScroll;
        if (headerY < currY)
        {
            // The header is before our current scroll position. the closest
            // of these will be our first reference node
            relativeHeaderIndex += 1;
            minY = headerY;
        }
        else if (maxY == 0 && headerY < editorContentHeight - editorVisibleHeight)
        {
            // Skip any headers that are within the last screen of the editor.
            // we'll interpolate to the end of the document in that case.
            maxY = headerY;
        }
    }

    // Usually, we'll be scrolling between two reference nodes, but toward the end
    // of the document we'll ignore nodes and reference the end of the document instead
    BOOL interpolateToEndOfDocument = NO;
    if (maxY == 0)
    {
        // We only have a reference node before our current position,
        // but not after, so we'll use the end of the document.
        maxY = editorContentHeight - editorVisibleHeight + adjustmentForScroll;
        interpolateToEndOfDocument = YES;
    }

    // We are currently at currY offset, between minY and maxY, which represent
    // headers indexed by relativeHeaderIndex and relativeHeaderIndex+1.
    currY = MAX(0, currY - minY);
    maxY -= minY;
    CGFloat percentScrolledBetweenHeaders =
        maxY > 0 ? MAX(0, MIN(1.0, currY / maxY)) : (currY > 0 ? 1.0 : 0.0);

    // Find the Y positions in the preview that we're scrolling between.
    NSArray<NSNumber *> *previewAnchors = self.previewAnchors;
    NSInteger previewAnchorCount = (NSInteger)previewAnchors.count;
    CGFloat topHeaderY = 0;
    CGFloat bottomHeaderY =
        self.previewContentHeight - self.previewVisibleHeight;
    if (relativeHeaderIndex >= 0 && relativeHeaderIndex < previewAnchorCount)
    {
        topHeaderY = floor(previewAnchors[relativeHeaderIndex].doubleValue)
            - adjustmentForScroll;
    }
    if (!interpolateToEndOfDocument
            && relativeHeaderIndex + 1 < previewAnchorCount)
    {
        bottomHeaderY = ceil(previewAnchors[relativeHeaderIndex + 1].doubleValue)
            - adjustmentForScroll;
    }

    return topHeaderY + (bottomHeaderY - topHeaderY) * percentScrolledBetweenHeaders;
}

- (CGFloat)editorOffsetForPreviewOffset:(CGFloat)offset
{
    // The forward map is non-decreasing in the editor offset, so bisect it.
    CGFloat low = 0.0;
    CGFloat high = [self editorScrollLimit];
    if (offset <= [self previewOffsetForEditorOffset:low])
        return low;
    if (offset >= [self previewOffsetForEditorOffset:high])
        return high;

    for (NSUInteger i = 0;
            i < kMPScrollSyncMaxIterations
                && high - low > kMPScrollSyncTolerance;
            i++)
    {
        CGFloat middle = (low + high) / 2.0;
        if ([self previewOffsetForEditorOffset:middle] < offset)
            low = middle;
        else
            high = middle;
    }
    return (low + high) / 2.0;
}

@end
