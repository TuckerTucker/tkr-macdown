//
//  MPPaperThemeTests.m
//  MacDown
//
//  Pins the contract of the eight paper themes. Each paper theme ships as
//  three files that must agree: Themes/<Name>.style (editor colors),
//  Themes/<Name>+.style (the same colors plus scaled, face-named headings)
//  and Styles/<Name>.css (the preview). The audit checks, against the files
//  copied into the app bundle:
//
//  - every expected theme has all three files, and every observed .style/.css
//    pair is either expected or a declared exemption (so a theme added
//    outside the list cannot slip past unexamined);
//  - both .style files parse through the real peg-markdown-highlight parser;
//  - the editor background equals the preview's --paper;
//  - every foreground meets WCAG 2.1 contrast (4.5:1) on every ground it can
//    be drawn on, in the editor and in the preview;
//  - every heading face named in a .style resolves to an installed font;
//  - every CSS font-family stack ends in a generic family.
//
//  The audit is a pure function of an injected population (file names plus
//  contents), so the negative tests drive the same code with one file
//  replaced by a fixture from MacDownTests/Fixtures.
//

#import <XCTest/XCTest.h>
#import "HGMarkdownHighlighter.h"


/// The WCAG 2.1 AA floor for normal-size text.
static const double kMPPaperMinimumContrast = 4.5;

/// Returns the error messages a stylesheet produces when parsed.
typedef NSArray<NSString *> *(^MPStylesheetParser)(NSString *stylesheet);


#pragma mark - Population

static NSArray<NSString *> *MPPaperThemeExpectedNames(void)
{
    return @[@"Vellum", @"Sepia", @"Kraft", @"Newsprint", @"Legal Pad",
             @"Rice", @"Linen", @"Blueprint"];
}

/// Observed .style/.css pairs that are deliberately outside this audit,
/// each with the reason it is exempt.
static NSDictionary<NSString *, NSString *> *MPPaperThemeExemptions(void)
{
    return @{
        @"Solarized (Light)": @"upstream MacDown theme, not a paper theme",
        @"Solarized (Dark)": @"upstream MacDown theme, not a paper theme",
    };
}

/// Expected themes whose three files are all present in the population.
static NSArray<NSString *> *MPPaperThemesExamined(
    NSArray<NSString *> *styleNames, NSArray<NSString *> *cssNames)
{
    NSMutableArray<NSString *> *examined = [NSMutableArray array];
    for (NSString *name in MPPaperThemeExpectedNames())
    {
        NSString *style = [name stringByAppendingString:@".style"];
        NSString *plus = [name stringByAppendingString:@"+.style"];
        NSString *css = [name stringByAppendingString:@".css"];
        if ([styleNames containsObject:style]
                && [styleNames containsObject:plus]
                && [cssNames containsObject:css])
            [examined addObject:name];
    }
    return examined;
}


#pragma mark - Parsing

/// Parses a peg-markdown-highlight stylesheet into block name -> attributes.
/// Attribute names are lowercased; values are trimmed.
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *
    MPPaperParseStyle(NSString *text)
{
    NSMutableDictionary *blocks = [NSMutableDictionary dictionary];
    NSMutableDictionary *current = nil;
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:
                               [NSCharacterSet newlineCharacterSet]])
    {
        NSString *line = [raw stringByTrimmingCharactersInSet:space];
        if (!line.length || [line hasPrefix:@"#"])
            continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
        {
            current = [NSMutableDictionary dictionary];
            blocks[line] = current;
            continue;
        }
        NSString *key = [[line substringToIndex:colon.location]
                         stringByTrimmingCharactersInSet:space];
        NSString *value = [[line substringFromIndex:NSMaxRange(colon)]
                           stringByTrimmingCharactersInSet:space];
        current[key.lowercaseString] = value;
    }
    return blocks;
}

/// Removes /* ... */ comments from CSS.
static NSString *MPPaperStripCSSComments(NSString *css)
{
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"/\\*.*?\\*/"
                             options:NSRegularExpressionDotMatchesLineSeparators
                               error:NULL];
    return [re stringByReplacingMatchesInString:css options:0
                                          range:NSMakeRange(0, css.length)
                                   withTemplate:@""];
}

