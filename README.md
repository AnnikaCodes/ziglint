# ziglint
[![Zig CI](https://github.com/AnnikaCodes/ziglint/actions/workflows/ci.yml/badge.svg)](https://github.com/AnnikaCodes/ziglint/actions/workflows/ci.yml)

`ziglint` is a configurable code analysis tool for Zig codebases. It's a work in progress and doesn't have many features at the moment, but it can be used.

Right now, there are only five functional linting rules: [`max_line_length`](#max_line_length), [`check_format`](#check_format), [`dupe_import`](#dupe_import), [`file_as_struct`](#file_as_struct), and [`banned_comment_phrases`](#banned_comment_phrases). However, more rules are planned.

# Installation
Prebuilt `ziglint` binaries for the most common platforms are available through [GitHub Releases](https://github.com/AnnikaCodes/ziglint/releases/latest); this is the recommended way to install `ziglint`.
You should rename the binary to `ziglint` and put it somewhere in your shell's `PATH`. For example:
```bash
mv ziglint-macos-x86_64 /usr/local/bin/ziglint
chmod +x /usr/local/bin/ziglint
```

If you use GitHub Actions, the [`AnnikaCodes/install-ziglint` Action](https://github.com/marketplace/actions/install-ziglint) will install `ziglint` onto your runner for you, so you can use it in your workflows without having to manually install it.

Windows users should know that `ziglint` has not been thoroughly tested on Windows; it should work fine, but please [report any bugs](https://github.com/AnnikaCodes/ziglint/issues/new).

macOS users should know that `ziglint` has not been codesigned, so you may need to explicitly allow it to run in System Preferences' "Privacy & Security" section: <details>
    <summary>image showing the System Preferences button you may need to click</summary>
    ![image](https://github.com/AnnikaCodes/ziglint/assets/56906084/a2914cba-9356-4eaa-a3d3-37ee816a5d74)
</details>


## Upgrading
`ziglint` has a built-in upgrade system.
You can run `ziglint upgrade` to automatically check if a newer version of `ziglint` is available and download it if so.
`ziglint upgrade` will attempt to replace the running copy with the latest version, and fall back to installing to `/usr/local/bin/ziglint` or the current directory.

# Configuration
Basic usage information can be viewed by running `ziglint help`, or you can just run `ziglint` to lint the current directory's Zig files.

Each `ziglint` rule can be configured to give an error or a warning.
Warnings still print the fault, but do not increment the exit code — this means that if only warnings are encounter, `ziglint` will exit successfully.
When rules are specified by command line flags, they cause errors by default.
To cause a warning instead, add `warn` or `warning` after the flag; for instance, `ziglint --check-format warn` or `ziglint --max-line-length 80,warning`.

You can enable or disable rules using either command-line options or a `ziglint.json` file. `ziglint` will look for the latter configuration file in directories starting from whichever directory you specify on the command line to be linted. An example `ziglint.json` to cap line length at 120 characters might look like this:
```json
{
    "max_line_length": {
        "limit": 120,
        "severity": "error"
    }
}
```

You can also tell `ziglint` to ignore individual lines of code via the comment directive `// ziglint: ignore`. If that's on a line of its own, `ziglint` will ignore the next line; if it comes at the end of a line, that line will be ignored.

For example, this line of code will throw an error if [`max_line_length`](#max_line_length) is set to 50:
```rust
std.debug.print("I am more than 50 characters long!", .{});
```
But neither of these blocks will:
```rust
// ziglint: ignore
std.debug.print("I am more than 50 characters long!", .{});
```
```rust
std.debug.print("I am more than 50 characters long!", .{}); // ziglint: ignore
```

`ziglint` will also ignore files listed in the nearest `.gitignore` file to the files/folders you're linting.
You can disable this feature with the `--include-gitignored` command-line option.
## Rules
Here's a list of all the linting rules supported by `ziglint`. Remember, this software is still a work in progress!

Anywhere you see `<severity>`, you can replace it with:
- `"error"` to enable the rule and treat violations as errors
- `"warning"` to enable the rule and treat violations as warnings
- `"disabled"` to disable the rule

## `banned_comment_phrases`
This rule creates a linting error or warning if specified phrases are present as substrings in comments. Users should be aware that the comment-detection code currently contains a bug with certain strings.

### `ziglint.json`
```json
{
    "banned_comment_phrases": {
        "error": [phrases to raise a lint error for],
        "warning": [phrases to raise a lint warning for]
    }
}
```
You may omit either `error` or `warning`.

### Command line
It is currently not possible to configure this rule from the command line.

## `check_format`
This rule creates a linting error or warning if the provided source code isn't formatted in the same way as Zig's autoformatter dictates. It also creates linting errors when there are AST (code parsing) errors.

This rule has a similar effect to `zig fmt --check`.
### `ziglint.json`
```json
{
    "check_format": <severity
}
```
### Command line
```bash
ziglint --check-format
```

## `exclude`
This rule excludes files from being linted (unless they are specified on the command line directly).

Note that include/exclude directives are additive and there is no priority for specifying on the command line. (However, include directives take precedence over excludes.)

It accepts Gitignore-style globs to specify paths.
### `ziglint.json`
```json
{
    "exclude": <array of files to exclude>
}
```
### Command line
```bash
ziglint --exclude <comma-separated list of paths to exclude>
```

## `include`
This rule negates exclusions. If the `include`d files aren't in the paths/working directory `ziglint` is searching in, they still won't be linted, but if they were listed in an `exclude` rule then they will be.
Note that include/exclude directives are additive and there is no priority for specifying on the command line. (However, include directives take precedence over excludes.)

Like `exclude`, it accepts Gitignore-style globs to match paths.
### `ziglint.json`
```json
{
    "include": <array of files to include>
}
```
### Command line
```bash
ziglint --include <comma-separated list of paths to include>
```

## `max_line_length`
This rule restricts the possible length of a line of source code. It will create a linting error if any line of Zig code is longer than the specified maximum. It defaults to 100 characters.
### `ziglint.json`
```json
{
    "max_line_length": {
        "limit": <maximum number of characters per line>,
        "severity": <severity>
}
```
### Command line
```bash
ziglint --max-line-length <maximum number of characters per line>
```

## `dupe_import`
This rule checks for cases where `@import` is called multiple times with the same value within a file.
### `ziglint.json`
```json
{
    "dupe_import": <severity>
}
```
### Command line
```bash
ziglint --dupe-import
```

## `file_as_struct`
This rule checks for file name capitalization in the presence of top level fields. Files with top
level fields can be treated as structs and per Zig [naming
conventions](https://ziglang.org/documentation/master/#Names) for types should be capitalized,
otherwise file names should not be capitalized.
### `ziglint.json`
```json
{
    "file_as_struct": <severity>
}
```
### Command line
```bash
ziglint --file-as-struct
```