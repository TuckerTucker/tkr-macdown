//
//  MPMainController.h
//  MacDown
//
//  Created by Tzu-ping Chung  on 7/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import <Foundation/Foundation.h>
@class MPPreferences;
@protocol MPErrorPresenting;

// The Sparkle channel pre-release items are published in.
extern NSString * const MPUpdaterBetaChannel;

@interface MPMainController : NSObject <NSApplicationDelegate>

@property (nonatomic, readonly) MPPreferences *preferences;

// Errors the user must see (a refused open request, a document that failed
// to open) go here. NSApp unless replaced.
@property (nonatomic, strong) id<MPErrorPresenting> errorPresenter;

// Why updates are off in this build, for the UI to show where updates are
// offered; nil when they are on.
@property (nonatomic, readonly) NSString *updatesUnavailableReason;

// info is the app's Info.plist dictionary; -init passes the main bundle's.
- (instancetype)initWithInfoDictionary:(NSDictionary *)info
    NS_DESIGNATED_INITIALIZER;

// YES if info (an app's Info.plist dictionary) carries a non-empty
// SUPublicEDKey, i.e. the build can verify Ed25519-signed updates. The
// updater is only started when this holds.
+ (BOOL)isUpdaterConfiguredWithInfoDictionary:(NSDictionary *)info;

- (IBAction)checkForUpdates:(id)sender;

// Carries out an x-macdown://open request, or presents why it was refused.
- (void)handleOpenRequest:(NSString *)request;

@end
