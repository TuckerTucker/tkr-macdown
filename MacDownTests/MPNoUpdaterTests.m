//
//  MPNoUpdaterTests.m
//  MacDown
//
//  This fork does not distribute updates, so it ships no updater: no Sparkle
//  framework or code, no update keys in Info.plist, no update UI, and no
//  update settings left behind in a user's defaults (work-ni3yq8xu).
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "MPPreferences.h"


@interface MPPreferences (NoUpdaterTesting)
- (void)cleanupObsoleteKeys;
@end


@interface MPNoUpdaterTests : XCTestCase
@end


@implementation MPNoUpdaterTests

- (void)testBundleCarriesNoUpdaterFramework
{
    NSBundle *app = [NSBundle mainBundle];
    NSString *frameworks = app.privateFrameworksPath;
    NSArray *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:frameworks error:NULL] ?: @[];
    for (NSString *name in names)
        XCTAssertFalse([name.lowercaseString containsString:@"sparkle"],
                       @"%@ is bundled", name);
    XCTAssertNil(NSClassFromString(@"SPUStandardUpdaterController"));
    XCTAssertNil(NSClassFromString(@"SPUUpdater"));
}

- (void)testInfoPlistDeclaresNoUpdateKeys
{
    for (NSString *key in [NSBundle mainBundle].infoDictionary)
        XCTAssertFalse([key hasPrefix:@"SU"], @"Info.plist declares %@", key);
}

- (void)testNoMenuOffersToCheckForUpdates
{
    NSMutableArray<NSMenu *> *menus = [NSMutableArray array];
    if (NSApp.mainMenu)
        [menus addObject:NSApp.mainMenu];
    XCTAssertGreaterThan(menus.count, 0u, @"the main menu must be loaded");
    NSUInteger items = 0;
    while (menus.count)
    {
        NSMenu *menu = menus.lastObject;
        [menus removeLastObject];
        for (NSMenuItem *item in menu.itemArray)
        {
            items++;
            // By title as well: with no handler left, the nib loader drops
            // the item's action, so an item put back would carry none.
            XCTAssertNotEqualObjects(NSStringFromSelector(item.action),
                                     @"checkForUpdates:", @"%@", item.title);
            XCTAssertFalse([item.title rangeOfString:@"Check for Update"
                    options:NSCaseInsensitiveSearch].location != NSNotFound,
                @"%@", item.title);
            if (item.submenu)
                [menus addObject:item.submenu];
        }
    }
    XCTAssertGreaterThan(items, 20u, @"examined too few items to mean much");
}

// Defaults written while MacDown had an updater: the pre-release choice,
// and what Sparkle stored for itself. Nothing reads them any more.
- (void)testUpdateSettingsAreRemovedFromDefaults
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *keys = @[@"updateIncludesPreReleases",
                      @"SUEnableAutomaticChecks", @"SULastCheckTime",
                      @"SUHasLaunchedBefore"];
    NSString *kept = @"editorSyncScrolling";
    id keptValue = [defaults objectForKey:kept];
    for (NSString *key in keys)
        [defaults setObject:@YES forKey:key];
    [self addTeardownBlock:^{
        for (NSString *key in keys)
            [defaults removeObjectForKey:key];
    }];

    [[MPPreferences sharedInstance] cleanupObsoleteKeys];

    for (NSString *key in keys)
        XCTAssertNil([defaults objectForKey:key], @"%@ was kept", key);
    XCTAssertEqualObjects([defaults objectForKey:kept], keptValue,
                          @"a setting still in use must be left alone");
}

@end
