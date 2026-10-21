//
//  MPErrorPresenting.h
//  MacDown
//
//  Where an error the user needs to see is sent. The application presents it
//  in the standard alert; tests inject a presenter that records it instead.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MPErrorPresenting <NSObject>

- (BOOL)presentError:(NSError *)error;

@end


@interface NSApplication (MPErrorPresenting) <MPErrorPresenting>
@end

NS_ASSUME_NONNULL_END
