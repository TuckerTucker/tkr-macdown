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
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = reason;
        info[NSURLErrorKey] = url;
        if (cause)
            info[NSUnderlyingErrorKey] = (__bridge NSError *)cause;
        *error = [NSError errorWithDomain:MPPlugInErrorDomain code:code
                                 userInfo:info];
    }
    return NO;
}


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
    return self;
}

- (BOOL)verifyBundleAtURL:(NSURL *)url error:(NSError **)error
{
    SecStaticCodeRef code = NULL;
    OSStatus status = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (status != errSecSuccess || !code)
    {
        NSString *reason = [NSString stringWithFormat:
            @"Cannot read code at %@ (OSStatus %d).", url.path, (int)status];
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
    // 1. Integrity: the signature exists and the bundle is unmodified.
    CFErrorRef cause = NULL;
    OSStatus status = SecStaticCodeCheckValidityWithErrors(
        code, kMPPlugInValidityFlags, NULL, &cause);
    if (status != errSecSuccess)
    {
        BOOL unsigned_ = (status == errSecCSUnsigned);
        NSString *reason = unsigned_ ?
            @"The plug-in is not code signed." :
            [NSString stringWithFormat:
                @"The plug-in's code signature is invalid (OSStatus %d).",
                (int)status];
        BOOL result = MPPlugInFail(
            error, unsigned_ ? MPPlugInErrorUnsigned :
                               MPPlugInErrorInvalidSignature,
            url, reason, cause);
        if (cause)
            CFRelease(cause);
        return result;
    }

    // 2. Identity: an ad-hoc signature is intact but names nobody, so it
    // proves nothing about where the code came from.
    CFDictionaryRef cfInfo = NULL;
    status = SecCodeCopySigningInformation(
        code, kSecCSSigningInformation, &cfInfo);
    if (status != errSecSuccess || !cfInfo)
    {
        NSString *reason = [NSString stringWithFormat:
            @"Cannot read the plug-in's signing information (OSStatus %d).",
            (int)status];
        return MPPlugInFail(error, MPPlugInErrorInvalidSignature, url,
                            reason, NULL);
    }
    NSDictionary *info = CFBridgingRelease(cfInfo);
    uint32_t flags = [info[(__bridge NSString *)kSecCodeInfoFlags]
                      unsignedIntValue];
    NSArray *certificates = info[(__bridge NSString *)kSecCodeInfoCertificates];
    if ((flags & kSecCodeSignatureAdhoc) || certificates.count == 0)
    {
        return MPPlugInFail(error, MPPlugInErrorAdHocSignature, url,
                            @"The plug-in is ad-hoc signed and has no "
                            @"signing identity.", NULL);
    }

    // 3. Trust: the signing identity must satisfy the requirement, so a
    // certificate the attacker minted for themselves is not enough.
    SecRequirementRef requirement = NULL;
    status = SecRequirementCreateWithString(
        (__bridge CFStringRef)self.requirement, kSecCSDefaultFlags,
        &requirement);
    if (status != errSecSuccess || !requirement)
    {
        NSString *reason = [NSString stringWithFormat:
            @"The plug-in code requirement \"%@\" is invalid (OSStatus %d).",
            self.requirement, (int)status];
        return MPPlugInFail(error, MPPlugInErrorRequirementNotSatisfied, url,
                            reason, NULL);
    }
    cause = NULL;
    status = SecStaticCodeCheckValidityWithErrors(
        code, kMPPlugInValidityFlags, requirement, &cause);
    CFRelease(requirement);
    if (status != errSecSuccess)
    {
        NSString *reason = [NSString stringWithFormat:
            @"The plug-in's signer does not satisfy \"%@\" (OSStatus %d).",
            self.requirement, (int)status];
        BOOL result = MPPlugInFail(error, MPPlugInErrorRequirementNotSatisfied,
                                   url, reason, cause);
        if (cause)
            CFRelease(cause);
        return result;
    }
    return YES;
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
    self = [super init];
    if (!self || !bundle)
        return nil;

    // Plug-ins live in a user-writable directory, so anything dropped there
    // would otherwise run as native code inside MacDown. Nothing from the
    // bundle is loaded until its signature checks out.
    NSError *verifyError = nil;
    if (![verifier verifyBundleAtURL:bundle.bundleURL error:&verifyError])
    {
        NSLog(@"Refusing to load plug-in %@: %@",
              bundle.bundlePath, verifyError.localizedDescription);
        return nil;
    }

    if (!bundle.isLoaded)
    {
        NSError *e = nil;
        BOOL ok = [bundle loadAndReturnError:&e];
        if (!ok)
            return nil;
    }
    Class plugInClass = bundle.principalClass;
    if (!plugInClass)
        return nil;
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
