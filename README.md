# ziglint
[![Zig CI](https://github.com/AnnikaCodes/ziglint/actions/workflows/ci.yml/badge.svg)](https://github.com/AnnikaCodes/ziglint/actions/workflows/ci.yml)

`ziglint` is a configurable code analysis tool for Zig codebases. It's a work in progress and doesn't have many features at the moment, but it can be used.

Right now, there's only one functional linting rule: [`max_line_length`](#max_line_length). However, a rule to catch unnecessarily mutable pointers is currently being developed, and more rules are planned.

# Installation
Prebuilt `ziglint` binaries for the most common platforms are available through [GitHub Releases](https://github.com/AnnikaCodes/ziglint/releases/latest); this is the recommended way to install `ziglint`.
You should rename the binary to `ziglint` and put it somewhere in your shell's `PATH`. For example:
```bash
mv ziglint-macos-x86_64 /usr/local/bin/ziglint
chmod +x /usr/local/bin/ziglint
```

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

You can enable or disable rules using either command-line options or a `ziglint.json` file. `ziglint` will look for the latter configuration file in directories starting from whichever directory you specify on the command line to be linted. An example `ziglint.json` to cap line length at 120 characters might look like this:
```json
{
    "max_line_length": 120
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
## `max_line_length`
This rule restricts the possible length of a line of source code. It will create a linting error if any line of Zig code is longer than the specified maximum.
### `ziglint.json`
```json
{
    "max_line_length": <maximum number of characters per line>
}
```
### Command line
```bash
ziglint --max-line-length <maximum number of characters per line>
```

## `check_format`
This rule creates a linting error if the provided source code isn't formatted in the same way as Zig's autoformatter dictates. It also creates linting errors when there are AST (code parsing) errors.

This rule has a similar effect to `zig fmt --check`.
### `ziglint.json`
```json
{
    "check_format": true
}
```
### Command line
```bash
ziglint --check-format
```
