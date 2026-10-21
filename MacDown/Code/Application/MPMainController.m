//
//  MPMainController.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 7/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPMainController.h"
#import <MASPreferences/MASPreferencesWindowController.h>
#import <Sparkle/SPUStandardUpdaterController.h>
#import <Sparkle/SPUUpdater.h>
#import <Sparkle/SPUUpdaterDelegate.h>
#import "MPGlobals.h"
#import "MPUtilities.h"
#import "NSDocumentController+Document.h"
#import "NSUserDefaults+Suite.h"
#import "MPPreferences.h"
#import "MPGeneralPreferencesViewController.h"
#import "MPMarkdownPreferencesViewController.h"
#import "MPEditorPreferencesViewController.h"
#import "MPHtmlPreferencesViewController.h"
#import "MPTerminalPreferencesViewController.h"
#import "MPDocument.h"
#import "MPErrorPresenting.h"
#import "MPOpenRequest.h"


static NSString * const kMPTreatLastSeenStampKey = @"treatLastSeenStamp";


NS_INLINE void MPOpenBundledFile(NSString *resource, NSString *extension)
{
    NSURL *source = [[NSBundle mainBundle] URLForResource:resource
                                            withExtension:extension];
    NSString *filename = source.absoluteString.lastPathComponent;
    NSURL *target = [NSURL fileURLWithPathComponents:@[NSTemporaryDirectory(),
                                                       filename]];
    BOOL ok = NO;
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager removeItemAtURL:target error:NULL];
    ok = [manager copyItemAtURL:source toURL:target error:NULL];

    if (!ok)
        return;
    NSDocumentController *c = [NSDocumentController sharedDocumentController];
    [c openDocumentWithContentsOfURL:target display:YES completionHandler:
     ^(NSDocument *document, BOOL wasOpen, NSError *error) {
         if (!document || wasOpen || error)
             return;
         NSRect frame = [NSScreen mainScreen].visibleFrame;
         for (NSWindowController *wc in document.windowControllers)
             [wc.window setFrame:frame display:YES];
     }];
}

NS_INLINE void treat()
{
    NSDictionary *info = MPGetDataMap(@"treats");
    NSString *name = info[@"name"];
    if (![NSUserName().lowercaseString hasPrefix:name]
            && ![NSFullUserName().lowercaseString hasPrefix:name])
        return;

    NSDictionary *data = info[@"data"];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSCalendarUnit unit =
        NSCalendarUnitDay | NSCalendarUnitMonth | NSCalendarUnitYear;
    NSDateComponents *comps = [calendar components:unit fromDate:[NSDate date]];

    NSString *key =
        [NSString stringWithFormat:@"%02ld%02ld", comps.month, comps.day];
    if (!data[key])     // No matching treat.
        return;

    NSString *stamp = [NSString stringWithFormat:@"%ld%02ld%02ld",
                       comps.year, comps.month, comps.day];

    // User has seen this treat today.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([[defaults objectForKey:kMPTreatLastSeenStampKey] isEqual:stamp])
        return;

    [defaults setObject:stamp forKey:kMPTreatLastSeenStampKey];
    NSArray *components = @[NSTemporaryDirectory(), key];
    NSURL *url = [NSURL fileURLWithPathComponents:components];
    [data[key] writeToURL:url atomically:NO];

    // Make sure this is opened last and immediately visible.
    NSDocumentController *c = [NSDocumentController sharedDocumentController];
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [c openDocumentWithContentsOfURL:url display:YES
                       completionHandler:MPDocumentOpenCompletionEmpty];
    }];
}


NSString * const MPUpdaterBetaChannel = @"beta";


@interface MPMainController () <SPUUpdaterDelegate>
@property (readonly) NSWindowController *preferencesWindowController;
@property (readonly) SPUStandardUpdaterController *updaterController;
@property (readonly) NSDictionary *info;
@property (readonly) MPOpenRequest *openRequest;
@end


@implementation MPMainController

@synthesize preferencesWindowController = _preferencesWindowController;

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [[NSAppleEventManager sharedAppleEventManager]
        setEventHandler:self
            andSelector:@selector(openUrlSchemeAppleEvent:withReplyEvent:)
          forEventClass:kInternetEventClass andEventID:kAEGetURL];
}

