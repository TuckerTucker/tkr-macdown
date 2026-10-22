//
//  MPPlugInTests.m
//  MacDown
//
//  Covers plug-in code-signature verification (TM-2 / TB-6): a bundle in the
//  user-writable PlugIns directory must not have any of its code loaded
//  unless it carries a valid, non-ad-hoc signature from a trusted identity.
//
//  Fixtures are real bundles built at test time in a temporary directory:
//  a one-class Objective-C bundle executable is compiled with clang, then
//  each test wraps a copy of it in a .plugin bundle that is left as the
//  linker produced it, stripped of its signature, or ad-hoc signed with
//  codesign. Nothing is mocked; the verifier under test calls the Security
//  framework against those files.
//
//  What is NOT reachable here: a loadable plug-in signed by a real
//  Developer ID. Producing one needs a signing identity issued by Apple,
//  which neither developer machines without an account nor CI have, and
//  minting one locally is exactly what the requirement is meant to refuse.
//  The accept path is therefore covered in two halves:
//    - the real verifier, given a requirement Apple's own signature meets,
//      accepts an Apple-signed bundle that ships with macOS
//      (/System/Applications/Calculator.app), proving that a validly
//      signed bundle passes every structural check; and
//    - MPPlugIn, given an injected verifier that accepts, loads the bundle
//      and instantiates its principal class, proving the load path still
//      works once verification passes.
//

#import <XCTest/XCTest.h>
#import "MPErrorPresenting.h"
#import "MPPlugIn.h"
#import "MPPlugInController.h"


static NSString * const kMPAppleSignedBundlePath =
    @"/System/Applications/Calculator.app";

static NSString * const kMPLoadableDisplayName = @"Accepted Fixture";
static NSString * const kMPMenuDisplayName = @"Menu Fixture";


/// Runs a tool to completion with a minimal environment: the test host's own
/// (DYLD_* injection from the XCTest runner among it) must not leak into the
/// toolchain. Returns nil on success, or a description of the failure.
static NSString *MPRunTool(NSString *tool, NSArray<NSString *> *arguments)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    task.environment = @{
        @"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin",
        @"HOME": NSHomeDirectory(),
        @"TMPDIR": NSTemporaryDirectory(),
    };
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error])
        return [NSString stringWithFormat:@"Cannot launch %@: %@", tool, error];
    NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus == 0)
        return nil;
    NSString *text = [[NSString alloc] initWithData:output
                                           encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"%@ %@ exited %d: %@", tool,
            [arguments componentsJoinedByString:@" "],
            task.terminationStatus, text];
}

/// Compiles a one-class Objective-C bundle executable whose -name returns
/// displayName. The output is left exactly as the linker wrote it
/// (linker-signed ad hoc, no sealed bundle signature), as a plug-in author's
/// build would be. Returns nil on success, or a description of the failure.
static NSString *MPCompileFixture(NSString *directory, NSString *className,
                                  NSString *displayName, NSString *output)
{
    NSString *source = [NSString stringWithFormat:
        @"#import <Foundation/Foundation.h>\n"
        @"@interface %1$@ : NSObject\n@end\n"
        @"@implementation %1$@\n"
        @"- (NSString *)name { return @\"%2$@\"; }\n"
        @"@end\n", className, displayName];
    NSString *sourcePath = [directory stringByAppendingPathComponent:
        [className stringByAppendingPathExtension:@"m"]];
    NSError *error = nil;
    if (![source writeToFile:sourcePath atomically:YES
                    encoding:NSUTF8StringEncoding error:&error])
        return error.description;
    return MPRunTool(@"/usr/bin/xcrun", @[
        @"--sdk", @"macosx", @"clang", @"-bundle", @"-fobjc-arc",
        @"-framework", @"Foundation", sourcePath, @"-o", output]);
}


// Compiled once per run (the toolchain is the slow part), then copied into a
// fresh bundle per test. Two executables with distinct principal classes:
// the probe is never loaded while the gate works, so a test can assert its
// class is absent from the process; the loadable one backs the accept path.
static NSString *sFixtureDirectory;
static NSString *sProbeExecutable;
static NSString *sProbeClassName;
static NSString *sLoadableExecutable;
static NSString *sLoadableClassName;
static NSString *sMenuExecutable;
static NSString *sMenuClassName;
static NSString *sFixtureFailure;


