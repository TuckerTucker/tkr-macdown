//
//  MPPlugIn.m
//  MacDown
//
//  Created by Tzu-ping Chung on 02/3.
//  Copyright © 2016 Tzu-ping Chung . All rights reserved.
//

#import "MPPlugIn.h"
#import <Security/Security.h>


NSString * const MPPlugInErrorDomain = @"com.uranusjr.macdown.plugin";

// Developer ID: chains to Apple's root through the Developer ID
// intermediate (marker OID ...6.2.6) to a Developer ID Application leaf
// (...6.1.13). "anchor apple generic" alone also accepts Apple Development
// certificates, which any Apple account can create for free.
static NSString * const kMPPlugInDefaultRequirement =
    @"anchor apple generic"
    @" and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
    @" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists";

// Every architecture slice is checked (not just the one we would load), the
// stricter structural rules apply (no unsealed files, no trailing data), and
// frameworks or helpers nested inside the bundle must validate too.
static const SecCSFlags kMPPlugInValidityFlags =
    kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode;


static BOOL MPPlugInFail(NSError **error, MPPlugInErrorCode code,
                         NSURL *url, NSString *reason, CFErrorRef cause)
{
    if (error)
    {
        NSString *name = url.lastPathComponent.stringByDeletingPathExtension;
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:
            NSLocalizedString(@"MacDown didn't load the plug-in “%@”.",
                              @"Plug-in refused: title naming the plug-in"),
            name];
        info[NSLocalizedFailureReasonErrorKey] = reason;
        NSString *folder = url.URLByDeletingLastPathComponent.path;
        BOOL signing = code <= MPPlugInErrorRequirementNotSatisfied;
        NSString *remedy = [NSString stringWithFormat:signing ?
            NSLocalizedString(
                @"MacDown only loads plug-ins signed with a Developer ID. Ask "
                @"the plug-in's developer for a signed version, or remove it "
                @"from %@.", @"Plug-in refused for its signature: what to do") :
            NSLocalizedString(
                @"Ask the plug-in's developer for a version that works with "
                @"this MacDown, or remove it from %@.",
                @"Plug-in failed to load: what to do"), folder];
        info[NSLocalizedRecoverySuggestionErrorKey] =
            [NSString stringWithFormat:@"%@ %@", reason, remedy];
        info[NSURLErrorKey] = url;
        if (cause)
            info[NSUnderlyingErrorKey] = (__bridge NSError *)cause;
        *error = [NSError errorWithDomain:MPPlugInErrorDomain code:code
                                 userInfo:info];
    }
    return NO;
}


@interface MPPlugInSignatureVerifier ()
@property (nonatomic) SecRequirementRef compiledRequirement;
@end


@implementation MPPlugInSignatureVerifier

- (instancetype)init
{
    return [self initWithRequirement:kMPPlugInDefaultRequirement];
}

- (instancetype)initWithRequirement:(NSString *)requirement
{
    self = [super init];
    if (!self)
        return nil;
    _requirement = [requirement copy];
    SecRequirementRef compiled = NULL;
    if (SecRequirementCreateWithString((__bridge CFStringRef)_requirement,
            kSecCSDefaultFlags, &compiled) == errSecSuccess)
        _compiledRequirement = compiled;
    return self;
}

- (void)dealloc
{
    if (_compiledRequirement)
        CFRelease(_compiledRequirement);
}

- (BOOL)verifyBundleAtURL:(NSURL *)url error:(NSError **)error
{
    if (!self.compiledRequirement)
    {
        NSString *reason = [NSString stringWithFormat:NSLocalizedString(
            @"Its signing requirement \"%@\" is invalid.",
            @"Plug-in refused: bad requirement"), self.requirement];
        return MPPlugInFail(error, MPPlugInErrorRequirementNotSatisfied, url,
                            reason, NULL);
    }

    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (status != errSecSuccess || !code)
    {
        NSString *reason = [NSString stringWithFormat:NSLocalizedString(
            @"Its code can't be read (OSStatus %d).",
            @"Plug-in refused: unreadable"), (int)status];
        return MPPlugInFail(error, MPPlugInErrorInvalidSignature, url,
                            reason, NULL);
    }

    BOOL ok = [self verifyStaticCode:code url:url error:error];
    CFRelease(code);
    return ok;
}

