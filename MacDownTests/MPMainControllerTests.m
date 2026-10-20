//
//  MPMainControllerTests.m
//  MacDown
//
//  Tests the x-macdown:// open-request URL guard (TB-3).
//

#import <XCTest/XCTest.h>
#import "MPMainController.h"


// Test-only access to the otherwise-private validation helper. Declaring the
// category here keeps the production header clean while still letting us
// exercise the guard directly.
@interface MPMainController (Testing)
- (NSURL *)validatedFileURLFromString:(NSString *)urlString;
@end


@interface MPMainControllerTests : XCTestCase
@property (nonatomic, strong) MPMainController *controller;
@property (nonatomic, copy) NSString *tempFilePath;
@end


@implementation MPMainControllerTests

- (void)setUp
{
    [super setUp];
    self.controller = [[MPMainController alloc] init];

    // Write a real local markdown file in the temp directory.
    NSString *name = [NSString stringWithFormat:@"macdown-tb3-%@.md",
                      [[NSUUID UUID] UUIDString]];
    self.tempFilePath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSError *error = nil;
    BOOL written = [@"# hello\n"
                    writeToFile:self.tempFilePath atomically:YES
                       encoding:NSUTF8StringEncoding error:&error];
    XCTAssertTrue(written, @"Failed to write temp file: %@", error);
}

- (void)tearDown
{
    if (self.tempFilePath)
        [[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath
                                                   error:NULL];
    self.controller = nil;
    [super tearDown];
}

- (void)testFileURLToExistingLocalFileIsAccepted
{
    NSURL *fileURL = [NSURL fileURLWithPath:self.tempFilePath];
    NSURL *result =
        [self.controller validatedFileURLFromString:fileURL.absoluteString];

    XCTAssertNotNil(result, @"A file:// URL to a real local file must be accepted");
    XCTAssertTrue(result.isFileURL, @"Accepted URL must be a file URL");
}

- (void)testHTTPSchemeIsRejected
{
    NSURL *result =
        [self.controller validatedFileURLFromString:@"http://evil.example/x.md"];
    XCTAssertNil(result, @"A non-file scheme (http) must be rejected");
}

- (void)testSensitiveSystemFileIsRejected
{
    NSURL *result =
        [self.controller validatedFileURLFromString:@"file:///etc/passwd"];
    XCTAssertNil(result, @"A sensitive system file must be rejected");
}

- (void)testNonexistentFileIsRejected
{
    NSURL *result = [self.controller validatedFileURLFromString:
                     @"file:///does/not/exist/anywhere.md"];
    XCTAssertNil(result, @"A path that does not resolve to a file must be rejected");
}

@end