/// A verifier with a fixed answer, recording which bundle it was asked
/// about. Injected through MPPlugIn's designated initializer.
@interface MPFixedAnswerVerifier : NSObject <MPPlugInVerifying>
@property (nonatomic) BOOL answer;
@property (atomic, copy) NSURL *askedURL;
@property (atomic) NSUInteger askCount;
@property (atomic) NSUInteger mainThreadAskCount;
@end

@implementation MPFixedAnswerVerifier

- (BOOL)verifyBundleAtURL:(NSURL *)url error:(NSError **)error
{
    self.askedURL = url;
    self.askCount++;
    if ([NSThread isMainThread])
        self.mainThreadAskCount++;
    if (!self.answer && error)
    {
        *error = [NSError errorWithDomain:MPPlugInErrorDomain
            code:MPPlugInErrorUnsigned userInfo:@{
                NSURLErrorKey: url,
                NSLocalizedRecoverySuggestionErrorKey: @"Fixture refusal.",
            }];
    }
    return self.answer;
}

@end


@interface MPRecordingPlugInErrorPresenter : NSObject <MPErrorPresenting>
@property (nonatomic) NSMutableArray<NSError *> *errors;
@end

@implementation MPRecordingPlugInErrorPresenter

- (BOOL)presentError:(NSError *)error
{
    if (!self.errors)
        self.errors = [NSMutableArray array];
    [self.errors addObject:error];
    return NO;
}

@end


@interface MPPlugInTests : XCTestCase
@property (nonatomic, copy) NSString *workDirectory;
@end


@implementation MPPlugInTests

+ (void)setUp
{
    [super setUp];
    NSString *suffix = [[[NSUUID UUID] UUIDString]
                        stringByReplacingOccurrencesOfString:@"-"
                                                  withString:@""];
    sFixtureDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"macdown-plugin-fixtures-" stringByAppendingString:suffix]];
    [[NSFileManager defaultManager] createDirectoryAtPath:sFixtureDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];

    sProbeClassName = [@"MPPlugInProbe" stringByAppendingString:suffix];
    sProbeExecutable =
        [sFixtureDirectory stringByAppendingPathComponent:@"probe"];
    sFixtureFailure = MPCompileFixture(sFixtureDirectory, sProbeClassName,
                                       @"Probe", sProbeExecutable);
    if (sFixtureFailure)
        return;

    sLoadableClassName = [@"MPPlugInLoadable" stringByAppendingString:suffix];
    sLoadableExecutable =
        [sFixtureDirectory stringByAppendingPathComponent:@"loadable"];
    sFixtureFailure = MPCompileFixture(sFixtureDirectory, sLoadableClassName,
                                       kMPLoadableDisplayName,
                                       sLoadableExecutable);
    if (sFixtureFailure)
        return;

    sMenuClassName = [@"MPPlugInMenu" stringByAppendingString:suffix];
    sMenuExecutable =
        [sFixtureDirectory stringByAppendingPathComponent:@"menu"];
    sFixtureFailure = MPCompileFixture(sFixtureDirectory, sMenuClassName,
                                       kMPMenuDisplayName, sMenuExecutable);
}

+ (void)tearDown
{
    [[NSFileManager defaultManager] removeItemAtPath:sFixtureDirectory
                                               error:NULL];
    [super tearDown];
}

- (void)setUp
{
    [super setUp];
    // Fail, never skip: a suite that silently did not build its fixtures
    // would report green having examined nothing.
    XCTAssertNil(sFixtureFailure, @"Fixture build failed: %@",
                 sFixtureFailure);

    NSString *name = [NSString stringWithFormat:@"macdown-plugin-%@",
                      [[NSUUID UUID] UUIDString]];
    self.workDirectory =
        [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager]
               createDirectoryAtPath:self.workDirectory
               withIntermediateDirectories:YES attributes:nil error:&error];
    XCTAssertTrue(ok, @"Cannot create work directory: %@", error);
}

