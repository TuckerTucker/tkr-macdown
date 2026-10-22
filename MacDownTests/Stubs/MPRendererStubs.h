//
//  MPRendererStubs.h
//  MacDownTests
//
//  Reusable, configurable test doubles for MPRenderer's data source and
//  delegate protocols (findings TEST-1, TEST-13). The renderer pulls every
//  input it needs (markdown text, extension flags, smartypants/TOC/front-matter
//  toggles, asset toggles) from these two objects, and pushes its produced HTML
//  back through the delegate. By making each of those values a settable
//  property — and capturing the produced HTML — these stubs let a test drive
//  MPRenderer end-to-end without the real MPDocument/MPPreferences machinery.
//

#import <Foundation/Foundation.h>
#import "MPRenderer.h"


/**
 *  Configurable @c MPRendererDataSource stub.
 *
 *  Supplies the markdown body and HTML title the renderer asks for, plus the
 *  "is the web view still loading" flag polled by @c parseAndRenderWithMaxDelay:.
 */
@interface MPTestRendererDataSource : NSObject <MPRendererDataSource>

/** Markdown returned from @c rendererMarkdown:. Defaults to @c \@"". */
@property (nonatomic, copy) NSString *markdown;

/** Title returned from @c rendererHTMLTitle:. Defaults to @c nil. */
@property (nonatomic, copy) NSString *htmlTitle;

/** Value returned from @c rendererLoading. Defaults to @c NO. */
@property (nonatomic, assign) BOOL loading;

@end


/**
 *  Configurable @c MPRendererDelegate stub.
 *
 *  Exposes every renderer preference as a settable property so a test can pin
 *  the exact extension/flag combination it needs, and captures the HTML handed
 *  to @c renderer:didProduceHTMLOutput: so the end-to-end output can be
 *  asserted on.
 */
@interface MPTestRendererDelegate : NSObject <MPRendererDelegate>

/** Bitmask returned from @c rendererExtensions:. Defaults to @c 0. */
@property (nonatomic, assign) int extensions;

/** Value returned from @c rendererHasSmartyPants:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL hasSmartyPants;

/** Value returned from @c rendererRendersTOC:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL rendersTOC;

/** Value returned from @c rendererStyleName:. Defaults to @c nil. */
@property (nonatomic, copy) NSString *styleName;

/** Value returned from @c rendererDetectsFrontMatter:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL detectsFrontMatter;

/** Value returned from @c rendererHasSyntaxHighlighting:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL hasSyntaxHighlighting;

/** Value returned from @c rendererHasMermaid:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL hasMermaid;

/** Value returned from @c rendererHasGraphviz:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL hasGraphviz;

/** Value returned from @c rendererCodeBlockAccesory:. Defaults to None. */
@property (nonatomic, assign) MPCodeBlockAccessoryType codeBlockAccessory;

/** Value returned from @c rendererHasMathJax:. Defaults to @c NO. */
@property (nonatomic, assign) BOOL hasMathJax;

/** Value returned from @c rendererHighlightingThemeName:. Defaults to @c nil. */
@property (nonatomic, copy) NSString *highlightingThemeName;

/** The most recent HTML passed to @c renderer:didProduceHTMLOutput:. */
@property (nonatomic, copy, readonly) NSString *capturedHTML;

/** YES once @c renderer:didProduceHTMLOutput: has been called at least once. */
@property (nonatomic, assign, readonly) BOOL didProduceHTML;

/** Number of times @c renderer:didProduceHTMLOutput: has been called. */
@property (nonatomic, assign, readonly) NSUInteger produceCount;

@end
