//
//  MPPreferencesTests.m
//  MPPreferencesTests
//
//  Created by Tzu-ping Chung  on 6/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import <XCTest/XCTest.h>
#import "MPPreferences.h"


#pragma mark - Isolation strategy
//
// Why snapshot/restore instead of a redirected/suite-backed test double:
//
// MPPreferences inherits PAPreferences, which provides every @dynamic property
// accessor lazily via +resolveInstanceMethod: -> class_addMethod (see
// Pods/PAPreferences/PAPreferences/PAPreferences.m). Those accessors are
// installed on the *exact* class that first receives the selector. When the
// real +sharedInstance is used, PAPreferences resolves them on PAPreferences /
// MPPreferences, so they work. But instantiating a test-only *subclass*
// directly never triggers resolution for that subclass, so even basic accessors
// (and the init path at MPPreferences.m:54, `self.firstVersionInstalled = ...`)
// crash with `unrecognized selector`. The subclass-override seam is therefore
// unviable with this pod.
//
// So these tests exercise the real `[MPPreferences sharedInstance]` (whose
// accessors DO resolve) and protect the user's real NSUserDefaults by
// snapshotting every key a test will touch in -setUp and writing the captured
// values back in an -addTeardownBlock: (which runs even if an assertion fails).
// After each test the live defaults are byte-for-byte what they were before.
//
// HANDOFF — true storage isolation needs a production seam, not a test trick:
//   * Route MPPreferences's -cleanupObsoleteAutosaveValues (MPPreferences.m:203)
//     and -loadDefaultUserDefaults (MPPreferences.m:277) through `[self
//     userDefaults]` instead of `[NSUserDefaults standardUserDefaults]`, and
//   * Provide a PAPreferences-compatible way to resolve the @dynamic accessors
//     on a suite-backed instance (e.g. a designated initializer that accepts a
//     suite name and ensures resolution happens on a usable class).
//   Until both exist, snapshot/restore is the correct, safe approach.


/// NSUserDefaults keys every test in this file may read or write. -setUp
/// snapshots exactly these; the teardown block restores exactly these.
///
/// `editorBaseFontInfo` is the backing key behind the `editorBaseFont`
/// convenience accessor (see -setEditorBaseFont: in MPPreferences.m).
static NSString * const kMPTouchedDefaultsKeys[] = {
    @"editorBaseFontInfo",
    @"extensionTables",
    @"htmlStyleName",
};
static const NSUInteger kMPTouchedDefaultsKeyCount =
    sizeof(kMPTouchedDefaultsKeys) / sizeof(kMPTouchedDefaultsKeys[0]);


#pragma mark - Tests

@interface MPPreferencesTests : XCTestCase
@property (nonatomic, strong) MPPreferences *preferences;
/// Original values (or NSNull placeholders for absent keys) captured in -setUp.
@property (nonatomic, copy) NSDictionary<NSString *, id> *defaultsSnapshot;
@end


@implementation MPPreferencesTests

- (void)setUp
{
    [super setUp];

    // The real singleton — the only instance whose @dynamic accessors PAPreferences
    // actually resolves. Its backing store is the live standardUserDefaults.
    self.preferences = [MPPreferences sharedInstance];

    NSArray<NSString *> *keys = [self touchedDefaultsKeys];

    // Capture the user's real values BEFORE any test mutates them.
    self.defaultsSnapshot = [self snapshotForKeys:keys];

    // Restore unconditionally, even if an assertion aborts the test mid-way, so
    // the user's real NSUserDefaults is left exactly as we found it.
    NSDictionary<NSString *, id> *snapshot = self.defaultsSnapshot;
    MPPreferences *preferences = self.preferences;
    [self addTeardownBlock:^{
        [MPPreferencesTests restoreSnapshot:snapshot intoDefaults:preferences.userDefaults];
    }];
}

- (void)tearDown
{
    self.preferences = nil;
    self.defaultsSnapshot = nil;
    [super tearDown];
}


#pragma mark - Snapshot/restore helpers

