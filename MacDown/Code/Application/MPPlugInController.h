//
//  MPPlugInController.h
//  MacDown
//
//  Created by Tzu-ping Chung on 02/3.
//  Copyright © 2016 Tzu-ping Chung . All rights reserved.
//

#import <Cocoa/Cocoa.h>
@class MPPlugIn;
@protocol MPErrorPresenting, MPPlugInVerifying;

NS_ASSUME_NONNULL_BEGIN

// Builds the Plug-ins menu. The plug-ins folder is scanned in the
// background, at launch and whenever the menu opens; a bundle is verified
// once, and again only when its contents change. Plug-ins that were refused
// stay in the menu, greyed out, with a tool tip saying why.
@interface MPPlugInController : NSObject <NSMenuDelegate>

@property (weak) IBOutlet NSDocumentController *documentController;

// As of the last finished scan, in file name order.
@property (nonatomic, readonly, copy) NSArray<MPPlugIn *> *plugIns;
@property (nonatomic, readonly, copy) NSArray<NSError *> *refusals;

// Where a plug-in's failure to run is reported. NSApp unless replaced.
@property (nonatomic, strong) id<MPErrorPresenting> errorPresenter;

// Scans MacDown's PlugIns data folder with the Developer ID verifier.
- (instancetype)init;
- (instancetype)initWithDirectory:(NSString *)directory
                         verifier:(id<MPPlugInVerifying>)verifier
    NS_DESIGNATED_INITIALIZER;

// Rescans the folder off the main thread. completion runs on the main
// queue once plugIns and refusals (and an attached menu) are up to date.
- (void)reloadWithCompletion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
