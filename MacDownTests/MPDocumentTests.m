//
//  MPDocumentTests.m
//  MacDown
//
//  Unit tests for MPDocument's model/data layer (finding TEST-2).
//
//  Scope: these tests exercise the parts of MPDocument that do NOT require the
//  MPDocument.xib nib, the WebView preview, the editor view, the renderer, or
//  the syntax highlighter to be instantiated. That means class-level document
//  policy, the preferences accessor, NSDocument init, and the inbound data
//  decoding path of -readFromData:ofType:error:.
//
//  Behaviors that are genuinely view-backed (the `markdown`/`html` properties,
//  the markdown round-trip through -dataOfType:error:, and the previewVisible/
//  editorVisible geometry flags) are documented here as deferred because they
//  read or write through IBOutlets (editor, renderer, preview, editorContainer)
//  that are only populated once the nib loads. Forcing the nib would stand up
//  the full window + WebView UI, which is out of scope for a unit test. Those
//  tests that touch the un-loaded state assert the documented degenerate
//  behavior so it is locked in rather than left unverified.
//

#import <XCTest/XCTest.h>
#import "MPDocument.h"
#import "MPPreferences.h"


// Test-only access to MPDocument's otherwise-private decoded-input buffer.
// -readFromData:ofType:error: stores the decoded text in `loadedString` and
// defers committing it to the editor until the nib's views exist. Exposing it
// here lets us verify the decode logic directly without loading the nib. This
// mirrors the (Testing) category pattern already used in MPMainControllerTests.
@interface MPDocument (Testing)
@property (copy) NSString *loadedString;
@end


@interface MPDocumentTests : XCTestCase
@property (nonatomic, strong) MPDocument *document;
@end


@implementation MPDocumentTests

- (void)setUp
{
    [super setUp];
    self.document = [[MPDocument alloc] init];
}

- (void)tearDown
{
    self.document = nil;
    [super tearDown];
}


#pragma mark - Lifecycle

- (void)testInitReturnsConfiguredDocument
{
    XCTAssertNotNil(self.document, @"-init should return a usable instance.");
    XCTAssertTrue([self.document isKindOfClass:[NSDocument class]],
                  @"MPDocument must remain an NSDocument subclass.");
}


#pragma mark - Class-level document policy

- (void)testAutosavesInPlace
{
    XCTAssertTrue([MPDocument autosavesInPlace],
                  @"MacDown documents are expected to autosave in place.");
}

- (void)testWritableTypesIsMarkdownUTI
{
    NSArray *types = [MPDocument writableTypes];
    XCTAssertEqualObjects(types, @[@"net.daringfireball.markdown"],
                          @"Only the markdown UTI should be writable.");
}

- (void)testWindowNibName
{
    XCTAssertEqualObjects(self.document.windowNibName, @"MPDocument",
                          @"MPDocument must load the MPDocument nib.");
}


#pragma mark - Preferences accessor

- (void)testPreferencesIsSharedInstance
{
    XCTAssertNotNil(self.document.preferences,
                    @"preferences accessor must never return nil.");
    XCTAssertEqual(self.document.preferences, [MPPreferences sharedInstance],
                   @"preferences must vend the shared singleton.");
}

- (void)testPreferencesIsSharedAcrossDocuments
{
    MPDocument *other = [[MPDocument alloc] init];
    XCTAssertEqual(self.document.preferences, other.preferences,
                   @"All documents must observe the same preferences object.");
}


#pragma mark - Inbound data decoding (-readFromData:ofType:error:)

- (void)testReadFromValidUTF8DataSucceedsAndBuffersContent
{
    NSString *source = @"# Heading\n\nA paragraph with *emphasis*.\n";
    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    BOOL ok = [self.document readFromData:data
                                  ofType:@"net.daringfireball.markdown"
                                   error:&error];

    XCTAssertTrue(ok, @"Valid UTF-8 markdown must decode successfully.");
    XCTAssertNil(error, @"A successful read must not populate the error out-arg.");
    XCTAssertEqualObjects(self.document.loadedString, source,
                          @"Decoded content must be buffered verbatim until the "
                          @"editor is available.");
}

- (void)testReadFromEmptyDataSucceedsWithEmptyString
{
    NSData *data = [NSData data];

    NSError *error = nil;
    BOOL ok = [self.document readFromData:data
                                  ofType:@"net.daringfireball.markdown"
                                   error:&error];

    XCTAssertTrue(ok, @"Empty data is a valid (empty) UTF-8 document.");
    XCTAssertEqualObjects(self.document.loadedString, @"",
                          @"Empty input should buffer as the empty string.");
}

- (void)testReadPreservesMultibyteUnicode
{
    NSString *source = @"# 日本語\n\némoji: 🚀 — café\n";
    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    BOOL ok = [self.document readFromData:data
                                  ofType:@"net.daringfireball.markdown"
                                   error:&error];

    XCTAssertTrue(ok, @"Multibyte UTF-8 content must decode successfully.");
    XCTAssertEqualObjects(self.document.loadedString, source,
                          @"Unicode content must survive the decode unchanged.");
}

- (void)testReadFromInvalidUTF8DataFails
{
    // 0xFF and 0xFE are never valid UTF-8 bytes, so decoding must fail.
    const unsigned char bytes[] = {0xFF, 0xFE, 0xFF, 0xFE};
    NSData *data = [NSData dataWithBytes:bytes length:sizeof(bytes)];

    NSError *error = nil;
    BOOL ok = [self.document readFromData:data
                                  ofType:@"net.daringfireball.markdown"
                                   error:&error];

    XCTAssertFalse(ok, @"Undecodable bytes must be rejected, not silently kept.");
    XCTAssertNil(self.document.loadedString,
                 @"A failed decode must not leave stale buffered content.");
}


#pragma mark - View-backed behavior before the nib loads
//
// The following tests lock in the documented behavior of the view-backed
// accessors when no nib/editor exists. They are NOT a substitute for the
// deferred integration tests noted in the file header; they exist so the
// "no editor yet" state is verified rather than assumed.

- (void)testMarkdownIsNilBeforeEditorExists
{
    // `markdown` reads self.editor.string; with no nib the editor outlet is nil,
    // so the property reports nil. The setter is likewise a no-op without an
    // editor. A real round-trip needs the editor view and is deferred.
    XCTAssertNil(self.document.markdown,
                 @"markdown is editor-backed and unavailable before the nib.");

    self.document.markdown = @"ignored without an editor";
    XCTAssertNil(self.document.markdown,
                 @"Setting markdown without an editor must remain a no-op.");
}

- (void)testVisibilityFlagsAreFalseBeforeNibLoads
{
    // previewVisible / editorVisible are derived from view frame geometry. With
    // no nib the outlets are nil and report zero-width frames, so both are NO.
    XCTAssertFalse(self.document.previewVisible,
                   @"previewVisible derives from view geometry; NO without a nib.");
    XCTAssertFalse(self.document.editorVisible,
                   @"editorVisible derives from view geometry; NO without a nib.");
}

- (void)testDataOfTypeIsGracefulWithoutEditor
{
    // -dataOfType: serializes self.editor.string; with no editor it must return
    // nil without crashing. The data->data round-trip is deferred to an
    // integration test that has a live editor.
    NSError *error = nil;
    NSData *data = [self.document dataOfType:@"net.daringfireball.markdown"
                                      error:&error];
    XCTAssertNil(data,
                 @"With no editor there is nothing to serialize; expect nil.");
}

@end
