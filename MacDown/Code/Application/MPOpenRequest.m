//
//  MPOpenRequest.m
//  MacDown
//

#import "MPOpenRequest.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>


NSString * const MPOpenRequestErrorDomain = @"com.uranusjr.macdown.open-request";


// stringByResolvingSymlinksInPath turns /private/var/x into /var/x, but only
// when x exists; read both spellings the same way.
static NSString *MPShortSystemPath(NSString *path)
{
    for (NSString *prefix in @[@"/private/var", @"/private/etc",
                               @"/private/tmp"])
    {
        if ([path isEqualToString:prefix]
                || [path hasPrefix:[prefix stringByAppendingString:@"/"]])
            return [path substringFromIndex:@"/private".length];
    }
    return path;
}

static BOOL MPPathIsWithin(NSString *path, NSString *folder)
{
    if ([folder hasSuffix:@"/"])
        folder = [folder substringToIndex:folder.length - 1];
    return [path isEqualToString:folder]
        || [path hasPrefix:[folder stringByAppendingString:@"/"]];
}

static NSString *MPCanonicalPath(NSString *path)
{
    path = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
    return MPShortSystemPath(path);
}


@interface MPOpenRequest ()
@property (nonatomic, copy) NSArray<UTType *> *editableTypes;
@property (nonatomic, copy) NSSet<NSString *> *editableExtensions;
@end


@implementation MPOpenRequest

+ (NSArray<NSString *> *)protectedLocations
{
    return @[@"/System", @"/Library", @"/usr", @"/bin", @"/sbin", @"/dev",
             @"/cores", @"/etc", @"/var", @"/private"];
}

- (instancetype)initWithInfoDictionary:(NSDictionary *)info
{
    self = [super init];
    if (!self)
        return nil;

    NSMutableArray<UTType *> *types = [NSMutableArray array];
    NSMutableSet<NSString *> *extensions = [NSMutableSet set];
    for (NSDictionary *entry in info[@"CFBundleDocumentTypes"])
    {
        if (![entry isKindOfClass:[NSDictionary class]]
                || ![entry[@"CFBundleTypeRole"] isEqual:@"Editor"])
            continue;
        for (NSString *identifier in entry[@"LSItemContentTypes"])
        {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type)
                [types addObject:type];
        }
        for (NSString *extension in entry[@"CFBundleTypeExtensions"])
            [extensions addObject:extension.lowercaseString];
    }
    self.editableTypes = types;
    self.editableExtensions = extensions;
    return self;
}


#pragma mark - Errors

- (NSError *)errorWithCode:(MPOpenRequestErrorCode)code
                    target:(NSString *)target
                suggestion:(NSString *)suggestion
{
    NSString *name = target.lastPathComponent;
    NSString *description = name.length ?
        [NSString stringWithFormat:NSLocalizedString(
            @"MacDown didn't open “%@” from a link.",
            @"Open request refused: title naming the file"), name] :
        NSLocalizedString(@"MacDown didn't open a link it was sent.",
                          @"Open request refused: title without a file");
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description;
    info[NSLocalizedRecoverySuggestionErrorKey] = suggestion;
    if (target)
        info[NSFilePathErrorKey] = target;
    return [NSError errorWithDomain:MPOpenRequestErrorDomain code:code
                           userInfo:info];
}

static NSURL *MPFail(NSError **error, NSError *reason)
{
    if (error)
        *error = reason;
    return nil;
}


#pragma mark - Validation

- (NSURL *)fileURLForRequest:(NSString *)requestString error:(NSError **)error
{
    NSString *malformed = NSLocalizedString(
        @"The link isn't a MacDown open link. Open links look like "
        @"x-macdown://open?url=file:///path/to/file.md",
        @"Open request refused: malformed x-macdown URL");

    NSURLComponents *components = requestString.length ?
        [NSURLComponents componentsWithString:requestString] : nil;
    if (!components
            || ![components.scheme.lowercaseString isEqualToString:@"x-macdown"]
            || ![components.host isEqualToString:@"open"])
    {
        return MPFail(error, [self errorWithCode:MPOpenRequestErrorMalformed
                                          target:nil suggestion:malformed]);
    }
    NSString *target = nil;
    for (NSURLQueryItem *item in components.queryItems)
    {
        if ([item.name isEqualToString:@"url"])
        {
            target = item.value;
            break;
        }
    }
    if (!target.length)
    {
        return MPFail(error, [self errorWithCode:MPOpenRequestErrorMalformed
                                          target:nil suggestion:malformed]);
    }
    return [self fileURLForTarget:target error:error];
}

- (NSURL *)fileURLForTarget:(NSString *)targetString error:(NSError **)error
{
    NSURL *target = targetString.length ?
        [NSURL URLWithString:targetString] : nil;
    if (!target.isFileURL || !target.path.length)
    {
        NSString *suggestion = NSLocalizedString(
            @"Only files on this Mac can be opened from a link. To read a web "
            @"page, open it in your browser.",
            @"Open request refused: not a file URL");
        return MPFail(error, [self errorWithCode:MPOpenRequestErrorNotAFile
                                          target:nil suggestion:suggestion]);
    }

    // Resolve "../" and symlinks first, so neither can lead the checks below
    // somewhere other than the file that would be opened.
    NSString *path = MPCanonicalPath(target.path);
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory])
    {
        NSString *suggestion = [NSString stringWithFormat:NSLocalizedString(
            @"There is no file at %@. It may have been moved or renamed.",
            @"Open request refused: no such file"), target.path];
        return MPFail(error, [self errorWithCode:MPOpenRequestErrorNoSuchFile
                                          target:target.path
                                      suggestion:suggestion]);
    }
    if (isDirectory)
    {
        NSString *suggestion = NSLocalizedString(
            @"The link points to a folder. MacDown opens files.",
            @"Open request refused: directory");
        return MPFail(error, [self errorWithCode:MPOpenRequestErrorDirectory
                                          target:path suggestion:suggestion]);
    }

    NSString *temporary = MPCanonicalPath(NSTemporaryDirectory());
    if (!MPPathIsWithin(path, temporary))
    {
        for (NSString *location in [[self class] protectedLocations])
        {
            if (!MPPathIsWithin(path, location))
                continue;
            NSString *suggestion = [NSString stringWithFormat:NSLocalizedString(
                @"Files in %@ are part of the system and can't be opened from "
                @"a link. To read this file, choose File > Open in MacDown.",
                @"Open request refused: protected location"), location];
            return MPFail(error, [self
                errorWithCode:MPOpenRequestErrorProtectedLocation
                       target:path suggestion:suggestion]);
        }
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    if (![self isEditableFileAtURL:url])
    {
        NSString *suggestion = NSLocalizedString(
            @"Links can only open Markdown and plain text files. To read this "
            @"file, choose File > Open in MacDown.",
            @"Open request refused: unsupported file type");
        return MPFail(error, [self
            errorWithCode:MPOpenRequestErrorUnsupportedType
                   target:path suggestion:suggestion]);
    }
    return url;
}

- (BOOL)isEditableFileAtURL:(NSURL *)url
{
    if ([self.editableExtensions containsObject:
            url.pathExtension.lowercaseString])
        return YES;
    UTType *type = nil;
    [url getResourceValue:&type forKey:NSURLContentTypeKey error:NULL];
    for (UTType *editable in self.editableTypes)
    {
        if ([type conformsToType:editable])
            return YES;
    }
    return NO;
}

@end
