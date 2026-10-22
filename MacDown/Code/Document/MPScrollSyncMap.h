//
//  MPScrollSyncMap.h
//  MacDown
//
//  Maps a scroll offset in the editor to the matching offset in the preview,
//  and back (#114, #287, #1023). Both panes are aligned on reference nodes,
//  the headers and stand-alone images they have in common, matched by index.
//  Between two nodes the offset is interpolated; past the last node that is
//  not within the editor's final screen it is interpolated to the end.
//
//  Near the middle of the document a node is aligned half a screen down, so
//  the matching content sits mid-pane; the alignment tapers off over the
//  first and last screen, so the tops and the ends of the panes coincide.
//
//  The map is a pure function of the geometry it is built with.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct
{
    CGFloat contentHeight;  // Height of everything that can scroll.
    CGFloat visibleHeight;  // Height of the viewport.
} MPScrollSyncPane;

NS_INLINE MPScrollSyncPane MPScrollSyncPaneMake(CGFloat content,
                                                CGFloat visible)
{
    MPScrollSyncPane pane = {content, visible};
    return pane;
}


@interface MPScrollSyncMap : NSObject

// Anchors are the vertical positions of the reference nodes in each pane, in
// document order. Editor anchors within the editor's last screen are expected
// to have been left out already (see -[MPDocument updateHeaderLocations]).
- (instancetype)initWithEditorAnchors:(NSArray<NSNumber *> *)editorAnchors
                               editor:(MPScrollSyncPane)editor
                       previewAnchors:(NSArray<NSNumber *> *)previewAnchors
                              preview:(MPScrollSyncPane)preview
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (CGFloat)previewOffsetForEditorOffset:(CGFloat)offset;

// The inverse of -previewOffsetForEditorOffset:, clamped to the editor's
// scrollable range. Where several editor offsets map to the same preview
// offset, one of them is returned.
- (CGFloat)editorOffsetForPreviewOffset:(CGFloat)offset;

@end

NS_ASSUME_NONNULL_END