/// Returns the custom properties of the first top-level `:root` rule, so a
/// `:root` nested in `@media print` (the print palette) is never read.
/// Keys keep their leading `--`; values are trimmed.
static NSDictionary<NSString *, NSString *> *MPPaperRootProperties(
    NSString *css)
{
    css = MPPaperStripCSSComments(css);
    NSUInteger depth = 0;
    unichar quote = 0;
    NSUInteger bodyStart = NSNotFound;
    for (NSUInteger i = 0; i < css.length; i++)
    {
        unichar c = [css characterAtIndex:i];
        if (quote)
        {
            if (c == quote)
                quote = 0;
            continue;
        }
        if (c == '"' || c == '\'')
            quote = c;
        else if (c == '{')
            depth++;
        else if (c == '}')
        {
            if (depth == 1 && bodyStart != NSNotFound)
            {
                NSString *body = [css substringWithRange:
                    NSMakeRange(bodyStart, i - bodyStart)];
                NSMutableDictionary *props = [NSMutableDictionary dictionary];
                NSCharacterSet *ws =
                    [NSCharacterSet whitespaceAndNewlineCharacterSet];
                for (NSString *decl in [body componentsSeparatedByString:@";"])
                {
                    NSRange colon = [decl rangeOfString:@":"];
                    if (colon.location == NSNotFound)
                        continue;
                    NSString *key = [[decl substringToIndex:colon.location]
                                     stringByTrimmingCharactersInSet:ws];
                    if ([key hasPrefix:@"--"])
                        props[key] = [[decl substringFromIndex:
                                          NSMaxRange(colon)]
                                      stringByTrimmingCharactersInSet:ws];
                }
                return props;
            }
            if (depth)
                depth--;
        }
        else if (depth == 0 && c == ':'
                 && [[css substringFromIndex:i] hasPrefix:@":root"])
        {
            NSRange brace = [css rangeOfString:@"{" options:0
                range:NSMakeRange(i, css.length - i)];
            NSString *between = [css substringWithRange:
                NSMakeRange(i + 5, brace.location == NSNotFound ?
                                   0 : brace.location - i - 5)];
            NSString *rest = [between stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (brace.location != NSNotFound && !rest.length)
            {
                bodyStart = brace.location + 1;
                depth = 1;
                i = brace.location;
            }
        }
    }
    return @{};
}

/// Returns the value of every `font-family:` declaration in the CSS.
static NSArray<NSString *> *MPPaperFontFamilyStacks(NSString *css)
{
    css = MPPaperStripCSSComments(css);
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"font-family\\s*:\\s*([^;}]+)"
                             options:NSRegularExpressionCaseInsensitive
                               error:NULL];
    NSMutableArray *stacks = [NSMutableArray array];
    for (NSTextCheckingResult *m in
         [re matchesInString:css options:0
                       range:NSMakeRange(0, css.length)])
    {
        NSString *stack = [[css substringWithRange:[m rangeAtIndex:1]]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [stacks addObject:stack];
    }
    return stacks;
}

/// YES if the last family of a font-family stack is a generic keyword.
/// A quoted name is never generic ("serif" names a font called serif).
static BOOL MPPaperStackEndsInGeneric(NSString *stack)
{
    static NSSet *generics;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        generics = [NSSet setWithArray:@[
            @"serif", @"sans-serif", @"monospace", @"cursive", @"fantasy",
            @"system-ui", @"ui-serif", @"ui-sans-serif", @"ui-monospace",
            @"ui-rounded"]];
    });
    NSString *last = [stack componentsSeparatedByString:@","].lastObject;
    last = [last stringByReplacingOccurrencesOfString:@"!important"
                                           withString:@""];
    last = [last stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [generics containsObject:last.lowercaseString];
}


#pragma mark - Color

/// Normalizes a 6-digit hex color (with or without '#') to uppercase without
/// '#'; returns nil for anything else.
static NSString *MPPaperHex(NSString *value)
{
    if ([value hasPrefix:@"#"])
        value = [value substringFromIndex:1];
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefABCDEF"] invertedSet];
    if (value.length != 6
            || [value rangeOfCharacterFromSet:notHex].location != NSNotFound)
        return nil;
    return value.uppercaseString;
}

