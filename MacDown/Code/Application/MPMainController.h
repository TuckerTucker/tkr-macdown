//
//  MPMainController.h
//  MacDown
//
//  Created by Tzu-ping Chung  on 7/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import <Foundation/Foundation.h>
@class MPPreferences;

@interface MPMainController : NSObject <NSApplicationDelegate>

@property (nonatomic, readonly) MPPreferences *preferences;

// YES if info (an app's Info.plist dictionary) carries a non-empty
// SUPublicEDKey, i.e. the build can verify Ed25519-signed updates. The
// updater is only started when this holds.
+ (BOOL)isUpdaterConfiguredWithInfoDictionary:(NSDictionary *)info;

- (IBAction)checkForUpdates:(id)sender;

@end
