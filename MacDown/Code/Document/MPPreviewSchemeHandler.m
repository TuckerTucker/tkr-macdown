//
//  MPPreviewSchemeHandler.m
//  MacDown
//

#import "MPPreviewSchemeHandler.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString * const kMPPreviewFileScheme = @"x-macdown-file";
NSString * const kMPPreviewAssetScheme = @"x-macdown-asset";

NSString * const kMPPreviewContentSecurityPolicy =
    @"default-src 'none'; "
    @"script-src x-macdown-asset:; "
    @"style-src x-macdown-asset: x-macdown-file: 'unsafe-inline'; "
    @"font-src x-macdown-asset: x-macdown-file: data:; "
    @"img-src x-macdown-file: x-macdown-asset: https: data:; "
    @"media-src x-macdown-file: https:; "
    @"frame-src https:; "
    @"base-uri 'none'; form-action 'none'; object-src 'none'";


NSURL *MPPreviewURLForPath(NSString *scheme, NSString *path)
{
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = @"";
    components.path = path.stringByStandardizingPath;
    return components.URL;
}

NS_INLINE NSString *MPPreviewPageKey(NSURL *url)
{
    return url.path.stringByStandardizingPath;
}

// A charset is declared only for text that is valid UTF-8. Anything else is
// left to WebKit, which honours a BOM or an @charset rule the way the legacy
// file:// preview did; a declared charset would override both.
NS_INLINE NSString *MPPreviewMIMETypeForPath(NSString *path, NSData *data)
{
    UTType *type = [UTType typeWithFilenameExtension:path.pathExtension];
    NSString *mime = type.preferredMIMEType;
    if (!mime)
        return @"application/octet-stream";
    if (data && [type conformsToType:UTTypeText]
            && [[NSString alloc] initWithData:data
                                     encoding:NSUTF8StringEncoding])
        return [mime stringByAppendingString:@"; charset=utf-8"];
    return mime;
}

// The single byte range a Range header asks for in a file of length bytes.
// Returns NO for a header this handler does not narrow the response by (a
// missing, malformed or multi-range one), which is answered with the whole
// file. *satisfiable is NO when the range lies past the end of the file.
static BOOL MPPreviewByteRange(NSString *header, unsigned long long length,
                               NSRange *range, BOOL *satisfiable)
{
    NSString *prefix = @"bytes=";
    if (![header hasPrefix:prefix])
        return NO;
    NSString *spec = [header substringFromIndex:prefix.length];
    spec = [spec stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
    NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"-"];
    if ([spec containsString:@","] || parts.count != 2)
        return NO;
    NSCharacterSet *nonDigits =
        [NSCharacterSet decimalDigitCharacterSet].invertedSet;
    for (NSString *part in parts)
    {
        if ([part rangeOfCharacterFromSet:nonDigits].location != NSNotFound)
            return NO;
    }
    NSString *first = parts[0];
    NSString *last = parts[1];
    unsigned long long start = 0;
    unsigned long long end = 0;
    if (!first.length)
    {
        // bytes=-N: the last N bytes.
        if (!last.length)
            return NO;
        unsigned long long suffix = strtoull(last.UTF8String, NULL, 10);
        if (!suffix || !length)
        {
            *satisfiable = NO;
            return YES;
        }
        start = suffix >= length ? 0 : length - suffix;
        end = length - 1;
    }
    else
    {
        start = strtoull(first.UTF8String, NULL, 10);
        if (last.length
                && strtoull(last.UTF8String, NULL, 10) < start)
            return NO;
        if (start >= length)
        {
            *satisfiable = NO;
            return YES;
        }
        end = last.length ?
            MIN(strtoull(last.UTF8String, NULL, 10), length - 1) : length - 1;
    }
    *satisfiable = YES;
    *range = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1));
    return YES;
}


@interface MPPreviewSchemeHandler ()
@property (copy) NSArray<NSString *> *rootPaths;
@property (strong) NSMutableDictionary<NSString *, NSData *> *pages;
@property (strong) NSHashTable *activeTasks;
@property (strong) dispatch_queue_t ioQueue;
@end


@implementation MPPreviewSchemeHandler