/// WCAG 2.1 relative luminance of a normalized hex color.
static double MPPaperLuminance(NSString *hex)
{
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    double channels[3] = {
        ((rgb >> 16) & 0xFF) / 255.0,
        ((rgb >> 8) & 0xFF) / 255.0,
        (rgb & 0xFF) / 255.0,
    };
    for (int i = 0; i < 3; i++)
    {
        double c = channels[i];
        channels[i] = c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * channels[0] + 0.7152 * channels[1]
        + 0.0722 * channels[2];
}

/// WCAG 2.1 contrast ratio between two normalized hex colors.
static double MPPaperContrast(NSString *a, NSString *b)
{
    double la = MPPaperLuminance(a);
    double lb = MPPaperLuminance(b);
    return (MAX(la, lb) + 0.05) / (MIN(la, lb) + 0.05);
}


#pragma mark - Audit

static void MPPaperAuditStyle(NSString *theme, NSString *file,
                              NSString *text, NSString *paper,
                              NSMutableArray<NSString *> *findings)
{
    NSDictionary *blocks = MPPaperParseStyle(text);

    // The grounds every foreground can be drawn on in the editor.
    NSArray *groundBlocks =
        @[@"editor", @"editor-selection", @"editor-current-line"];
    NSMutableArray *grounds = [NSMutableArray array];
    for (NSString *block in groundBlocks)
    {
        NSString *raw = blocks[block][@"background"];
        NSString *hex = MPPaperHex(raw);
        if (!hex)
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: %@ %@ background '%@' is missing or not a 6-digit "
                @"hex color", theme, file, block, raw ?: @""]];
            continue;
        }
        [grounds addObject:@[block, hex]];
    }

    NSString *editorBackground = MPPaperHex(blocks[@"editor"][@"background"]);
    if (editorBackground && paper
            && ![editorBackground isEqualToString:paper])
    {
        [findings addObject:[NSString stringWithFormat:
            @"%@: %@ editor background %@ differs from Styles/%@.css "
            @"--paper %@", theme, file, editorBackground, theme, paper]];
    }

    NSArray *names = [blocks.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *block in names)
    {
        NSDictionary *attrs = blocks[block];
        NSString *rawForeground = attrs[@"foreground"];
        if (rawForeground)
        {
            NSString *foreground = MPPaperHex(rawForeground);
            if (!foreground)
            {
                [findings addObject:[NSString stringWithFormat:
                    @"%@: %@ %@ foreground '%@' is not a 6-digit hex color",
                    theme, file, block, rawForeground]];
            }
            for (NSArray *ground in foreground ? grounds : @[])
            {
                double ratio = MPPaperContrast(foreground, ground[1]);
                if (ratio < kMPPaperMinimumContrast)
                {
                    [findings addObject:[NSString stringWithFormat:
                        @"%@: %@ %@ foreground %@ on %@ background %@ has "
                        @"contrast %.2f:1, below %.1f:1", theme, file, block,
                        foreground, ground[0], ground[1], ratio,
                        kMPPaperMinimumContrast]];
                }
            }
        }

        NSString *face = attrs[@"font-family"];
        if (face && ![NSFont fontWithName:face size:12.0])
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: %@ %@ font-family '%@' does not resolve to an "
                @"installed font face", theme, file, block, face]];
        }
    }
}

static void MPPaperAuditCSS(NSString *theme, NSString *file, NSString *text,
                            NSMutableArray<NSString *> *findings)
{
    NSDictionary *props = MPPaperRootProperties(text);
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"--paper", @"--ink", @"--muted", @"--accent",
                            @"--selection", @"--current-line",
                            @"--code-background"])
    {
        NSString *hex = MPPaperHex(props[key]);
        if (!hex)
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: %@ top-level :root %@ '%@' is missing or not a "
                @"6-digit hex color", theme, file, key, props[key] ?: @""]];
            continue;
        }
        colors[key] = hex;
    }

    for (NSString *ink in @[@"--ink", @"--muted", @"--accent"])
    {
        for (NSString *ground in @[@"--paper", @"--selection",
                                   @"--current-line", @"--code-background"])
        {
            if (!colors[ink] || !colors[ground])
                continue;
            double ratio = MPPaperContrast(colors[ink], colors[ground]);
            if (ratio < kMPPaperMinimumContrast)
            {
                [findings addObject:[NSString stringWithFormat:
                    @"%@: %@ %@ %@ on %@ %@ has contrast %.2f:1, below "
                    @"%.1f:1", theme, file, ink, colors[ink], ground,
                    colors[ground], ratio, kMPPaperMinimumContrast]];
            }
        }
    }

    for (NSString *stack in MPPaperFontFamilyStacks(text))
    {
        if (!MPPaperStackEndsInGeneric(stack))
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: %@ font-family stack '%@' does not end in a generic "
                @"family", theme, file, stack]];
        }
    }
}

