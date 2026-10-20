//
//  MPPlugIn.h
//  MacDown
//
//  Created by Tzu-ping Chung on 02/3.
//  Copyright © 2016 Tzu-ping Chung . All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MPDOcument.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MPPlugInErrorDomain;

typedef NS_ENUM(NSInteger, MPPlugInErrorCode)
{
    // The bundle carries no code signature at all.
    MPPlugInErrorUnsigned = 1,
    // The signature is malformed, or the bundle was modified after signing.
    MPPlugInErrorInvalidSignature = 2,
    // The bundle is ad-hoc signed: no signing identity stands behind it.
    MPPlugInErrorAdHocSignature = 3,
    // Signed, but not by an identity satisfying the code requirement.
    MPPlugInErrorRequirementNotSatisfied = 4,
};


// Decides whether the code in a plug-in bundle may be loaded into MacDown.
// This is the seam MPPlugIn depends on, so callers (and tests) can supply
// their own policy.
@protocol MPPlugInVerifying <NSObject>

// Returns YES only if the bundle at url may be loaded. On NO, error (if
// given) is set to an MPPlugInErrorDomain error describing why.
- (BOOL)verifyBundleAtURL:(NSURL *)url error:(NSError **)error;

@end


// Default verifier, backed by the Security framework's static code checks.
// A bundle passes only if its signature is intact across all architectures
// and nested code, it is not ad-hoc signed, and its signing identity
// satisfies the code requirement.
@interface MPPlugInSignatureVerifier : NSObject <MPPlugInVerifying>

// The requirement text (code signing requirement language) a bundle's
// signer must satisfy.
@property (nonatomic, readonly, copy) NSString *requirement;

// Uses "anchor apple generic": the signing certificate must chain to
// Apple's root, i.e. a Developer ID, Mac App Store or Apple Development
// identity. A self-signed certificate does not satisfy it.
- (instancetype)init;
- (instancetype)initWithRequirement:(NSString *)requirement
    NS_DESIGNATED_INITIALIZER;

@end


@interface MPPlugIn : NSObject

@property (nonatomic, readonly) NSString *name;

// Verifies the bundle with an MPPlugInSignatureVerifier before loading it.
- (nullable instancetype)initWithBundle:(NSBundle *)bundle;

// Verifies the bundle with verifier before loading it. Returns nil, without
// loading any of the bundle's code, if verification fails.
- (nullable instancetype)initWithBundle:(NSBundle *)bundle
                               verifier:(id<MPPlugInVerifying>)verifier
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)run:(id)sender;

- (void)plugInDidInitialize;

@end

NS_ASSUME_NONNULL_END