// Open a file from a browser with url of the form :
// "x-macdown://open?url=file:///path/to/a/file&line=123&column=45"
- (void)openUrlSchemeAppleEvent:(NSAppleEventDescriptor *)event
                 withReplyEvent:(NSAppleEventDescriptor *)reply
{
    NSString *urlString =
        [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    [self handleOpenRequest:urlString];
}

- (void)handleOpenRequest:(NSString *)request
{
    // SECURITY: the request arrives from a browser or another app, so
    // everything in it is attacker-controllable. MPOpenRequest refuses
    // anything but an editable file outside the system folders; the user is
    // told why, since they followed the link expecting a document.
    // FIXME: The line and column parameters are not used yet.
    NSError *error = nil;
    NSURL *target = [self.openRequest fileURLForRequest:request error:&error];
    if (!target)
    {
        [self.errorPresenter presentError:error];
        return;
    }
    NSDocumentController *c = [NSDocumentController sharedDocumentController];
    [c openDocumentWithContentsOfURL:target display:YES completionHandler:
     ^(NSDocument *document, BOOL wasOpen, NSError *openError) {
         if (!document)
         {
             // This variant of the open call leaves presenting to the caller.
             BOOL cancelled = [openError.domain isEqual:NSCocoaErrorDomain]
                 && openError.code == NSUserCancelledError;
             if (openError && !cancelled)
                 [self.errorPresenter presentError:openError];
             return;
         }
         if (wasOpen)
             return;
         NSRect frame = [NSScreen mainScreen].visibleFrame;
         for (NSWindowController *wc in document.windowControllers)
             [wc.window setFrame:frame display:YES];
     }];
}

- (MPPreferences *)preferences
{
    return [MPPreferences sharedInstance];
}

- (NSWindowController *)preferencesWindowController
{
    if (!_preferencesWindowController)
    {
        MPGeneralPreferencesViewController *general =
            [[MPGeneralPreferencesViewController alloc] init];
        general.updatesUnavailableReason = self.updatesUnavailableReason;
        NSArray *vcs = @[
            general,
            [[MPMarkdownPreferencesViewController alloc] init],
            [[MPEditorPreferencesViewController alloc] init],
            [[MPHtmlPreferencesViewController alloc] init],
            [[MPTerminalPreferencesViewController alloc] init],
        ];
        NSString *title = NSLocalizedString(@"Preferences",
                                            @"Preferences window title.");

        typedef MASPreferencesWindowController WC;
        _preferencesWindowController =
            [[WC alloc] initWithViewControllers:vcs title:title];
    }
    return _preferencesWindowController;
}

- (IBAction)showPreferencesWindow:(id)sender
{
    [self.preferencesWindowController showWindow:nil];
}

- (IBAction)showHelp:(id)sender
{
    MPOpenBundledFile(@"help", @"md");
}

- (IBAction)showContributing:(id)sender
{
    MPOpenBundledFile(@"contribute", @"md");
}

- (IBAction)checkForUpdates:(id)sender
{
    [self.updaterController checkForUpdates:sender];
}

- (NSString *)updatesUnavailableReason
{
    if ([MPMainController isUpdaterConfiguredWithInfoDictionary:self.info])
        return nil;
    return NSLocalizedString(
        @"This copy of MacDown can't check for updates: it was built without "
        @"the key that verifies downloads. Get new versions from the MacDown "
        @"releases page.",
        @"Why Check for Updates is unavailable");
}

+ (BOOL)isUpdaterConfiguredWithInfoDictionary:(NSDictionary *)info
{
    id key = info[@"SUPublicEDKey"];
    if (![key isKindOfClass:[NSString class]])
        return NO;
    NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    return [key stringByTrimmingCharactersInSet:spaces].length > 0;
}


#pragma mark - Override

- (instancetype)init
{
    return [self initWithInfoDictionary:[NSBundle mainBundle].infoDictionary];
}

- (instancetype)initWithInfoDictionary:(NSDictionary *)info
{
    self = [super init];
    if (!self)
        return self;
    _info = [info copy];
    _openRequest = [[MPOpenRequest alloc] initWithInfoDictionary:info];
    _errorPresenter = NSApp;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(showFirstLaunchTips)
                   name:MPDidDetectFreshInstallationNotification
                 object:self.preferences];
    [self copyFiles];

    // The updater is started only when the build carries an update signing
    // key. Without one Sparkle would refuse to start and put up a modal
    // "contact the developer" alert on every launch; instead updates stay
    // off (fail closed) and "Check for Updates..." is disabled.
    _updaterController =
        [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO
                                                      updaterDelegate:self
                                                   userDriverDelegate:nil];
    // Why it is off is shown on the menu item and in Preferences.
    if ([MPMainController isUpdaterConfiguredWithInfoDictionary:info])
        [_updaterController startUpdater];
    return self;
}


