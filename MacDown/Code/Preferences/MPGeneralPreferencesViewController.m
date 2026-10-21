//
//  MPGeneralPreferencesViewController.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 01/7.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPGeneralPreferencesViewController.h"
#import "MPPreferences.h"


@interface MPGeneralPreferencesViewController ()
@property (weak) IBOutlet NSButton *autoRenderingToggle;
@property (weak) IBOutlet NSButton *preReleasesToggle;
@end


@implementation MPGeneralPreferencesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self updatePreReleasesToggle];
}

- (void)setUpdatesUnavailableReason:(NSString *)reason
{
    _updatesUnavailableReason = [reason copy];
    [self updatePreReleasesToggle];
}

- (void)updatePreReleasesToggle
{
    self.preReleasesToggle.enabled = (self.updatesUnavailableReason == nil);
    self.preReleasesToggle.toolTip = self.updatesUnavailableReason;
}

#pragma mark - MASPreferencesViewController

- (NSString *)viewIdentifier
{
    return @"GeneralPreferences";
}

- (NSImage *)toolbarItemImage
{
    return [NSImage imageNamed:@"PreferencesGeneral"];
}

- (NSString *)toolbarItemLabel
{
    return NSLocalizedString(@"General", @"Preference pane title.");
}


#pragma mark - IBAction

- (IBAction)updateWordCounterVisibility:(id)sender
{
    if (sender == self.autoRenderingToggle)
    {
        if (self.autoRenderingToggle.state != NSOnState)
            self.preferences.editorShowWordCount = NO;
    }
}

@end