/// Audits the paper themes in an injected population.
///
/// styleNames and cssNames are the file names observed in Themes/ and
/// Styles/; contents maps "Themes/<file>" and "Styles/<file>" to text.
/// Returns one human-readable finding per violation; empty means the
/// population meets the contract.
static NSArray<NSString *> *MPPaperThemeFindings(
    NSArray<NSString *> *styleNames, NSArray<NSString *> *cssNames,
    NSDictionary<NSString *, NSString *> *contents)
{
    NSMutableArray<NSString *> *findings = [NSMutableArray array];
    NSArray *expected = MPPaperThemeExpectedNames();
    NSDictionary *exemptions = MPPaperThemeExemptions();

    // Complement: every observed .style/.css pair must be listed or exempt.
    NSMutableSet *pairs = [NSMutableSet set];
    for (NSString *css in cssNames)
    {
        NSString *name = css.stringByDeletingPathExtension;
        if ([styleNames containsObject:
                [name stringByAppendingString:@".style"]])
            [pairs addObject:name];
    }
    for (NSString *name in
         [pairs.allObjects sortedArrayUsingSelector:@selector(compare:)])
    {
        if (![expected containsObject:name] && !exemptions[name])
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: Themes/%@.style and Styles/%@.css form a theme pair "
                @"that is neither an expected paper theme nor exempt",
                name, name, name]];
        }
    }
    for (NSString *name in exemptions)
    {
        if (![pairs containsObject:name])
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: exemption no longer matches an observed theme pair; "
                @"remove it", name]];
        }
    }

    for (NSString *theme in expected)
    {
        NSString *styleFile = [theme stringByAppendingString:@".style"];
        NSString *plusFile = [theme stringByAppendingString:@"+.style"];
        NSString *cssFile = [theme stringByAppendingString:@".css"];

        NSString *paper = nil;
        NSString *cssText = [cssNames containsObject:cssFile] ?
            contents[[@"Styles/" stringByAppendingString:cssFile]] : nil;
        if (cssText)
        {
            NSString *path = [@"Styles/" stringByAppendingString:cssFile];
            MPPaperAuditCSS(theme, path, cssText, findings);
            paper = MPPaperHex(MPPaperRootProperties(cssText)[@"--paper"]);
        }
        else
        {
            [findings addObject:[NSString stringWithFormat:
                @"%@: missing sibling Styles/%@", theme, cssFile]];
        }

        for (NSString *file in @[styleFile, plusFile])
        {
            NSString *path = [@"Themes/" stringByAppendingString:file];
            NSString *text = [styleNames containsObject:file] ?
                contents[path] : nil;
            if (!text)
            {
                [findings addObject:[NSString stringWithFormat:
                    @"%@: missing sibling %@", theme, path]];
                continue;
            }
            MPPaperAuditStyle(theme, path, text, paper, findings);
        }
    }
    return findings;
}

/// Runs every present paper .style file through a stylesheet parser and
/// reports each error message it produces.
static NSArray<NSString *> *MPPaperThemeParseFindings(
    NSArray<NSString *> *styleNames,
    NSDictionary<NSString *, NSString *> *contents, MPStylesheetParser parse)
{
    NSMutableArray<NSString *> *findings = [NSMutableArray array];
    for (NSString *theme in MPPaperThemeExpectedNames())
    {
        for (NSString *suffix in @[@".style", @"+.style"])
        {
            NSString *file = [theme stringByAppendingString:suffix];
            NSString *path = [@"Themes/" stringByAppendingString:file];
            NSString *text = contents[path];
            if (![styleNames containsObject:file] || !text)
                continue;
            for (NSString *message in parse(text))
            {
                [findings addObject:[NSString stringWithFormat:
                    @"%@: %@ does not parse cleanly: %@",
                    theme, path, message]];
            }
        }
    }
    return findings;
}


