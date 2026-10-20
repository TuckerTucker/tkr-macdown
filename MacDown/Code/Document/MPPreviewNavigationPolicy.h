//
//  MPPreviewNavigationPolicy.h
//  MacDown
//
//  Decides what the WKWebView preview does with each navigation request.
//
//  This is the second, independent layer of the #1050 fix (TM-1/TB-1). The
//  first layer is the preview's Content-Security-Policy, which blocks document
//  scripts. This layer holds even if that one fails: no decision it returns
//  ever lets the host hand a code-bearing local file (application, bundle,
//  executable, script, installer package, location file) to NSWorkspace to be
//  opened. Such files are revealed in Finder instead.
//
//  Rules, in the order they are applied:
//
//  1. A nil URL, a URL without a scheme, a local URL with no path, or a local
//     URL naming a remote host  -> Cancel.
//  2. Subframe: http, https, about:blank and about:srcdoc -> Allow; anything
//     else (file, x-macdown-file, x-macdown-asset, data, ...) -> Cancel.
//  3. Main frame, same document as `currentURL` (same scheme, same
//     percent-decoded path; host too for non-local schemes; fragment and query
//     ignored) -> Allow. This covers the host's own load and #anchor jumps.
//     Exception: a link activation whose URL is exactly `currentURL` ->
//     Cancel, as the legacy WebView policy did.
//  4. Main frame, any other target, navigation type other than link
//     activation (Other, form submit/resubmit, back/forward, reload; scripted
//     `location` changes and <meta http-equiv=refresh> arrive as Other)
//     -> Cancel. Never Open or Reveal.
//  5. Main frame link activation to another target:
//     - file, x-macdown-file -> translated to a file URL; Reveal when the
//       code-bearing predicate says YES, otherwise Open.
//     - http, https, mailto -> Open.
//     - x-macdown-asset, javascript, data, blob, about -> Cancel.
//     - any other scheme (vscode:, x-macdown:, ...) -> Open. Document
//       scripts cannot run under the preview's CSP, so a link activation is
//       the user clicking a link; handing an app URL to the system is what a
//       browser does. Note WebKit also reports a scripted `.click()` as a
//       link activation, which is why file targets are never trusted on the
//       navigation type alone and are always checked by the predicate.
//
//  Host integration notes: pass `currentURL` as the URL the host loaded the
//  document at (its base URL, without fragment). For a navigation action
//  whose `targetFrame` is nil (target=_blank, window.open), pass
//  `isMainFrame:YES` so it is decided like a main-frame link. The predicate
//  is evaluated when the decision is made; the host opens the file later, so
//  the check is advisory against a file swapped in between (accepted: the
//  attacker would already need local write access).
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "MPPreviewSchemeHandler.h"

NS_ASSUME_NONNULL_BEGIN


typedef NS_ENUM(NSInteger, MPPreviewNavigationAction)
{
    // Let the preview load it.
    MPPreviewNavigationActionAllow,
    // Drop it; do nothing.
    MPPreviewNavigationActionCancel,
    // Cancel in the preview; the host opens `targetURL` (a file or web URL)
    // as it does today (-openOrCreateFileForUrl:).
    MPPreviewNavigationActionOpen,
    // Cancel; the host reveals `targetURL` (a file URL) in Finder instead of
    // opening it.
    MPPreviewNavigationActionReveal,
};

// Returns YES when opening `fileURL` could launch or install code.
typedef BOOL (^MPCodeBearingPredicate)(NSURL *fileURL);

// The default predicate. Fails closed: YES for a non-file URL, an empty
// path, or an alias that cannot be resolved. Otherwise it follows symlinks
// and Finder aliases and returns YES if the link path or its resolved target
//  - is an existing directory that is a package or bundle, or
//  - is an existing regular file with an executable bit, or
//  - has a content type (NSURLContentTypeKey when the item exists, plus the
//    type of its filename extension) conforming to an application, bundle,
//    plug-in, app extension, executable, script, installer package,
//    Automator workflow or action, Terminal settings, or internet location
//    file (.webloc/.inetloc/.fileloc), or
//  - has one of a fixed list of code-bearing extensions (for types the
//    system has not declared, which resolve to dynamic UTIs).
// Markdown, text, images, PDF and HTML return NO. Scripts (including .js and
// .py) are deliberately included: some have system launchers that run them.
MPCodeBearingPredicate MPPreviewNavigationPolicyDefaultCodeBearingPredicate(
    void);


@interface MPPreviewNavigationDecision : NSObject
@property (readonly) MPPreviewNavigationAction action;
// Set only for Open and Reveal. Local targets are file URLs without
// fragment or query (x-macdown-file:///p#x -> file:///p).
@property (readonly, nullable) NSURL *targetURL;
- (instancetype)init NS_UNAVAILABLE;
@end


@interface MPPreviewNavigationPolicy : NSObject

- (instancetype)initWithCodeBearingPredicate:(MPCodeBearingPredicate)predicate
    NS_DESIGNATED_INITIALIZER;

// Uses MPPreviewNavigationPolicyDefaultCodeBearingPredicate().
- (instancetype)init;

- (MPPreviewNavigationDecision *)decisionForURL:(nullable NSURL *)url
                                 navigationType:(WKNavigationType)type
                                    isMainFrame:(BOOL)isMainFrame
                                     currentURL:(nullable NSURL *)currentURL;

// x-macdown-file:///p -> file:///p, and file URLs normalised the same way.
// The fragment and query are dropped: they cannot be honoured by opening
// another file, and -openOrCreateFileForUrl: works on the path. Returns nil
// for any other scheme, an empty path, or a host other than localhost.
+ (nullable NSURL *)fileURLForPreviewURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
