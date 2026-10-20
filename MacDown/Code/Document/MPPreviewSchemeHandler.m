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
    @"img-src x-macdown-file: x-macdown-asset: https: http: data:; "
    @"media-src x-macdown-file: https: http:; "
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

NS_INLINE NSString *MPPreviewMIMETypeForPath(NSString *path)
{
    UTType *type = [UTType typeWithFilenameExtension:path.pathExtension];
    NSString *mime = type.preferredMIMEType;
    if (!mime)
        return @"application/octet-stream";
    if ([type conformsToType:UTTypeText])
        return [mime stringByAppendingString:@"; charset=utf-8"];
    return mime;
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

    dispatch_async(self.ioQueue, ^{
        BOOL isDirectory = NO;
        NSFileManager *manager = [NSFileManager defaultManager];
        NSData *data = nil;
        if ([manager fileExistsAtPath:path isDirectory:&isDirectory]
                && !isDirectory)
        {
            data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!data)
            {
                [self respondToTask:task url:url status:404 headers:@{}
                               data:nil];
                return;
            }
            NSDictionary *headers = @{
                @"Content-Type": MPPreviewMIMETypeForPath(path),
            };
            [self respondToTask:task url:url status:200 headers:headers
                           data:data];
        });
    });
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