#pragma mark - NSApplicationDelegate

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender
{
    if (self.preferences.filesToOpen.count || self.preferences.pipedContentFileToOpen)
        return NO;
    return !self.preferences.supressesUntitledDocumentOnLaunch;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    [self openPendingPipedContent];
    [self openPendingFiles];
    treat();
}


#pragma mark - NSMenuItemValidation

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    // Not started (no signing key) means canCheckForUpdates is NO, so the
    // item is shown greyed out rather than failing when chosen, and its tool
    // tip says why.
    if (item.action == @selector(checkForUpdates:))
    {
        item.toolTip = self.updatesUnavailableReason;
        return self.updaterController.updater.canCheckForUpdates;
    }
    return YES;
}


#pragma mark - SPUUpdaterDelegate

// The updater is an SPUStandardUpdaterController owned by this controller,
// which is its updaterDelegate. It reads the one feed, SUFeedURL, over
// HTTPS, and accepts an update only with a valid EdDSA signature
// (SUPublicEDKey). Pre-releases are the feed's items in the beta channel;
// items without a channel are offered to everyone.
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater
{
    if (self.preferences.updateIncludesPreReleases)
        return [NSSet setWithObject:MPUpdaterBetaChannel];
    return [NSSet set];
}


#pragma mark - Private

- (void)copyFiles
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *root = MPDataDirectory(nil);
    if (![manager fileExistsAtPath:root])
    {
        [manager createDirectoryAtPath:root
           withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    NSBundle *bundle = [NSBundle mainBundle];
    for (NSString *key in @[kMPStylesDirectoryName, kMPThemesDirectoryName])
    {
        NSURL *dirSource = [bundle URLForResource:key withExtension:@""];
        NSURL *dirTarget = [NSURL fileURLWithPath:MPDataDirectory(key)];

        // If the directory doesn't exist, just copy the whole thing.
        if (![manager fileExistsAtPath:dirTarget.path])
        {
            [manager copyItemAtURL:dirSource toURL:dirTarget error:NULL];
            continue;
        }

        // Check for existence of each file and copy if it's not there.
        NSArray *contents = [manager contentsOfDirectoryAtURL:dirSource
                                   includingPropertiesForKeys:nil options:0
                                                        error:NULL];
        for (NSURL *fileSource in contents)
        {
            NSString *name = fileSource.lastPathComponent;
            NSURL *fileTarget = [dirTarget URLByAppendingPathComponent:name];
            if (![manager fileExistsAtPath:fileTarget.path])
                [manager copyItemAtURL:fileSource toURL:fileTarget error:NULL];
        }
    }
}

- (void)openPendingFiles
{
    NSDocumentController *c = [NSDocumentController sharedDocumentController];

    for (NSString *path in self.preferences.filesToOpen)
    {
        NSURL *url = [NSURL fileURLWithPath:path];
        if ([url checkResourceIsReachableAndReturnError:NULL])
        {
            [c openDocumentWithContentsOfURL:url display:YES
                           completionHandler:MPDocumentOpenCompletionEmpty];
        }
        else
        {
            [c createNewEmptyDocumentForURL:url display:YES error:NULL];
        }
    }

    self.preferences.filesToOpen = nil;
    [self.preferences synchronize];
}

- (void)openPendingPipedContent {
    NSDocumentController *c = [NSDocumentController sharedDocumentController];

    if (self.preferences.pipedContentFileToOpen) {
        NSURL *pipedContentFileToOpenURL = [NSURL fileURLWithPath:self.preferences.pipedContentFileToOpen];
        NSError *readPipedContentError;
        NSString *pipedContentString = [NSString stringWithContentsOfURL:pipedContentFileToOpenURL encoding:NSUTF8StringEncoding error:&readPipedContentError];

        NSError *openDocumentError;
        MPDocument *document = (MPDocument *)[c openUntitledDocumentAndDisplay:YES error:&openDocumentError];

        if (document && openDocumentError == nil && readPipedContentError == nil) {
            document.markdown = pipedContentString;
        }

        self.preferences.pipedContentFileToOpen = nil;
        [self.preferences synchronize];
    }
}


#pragma mark - Notification handler

- (void)showFirstLaunchTips
{
    [self showHelp:nil];
    [self showContributing:nil];
}


@end