- (BOOL)verifyStaticCode:(SecStaticCodeRef)code url:(NSURL *)url
                   error:(NSError **)error
{
    // One pass hashes the bundle: integrity (the signature exists and the
    // bundle is unmodified) is checked before the requirement, so a
    // requirement failure means the signature is intact but its signer is
    // not trusted.
    CFErrorRef cause = NULL;
    OSStatus status = SecStaticCodeCheckValidityWithErrors(
        code, kMPPlugInValidityFlags, self.compiledRequirement, &cause);
    if (status == errSecSuccess)
        return YES;

    MPPlugInErrorCode errorCode = MPPlugInErrorInvalidSignature;
    NSString *reason = nil;
    if (status == errSecCSUnsigned)
    {
        errorCode = MPPlugInErrorUnsigned;
        reason = NSLocalizedString(@"It isn't code signed.",
                                   @"Plug-in refused: unsigned");
    }
    else if (status == errSecCSReqFailed)
    {
        // An ad-hoc signature is intact but names nobody, so it proves
        // nothing about where the code came from.
        errorCode = [self isAdHocSigned:code] ?
            MPPlugInErrorAdHocSignature : MPPlugInErrorRequirementNotSatisfied;
        reason = errorCode == MPPlugInErrorAdHocSignature ?
            NSLocalizedString(@"It is ad-hoc signed, so no developer "
                              @"identity stands behind it.",
                              @"Plug-in refused: ad hoc") :
            NSLocalizedString(@"It isn't signed with a Developer ID.",
                              @"Plug-in refused: untrusted signer");
    }
    else
    {
        reason = [NSString stringWithFormat:NSLocalizedString(
            @"Its code signature is invalid or it was changed after signing "
            @"(OSStatus %d).", @"Plug-in refused: invalid signature"),
            (int)status];
    }
    BOOL result = MPPlugInFail(error, errorCode, url, reason, cause);
    if (cause)
        CFRelease(cause);
    return result;
}

- (BOOL)isAdHocSigned:(SecStaticCodeRef)code
{
    CFDictionaryRef cfInfo = NULL;
    OSStatus status = SecCodeCopySigningInformation(
        code, kSecCSSigningInformation, &cfInfo);
    if (status != errSecSuccess || !cfInfo)
        return NO;
    NSDictionary *info = CFBridgingRelease(cfInfo);
    uint32_t flags = [info[(__bridge NSString *)kSecCodeInfoFlags]
                      unsignedIntValue];
    NSArray *certificates = info[(__bridge NSString *)kSecCodeInfoCertificates];
    return (flags & kSecCodeSignatureAdhoc) || certificates.count == 0;
}

@end


@interface MPPlugIn ()
@property (nonatomic) id content;
@end


@implementation MPPlugIn

- (void)setName:(NSString *)name
{
    _name = name;
}

- (instancetype)initWithBundle:(NSBundle *)bundle
{
    MPPlugInSignatureVerifier *verifier =
        [[MPPlugInSignatureVerifier alloc] init];
    return [self initWithBundle:bundle verifier:verifier];
}

- (instancetype)initWithBundle:(NSBundle *)bundle
                      verifier:(id<MPPlugInVerifying>)verifier
{
    return [self initWithBundle:bundle verifier:verifier error:NULL];
}

- (instancetype)initWithBundle:(NSBundle *)bundle
                      verifier:(id<MPPlugInVerifying>)verifier
                         error:(NSError **)error
{
    self = [super init];
    if (!self || !bundle)
        return nil;

    // Plug-ins live in a user-writable directory, so anything dropped there
    // would otherwise run as native code inside MacDown. Nothing from the
    // bundle is loaded until its signature checks out.
    //
    // Accepted trade-off: the bundle is loaded from the path that was
    // verified, so a process that swaps the executable in between loads
    // unverified code. Such a process already runs as this user, with the
    // same access to everything MacDown can reach; copying the bundle
    // somewhere first would not stop it, since it can write there too.
    if (![verifier verifyBundleAtURL:bundle.bundleURL error:error])
        return nil;

    if (!bundle.isLoaded)
    {
        NSError *loadError = nil;
        if (![bundle loadAndReturnError:&loadError])
        {
            NSString *reason = loadError.localizedFailureReason
                ?: loadError.localizedDescription;
            MPPlugInFail(error, MPPlugInErrorLoadFailed, bundle.bundleURL,
                         reason, (__bridge CFErrorRef)loadError);
            return nil;
        }
    }
    Class plugInClass = bundle.principalClass;
    if (!plugInClass)
    {
        MPPlugInFail(error, MPPlugInErrorNoPrincipalClass, bundle.bundleURL,
                     NSLocalizedString(@"It has no principal class.",
                                       @"Plug-in refused: no class"), NULL);
        return nil;
    }
    self.content = [[plugInClass alloc] init];

    if ([self.content respondsToSelector:@selector(name)])
        self.name = [self.content name];
    if (!self.name)
    {
        NSURL *url = bundle.bundleURL;
        self.name = url.lastPathComponent.stringByDeletingPathExtension;
    }

    return self;
}

- (void)plugInDidInitialize
{
    if ([self.content respondsToSelector:@selector(plugInDidInitialize)])
        [self.content plugInDidInitialize];
}

- (BOOL)run:(id)sender
{
    if ([self.content respondsToSelector:@selector(run:)])
        return [self.content run:sender];
    return NO;
}

@end
