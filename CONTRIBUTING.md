# Contributing to MacDown

## Coding Style

All style rules are enforced under all circumstances except for external dependencies.

### Objective-C

#### The 80-column Rule

All code should obey the 80-column rule.

Exception: If a URL in a comment is too long, it can go over the limit. This happens a lot for Apple’s official documentation. Remember, however, that many websites offer alternative, shorter URL forms that are permanent. For example:

* The title slug in StackOverflow (and other StackExchange sites) URLs can be ommitted. The following two are equivalent:

    `http://stackoverflow.com/questions/13155612/how-does-one-eliminate-objective-c-try-catch-blocks-like-this`
    `http://stackoverflow.com/questions/13155612`

* The commit hash in GitHub commit page’s URL can be shortened. The followings are all equivalent:

    `https://github.com/uranusjr/macdown/commit/1612abb9dbd24113751958777a49cffc6767989c`
    `https://github.com/uranusjr/macdown/commit/1612abb9dbd24`
    `https://github.com/uranusjr/macdown/commit/1612abb`

#### Code Blocks

* Braces go in separate lines. ([Allman style](http://en.wikipedia.org/wiki/Indent_style#Allman_style).)
* If only one statement is contained inside the block, omit braces unless...
    * This is part of an if-(else if-)else structure. All brace styles in the same structure should match (i.e. either non or all of them omit braces).

#### Stetements Inside `if`, `while`, etc.

* Prefer implicit boolean conversion when it makes sense.
    * `if (str.length)` is better than `if (str.length != 0)` if you want to know whether a string is empty. 
    * The same applies when checking for an object’s `nil`-ness.
    * If what you want to compare against is *zero as a number*, not emptiness, such as for `NSRange` position, `NSPoint` coordinates, etc., *do* use the `== 0`/`!= 0` expression.

* If statements need to span multiple lines, prefer putting logical operators at the *beginning* of the line.

    Yes:
    ```c
    while (this_is_very_long
           || this_is_also_very_long)
    {
        // ...
    }
    ```

    No:
    ```c
    while (this_is_very_long ||
           this_is_also_very_long)
    {
        // ...
    }
    ```

* If code alignment is ambiguious, add extra indentation.

    Yes:
    ```c
    if (this_is_very_long
            || this_is_also_very_long)
        foo++;
    ```

    No:
    ```c
    if (this_is_very_long
        || this_is_also_very_long)
        foo++;
    ```

    The above is not enforced (but recommended) if braces exist. Useful if you have a hard time fitting the statement into the 80-column constraint.

    Okay:
    ```c
    if (this_is_very_long
        || this_is_very_very_truly_long)
    {
        foo++;
        bar--;
    }
    ```

#### Invisible Characters

Always use *four spaces* instead of tabs for indentation. Trailing whitespaces should be removed. You can turn on the **Automatically trim trailing whitespace** option in Xcode to let it do the job for you.

Try to ensure that there’s a trailing newline in the end of a file. This is not strictly enforced since there are no easy ways to do that (except checking manually), but I’d appriciate the effort.

## Version Control

MacDown uses Git for source control, and is hosted on GitHub.

### Commit Messages

[General rules](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html) apply. If you absolutely need to, the first line of the message *can* go as long as 72 (instead of 50) characters, but it must not exceed it.

Xcode’s commit window does not do a good job indicating whether your commit message is well-formed. I seldom use it personally, but if you do, you can check whether the commit message is good after you push to GitHub—If you see the first line of your commit message getting truncated, it is too long.

### Pull Requests

Please rebase your branch to `master` when you submit the pull request. There can be some nagging bugs when Git tries to merge files that are not code, particularly `.xib` and project files. When in doubt, always consider splitting changes into smaller commits so that you won’t need to re-apply your changes when things break.

Under certain circumstances I may wish you to perform further rebasing and/or squashing *after* you submit your pull request, or even perform them myself instead of merging your commits as-is. Don’t worry—you will always get full credits for your contribution.

## Making a signed build

This fork does not distribute updates: the app has no updater, and nothing is published to a feed. When a build is to be shared, `Tools/build_for_release.py` produces one that Gatekeeper accepts: Developer ID signed, notarized and stapled, and zipped. It runs without prompts: every input is a flag or an environment variable (`python3 Tools/build_for_release.py --help`).

### One-time setup

1. Install the dependencies:

    ```sh
    git submodule update --init --recursive
    bundle exec pod install
    python3 -m pip install -r Tools/requirements.txt
    ```

2. Install a **Developer ID Application** certificate in your login keychain (`security find-identity -v -p codesigning` lists it). Apple Development certificates are refused.

3. Store notarization credentials once. This asks for an app-specific password interactively, so it is the one step a person must do:

    ```sh
    xcrun notarytool store-credentials macdown-notary \
        --apple-id you@example.com --team-id TEAMID
    ```

### Each build

1. Commit everything and tag the commit. The script refuses development versions (such as `0.8.0d12`, built from an untagged commit) and dirty trees, because no commit would reproduce the build:

    ```sh
    git tag v0.8.1
    ```

2. Build and sign:

    ```sh
    export MACDOWN_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)"
    python3 Tools/build_for_release.py --notary-profile macdown-notary
    ```

    The script wipes `Build/`, builds `peg-markdown-highlight` and archives the Release configuration. It then signs inside-out with the hardened runtime and a secure timestamp: the `macdown` command-line tool first, then the app with `Tools/MacDown-release.entitlements`. It checks `codesign --verify --deep --strict`, notarizes and staples the app, checks `spctl --assess`, and zips it with `ditto` as `Build/MacDown-<version>.zip`. Without `--notary-profile` it signs but does not notarize, and Gatekeeper will block the first launch of a downloaded copy.

    The entitlements file turns off library validation. Without that, the hardened runtime would refuse every plug-in not signed by your own team, while MacDown admits plug-ins signed by any Developer ID and checks that signature itself before loading one.

    Exit status 0 means the zip is ready to share; 2 means a precondition refused the build (the message says what to fix); 1 means an external tool failed. Progress is logged as JSON lines on standard error.

### Release tooling tests

```sh
python3 -m pip install -r Tools/requirements.txt
python3 -m unittest discover -s Tools/tests
```

## More to Come

This style guide is a work in progress. Please feel free to ask if you have any questions about it. I’ll add more rules if there’s ambiguity.