- (void)tearDown
{
    [[NSFileManager defaultManager] removeItemAtPath:self.workDirectory
                                               error:NULL];
    [super tearDown];
}


#pragma mark - Fixture building

- (BOOL)run:(NSString *)tool arguments:(NSArray<NSString *> *)arguments
{
    NSString *failure = MPRunTool(tool, arguments);
    XCTAssertNil(failure);
    return failure == nil;
}

/// Builds <work>/<name>.plugin around a copy of executable, with an
/// Info.plist naming className as the principal class.
- (NSString *)plugInNamed:(NSString *)name
               executable:(NSString *)executable
                className:(NSString *)className
{
    NSString *bundlePath = [self.workDirectory stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"plugin"]];
    NSString *macOS = [bundlePath stringByAppendingPathComponent:
                       @"Contents/MacOS"];
    NSFileManager *manager = [NSFileManager defaultManager];
    XCTAssertTrue([manager createDirectoryAtPath:macOS
                     withIntermediateDirectories:YES attributes:nil
                                           error:NULL]);
    NSError *error = nil;
    XCTAssertTrue([manager copyItemAtPath:executable
                     toPath:[macOS stringByAppendingPathComponent:name]
                      error:&error], @"%@", error);

    NSDictionary *info = @{
        @"CFBundleExecutable": name,
        @"CFBundleIdentifier": [@"com.uranusjr.macdown.tests."
                                stringByAppendingString:name],
        @"CFBundleInfoDictionaryVersion": @"6.0",
        @"CFBundlePackageType": @"BNDL",
        @"NSPrincipalClass": className,
    };
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:
                           @"Contents/Info.plist"];
    XCTAssertTrue([info writeToFile:plistPath atomically:YES]);
    return bundlePath;
}

/// A probe plug-in as the linker left it: never passed through codesign.
- (NSString *)probePlugInNamed:(NSString *)name
{
    return [self plugInNamed:name executable:sProbeExecutable
                   className:sProbeClassName];
}

/// A probe plug-in with no code signature at all, not even the linker's.
- (NSString *)unsignedPlugInNamed:(NSString *)name
{
    NSString *path = [self probePlugInNamed:name];
    NSString *executable = [path stringByAppendingPathComponent:
        [@"Contents/MacOS" stringByAppendingPathComponent:name]];
    [self run:@"/usr/bin/codesign"
        arguments:@[@"--remove-signature", executable]];
    return path;
}

/// A probe plug-in ad-hoc signed by codesign: sealed, but by no identity.
- (NSString *)adHocPlugInNamed:(NSString *)name
{
    NSString *path = [self probePlugInNamed:name];
    [self run:@"/usr/bin/codesign"
        arguments:@[@"--force", @"--sign", @"-", path]];
    return path;
}

- (NSError *)verifyPath:(NSString *)path
           withVerifier:(MPPlugInSignatureVerifier *)verifier
               accepted:(BOOL *)accepted
{
    NSError *error = nil;
    *accepted = [verifier verifyBundleAtURL:[NSURL fileURLWithPath:path]
                                      error:&error];
    return error;
}


#pragma mark - MPPlugInSignatureVerifier

- (void)testVerifierRejectsUnsignedBundle
{
    NSString *path = [self unsignedPlugInNamed:@"Unsigned"];

    BOOL ok = YES;
    NSError *error = [self verifyPath:path
        withVerifier:[[MPPlugInSignatureVerifier alloc] init] accepted:&ok];

    XCTAssertFalse(ok, @"An unsigned bundle must be rejected");
    XCTAssertEqualObjects(error.domain, MPPlugInErrorDomain);
    XCTAssertEqual(error.code, MPPlugInErrorUnsigned, @"%@", error);
}

- (void)testVerifierRejectsLinkerSignedBundleWithoutSealedSignature
{
    NSString *path = [self probePlugInNamed:@"LinkerSigned"];

    BOOL ok = YES;
    NSError *error = [self verifyPath:path
        withVerifier:[[MPPlugInSignatureVerifier alloc] init] accepted:&ok];

    XCTAssertFalse(ok, @"A bundle that was never codesigned must be rejected");
    // The linker's signature is ad hoc and seals no resources. Checked in
    // one pass with the requirement, the missing identity is what is
    // reported; either way the user is told it has no Developer ID.
    XCTAssertEqual(error.code, MPPlugInErrorAdHocSignature, @"%@", error);
}