- (instancetype)initWithAllowedRoots:(NSArray<NSURL *> *)roots
{
    self = [super init];
    if (!self)
        return nil;

    if (roots)
    {
        NSMutableArray *paths = [NSMutableArray array];
        for (NSURL *root in roots)
        {
            NSString *path = root.path.stringByStandardizingPath
                .stringByResolvingSymlinksInPath;
            if (path.length)
                [paths addObject:path];
        }
        self.rootPaths = paths;
    }
    self.pages = [NSMutableDictionary dictionary];
    self.activeTasks = [NSHashTable weakObjectsHashTable];
    self.ioQueue = dispatch_queue_create(
        "com.uranusjr.macdown.preview-scheme", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)setPageHTML:(NSString *)html forURL:(NSURL *)url
{
    NSString *key = MPPreviewPageKey(url);
    if (!key)
        return;
    self.pages[key] = [html dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)isPathAllowed:(NSString *)path
{
    if (!self.rootPaths)
        return YES;
    for (NSString *root in self.rootPaths)
    {
        if ([path isEqualToString:root]
                || [path hasPrefix:[root stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}


#pragma mark - WKURLSchemeHandler

- (void)webView:(WKWebView *)webView
        startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSURL *url = task.request.URL;
    [self.activeTasks addObject:task];

    NSData *page = self.pages[MPPreviewPageKey(url)];
    if (page)
    {
        NSDictionary *headers = @{
            @"Content-Type": @"text/html; charset=utf-8",
            @"Content-Security-Policy": kMPPreviewContentSecurityPolicy,
        };
        [self respondToTask:task url:url status:200 headers:headers data:page];
        return;
    }

    NSString *path =
        url.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (!path.length || ![self isPathAllowed:path])
    {
        [self respondToTask:task url:url status:404 headers:@{} data:nil];
        return;
    }

    // Media elements read local audio and video in byte ranges, and cannot
    // play or seek a file served only whole.
    NSString *rangeHeader = [task.request valueForHTTPHeaderField:@"Range"];
    dispatch_async(self.ioQueue, ^{
        NSInteger status = 404;
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        NSData *data = [self readFileAtPath:path range:rangeHeader
                                     status:&status headers:headers];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self respondToTask:task url:url status:status headers:headers
                           data:data];
        });
    });
}

// Runs on ioQueue. Reads the file, or the part of it rangeHeader asks for,
// and fills in the status and headers to answer with.
- (NSData *)readFileAtPath:(NSString *)path range:(NSString *)rangeHeader
                    status:(NSInteger *)status
                   headers:(NSMutableDictionary *)headers
{
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]
            || isDirectory)
        return nil;
    NSDictionary *attributes = [manager attributesOfItemAtPath:path
                                                         error:NULL];
    unsigned long long length = attributes.fileSize;

    NSRange range = NSMakeRange(0, 0);
    BOOL satisfiable = YES;
    BOOL ranged = rangeHeader
        && MPPreviewByteRange(rangeHeader, length, &range, &satisfiable);
    headers[@"Accept-Ranges"] = @"bytes";
    if (ranged && !satisfiable)
    {
        *status = 416;
        headers[@"Content-Range"] =
            [NSString stringWithFormat:@"bytes */%llu", length];
        return [NSData data];
    }

    NSData *data = nil;
    if (ranged)
    {
        NSFileHandle *handle =
            [NSFileHandle fileHandleForReadingAtPath:path];
        if ([handle seekToOffset:range.location error:NULL])
            data = [handle readDataUpToLength:range.length error:NULL];
        [handle closeAndReturnError:NULL];
    }
    else
    {
        data = [NSData dataWithContentsOfFile:path
                                      options:NSDataReadingMappedIfSafe
                                        error:NULL];
    }
    if (!data)
        return nil;

    if (ranged)
    {
        *status = 206;
        headers[@"Content-Range"] = [NSString stringWithFormat:
            @"bytes %lu-%lu/%llu", (unsigned long)range.location,
            (unsigned long)(range.location + data.length - 1), length];
        headers[@"Content-Type"] = MPPreviewMIMETypeForPath(path, nil);
    }
    else
    {
        *status = 200;
        headers[@"Content-Type"] = MPPreviewMIMETypeForPath(path, data);
    }
    return data;
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    [self.activeTasks removeObject:task];
}

- (void)respondToTask:(id<WKURLSchemeTask>)task url:(NSURL *)url
               status:(NSInteger)status headers:(NSDictionary *)headers
                 data:(NSData *)data
{
    // WebKit raises if a task is answered after it has been stopped.
    if (![self.activeTasks containsObject:task])
        return;
    [self.activeTasks removeObject:task];

    // Files change on disk while the preview is open (#931); never let WebKit
    // reuse a stale copy.
    NSMutableDictionary *fields = [headers mutableCopy];
    fields[@"Cache-Control"] = @"no-store";
    fields[@"Content-Length"] = @(data.length).stringValue;
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:fields];
    [task didReceiveResponse:response];
    if (data.length)
        [task didReceiveData:data];
    [task didFinish];
}

@end
