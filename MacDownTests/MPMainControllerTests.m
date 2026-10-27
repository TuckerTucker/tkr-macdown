//
//  MPMainControllerTests.m
//  MacDown
//
//  Tests the x-macdown:// open-request guard (TB-3): MPOpenRequest decides,
//  and MPMainController shows the user why a request was refused instead of
//  only logging it. Fixtures are real files and symlinks in a temporary
//  folder; the editable types come from the app's own Info.plist.
//
//  Also tests seeding the data directory with the bundled Styles and Themes:
//  the source is the app bundle itself, the target a temporary folder.
//

#import <XCTest/XCTest.h>
#import "MPErrorPresenting.h"
#import "MPMainController.h"
#import "MPOpenRequest.h"


/// Records what would have been shown to the user.
@interface MPRecordingErrorPresenter : NSObject <MPErrorPresenting>
@property (nonatomic) NSMutableArray<NSError *> *errors;
@end

@implementation MPRecordingErrorPresenter

- (instancetype)init
{
    self = [super init];
    if (self)
        _errors = [NSMutableArray array];
    return self;
}

- (BOOL)presentError:(NSError *)error
{
    [self.errors addObject:error];
    return NO;
}

@end


@interface MPMainControllerTests : XCTestCase
@property (nonatomic) MPOpenRequest *request;
@property (nonatomic, copy) NSString *directory;
@end


@implementation MPMainControllerTests

- (void)setUp
{
    [super setUp];
    self.request = [[MPOpenRequest alloc]
        initWithInfoDictionary:[NSBundle mainBundle].infoDictionary];
    NSString *name = [NSString stringWithFormat:@"macdown-tb3-%@",
                      [[NSUUID UUID] UUIDString]];
    self.directory =
        [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtPath:self.directory withIntermediateDirectories:YES
                   attributes:nil error:NULL]);
}

- (void)tearDown
{
    [[NSFileManager defaultManager] removeItemAtPath:self.directory
                                               error:NULL];
    [super tearDown];
}

- (NSString *)fileNamed:(NSString *)name
{
    NSString *path = [self.directory stringByAppendingPathComponent:name];
    XCTAssertTrue([@"# hello\n" writeToFile:path atomically:YES
                                  encoding:NSUTF8StringEncoding error:NULL]);
    return path;
}

- (NSString *)linkNamed:(NSString *)name to:(NSString *)destination
{
    NSString *path = [self.directory stringByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager]
        createSymbolicLinkAtPath:path withDestinationPath:destination
                           error:&error], @"%@", error);
    return path;
}

- (NSError *)refusalForTarget:(NSString *)target
{
    NSError *error = nil;
    NSURL *url = [self.request fileURLForTarget:target error:&error];
    XCTAssertNil(url, @"%@ must be refused", target);
    XCTAssertEqualObjects(error.domain, MPOpenRequestErrorDomain);
    XCTAssertGreaterThan(error.localizedDescription.length, 0);
    XCTAssertGreaterThan(error.localizedRecoverySuggestion.length, 0,
                         @"the user must be told what to do instead");
    return error;
}

- (NSString *)fileURLStringForPath:(NSString *)path
{
    return [NSURL fileURLWithPath:path].absoluteString;
}

/// A readable regular file under /private/var/db, which every macOS has.
- (NSString *)systemDatabaseFile
{
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in [manager contentsOfDirectoryAtPath:@"/private/var/db"
                                                        error:NULL])
    {
        NSString *path = [@"/private/var/db" stringByAppendingPathComponent:name];
        BOOL isDirectory = YES;
        if ([manager fileExistsAtPath:path isDirectory:&isDirectory]
                && !isDirectory && [manager isReadableFileAtPath:path])
            return path;
    }
    return nil;
}


#pragma mark - Accepted

- (void)testMarkdownFileIsAccepted
{
    NSString *path = [self fileNamed:@"note.md"];
    NSError *error = nil;
    NSURL *url = [self.request
        fileURLForTarget:[self fileURLStringForPath:path] error:&error];
    XCTAssertNotNil(url, @"%@", error);
    XCTAssertTrue(url.isFileURL);
    XCTAssertEqualObjects(url.lastPathComponent, @"note.md");
}

- (void)testPlainTextFileIsAccepted
{
    NSString *path = [self fileNamed:@"note.txt"];
    XCTAssertNotNil([self.request
        fileURLForTarget:[self fileURLStringForPath:path] error:NULL]);
}

- (void)testWholeRequestYieldsItsFile
{
    NSString *path = [self fileNamed:@"note.md"];
    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"x-macdown://open"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url"
                                    value:[self fileURLStringForPath:path]],
        [NSURLQueryItem queryItemWithName:@"line" value:@"3"],
    ];
    NSError *error = nil;
    NSURL *url = [self.request fileURLForRequest:components.string
                                           error:&error];
    XCTAssertEqualObjects(url.lastPathComponent, @"note.md", @"%@", error);
}


