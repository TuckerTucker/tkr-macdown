//
//  MPPreviewNavigationPolicy.m
//  MacDown
//

#import "MPPreviewNavigationPolicy.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>


#pragma mark - Code-bearing predicate

NS_INLINE NSArray<UTType *> *MPCodeBearingTypes(void)
{
    static NSArray<UTType *> *types = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSMutableArray *list = [@[
            UTTypeApplication, UTTypeApplicationBundle,
            UTTypeApplicationExtension, UTTypeExecutable,
            UTTypeUnixExecutable, UTTypeScript, UTTypeShellScript,
            UTTypeAppleScript, UTTypePluginBundle, UTTypeBundle,
        ] mutableCopy];
        // Declared by system apps rather than the UTType headers; any the
        // system does not know resolve to nil and are skipped. Location
        // files open whatever URL they hold, including a local app.
        NSArray *identifiers = @[
            @"com.apple.installer-package-archive",
            @"com.apple.terminal.shell-script",
            @"com.apple.terminal.settings",
            @"com.apple.automator-workflow",
            @"com.apple.automator-action",
            @"com.apple.applescript.script",
            @"com.apple.applescript.script-bundle",
            @"com.apple.internet-location",
            @"com.apple.web-internet-location",
            @"com.apple.file-internet-location",
            @"com.apple.generic-internet-location",
        ];
        for (NSString *identifier in identifiers)
        {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type)
                [list addObject:type];
        }
        types = [list copy];
    });
    return types;
}

// Extensions whose system type may be undeclared (a dynamic UTI conforms to
// nothing), so the type check alone would miss them.
NS_INLINE NSSet<NSString *> *MPCodeBearingExtensions(void)
{
    static NSSet<NSString *> *extensions = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        extensions = [NSSet setWithArray:@[
            @"app", @"appex", @"bundle", @"plugin", @"kext", @"prefpane",
            @"saver", @"qlgenerator", @"mdimporter", @"xpc", @"framework",
            @"component", @"service", @"osax", @"wdgt", @"workflow",
            @"action", @"scpt", @"scptd", @"applescript", @"pkg", @"mpkg",
            @"command", @"tool", @"terminal", @"sh", @"jar", @"webloc",
            @"inetloc", @"fileloc",
        ]];
    });
    return extensions;
}

NS_INLINE BOOL MPTypeIsCodeBearing(UTType *type)
{
    if (!type)
        return NO;
    for (UTType *codeType in MPCodeBearingTypes())
    {
        if ([type conformsToType:codeType])
            return YES;
    }
    return NO;
}

NS_INLINE BOOL MPItemIsCodeBearing(NSURL *url)
{
    NSString *extension = url.pathExtension.lowercaseString;
    if ([MPCodeBearingExtensions() containsObject:extension])
        return YES;
    UTType *extensionType = extension.length ?
        [UTType typeWithFilenameExtension:extension] : nil;
    if (MPTypeIsCodeBearing(extensionType))
        return YES;

    NSNumber *isDirectory = nil;
    if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey
                         error:NULL] || !isDirectory)
        return NO;  // Nonexistent: the extension checks above decide.

    UTType *contentType = nil;
    [url getResourceValue:&contentType forKey:NSURLContentTypeKey error:NULL];
    if (MPTypeIsCodeBearing(contentType))
        return YES;

    if (isDirectory.boolValue)
    {
        NSNumber *isPackage = nil;
        [url getResourceValue:&isPackage forKey:NSURLIsPackageKey error:NULL];
        return isPackage.boolValue;
    }
    return [[NSFileManager defaultManager]
            isExecutableFileAtPath:url.path];
}

MPCodeBearingPredicate MPPreviewNavigationPolicyDefaultCodeBearingPredicate(
    void)
{
    return ^BOOL(NSURL *fileURL) {
        if (!fileURL.isFileURL || !fileURL.path.length)
            return YES;
        if (MPItemIsCodeBearing(fileURL))
            return YES;

        NSURL *resolved = fileURL.URLByResolvingSymlinksInPath;
        NSNumber *isAlias = nil;
        [resolved getResourceValue:&isAlias forKey:NSURLIsAliasFileKey
                             error:NULL];
        if (isAlias.boolValue)
        {
            NSURLBookmarkResolutionOptions options =
                NSURLBookmarkResolutionWithoutUI
                | NSURLBookmarkResolutionWithoutMounting;
            resolved = [NSURL URLByResolvingAliasFileAtURL:resolved
                                                   options:options
                                                     error:NULL];
            if (!resolved)
                return YES;
            resolved = resolved.URLByResolvingSymlinksInPath;
        }
        if ([resolved isEqual:fileURL])
            return NO;
        return MPItemIsCodeBearing(resolved);
    };
}


#pragma mark - Decision

@interface MPPreviewNavigationDecision ()
@property (readwrite) MPPreviewNavigationAction action;
@property (readwrite, nullable) NSURL *targetURL;
@end


@implementation MPPreviewNavigationDecision

- (instancetype)initWithAction:(MPPreviewNavigationAction)action
                     targetURL:(NSURL *)targetURL
{
    self = [super init];
    if (!self)
        return nil;
    _action = action;
    _targetURL = targetURL;
    return self;
}

