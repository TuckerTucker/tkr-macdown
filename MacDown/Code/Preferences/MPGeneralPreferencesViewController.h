//
//  MPGeneralPreferencesViewController.h
//  MacDown
//
//  Created by Tzu-ping Chung  on 01/7.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPPreferencesViewController.h"
#import <MASPreferences/MASPreferencesViewController.h>

@interface MPGeneralPreferencesViewController : MPPreferencesViewController
    <MASPreferencesViewController>

// When set, updates are off in this build: the pre-release option is greyed
// out and its tool tip carries this reason.
@property (nonatomic, copy) NSString *updatesUnavailableReason;

@end
