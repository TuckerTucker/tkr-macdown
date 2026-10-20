//
//  MPUpdaterConfigurationTests.m
//  MacDown
//
//  Covers the Sparkle 2 updater gate (DEP-5 / TM-3 / TB-4): updates are
//  verified with Ed25519 only, and a build without SUPublicEDKey must keep
//  the updater off (fail closed) without Sparkle's modal start-up alert,
//  leaving "Check for Updates..." disabled.
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "MPMainController.h"


@interface MPMainController (UpdaterTesting)
- (BOOL)validateMenuItem:(NSMenuItem *)item;
@end


@interface MPUpdaterConfigurationTests : XCTestCase
@end


@implementation MPUpdaterConfigurationTests

- (void)testMissingKeyIsNotConfigured
{
    XCTAssertFalse([MPMainController isUpdaterConfiguredWithInfoDictionary:@{}]);
    XCTAssertFalse([MPMainController isUpdaterConfiguredWithInfoDictionary:nil]);
}

- (void)testEmptyOrBlankKeyIsNotConfigured
{
    // An unset $(SPARKLE_PUBLIC_ED_KEY) build setting expands to "".
    XCTAssertFalse([MPMainController isUpdaterConfiguredWithInfoDictionary:
                    @{@"SUPublicEDKey": @""}]);
    XCTAssertFalse([MPMainController isUpdaterConfiguredWithInfoDictionary:
                    @{@"SUPublicEDKey": @" \n\t"}]);
}

- (void)testNonStringKeyIsNotConfigured
{
    XCTAssertFalse([MPMainController isUpdaterConfiguredWithInfoDictionary:
                    @{@"SUPublicEDKey": @42}]);
}

- (void)testPresentKeyIsConfigured
{
    // 32 zero bytes, base64: the shape of an Ed25519 public key. Whether a
    // key is cryptographically valid is Sparkle's decision, not this gate's.
    NSString *key = @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    XCTAssertTrue([MPMainController isUpdaterConfiguredWithInfoDictionary:
                   @{@"SUPublicEDKey": key}]);
}

- (void)testThisBuildShipsTheKeyPlaceholderNotADSAKey
{
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    XCTAssertNotNil(info[@"SUPublicEDKey"],
                    @"Info.plist must declare SUPublicEDKey");
    XCTAssertNil(info[@"SUPublicDSAKeyFile"],
                 @"A DSA key would let Sparkle fall back to legacy DSA");
    XCTAssertNil(info[@"SUPublicDSAKey"]);
    XCTAssertTrue([info[@"SUFeedURL"] hasPrefix:@"https://"]);
    XCTAssertTrue([info[@"SUBetaFeedURL"] hasPrefix:@"https://"]);
}

- (void)testUnconfiguredBuildDisablesCheckForUpdates
{
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    XCTAssertFalse([MPMainController
                    isUpdaterConfiguredWithInfoDictionary:info],
                   @"The in-tree build has no signing key");

    MPMainController *controller = [[MPMainController alloc] init];
    NSMenuItem *item =
        [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                   action:@selector(checkForUpdates:)
                            keyEquivalent:@""];
    item.target = controller;

    XCTAssertFalse([controller validateMenuItem:item],
                   @"With the updater not started the item must be disabled");
}

@end
