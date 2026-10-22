//
//  MPPreviewTextCount.h
//  MacDown
//
//  Word and character counting for a WKWebView-hosted preview. The page
//  JavaScript (Resources/Scripts/text-count.js) collects raw text segments;
//  native code counts them with the same NSString logic the legacy
//  DOMNode+Text walk used, so the numbers are identical.
//

#import <Foundation/Foundation.h>

@class WKWebView;

typedef struct
{
    NSUInteger words;
    NSUInteger characters;
    NSUInteger charactersWithoutSpaces;
} MPPreviewTextCount;

extern NSString * const MPPreviewTextCountErrorDomain;

typedef NS_ENUM(NSInteger, MPPreviewTextCountErrorCode)
{
    MPPreviewTextCountErrorScriptUnavailable = 1,
    MPPreviewTextCountErrorNoWebView = 2,
};

// The JavaScript source evaluated in the preview. Its value is the payload
// accepted by MPPreviewTextCountFromPayload(). Returns nil if the bundled
// resource Scripts/text-count.js is missing.
extern NSString *MPPreviewTextCountScript(void);

// Counts a payload produced by MPPreviewTextCountScript(). Pure; never
// throws. Anything that does not match the expected shape counts as zero.
MPPreviewTextCount MPPreviewTextCountFromPayload(id payload);

// Evaluates the counting script in webView and calls completion, always
// asynchronously, on the main thread. On failure the count is zero and error
// is set. Completions are delivered in the order evaluations were requested.
void MPPreviewEvaluateTextCount(
    WKWebView *webView,
    void (^completion)(MPPreviewTextCount count, NSError *error));
