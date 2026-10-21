//
//  MPToolbarControllerTests.m
//  MacDown
//
//  Covers the toolbar-correctness remediation (Wave 1, W1-A):
//    Q-2 — action dispatch must pass the selector (SEL) to the document.
//    Q-4 — default item identifier generation must not read past a C-array.
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "MPToolbarController.h"


/// Exposes the private members the tests need to drive without a renderer.
@interface MPToolbarController (Testing)
- (void)selectedToolbarItemGroupItem:(NSSegmentedControl *)sender;
@end


/// Lightweight stand-in for MPDocument. Records whether a toolbar action was
/// dispatched to it, so the test can confirm the selector actually arrived.
@interface MPToolbarTestDocumentStub : NSObject
@property (nonatomic) BOOL didReceiveAction;
@end

@implementation MPToolbarTestDocumentStub
// Matches the action of the first subitem of the "indent-group" group.
- (void)unindent:(id)sender
{
    self.didReceiveAction = YES;
}
@end


@interface MPToolbarControllerTests : XCTestCase
@property (strong) MPToolbarController *controller;
@property (strong) NSToolbar *toolbar;
@end

@implementation MPToolbarControllerTests

- (void)setUp
{
    [super setUp];
    self.controller = [[MPToolbarController alloc] init];
    self.toolbar = [[NSToolbar alloc] initWithIdentifier:@"MPToolbarTests"];
}

- (void)tearDown
{
    self.controller = nil;
    [super tearDown];
}

#pragma mark - Q-4: default item identifiers (no out-of-bounds C-array read)

- (void)testDefaultItemIdentifiersProducedWithoutCrash
{
    // Before the fix this read spaceAfterIndices[0] of a zero-length array
    // (and walked flexibleSpaceAfterIndices past its end). It must now return a
    // populated list and simply not crash.
    NSArray<NSString *> *identifiers =
        [self.controller toolbarDefaultItemIdentifiers:self.toolbar];

    XCTAssertNotNil(identifiers);
    XCTAssertGreaterThan(identifiers.count, 0u);
}

- (void)testDefaultItemIdentifiersUseFlexibleSpacesAndExcludeOptionalItems
{
    NSArray<NSString *> *identifiers =
        [self.controller toolbarDefaultItemIdentifiers:self.toolbar];

    // No fixed spaces are intended in the default set.
    XCTAssertFalse([identifiers containsObject:NSToolbarSpaceItemIdentifier]);
    // Flexible spaces are intended.
    XCTAssertTrue([identifiers containsObject:NSToolbarFlexibleSpaceItemIdentifier]);

    // These items are explicitly excluded from the default toolbar.
    XCTAssertFalse([identifiers containsObject:@"comment"]);
    XCTAssertFalse([identifiers containsObject:@"highlight"]);
    XCTAssertFalse([identifiers containsObject:@"strikethrough"]);
}

// Flexible spaces follow the items at positions 2, 3, 5, 7 and 11 of the
// full item list, counting the three items left out of the default set.
- (void)testDefaultItemIdentifiersPlaceFlexibleSpacesAfterTheirItems
{
    NSString *flex = NSToolbarFlexibleSpaceItemIdentifier;
    NSArray<NSString *> *expected = @[
        @"indent-group", @"text-formatting-group", @"heading-group", flex,
        @"list-group", flex, @"blockquote", @"code", flex, @"link", @"image",
        flex, @"copy-html", flex, @"layout",
    ];
    XCTAssertEqualObjects(
        [self.controller toolbarDefaultItemIdentifiers:self.toolbar],
        expected);
}

- (void)testAllowedItemIdentifiersNonEmpty
{
    NSArray<NSString *> *allowed =
        [self.controller toolbarAllowedItemIdentifiers:self.toolbar];

    XCTAssertNotNil(allowed);
    XCTAssertGreaterThan(allowed.count, 0u);
}

#pragma mark - Q-2: group action dispatch passes the selector

- (void)testGroupActionDispatchInvokesSelectorOnDocument
{
    MPToolbarTestDocumentStub *stub = [[MPToolbarTestDocumentStub alloc] init];
    // The document property is a weak IBOutlet; the strong local keeps the stub
    // alive for the duration of the dispatch.
    [self.controller setValue:stub forKey:@"document"];

    NSSegmentedControl *sender = [[NSSegmentedControl alloc] init];
    sender.identifier = @"indent-group"; // populated in the controller's dictionary
    sender.segmentCount = 2;
    sender.selectedSegment = 0;          // -> "shift-left", action unindent:

    XCTAssertNoThrow([self.controller selectedToolbarItemGroupItem:sender]);
    XCTAssertTrue(stub.didReceiveAction,
                  @"Dispatch must reach unindent: on the document.");
}

- (void)testGroupActionDispatchIsSafeWhenDocumentDoesNotRespond
{
    // A bare NSObject does not implement the toolbar action selectors. The
    // respondsToSelector: guard must prevent any crash.
    NSObject *unrelated = [[NSObject alloc] init];
    [self.controller setValue:unrelated forKey:@"document"];

    NSSegmentedControl *sender = [[NSSegmentedControl alloc] init];
    sender.identifier = @"indent-group";
    sender.segmentCount = 2;
    sender.selectedSegment = 0;

    XCTAssertNoThrow([self.controller selectedToolbarItemGroupItem:sender]);
}

@end
