//
//  MPPreviewTextCount.m
//  MacDown
//
//  The counting helpers below were moved from DOMNode+Text.m. They are static
//  functions rather than an NSString category so they cannot collide with the
//  legacy NSString (WordCount) category while both files are in the target.
//

#import "MPPreviewTextCount.h"
#import <WebKit/WebKit.h>

NSString * const MPPreviewTextCountErrorDomain =
    @"com.uranusjr.macdown.preview-text-count";

static NSString * const kMPTextCountScriptName = @"text-count";
static NSString * const kMPTextCountScriptExtension = @"js";
static NSString * const kMPTextCountScriptDirectory = @"Scripts";

static NSString * const kMPTextCountWordsKey = @"words";
static NSString * const kMPTextCountCharactersKey = @"characters";


#pragma mark - String counting

NS_INLINE NSUInteger MPNumberOfWords(NSString *str)
{
    __block NSUInteger count = 0;
    NSStringEnumerationOptions options =
        NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired;
    [str enumerateSubstringsInRange:NSMakeRange(0, str.length)
                            options:options usingBlock:
     ^(NSString *sub, NSRange subRange, NSRange enclosingRange, BOOL *stop) {
         count++;
     }];
    return count;
}

NS_INLINE NSUInteger MPLengthExcludingCharacters(
    NSString *str, NSCharacterSet *excluded)
{
    NSUInteger length = 0;
    for (NSString *comp in [str componentsSeparatedByCharactersInSet:excluded])
        length += comp.length;
    return length;
}

static NSUInteger MPLengthWithoutNewlines(NSString *str)
{
    static NSCharacterSet *sp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sp = [NSCharacterSet newlineCharacterSet];
    });
    return MPLengthExcludingCharacters(str, sp);
}

static NSUInteger MPLengthWithoutWhitespacesAndNewlines(NSString *str)
{
    static NSCharacterSet *sp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sp = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    });
    return MPLengthExcludingCharacters(str, sp);
}


#pragma mark - Payload counting

// A word item is either a text segment (counted with NSString word
// enumeration) or a nested array standing for an inline CODE element, which
// counts as exactly one word if anything inside it counts. Any other object
// counts as zero.
static NSUInteger MPCountWordItems(NSArray *items)
{
    NSUInteger count = 0;
    for (id item in items)
    {
        if ([item isKindOfClass:[NSString class]])
            count += MPNumberOfWords(item);
        else if ([item isKindOfClass:[NSArray class]])
            count += MPCountWordItems(item) ? 1 : 0;
    }
    return count;
}

MPPreviewTextCount MPPreviewTextCountFromPayload(id payload)
{
    MPPreviewTextCount count = {0, 0, 0};
    if (![payload isKindOfClass:[NSDictionary class]])
        return count;

    id words = payload[kMPTextCountWordsKey];
    if ([words isKindOfClass:[NSArray class]])
        count.words = MPCountWordItems(words);

    id characters = payload[kMPTextCountCharactersKey];
    if ([characters isKindOfClass:[NSArray class]])
    {
        for (id segment in characters)
        {
            if (![segment isKindOfClass:[NSString class]])
                continue;
            count.characters += MPLengthWithoutNewlines(segment);
            count.charactersWithoutSpaces +=
                MPLengthWithoutWhitespacesAndNewlines(segment);
        }
    }
    return count;
}


#pragma mark - Script

NSString *MPPreviewTextCountScript(void)
{
    static NSString *script = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *url =
            [[NSBundle mainBundle] URLForResource:kMPTextCountScriptName
                                    withExtension:kMPTextCountScriptExtension
                                     subdirectory:kMPTextCountScriptDirectory];
        if (url)
            script = [NSString stringWithContentsOfURL:url
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    });
    return script;
}


#pragma mark - Evaluation

static NSError *MPPreviewTextCountError(
    MPPreviewTextCountErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:MPPreviewTextCountErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Counting walks every text segment of the document, so it runs off the
// main thread. Every outcome, success or failure, passes through one serial
// queue before hopping to the main queue, so completions are always
// asynchronous and arrive in request order.
static dispatch_queue_t MPTextCountQueue(void)
{
    static dispatch_queue_t queue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.uranusjr.macdown.preview-text-count", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void MPDeliverTextCount(
    void (^completion)(MPPreviewTextCount, NSError *),
    id payload, NSError *error)
{
    if (!completion)
        return;
    dispatch_async(MPTextCountQueue(), ^{
        MPPreviewTextCount count = {0, 0, 0};
        if (!error)
            count = MPPreviewTextCountFromPayload(payload);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(count, error);
        });
    });
}

void MPPreviewEvaluateTextCount(
    WKWebView *webView,
    void (^completion)(MPPreviewTextCount count, NSError *error))
{
    void (^handler)(MPPreviewTextCount, NSError *) = [completion copy];
    if (!webView)
    {
        NSError *error = MPPreviewTextCountError(
            MPPreviewTextCountErrorNoWebView,
            @"No web view to count text in.");
        MPDeliverTextCount(handler, nil, error);
        return;
    }
    NSString *script = MPPreviewTextCountScript();
    if (!script.length)
    {
        NSError *error = MPPreviewTextCountError(
            MPPreviewTextCountErrorScriptUnavailable,
            @"The text counting script is missing from the app bundle.");
        MPDeliverTextCount(handler, nil, error);
        return;
    }
    [webView evaluateJavaScript:script completionHandler:
     ^(id result, NSError *error) {
         MPDeliverTextCount(handler, result, error);
     }];
}
