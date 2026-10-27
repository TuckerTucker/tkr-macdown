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

@interface MPMainController : NSObject <NSApplicationDelegate>

@property (nonatomic, readonly) MPPreferences *preferences;

// Errors the user must see (a refused open request, a document that failed
// to open) go here. NSApp unless replaced.
@property (nonatomic, strong) id<MPErrorPresenting> errorPresenter;

// info is the app's Info.plist dictionary; -init passes the main bundle's.
- (instancetype)initWithInfoDictionary:(NSDictionary *)info
    NS_DESIGNATED_INITIALIZER;

// Carries out an x-macdown://open request, or presents why it was refused.
- (void)handleOpenRequest:(NSString *)request;

// Seeds root with the bundle's Styles and Themes folders, creating root if it
// is missing. A folder absent from root is copied whole; otherwise each
// missing file is copied, and an existing file is never overwritten, so new
// bundled themes reach existing installs without touching edited copies.
// Launch calls this with MPDataDirectory(nil) and the main bundle.
- (void)seedDataDirectory:(NSString *)root fromBundle:(NSBundle *)bundle
              fileManager:(NSFileManager *)manager;

@end