#pragma mark - Refused

- (void)testWebAddressIsRefused
{
    NSError *error = [self refusalForTarget:@"http://evil.example/x.md"];
    XCTAssertEqual(error.code, MPOpenRequestErrorNotAFile);
}

- (void)testMissingFileIsRefused
{
    NSError *error =
        [self refusalForTarget:@"file:///does/not/exist/anywhere.md"];
    XCTAssertEqual(error.code, MPOpenRequestErrorNoSuchFile);
}

- (void)testFolderIsRefused
{
    NSError *error = [self refusalForTarget:
                      [self fileURLStringForPath:self.directory]];
    XCTAssertEqual(error.code, MPOpenRequestErrorDirectory);
}

- (void)testSystemFileIsRefused
{
    NSError *error = [self refusalForTarget:@"file:///etc/hosts"];
    XCTAssertEqual(error.code, MPOpenRequestErrorProtectedLocation);
    error = [self refusalForTarget:@"file:///private/etc/hosts"];
    XCTAssertEqual(error.code, MPOpenRequestErrorProtectedLocation);
}

// stringByResolvingSymlinksInPath drops a leading /private from a file that
// exists, so a /private/var entry in the list never matched before.
- (void)testFilesUnderVarAreRefusedInBothSpellings
{
    NSString *path = [self systemDatabaseFile];
    XCTAssertNotNil(path, @"no readable file in /private/var/db to test with");
    NSString *shortPath = [path substringFromIndex:@"/private".length];
    for (NSString *spelling in @[path, shortPath])
    {
        NSError *error = [self refusalForTarget:
                          [self fileURLStringForPath:spelling]];
        XCTAssertEqual(error.code, MPOpenRequestErrorProtectedLocation,
                       @"%@", spelling);
    }
}

- (void)testSymlinkIntoTheSystemIsRefused
{
    NSString *link = [self linkNamed:@"hosts.md" to:@"/etc/hosts"];
    NSError *error = [self refusalForTarget:[self fileURLStringForPath:link]];
    XCTAssertEqual(error.code, MPOpenRequestErrorProtectedLocation);
}

- (void)testTraversalIntoTheSystemIsRefused
{
    NSString *path = [self.directory stringByAppendingPathComponent:
                      @"../../../../../../../../etc/hosts"];
    // Spelled out by hand: NSURL's own constructors would standardise "..".
    NSError *error =
        [self refusalForTarget:[@"file://" stringByAppendingString:path]];
    XCTAssertEqual(error.code, MPOpenRequestErrorProtectedLocation);
}

- (void)testFileMacDownDoesNotEditIsRefused
{
    NSString *path = [self fileNamed:@"page.html"];
    NSError *error = [self refusalForTarget:[self fileURLStringForPath:path]];
    XCTAssertEqual(error.code, MPOpenRequestErrorUnsupportedType);
}

// MacDown can view any data (a Viewer-role public.data entry); that must not
// make every file openable from a link.
- (void)testViewerRoleTypesDoNotCount
{
    MPOpenRequest *request = [[MPOpenRequest alloc] initWithInfoDictionary:@{
        @"CFBundleDocumentTypes": @[@{
            @"CFBundleTypeRole": @"Viewer",
            @"LSItemContentTypes": @[@"public.data"],
            @"CFBundleTypeExtensions": @[@"md"],
        }],
    }];
    NSString *path = [self fileNamed:@"note.md"];
    NSError *error = nil;
    XCTAssertNil([request fileURLForTarget:[self fileURLStringForPath:path]
                                     error:&error]);
    XCTAssertEqual(error.code, MPOpenRequestErrorUnsupportedType);
}

- (void)testRequestsThatAreNotOpenLinksAreRefused
{
    for (NSString *request in @[@"", @"x-macdown://delete?url=file:///a.md",
                                @"x-macdown://open", @"x-macdown://open?url=",
                                @"https://open?url=file:///a.md"])
    {
        NSError *error = nil;
        XCTAssertNil([self.request fileURLForRequest:request error:&error],
                     @"%@", request);
        XCTAssertEqual(error.code, MPOpenRequestErrorMalformed, @"%@", request);
        XCTAssertGreaterThan(error.localizedRecoverySuggestion.length, 0);
    }
}


#pragma mark - Shown to the user

