//
//  MPUpdaterConfigurationTests.m
//  MacDown
//
//  Covers the Sparkle 2 updater gate (DEP-5 / TM-3 / TB-4): updates are
//  verified with Ed25519 only, and a build without SUPublicEDKey must keep
//  the updater off (fail closed) without Sparkle's modal start-up alert,
//  leaving "Check for Updates..." disabled and saying why where updates are
//  offered. Controllers are built from an injected Info dictionary, so the
//  tests hold whether or not a maintainer has set the signing key.
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
@class SPUUpdater;
#import "MPGeneralPreferencesViewController.h"
#import "MPMainController.h"
#import "MPPreferences.h"


@interface MPMainController (UpdaterTesting)
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater;
@end

@interface MPGeneralPreferencesViewController (UpdaterTesting)
@property (weak) NSButton *preReleasesToggle;
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
}

// Upstream's feed lists builds signed with upstream's key: once this fork
// sets its own key, every one of them would fail verification.
- (void)testFeedIsTheForksOwnOverHTTPS
{
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSURL *feed = [NSURL URLWithString:info[@"SUFeedURL"]];
    XCTAssertEqualObjects(feed.scheme, @"https");
    XCTAssertEqualObjects(feed.host, @"raw.githubusercontent.com");
    XCTAssertTrue([feed.path hasPrefix:@"/TuckerTucker/tkr-macdown/"],
                  @"%@", feed);
    XCTAssertNil(info[@"SUBetaFeedURL"],
                 @"pre-releases are a channel of the one feed");
}

- (void)testPreReleasesAreTheBetaChannel
{
    MPPreferences *preferences = [MPPreferences sharedInstance];
    NSUserDefaults *defaults = preferences.userDefaults;
    NSString *key = @"updateIncludesPreReleases";
    id saved = [defaults objectForKey:key];
    [self addTeardownBlock:^{
        if (saved)
            [defaults setObject:saved forKey:key];
        else
            [defaults removeObjectForKey:key];
    }];
    MPMainController *controller =
        [[MPMainController alloc] initWithInfoDictionary:@{}];

    preferences.updateIncludesPreReleases = YES;
    XCTAssertEqualObjects([controller allowedChannelsForUpdater:nil],
                          [NSSet setWithObject:MPUpdaterBetaChannel]);
    preferences.updateIncludesPreReleases = NO;
    XCTAssertEqualObjects([controller allowedChannelsForUpdater:nil],
                          [NSSet set], @"stable items only");
}

- (void)testUnconfiguredBuildDisablesCheckForUpdatesAndSaysWhy
{
    MPMainController *controller =
        [[MPMainController alloc] initWithInfoDictionary:@{}];
    NSMenuItem *item =
        [[NSMenuItem alloc] initWithTitle:@"Check for Updates…"
                                   action:@selector(checkForUpdates:)
                            keyEquivalent:@""];
    item.target = controller;

    XCTAssertFalse([controller validateMenuItem:item],
                   @"With the updater not started the item must be disabled");
    XCTAssertNotNil(controller.updatesUnavailableReason);
    XCTAssertEqualObjects(item.toolTip, controller.updatesUnavailableReason,
                          @"the greyed-out item must say why");
}

- (void)testConfiguredBuildHasNoUnavailableReason
{
    NSString *key = @"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    MPMainController *controller = [[MPMainController alloc]
        initWithInfoDictionary:@{@"SUPublicEDKey": key}];
    XCTAssertNil(controller.updatesUnavailableReason);
}

- (void)testPreReleaseOptionIsGreyedOutWhenUpdatesAreOff
{
    MPGeneralPreferencesViewController *pane =
        [[MPGeneralPreferencesViewController alloc] init];
    pane.updatesUnavailableReason = @"No key.";
    [pane view];

    XCTAssertNotNil(pane.preReleasesToggle, @"outlet must be connected");
    XCTAssertFalse(pane.preReleasesToggle.enabled);
    XCTAssertEqualObjects(pane.preReleasesToggle.toolTip, @"No key.");

    pane.updatesUnavailableReason = nil;
    XCTAssertTrue(pane.preReleasesToggle.enabled);
    XCTAssertNil(pane.preReleasesToggle.toolTip);
}

@end