- (NSString *)description
{
    static NSString * const names[] = {
        @"Allow", @"Cancel", @"Open", @"Reveal",
    };
    return [NSString stringWithFormat:@"<%@ %@ %@>",
            self.class, names[self.action], self.targetURL];
}

@end


NS_INLINE MPPreviewNavigationDecision *MPDecision(
    MPPreviewNavigationAction action, NSURL *targetURL)
{
    return [[MPPreviewNavigationDecision alloc] initWithAction:action
                                                     targetURL:targetURL];
}

NS_INLINE BOOL MPIsLocalScheme(NSString *scheme)
{
    return [scheme isEqualToString:@"file"]
        || [scheme isEqualToString:kMPPreviewFileScheme];
}

// Identifies a document independent of fragment and query. Local URLs
// compare by scheme and percent-decoded, standardised path.
NS_INLINE NSString *MPDocumentKey(NSURL *url)
{
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length)
        return nil;
    if (MPIsLocalScheme(scheme))
    {
        NSString *path = url.path.stringByStandardizingPath;
        if (!path.length)
            return nil;
        return [NSString stringWithFormat:@"%@:%@", scheme, path];
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    components.fragment = nil;
    components.query = nil;
    components.scheme = scheme;
    components.host = components.host.lowercaseString;
    return components.string;
}


@interface MPPreviewNavigationPolicy ()
@property (copy) MPCodeBearingPredicate isCodeBearing;
@end


@implementation MPPreviewNavigationPolicy

- (instancetype)initWithCodeBearingPredicate:(MPCodeBearingPredicate)predicate
{
    self = [super init];
    if (!self)
        return nil;
    _isCodeBearing = [predicate copy];
    return self;
}

- (instancetype)init
{
    return [self initWithCodeBearingPredicate:
            MPPreviewNavigationPolicyDefaultCodeBearingPredicate()];
}

+ (NSURL *)fileURLForPreviewURL:(NSURL *)url
{
    if (!MPIsLocalScheme(url.scheme.lowercaseString))
        return nil;
    NSString *host = url.host;
    if (host.length && [host caseInsensitiveCompare:@"localhost"])
        return nil;
    NSString *path = url.path;
    if (![path hasPrefix:@"/"] || [path rangeOfString:@"\0"].length)
        return nil;
    return [NSURL fileURLWithPath:path isDirectory:url.hasDirectoryPath];
}

+ (NSURL *)linkTargetForFileURL:(NSURL *)fileURL
{
    if (fileURL.pathExtension.length
            || [fileURL checkResourceIsReachableAndReturnError:NULL])
        return fileURL;
    NSURL *markdownURL = [fileURL URLByAppendingPathExtension:@"md"];
    if ([markdownURL checkResourceIsReachableAndReturnError:NULL])
        return markdownURL;
    return fileURL;
}

- (MPPreviewNavigationDecision *)decisionForURL:(NSURL *)url
                                 navigationType:(WKNavigationType)type
                                    isMainFrame:(BOOL)isMainFrame
                              sourceIsMainFrame:(BOOL)sourceIsMainFrame
                                     currentURL:(NSURL *)currentURL
{
    MPPreviewNavigationDecision *cancel =
        MPDecision(MPPreviewNavigationActionCancel, nil);

    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length)
        return cancel;

    NSURL *fileURL = nil;
    if (MPIsLocalScheme(scheme))
    {
        fileURL = [[self class] fileURLForPreviewURL:url];
        if (!fileURL)
            return cancel;
    }

    if (!isMainFrame)
    {
        if ([scheme isEqualToString:@"http"]
                || [scheme isEqualToString:@"https"])
            return MPDecision(MPPreviewNavigationActionAllow, nil);
        NSString *string = url.absoluteString.lowercaseString;
        if ([string isEqualToString:@"about:blank"]
                || [string isEqualToString:@"about:srcdoc"])
            return MPDecision(MPPreviewNavigationActionAllow, nil);
        return cancel;
    }

    NSString *key = MPDocumentKey(url);
    NSString *currentKey = currentURL ? MPDocumentKey(currentURL) : nil;
    if (key && [key isEqualToString:currentKey])
    {
        if (type == WKNavigationTypeLinkActivated
                && [url.absoluteString isEqualToString:
                    currentURL.absoluteString])
            return cancel;
        return MPDecision(MPPreviewNavigationActionAllow, nil);
    }

    if (type != WKNavigationTypeLinkActivated || !sourceIsMainFrame)
        return cancel;

    if (fileURL)
    {
        NSURL *target = [[self class] linkTargetForFileURL:fileURL];
        if (!self.isCodeBearing || self.isCodeBearing(target))
            return MPDecision(MPPreviewNavigationActionReveal, target);
        return MPDecision(MPPreviewNavigationActionOpen, target);
    }

    static NSSet *cancelled = nil;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        cancelled = [NSSet setWithArray:@[
            kMPPreviewAssetScheme, @"javascript", @"data", @"blob", @"about",
        ]];
    });
    if ([cancelled containsObject:scheme])
        return cancel;
    // http, https, mailto, and app URL schemes (see rule 5 in the header).
    return MPDecision(MPPreviewNavigationActionOpen, url);
}

@end
