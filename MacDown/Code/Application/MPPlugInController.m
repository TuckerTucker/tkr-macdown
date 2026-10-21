//
//  MPPlugInController.m
//  MacDown
//
//  Created by Tzu-ping Chung on 02/3.
//  Copyright © 2016 Tzu-ping Chung . All rights reserved.
//

#import "NSString+Lookup.h"
#import "MPErrorPresenting.h"
#import "MPPlugIn.h"
#import "MPPlugInController.h"
#import "MPUtilities.h"


// What a bundle looked like when it was last verified: a change to any file
// in it changes the fingerprint, so a refused plug-in that is replaced or
// re-signed is checked again.
static NSString *MPBundleFingerprint(NSString *path)
{
    NSURL *url = [NSURL fileURLWithPath:path];
    NSArray *keys = @[NSURLContentModificationDateKey];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:url includingPropertiesForKeys:keys options:0
           errorHandler:nil];
    NSDate *latest = nil;
    [url getResourceValue:&latest forKey:NSURLContentModificationDateKey
                    error:NULL];
    NSUInteger count = 0;
    for (NSURL *item in enumerator)
    {
        NSDate *date = nil;
        [item getResourceValue:&date forKey:NSURLContentModificationDateKey
                         error:NULL];
        if (date && (!latest || [date compare:latest] == NSOrderedDescending))
            latest = date;
        count++;
    }
    return [NSString stringWithFormat:@"%f:%lu",
            latest.timeIntervalSinceReferenceDate, (unsigned long)count];
}


@interface MPPlugInRefusal : NSObject
@property (nonatomic, copy) NSString *fingerprint;
@property (nonatomic, copy) NSError *error;
@end

@implementation MPPlugInRefusal
@end


@interface MPPlugInController ()
@property (nonatomic, copy) NSString *directory;
@property (nonatomic) id<MPPlugInVerifying> verifier;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, readwrite, copy) NSArray<MPPlugIn *> *plugIns;
@property (nonatomic, readwrite, copy) NSArray<NSError *> *refusals;
@property (nonatomic, weak) NSMenu *menu;

// Only touched on queue. A loaded bundle's code stays in the process, so
// its plug-in is kept and never verified or instantiated again.
@property (nonatomic) NSMutableDictionary<NSString *, MPPlugIn *> *loaded;
@property (nonatomic)
    NSMutableDictionary<NSString *, MPPlugInRefusal *> *refused;
@end


@implementation MPPlugInController

- (instancetype)init
{
    return [self initWithDirectory:MPDataDirectory(kMPPlugInsDirectoryName)
                          verifier:[[MPPlugInSignatureVerifier alloc] init]];
}

- (instancetype)initWithDirectory:(NSString *)directory
                         verifier:(id<MPPlugInVerifying>)verifier
{
    self = [super init];
    if (!self)
        return nil;

    _directory = [directory copy];
    _verifier = verifier;
    _queue = dispatch_queue_create("com.uranusjr.macdown.plugins",
                                   DISPATCH_QUEUE_SERIAL);
    _plugIns = @[];
    _refusals = @[];
    _loaded = [NSMutableDictionary dictionary];
    _refused = [NSMutableDictionary dictionary];
    _errorPresenter = NSApp;
    [self reloadWithCompletion:nil];
    return self;
}


#pragma mark - Scanning