#pragma mark - Tests

@interface MPPaperThemeTests : XCTestCase
@property (nonatomic) NSArray<NSString *> *styleNames;
@property (nonatomic) NSArray<NSString *> *cssNames;
@property (nonatomic) NSDictionary<NSString *, NSString *> *contents;
@end


@implementation MPPaperThemeTests

- (void)setUp
{
    [super setUp];
    NSMutableDictionary *contents = [NSMutableDictionary dictionary];
    self.styleNames = [self observedFilesIn:@"Themes" extension:@"style"
                                       into:contents];
    self.cssNames = [self observedFilesIn:@"Styles" extension:@"css"
                                     into:contents];
    self.contents = contents;
}


#pragma mark - Helpers

/// Lists the files with an extension in a bundled resource folder and reads
/// each into contents under "<folder>/<file>".
- (NSArray<NSString *> *)observedFilesIn:(NSString *)folder
                               extension:(NSString *)extension
                                    into:(NSMutableDictionary *)contents
{
    NSURL *url = [[NSBundle mainBundle] URLForResource:folder
                                         withExtension:@""];
    XCTAssertNotNil(url, @"%@ must be copied into the app bundle.", folder);
    NSArray *all = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:url.path error:NULL];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *file in all)
    {
        if (![file.pathExtension isEqualToString:extension])
            continue;
        [names addObject:file];
        NSString *text = [NSString stringWithContentsOfURL:
                              [url URLByAppendingPathComponent:file]
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (text)
            contents[[folder stringByAppendingPathComponent:file]] = text;
    }
    return names;
}

- (NSString *)fixtureNamed:(NSString *)name extension:(NSString *)extension
{
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:name withExtension:extension];
    XCTAssertNotNil(url, @"Fixture must be bundled with the test target.");
    NSString *text = [NSString stringWithContentsOfURL:url
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    XCTAssertGreaterThan(text.length, 0u);
    return text ?: @"";
}

/// The real bundle population with one file's contents replaced.
- (NSDictionary *)contentsReplacing:(NSString *)key with:(NSString *)text
{
    NSMutableDictionary *contents = [self.contents mutableCopy];
    contents[key] = text;
    return contents;
}

