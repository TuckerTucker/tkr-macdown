//
//  MPAsset.h
//  MacDown
//
//  Created by Tzu-ping Chung  on 29/6.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import <Foundation/Foundation.h>


typedef NS_ENUM(NSInteger, MPAssetOption)
{
    MPAssetNone,
    MPAssetEmbedded,
    MPAssetFullLink,
    /**
     *  Like MPAssetFullLink, except that a file: URL is emitted as an
     *  x-macdown-asset:///<absolute path> URL, which the preview's
     *  WKURLSchemeHandler serves. Non-file URLs pass through unchanged. Use
     *  this for HTML loaded into the in-app preview; never for exported HTML.
     */
    MPAssetPreviewLink,
};

extern NSString * const kMPCSSType;
extern NSString * const kMPJavaScriptType;
extern NSString * const kMPMathJaxConfigType;

/** URL scheme under which the preview serves app/user asset files. */
extern NSString * const kMPPreviewAssetScheme;


@interface MPAsset : NSObject
+ (instancetype)assetWithURL:(NSURL *)url andType:(NSString *)typeName;
- (instancetype)initWithURL:(NSURL *)url andType:(NSString *)typeName;
- (NSString *)htmlForOption:(MPAssetOption)option;

/**
 *  The URL an asset at @c url is referenced by in preview HTML.
 *
 *  @param url Any URL. May be nil.
 *  @return For a file URL, @c x-macdown-asset:///<absolute path> with the path
 *          percent-encoded by NSURLComponents; any other URL unchanged; nil
 *          for nil.
 */
+ (NSURL *)previewURLForURL:(NSURL *)url;
@end


@interface MPStyleSheet : MPAsset
+ (instancetype)CSSWithURL:(NSURL *)url;
@end


@interface MPScript : MPAsset
+ (instancetype)javaScriptWithURL:(NSURL *)url;

/**
 *  A script whose linked form carries Subresource Integrity.
 *
 *  @param url The script URL.
 *  @param integrity An SRI metadata string such as @c "sha384-<base64>". When
 *         non-nil, linked renderings (full and preview links) emit
 *         @c integrity="..." and @c crossorigin="anonymous". Embedded
 *         renderings inline the content and carry neither.
 */
+ (instancetype)javaScriptWithURL:(NSURL *)url integrity:(NSString *)integrity;

/** SRI metadata emitted on linked renderings, or nil. */
@property (copy, readonly) NSString *integrity;
@end


@interface MPEmbeddedScript : MPScript
@end