- (void)testVerifierRejectsAdHocSignedBundle
{
    NSString *path = [self adHocPlugInNamed:@"AdHoc"];

    BOOL ok = YES;
    NSError *error = [self verifyPath:path
        withVerifier:[[MPPlugInSignatureVerifier alloc] init] accepted:&ok];

    XCTAssertFalse(ok, @"An ad-hoc signed bundle must be rejected");
    XCTAssertEqual(error.code, MPPlugInErrorAdHocSignature, @"%@", error);
}

- (void)testVerifierRejectsBundleModifiedAfterSigning
{
    NSString *path = [self adHocPlugInNamed:@"Tampered"];
    NSString *plistPath = [path stringByAppendingPathComponent:
                           @"Contents/Info.plist"];
    NSMutableDictionary *info =
        [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    info[@"CFBundleShortVersionString"] = @"9.9";
    XCTAssertTrue([info writeToFile:plistPath atomically:YES]);

    BOOL ok = YES;
    NSError *error = [self verifyPath:path
        withVerifier:[[MPPlugInSignatureVerifier alloc] init] accepted:&ok];

    XCTAssertFalse(ok, @"A bundle modified after signing must be rejected");
    XCTAssertEqual(error.code, MPPlugInErrorInvalidSignature, @"%@", error);
}

- (void)testVerifierAcceptsAppleSignedBundle
{
    NSURL *url = [NSURL fileURLWithPath:kMPAppleSignedBundlePath];
    XCTAssertTrue([url checkResourceIsReachableAndReturnError:NULL],
                  @"Fixture %@ must exist on every supported macOS",
                  kMPAppleSignedBundlePath);

    BOOL ok = NO;
    MPPlugInSignatureVerifier *verifier = [[MPPlugInSignatureVerifier alloc]
        initWithRequirement:@"anchor apple"];
    NSError *error = [self verifyPath:kMPAppleSignedBundlePath
                         withVerifier:verifier accepted:&ok];

    XCTAssertTrue(ok, @"A validly signed bundle meeting the requirement must "
                      @"pass: %@", error);
}

- (void)testVerifierRejectsValidSignatureFailingRequirement
{
    MPPlugInSignatureVerifier *verifier = [[MPPlugInSignatureVerifier alloc]
        initWithRequirement:@"identifier \"com.uranusjr.macdown.nobody\""];

    BOOL ok = YES;
    NSError *error = [self verifyPath:kMPAppleSignedBundlePath
                         withVerifier:verifier accepted:&ok];

    XCTAssertFalse(ok, @"A signer outside the requirement must be rejected");
    XCTAssertEqual(error.code, MPPlugInErrorRequirementNotSatisfied,
                   @"%@", error);
}

// "anchor apple generic" alone accepted any Apple-anchored signer,
// including free Apple Development certificates. A signer that is Apple
// anchored but not Developer ID must now be refused; Apple's own signature
// on Calculator is one that exists on every machine.
- (void)testDefaultRequirementRefusesAppleAnchoredNonDeveloperID
{
    BOOL ok = YES;
    NSError *error = [self verifyPath:kMPAppleSignedBundlePath
        withVerifier:[[MPPlugInSignatureVerifier alloc] init] accepted:&ok];

    XCTAssertFalse(ok, @"Only Developer ID signers may load");
    XCTAssertEqual(error.code, MPPlugInErrorRequirementNotSatisfied,
                   @"%@", error);
}

- (void)testDefaultRequirementNamesDeveloperIDCertificates
{
    NSString *requirement =
        [[MPPlugInSignatureVerifier alloc] init].requirement;
    XCTAssertTrue([requirement hasPrefix:@"anchor apple generic"]);
    XCTAssertTrue([requirement containsString:
        @"certificate 1[field.1.2.840.113635.100.6.2.6] exists"],
        @"Developer ID intermediate");
    XCTAssertTrue([requirement containsString:
        @"certificate leaf[field.1.2.840.113635.100.6.1.13] exists"],
        @"Developer ID Application leaf");
}


#pragma mark - MPPlugIn loading

- (void)testAdHocSignedPlugInIsNotLoaded
{
    NSBundle *bundle =
        [NSBundle bundleWithPath:[self adHocPlugInNamed:@"AdHocLoad"]];

    MPPlugIn *plugin = [[MPPlugIn alloc] initWithBundle:bundle];

    XCTAssertNil(plugin, @"An ad-hoc signed plug-in must be refused");
    XCTAssertFalse(bundle.isLoaded, @"Its code must not have been loaded");
    XCTAssertNil(NSClassFromString(sProbeClassName),
                 @"Its principal class must not exist in the process");
}

- (void)testNeverCodesignedPlugInIsNotLoaded
{
    NSBundle *bundle =
        [NSBundle bundleWithPath:[self probePlugInNamed:@"PlainLoad"]];

    MPPlugIn *plugin = [[MPPlugIn alloc] initWithBundle:bundle];

    XCTAssertNil(plugin, @"A plug-in that was never codesigned must be refused");
    XCTAssertFalse(bundle.isLoaded, @"Its code must not have been loaded");
    XCTAssertNil(NSClassFromString(sProbeClassName));
}

- (void)testRejectingVerifierPreventsLoad
{
    NSString *path = [self probePlugInNamed:@"Rejected"];
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    MPFixedAnswerVerifier *verifier = [[MPFixedAnswerVerifier alloc] init];
    verifier.answer = NO;

    MPPlugIn *plugin = [[MPPlugIn alloc] initWithBundle:bundle
                                               verifier:verifier];

    XCTAssertNil(plugin);
    XCTAssertEqualObjects(verifier.askedURL.path.stringByStandardizingPath,
                          path.stringByStandardizingPath,
                          @"The verifier must be consulted for this bundle");
    XCTAssertFalse(bundle.isLoaded);
    XCTAssertNil(NSClassFromString(sProbeClassName));
}

- (void)testAcceptingVerifierLoadsPlugIn
{
    NSString *path = [self plugInNamed:@"Accepted"
                            executable:sLoadableExecutable
                             className:sLoadableClassName];
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    MPFixedAnswerVerifier *verifier = [[MPFixedAnswerVerifier alloc] init];
    verifier.answer = YES;

    MPPlugIn *plugin = [[MPPlugIn alloc] initWithBundle:bundle
                                               verifier:verifier];

    XCTAssertNotNil(plugin, @"A verified plug-in must load");
    XCTAssertTrue(bundle.isLoaded);
    XCTAssertNotNil(NSClassFromString(sLoadableClassName));
    XCTAssertEqualObjects(plugin.name, kMPLoadableDisplayName,
                          @"The principal class must have been instantiated");
}


#pragma mark - MPPlugInController

- (MPPlugInController *)loadedControllerWithVerifier:
    (id<MPPlugInVerifying>)verifier
{
    MPPlugInController *controller = [[MPPlugInController alloc]
        initWithDirectory:self.workDirectory verifier:verifier];
    [self reload:controller];
    return controller;
}

- (void)reload:(MPPlugInController *)controller
{
    XCTestExpectation *done = [self expectationWithDescription:@"scan"];
    [controller reloadWithCompletion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:30.0];
}

- (NSMenu *)menuFor:(MPPlugInController *)controller
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Plug-ins"];
    menu.delegate = controller;
    [controller menuNeedsUpdate:menu];
    return menu;
}