/// The real peg-markdown-highlight parser, as MPDocument applies a theme.
- (MPStylesheetParser)realParser
{
    return ^NSArray<NSString *> *(NSString *stylesheet) {
        NSTextView *textView =
            [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
        HGMarkdownHighlighter *highlighter =
            [[HGMarkdownHighlighter alloc] initWithTextView:textView];
        __block NSArray<NSString *> *errors = @[];
        [highlighter applyStylesFromStylesheet:stylesheet
                              withErrorHandler:^(NSArray *messages) {
            errors = [messages copy];
        }];
        return errors;
    };
}

- (void)assertFindings:(NSArray<NSString *> *)findings
          allContainAll:(NSArray<NSString *> *)needles
{
    XCTAssertGreaterThan(findings.count, 0u, @"Expected a finding.");
    for (NSString *finding in findings)
        for (NSString *needle in needles)
            XCTAssertTrue([finding containsString:needle],
                          @"Finding '%@' should mention '%@'.",
                          finding, needle);
}


#pragma mark - Real bundle

- (void)testBundledPaperThemesMeetContract
{
    NSArray *examined = MPPaperThemesExamined(self.styleNames, self.cssNames);
    XCTAssertEqual(examined.count, 8u,
                   @"Expected all eight paper themes; examined %@", examined);

    NSArray *findings = MPPaperThemeFindings(self.styleNames, self.cssNames,
                                             self.contents);
    XCTAssertEqualObjects(findings, @[], @"%@",
                          [findings componentsJoinedByString:@"\n"]);
}

- (void)testBundledPaperThemesParseCleanly
{
    NSArray *findings = MPPaperThemeParseFindings(self.styleNames,
                                                  self.contents,
                                                  [self realParser]);
    XCTAssertEqualObjects(findings, @[], @"%@",
                          [findings componentsJoinedByString:@"\n"]);
}


#pragma mark - Negative populations

- (void)testMissingSiblingIsReported
{
    NSMutableArray *styles = [self.styleNames mutableCopy];
    [styles removeObject:@"Vellum+.style"];

    NSArray *findings = MPPaperThemeFindings(styles, self.cssNames,
                                             self.contents);
    XCTAssertEqualObjects(findings,
                          @[@"Vellum: missing sibling Themes/Vellum+.style"]);
    XCTAssertEqual(MPPaperThemesExamined(styles, self.cssNames).count, 7u);
}

- (void)testUnlistedThemePairIsReported
{
    NSArray *styles =
        [self.styleNames arrayByAddingObject:@"Mystery.style"];
    NSArray *css = [self.cssNames arrayByAddingObject:@"Mystery.css"];
    NSMutableDictionary *contents = [self.contents mutableCopy];
    contents[@"Themes/Mystery.style"] = self.contents[@"Themes/Linen.style"];
    contents[@"Styles/Mystery.css"] = self.contents[@"Styles/Linen.css"];

    NSArray *findings = MPPaperThemeFindings(styles, css, contents);
    XCTAssertEqual(findings.count, 1u, @"%@", findings);
    [self assertFindings:findings
           allContainAll:@[@"Mystery", @"neither an expected paper theme"]];
}

- (void)testLowContrastForegroundIsReported
{
    NSString *fixture = [self fixtureNamed:@"paper-low-contrast"
                                 extension:@"style"];
    NSDictionary *contents =
        [self contentsReplacing:@"Themes/Linen.style" with:fixture];

    NSArray *findings = MPPaperThemeFindings(self.styleNames, self.cssNames,
                                             contents);
    XCTAssertEqual(findings.count, 3u, @"One per editor ground: %@",
                   findings);
    [self assertFindings:findings
           allContainAll:@[@"Linen", @"Themes/Linen.style", @"LIST_BULLET",
                           @"A8A196", @"contrast", @"below 4.5:1"]];
    XCTAssertTrue([[findings componentsJoinedByString:@"\n"]
                   containsString:@"on editor background FAF7F0"], @"%@",
                  findings);
}

- (void)testUnresolvableFaceIsReported
{
    NSString *fixture = [self fixtureNamed:@"paper-missing-face+"
                                 extension:@"style"];
    NSDictionary *contents =
        [self contentsReplacing:@"Themes/Linen+.style" with:fixture];

    NSArray *findings = MPPaperThemeFindings(self.styleNames, self.cssNames,
                                             contents);
    XCTAssertEqual(findings.count, 1u, @"%@", findings);
    [self assertFindings:findings
           allContainAll:@[@"Themes/Linen+.style", @"H1", @"NoSuchFace-Bold",
                           @"does not resolve"]];
}

- (void)testStackWithoutGenericFamilyIsReported
{
    NSString *fixture = [self fixtureNamed:@"paper-no-generic"
                                 extension:@"css"];
    NSDictionary *contents =
        [self contentsReplacing:@"Styles/Linen.css" with:fixture];

    NSArray *findings = MPPaperThemeFindings(self.styleNames, self.cssNames,
                                             contents);
    XCTAssertEqual(findings.count, 1u, @"%@", findings);
    [self assertFindings:findings
           allContainAll:@[@"Styles/Linen.css", @"Georgia'",
                           @"does not end in a generic family"]];
}

- (void)testPrintPaletteIsNotReadAsScreenPalette
{
    // Every paper .css overrides --paper inside @media print; the audit
    // must compare the editor against the top-level (screen) value.
    NSDictionary *props =
        MPPaperRootProperties(self.contents[@"Styles/Kraft.css"]);
    XCTAssertEqualObjects(props[@"--paper"], @"#D9C4A0");
}

- (void)testStylesheetParseErrorIsReported
{
    NSString *broken = [self.contents[@"Themes/Linen.style"]
        stringByReplacingOccurrencesOfString:@"background: FAF7F0"
                                  withString:@"background: FAF7FG"];
    NSDictionary *contents =
        [self contentsReplacing:@"Themes/Linen.style" with:broken];

    NSArray *findings = MPPaperThemeParseFindings(self.styleNames, contents,
                                                  [self realParser]);
    XCTAssertEqual(findings.count, 1u, @"%@", findings);
    [self assertFindings:findings
           allContainAll:@[@"Themes/Linen.style", @"does not parse cleanly",
                           @"FAF7FG"]];
}

@end
