//
//  MPAsset.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 29/6.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPAsset.h"
#import <HBHandlebars/HBHandlebars.h>
#import "MPUtilities.h"


NSString * const kMPPlainType = @"text/plain";
NSString * const kMPCSSType = @"text/css";
NSString * const kMPJavaScriptType = @"text/javascript";
NSString * const kMPMathJaxConfigType = @"text/x-mathjax-config";
NSString * const kMPPreviewAssetScheme = @"x-macdown-asset";


@interface MPAsset ()
@property (strong) NSURL *url;
@property (copy, nonatomic) NSString *typeName;
@property (readonly) NSString *defaultTypeName;
- (NSMutableDictionary *)templateContext;
@end


@implementation MPAsset

- (NSString *)typeName
{
    return _typeName ? _typeName : self.defaultTypeName;
}

- (NSString *)defaultTypeName
{
    return kMPPlainType;
}


+ (instancetype)assetWithURL:(NSURL *)url andType:(NSString *)typeName
{
    return [[self alloc] initWithURL:url andType:typeName];
}

- (instancetype)initWithURL:(NSURL *)url andType:(NSString *)typeName
{
    self = [super init];
    if (!self)
        return nil;
    self.url = [url copy];
    self.typeName = typeName;
    return self;
}

- (instancetype)init
{
    return [self initWithURL:nil andType:nil];
}

+ (NSURL *)previewURLForURL:(NSURL *)url
{
    if (!url.isFileURL)
        return url;
    NSString *path = url.URLByStandardizingPath.path;
    if (!path.length)
        return nil;
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = kMPPreviewAssetScheme;
    components.host = @"";
    components.path = path;     // NSURLComponents percent-encodes the path.
    return components.URL;
}

- (NSMutableDictionary *)templateContext
{
    return [NSMutableDictionary dictionaryWithObject:self.typeName
                                              forKey:@"typeName"];
}

- (NSString *)templateForOption:(MPAssetOption)option
{
    NSString *reason =
        [NSString stringWithFormat:@"Method %@ requires overriding",
                                   NSStringFromSelector(_cmd)];
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:reason userInfo:nil];
}

- (NSString *)htmlForOption:(MPAssetOption)option
{
    NSMutableDictionary *context = [self templateContext];
    switch (option)
    {
        case MPAssetNone:
            break;
        case MPAssetEmbedded:
            if (self.url.isFileURL)
            {
                NSString *content = MPReadFileOfPath(self.url.path);
                if ([content hasSuffix:@"\n"])
                    content = [content substringToIndex:content.length - 1];
                context[@"content"] = content;
                break;
            }
            // Non-file URLs fallthrough to be treated as full links.
        case MPAssetFullLink:
            context[@"url"] = self.url.absoluteString;
            break;
        case MPAssetPreviewLink:
            context[@"url"] =
                [[self class] previewURLForURL:self.url].absoluteString;
            break;
    }

    NSString *template = [self templateForOption:option];
    if (!template || !context.count)
        return nil;

    NSString *result = [HBHandlebars renderTemplateString:template
                                              withContext:context error:NULL];

    return result;
}

@end


@implementation MPStyleSheet

- (NSString *)defaultTypeName
{
    return kMPCSSType;
}

+ (instancetype)CSSWithURL:(NSURL *)url
{
    return [super assetWithURL:url andType:kMPCSSType];
}

- (NSString *)templateForOption:(MPAssetOption)option
{
    NSString *template = nil;
    switch (option)
    {
        case MPAssetNone:
            break;
        case MPAssetEmbedded:
            if (self.url.isFileURL)
            {
                template = (@"<style type=\"{{ typeName }}\">\n"
                            @"{{{ content }}}\n</style>");
                break;
            }
            // Non-file URLs fallthrough to be treated as full links.
        case MPAssetFullLink:
        case MPAssetPreviewLink:
            template = (@"<link rel=\"stylesheet\" type=\"{{ typeName }}\" "
                        @"href=\"{{ url }}\">");
            break;
    }
    return template;
}

@end


@implementation MPScript

- (NSString *)defaultTypeName
{
    return kMPJavaScriptType;
}

+ (instancetype)javaScriptWithURL:(NSURL *)url
{
    return [super assetWithURL:url andType:kMPJavaScriptType];
}

+ (instancetype)javaScriptWithURL:(NSURL *)url integrity:(NSString *)integrity
{
    MPScript *script = [self javaScriptWithURL:url];
    script->_integrity = [integrity copy];
    return script;
}

- (NSMutableDictionary *)templateContext
{
    NSMutableDictionary *context = [super templateContext];
    if (self.integrity.length)
        context[@"integrity"] = self.integrity;
    return context;
}

- (NSString *)templateForOption:(MPAssetOption)option
{
    NSString *template = nil;
    switch (option)
    {
        case MPAssetNone:
            break;
        case MPAssetEmbedded:
            if (self.url.isFileURL)
            {
                template = (@"<script type=\"{{ typeName }}\">\n"
                            @"{{{ content }}}\n</script>");
                break;
            }
            // Non-file URLs fall-through to be treated as full links.
        case MPAssetFullLink:
        case MPAssetPreviewLink:
            template = (@"<script type=\"{{ typeName }}\" src=\"{{ url }}\""
                        @"{{#if integrity }} integrity=\"{{ integrity }}\""
                        @" crossorigin=\"anonymous\"{{/if }}></script>");
            break;
    }
    return template;
}

@end


@implementation MPEmbeddedScript

- (NSString *)htmlForOption:(MPAssetOption)option
{
    // An embedded script is always inlined. It must therefore never be part
    // of preview HTML, whose Content-Security-Policy blocks inline scripts.
    if (option == MPAssetFullLink || option == MPAssetPreviewLink)
        option = MPAssetEmbedded;
    return [super htmlForOption:option];
}

@end