- (void)reloadWithCompletion:(void (^)(void))completion
{
    dispatch_async(self.queue, ^{
        NSMutableArray<MPPlugIn *> *plugIns = [NSMutableArray array];
        NSMutableArray<MPPlugIn *> *initialized = [NSMutableArray array];
        NSMutableArray<NSError *> *refusals = [NSMutableArray array];
        NSMutableSet<NSString *> *present = [NSMutableSet set];

        NSArray *names = [[[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:self.directory error:NULL]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        for (NSString *name in names)
        {
            if (![name hasExtension:kMPPlugInFileExtension])
                continue;
            NSString *path =
                [self.directory stringByAppendingPathComponent:name];
            [present addObject:path];

            MPPlugIn *plugIn = self.loaded[path];
            if (plugIn)
            {
                [plugIns addObject:plugIn];
                continue;
            }
            NSString *fingerprint = MPBundleFingerprint(path);
            MPPlugInRefusal *refusal = self.refused[path];
            if ([refusal.fingerprint isEqualToString:fingerprint])
            {
                [refusals addObject:refusal.error];
                continue;
            }

            NSError *error = nil;
            NSBundle *bundle = [NSBundle bundleWithPath:path];
            plugIn = [[MPPlugIn alloc] initWithBundle:bundle
                                             verifier:self.verifier
                                                error:&error];
            if (plugIn)
            {
                self.loaded[path] = plugIn;
                [self.refused removeObjectForKey:path];
                [plugIns addObject:plugIn];
                [initialized addObject:plugIn];
                continue;
            }
            refusal = [[MPPlugInRefusal alloc] init];
            refusal.fingerprint = fingerprint;
            refusal.error = error;
            self.refused[path] = refusal;
            [refusals addObject:error];
        }
        for (NSString *path in self.refused.allKeys)
        {
            if (![present containsObject:path])
                [self.refused removeObjectForKey:path];
        }

        // Each plug-in hears it was initialised exactly once, off the main
        // thread as it always has.
        for (MPPlugIn *plugIn in initialized)
            [plugIn plugInDidInitialize];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.plugIns = plugIns;
            self.refusals = refusals;
            if (self.menu)
                [self populateMenu:self.menu];
            if (completion)
                completion();
        });
    });
}


#pragma mark - NSMenuDelegate

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    // Show what is known now, without blocking on signature checks; the
    // menu is refilled if the rescan finds something new.
    self.menu = menu;
    [self populateMenu:menu];
    [self reloadWithCompletion:nil];
}


#pragma mark - Private

- (void)populateMenu:(NSMenu *)menu
{
    [menu removeAllItems];
    for (MPPlugIn *plugin in self.plugIns)
    {
        NSMenuItem *item = [menu addItemWithTitle:plugin.name
                                           action:@selector(invokePlugIn:)
                                    keyEquivalent:@""];
        item.target = self;
        item.representedObject = plugin;
    }
    if (self.plugIns.count && self.refusals.count)
        [menu addItem:[NSMenuItem separatorItem]];
    for (NSError *refusal in self.refusals)
    {
        NSURL *url = refusal.userInfo[NSURLErrorKey];
        NSString *name = url.lastPathComponent.stringByDeletingPathExtension;
        NSString *title = [NSString stringWithFormat:NSLocalizedString(
            @"%@ (Not Loaded)", @"Plug-ins menu: a refused plug-in"), name];
        // No action, so the item is greyed out; the tool tip says why.
        NSMenuItem *item = [menu addItemWithTitle:title action:NULL
                                    keyEquivalent:@""];
        item.toolTip = refusal.localizedRecoverySuggestion;
        item.representedObject = refusal;
    }
    if (!self.plugIns.count && !self.refusals.count)
    {
        NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(
            @"No Plug-ins Installed", @"Plug-ins menu: empty")
                                           action:NULL keyEquivalent:@""];
        item.toolTip = [NSString stringWithFormat:NSLocalizedString(
            @"Plug-ins are loaded from %@.", @"Plug-ins menu: where from"),
            self.directory];
    }
}

- (void)invokePlugIn:(NSMenuItem *)item
{
    MPPlugIn *plugin = item.representedObject;
    if ([plugin run:item])
        return;
    NSDictionary *info = @{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            NSLocalizedString(@"The plug-in “%@” couldn't finish.",
                              @"Plug-in run failed: title"), plugin.name],
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(
            @"It reported a problem. If this keeps happening, contact the "
            @"plug-in's developer.", @"Plug-in run failed: what to do"),
    };
    [self.errorPresenter presentError:
        [NSError errorWithDomain:MPPlugInErrorDomain
                            code:MPPlugInErrorRunFailed userInfo:info]];
}

@end