/// The keys tests touch, as an NSArray for iteration.
- (NSArray<NSString *> *)touchedDefaultsKeys
{
    NSMutableArray<NSString *> *keys =
        [NSMutableArray arrayWithCapacity:kMPTouchedDefaultsKeyCount];
    for (NSUInteger i = 0; i < kMPTouchedDefaultsKeyCount; i++)
        [keys addObject:kMPTouchedDefaultsKeys[i]];
    return keys;
}

/// Read the current value of each key from the live defaults. Absent keys are
/// recorded as NSNull so -restore can distinguish "was unset" from "was set".
- (NSDictionary<NSString *, id> *)snapshotForKeys:(NSArray<NSString *> *)keys
{
    NSUserDefaults *defaults = self.preferences.userDefaults;
    NSMutableDictionary<NSString *, id> *snapshot =
        [NSMutableDictionary dictionaryWithCapacity:keys.count];
    for (NSString *key in keys)
    {
        id value = [defaults objectForKey:key];
        snapshot[key] = value ?: [NSNull null];
    }
    return snapshot;
}

/// Write a snapshot back into the given defaults: re-set keys that had values,
/// remove keys that were originally absent. Exposed as a class method so it can
/// run from a teardown block without retaining the test case.
+ (void)restoreSnapshot:(NSDictionary<NSString *, id> *)snapshot
           intoDefaults:(NSUserDefaults *)defaults
{
    for (NSString *key in snapshot)
    {
        id value = snapshot[key];
        if (value == [NSNull null])
            [defaults removeObjectForKey:key];
        else
            [defaults setObject:value forKey:key];
    }
    [defaults synchronize];
}


#pragma mark - Restore-helper guard

/// Proves the snapshot/restore machinery actually returns a mutated key to its
/// original value. This is what lets the round-trip tests below run against the
/// real defaults without permanently changing them.
- (void)testSnapshotRestoreReturnsKeyToOriginalValue
{
    NSUserDefaults *defaults = self.preferences.userDefaults;

    NSDictionary<NSString *, id> *before =
        [self snapshotForKeys:@[@"htmlStyleName"]];
    id original = before[@"htmlStyleName"];

    // Mutate through the real accessor, exactly as a normal test would.
    self.preferences.htmlStyleName = @"MPRestoreHelperSentinel";
    [self.preferences synchronize];
    XCTAssertEqualObjects(self.preferences.htmlStyleName, @"MPRestoreHelperSentinel",
                          @"Sanity: the mutation should take effect before restore.");

    // The helper must put it back precisely.
    [MPPreferencesTests restoreSnapshot:before intoDefaults:defaults];

    id current = [defaults objectForKey:@"htmlStyleName"];
    if (original == [NSNull null])
        XCTAssertNil(current,
                     @"Restore must remove a key that was originally unset.");
    else
        XCTAssertEqualObjects(current, original,
                              @"Restore must return a key to its original value.");
}

- (void)testFont
{
    NSFont *font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
    self.preferences.editorBaseFont = font;

    XCTAssertTrue([self.preferences synchronize],
                  @"Failed to synchronize user defaults.");

    NSFont *result = [self.preferences.editorBaseFont copy];
    XCTAssertEqualObjects(font, result,
                          @"Preferences not preserving font info correctly.");
}

/// Round-trip for a BOOL extension flag.
- (void)testExtensionTablesRoundTrip
{
    self.preferences.extensionTables = NO;
    XCTAssertTrue([self.preferences synchronize],
                  @"Failed to synchronize user defaults.");
    XCTAssertFalse(self.preferences.extensionTables,
                   @"extensionTables did not persist a NO value.");

    self.preferences.extensionTables = YES;
    XCTAssertTrue([self.preferences synchronize],
                  @"Failed to synchronize user defaults.");
    XCTAssertTrue(self.preferences.extensionTables,
                  @"extensionTables did not persist a YES value.");
}

/// Round-trip for an NSString preference.
- (void)testHtmlStyleNameRoundTrip
{
    self.preferences.htmlStyleName = @"SolarizedDark";
    XCTAssertTrue([self.preferences synchronize],
                  @"Failed to synchronize user defaults.");
    XCTAssertEqualObjects(self.preferences.htmlStyleName, @"SolarizedDark",
                          @"htmlStyleName did not round-trip correctly.");
}

@end
