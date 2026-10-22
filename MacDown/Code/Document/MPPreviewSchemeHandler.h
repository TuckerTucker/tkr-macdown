//
//  MPPreviewSchemeHandler.h
//  MacDown
//
//  Serves the preview's documents and assets to WKWebView through custom URL
//  schemes, so the preview never runs with file:// privileges.
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// x-macdown-file:///<absolute path> — the rendered document and anything it
// references relative to itself (images, stylesheets, media).
extern NSString * const kMPPreviewFileScheme;

// x-macdown-asset:///<absolute path> — MacDown's own styles and scripts. This
// is the only origin scripts may load from.
extern NSString * const kMPPreviewAssetScheme;

// The policy attached to every rendered page. Document-authored scripts,
// inline scripts and event-handler attributes never execute; only assets
// served under kMPPreviewAssetScheme do. Raw HTML therefore renders without
// being able to run code (#1050, #372).
extern NSString * const kMPPreviewContentSecurityPolicy;

// Builds <scheme>:///<path> for an absolute file path, percent-encoded.
NSURL *MPPreviewURLForPath(NSString *scheme, NSString *path);


@interface MPPreviewSchemeHandler : NSObject <WKURLSchemeHandler>

// Files are served only when their resolved path lies inside one of `roots`
// (symlinks and ".." are resolved first). Pass nil to serve any regular file
// the user can read.
- (instancetype)initWithAllowedRoots:(nullable NSArray<NSURL *> *)roots
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A virtual page: requests for exactly `url` (ignoring fragment and query)
// are answered with `html`, carrying kMPPreviewContentSecurityPolicy, instead
// of reading the file system. Setting nil html removes the page.
- (void)setPageHTML:(nullable NSString *)html forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