// A refused plug-in used to vanish, with the reason only in the log.
- (void)testRefusedPlugInIsListedGreyedOutWithTheReason
{
    [self unsignedPlugInNamed:@"Refused"];
    MPPlugInController *controller = [self loadedControllerWithVerifier:
        [[MPPlugInSignatureVerifier alloc] init]];

    NSMenu *menu = [self menuFor:controller];
    [menu update];

    XCTAssertEqual(menu.numberOfItems, 1);
    NSMenuItem *item = menu.itemArray.firstObject;
    XCTAssertTrue([item.title containsString:@"Refused"], @"%@", item.title);
    XCTAssertFalse(item.enabled, @"a refused plug-in must not be runnable");
    XCTAssertTrue([item.toolTip containsString:@"Developer ID"],
                  @"the tool tip must say what it needs: %@", item.toolTip);
    XCTAssertTrue([item.toolTip containsString:@"code signed"],
                  @"and what is wrong: %@", item.toolTip);
}

- (void)testSignaturesAreCheckedOnceAndOffTheMainThread
{
    [self probePlugInNamed:@"One"];
    [self probePlugInNamed:@"Two"];
    MPFixedAnswerVerifier *verifier = [[MPFixedAnswerVerifier alloc] init];
    MPPlugInController *controller =
        [self loadedControllerWithVerifier:verifier];
    XCTAssertEqual(verifier.askCount, 2u);

    // Opening the menu again and again re-checks nothing that is unchanged.
    for (int i = 0; i < 3; i++)
    {
        [self menuFor:controller];
        [self reload:controller];
    }
    XCTAssertEqual(verifier.askCount, 2u);
    XCTAssertEqual(verifier.mainThreadAskCount, 0u);
    XCTAssertEqual(controller.refusals.count, 2u);
}

