//
//  MPOpenRequest.h
//  MacDown
//
//  Decides whether an x-macdown:// open request may be carried out (TB-3).
//  The request arrives from a browser or another app, so everything in it is
//  attacker-controllable:
//
//      x-macdown://open?url=file:///path/to/a/file&line=123&column=45
//
//  A request is honoured only when its url names an existing regular file on
//  this Mac, outside the system locations below, whose type is one MacDown
//  edits (Markdown or plain text). Anything else is refused with an error
//  that says what was wrong and what the user can do instead, so it can be
//  shown to them rather than only logged.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MPOpenRequestErrorDomain;

typedef NS_ENUM(NSInteger, MPOpenRequestErrorCode)
{
    // Not of the form x-macdown://open?url=...
    MPOpenRequestErrorMalformed = 1,
    // The url is not a file:// URL (http:, javascript:, data:, ...).
    MPOpenRequestErrorNotAFile = 2,
    // Nothing exists at the path.
    MPOpenRequestErrorNoSuchFile = 3,
    // The path is a directory or a package.
    MPOpenRequestErrorDirectory = 4,
    // The file is in a protected system location.
    MPOpenRequestErrorProtectedLocation = 5,
    // The file exists but is not a type MacDown edits.
    MPOpenRequestErrorUnsupportedType = 6,
};


@interface MPOpenRequest : NSObject

// Folders whose contents may never be opened by a request. Compared after
// symlinks are resolved, with /private/var, /private/etc and /private/tmp
// read as /var, /etc and /tmp. The user's own temporary folder, which lives
// under /var, is not protected.
@property (class, nonatomic, readonly) NSArray<NSString *> *protectedLocations;

// info is an Info.plist dictionary. The app edits the types, and the
// extensions, of each Editor-role CFBundleDocumentTypes entry; Viewer-role
// entries (MacDown can view any data) do not count.
- (instancetype)initWithInfoDictionary:(nullable NSDictionary *)info
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The file a whole x-macdown:// URL asks to open, or nil with error set.
- (nullable NSURL *)fileURLForRequest:(NSString *)requestString
                                error:(NSError **)error;

// The file the url parameter of a request names, canonicalised, or nil
// with error set.
- (nullable NSURL *)fileURLForTarget:(NSString *)targetString
                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
