//
//  MPRendererStubs.m
//  MacDownTests
//
//  Implementation of the configurable MPRenderer test doubles. See the header
//  for the rationale (findings TEST-1, TEST-13).
//

#import "MPRendererStubs.h"


@implementation MPTestRendererDataSource

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    _markdown = @"";
    _htmlTitle = nil;
    _loading = NO;

    return self;
}

#pragma mark - MPRendererDataSource

- (BOOL)rendererLoading
{
    return self.loading;
}

- (NSString *)rendererMarkdown:(MPRenderer *)renderer
{
    return self.markdown;
}

- (NSString *)rendererHTMLTitle:(MPRenderer *)renderer
{
    return self.htmlTitle;
}

@end


@implementation MPTestRendererDelegate

@synthesize capturedHTML = _capturedHTML;
@synthesize didProduceHTML = _didProduceHTML;
@synthesize produceCount = _produceCount;

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    _extensions = 0;
    _hasSmartyPants = NO;
    _rendersTOC = NO;
    _styleName = nil;
    _detectsFrontMatter = NO;
    _hasSyntaxHighlighting = NO;
    _hasMermaid = NO;
    _hasGraphviz = NO;
    _codeBlockAccessory = MPCodeBlockAccessoryNone;
    _hasMathJax = NO;
    _highlightingThemeName = nil;

    _capturedHTML = nil;
    _didProduceHTML = NO;
    _produceCount = 0;

    return self;
}

#pragma mark - MPRendererDelegate

- (int)rendererExtensions:(MPRenderer *)renderer
{
    return self.extensions;
}

- (BOOL)rendererHasSmartyPants:(MPRenderer *)renderer
{
    return self.hasSmartyPants;
}

- (BOOL)rendererRendersTOC:(MPRenderer *)renderer
{
    return self.rendersTOC;
}

- (NSString *)rendererStyleName:(MPRenderer *)renderer
{
    return self.styleName;
}

- (BOOL)rendererDetectsFrontMatter:(MPRenderer *)renderer
{
    return self.detectsFrontMatter;
}

- (BOOL)rendererHasSyntaxHighlighting:(MPRenderer *)renderer
{
    return self.hasSyntaxHighlighting;
}

- (BOOL)rendererHasMermaid:(MPRenderer *)renderer
{
    return self.hasMermaid;
}

- (BOOL)rendererHasGraphviz:(MPRenderer *)renderer
{
    return self.hasGraphviz;
}

- (MPCodeBlockAccessoryType)rendererCodeBlockAccesory:(MPRenderer *)renderer
{
    return self.codeBlockAccessory;
}

- (BOOL)rendererHasMathJax:(MPRenderer *)renderer
{
    return self.hasMathJax;
}

- (NSString *)rendererHighlightingThemeName:(MPRenderer *)renderer
{
    return self.highlightingThemeName;
}

- (void)renderer:(MPRenderer *)renderer didProduceHTMLOutput:(NSString *)html
{
    _capturedHTML = [html copy];
    _didProduceHTML = YES;
    _produceCount += 1;
}

@end