- (void)testChangedPlugInIsCheckedAgain
{
    NSString *path = [self probePlugInNamed:@"Changing"];
    MPFixedAnswerVerifier *verifier = [[MPFixedAnswerVerifier alloc] init];
    MPPlugInController *controller =
        [self loadedControllerWithVerifier:verifier];
    XCTAssertEqual(verifier.askCount, 1u);

    NSString *plist = [path stringByAppendingPathComponent:
                       @"Contents/Info.plist"];
    NSDate *later = [NSDate dateWithTimeIntervalSinceNow:60.0];
    XCTAssertTrue([[NSFileManager defaultManager]
        setAttributes:@{NSFileModificationDate: later}
         ofItemAtPath:plist error:NULL]);
    [self reload:controller];
    XCTAssertEqual(verifier.askCount, 2u, @"a re-signed or replaced plug-in "
                                          @"must get a fresh verdict");
}

- (void)testRemovedPlugInLeavesTheMenu
{
    NSString *path = [self probePlugInNamed:@"Leaving"];
    MPFixedAnswerVerifier *verifier = [[MPFixedAnswerVerifier alloc] init];
    MPPlugInController *controller =
        [self loadedControllerWithVerifier:verifier];
    XCTAssertEqual(controller.refusals.count, 1u);

    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:path
                                                             error:NULL]);
    [self reload:controller];
    XCTAssertEqual(controller.refusals.count, 0u);
    NSMenu *menu = [self menuFor:controller];
    XCTAssertEqual(menu.numberOfItems, 1);
    XCTAssertFalse(menu.itemArray.firstObject.action,
                   @"only the greyed-out empty-state item remains");
}

- (void)testPlugInThatFailsToRunSaysSo
{
    [self plugInNamed:@"Menu" executable:sMenuExecutable
            className:sMenuClassName];
    MPFixedAnswerVerifier *verifier = [[MPFixedAnswerVerifier alloc] init];
    verifier.answer = YES;
    MPPlugInController *controller =
        [self loadedControllerWithVerifier:verifier];
    MPRecordingPlugInErrorPresenter *presenter =
        [[MPRecordingPlugInErrorPresenter alloc] init];
    controller.errorPresenter = presenter;

    NSMenu *menu = [self menuFor:controller];
    [menu update];
    XCTAssertEqual(menu.numberOfItems, 1);
    NSMenuItem *item = menu.itemArray.firstObject;
    XCTAssertEqualObjects(item.title, kMPMenuDisplayName);
    XCTAssertTrue(item.enabled);

    // The fixture has no -run:, so running it fails.
    [menu performActionForItemAtIndex:0];
    XCTAssertEqual(presenter.errors.count, 1u,
                   @"a failed run must not be silent");
    XCTAssertEqual(presenter.errors.firstObject.code, MPPlugInErrorRunFailed);
    XCTAssertTrue([presenter.errors.firstObject.localizedDescription
                   containsString:kMPMenuDisplayName]);
}

@end