- (void)testRefusedRequestIsShownToTheUser
{
    MPMainController *controller =
        [[MPMainController alloc] initWithInfoDictionary:@{}];
    MPRecordingErrorPresenter *presenter =
        [[MPRecordingErrorPresenter alloc] init];
    controller.errorPresenter = presenter;

    [controller handleOpenRequest:
        @"x-macdown://open?url=http%3A%2F%2Fevil.example%2Fx.md"];

    XCTAssertEqual(presenter.errors.count, 1u,
                   @"a refused link must not fail silently");
    XCTAssertEqualObjects(presenter.errors.firstObject.domain,
                          MPOpenRequestErrorDomain);
    XCTAssertEqual(presenter.errors.firstObject.code,
                   MPOpenRequestErrorNotAFile);
}


#pragma mark - Seeding the data directory

- (MPMainController *)controller
{
    return [[MPMainController alloc] initWithInfoDictionary:@{}];
}

- (NSString *)seedRoot
{
    return [self.directory stringByAppendingPathComponent:@"Data"];
}

- (void)seed
{
    [[self controller] seedDataDirectory:[self seedRoot]
                              fromBundle:[NSBundle mainBundle]
                             fileManager:[NSFileManager defaultManager]];
}

- (NSArray<NSString *> *)sortedContentsOfDirectory:(NSString *)path
{
    NSArray *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:path error:NULL];
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray<NSString *> *)bundledContentsOfDirectory:(NSString *)name
{
    NSURL *url = [[NSBundle mainBundle] URLForResource:name
                                         withExtension:@""];
    XCTAssertNotNil(url, @"the app bundle must contain %@", name);
    return [self sortedContentsOfDirectory:url.path];
}

// Every seeded file's path, mapped to its modification date.
- (NSDictionary<NSString *, NSDate *> *)modificationDatesUnder:(NSString *)root
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *dates = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"Styles", @"Themes"])
    {
        NSString *dir = [root stringByAppendingPathComponent:name];
        for (NSString *file in [self sortedContentsOfDirectory:dir])
        {
            NSString *path = [dir stringByAppendingPathComponent:file];
            NSDictionary *attributes =
                [manager attributesOfItemAtPath:path error:NULL];
            dates[path] = attributes.fileModificationDate;
        }
    }
    return [dates copy];
}

- (void)testSeedingAnAbsentRootCopiesBothFolders
{
    NSString *root = [self seedRoot];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:root]);

    [self seed];

    for (NSString *name in @[@"Styles", @"Themes"])
    {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSArray *expected = [self bundledContentsOfDirectory:name];
        XCTAssertGreaterThan(expected.count, 0u, @"%@", name);
        XCTAssertEqualObjects([self sortedContentsOfDirectory:path], expected,
                              @"%@", name);
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    XCTAssertTrue([manager fileExistsAtPath:
        [root stringByAppendingPathComponent:@"Themes/Vellum.style"]]);
    XCTAssertTrue([manager fileExistsAtPath:
        [root stringByAppendingPathComponent:@"Styles/Vellum.css"]]);
}

// The discriminating case: an existing install gains the new theme while
// the user's edited copy of a bundled one is left exactly as it was.
- (void)testSeedingKeepsEditedFilesAndAddsMissingOnes
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *themes =
        [[self seedRoot] stringByAppendingPathComponent:@"Themes"];
    XCTAssertTrue([manager createDirectoryAtPath:themes
                     withIntermediateDirectories:YES attributes:nil
                                           error:NULL]);
    NSString *vellum = [themes stringByAppendingPathComponent:@"Vellum.style"];
    NSData *edited =
        [@"/* edited by the user */\n" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([edited writeToFile:vellum atomically:YES]);
    NSString *sepia = [themes stringByAppendingPathComponent:@"Sepia.style"];
    XCTAssertFalse([manager fileExistsAtPath:sepia]);

    [self seed];

    XCTAssertTrue([manager fileExistsAtPath:sepia],
                  @"a newly bundled theme must reach an existing install");
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:vellum], edited,
                          @"an edited theme must never be overwritten");
    XCTAssertEqualObjects([self sortedContentsOfDirectory:themes],
                          [self bundledContentsOfDirectory:@"Themes"]);
}

- (void)testSeedingTwiceChangesNothing
{
    NSString *root = [self seedRoot];
    [self seed];

    NSString *vellum =
        [root stringByAppendingPathComponent:@"Themes/Vellum.style"];
    NSData *edited =
        [@"/* edited by the user */\n" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([edited writeToFile:vellum atomically:YES]);

    NSDictionary *before = [self modificationDatesUnder:root];
    XCTAssertGreaterThan(before.count, 0u);

    [self seed];

    NSDictionary *after = [self modificationDatesUnder:root];
    XCTAssertEqualObjects(after, before,
                          @"a second seed must neither add nor touch a file");
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:vellum], edited);
}

@end
