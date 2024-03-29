### 0.0.7
**BREAKING CHANGE!**
`ziglint` now supports specifying the severity of faults that a rule produces.
The `ziglint.json` format has been changed to accomodate this.

Other changes include:
- A `banned_comment_phrases` rule allowing the linter to fault certain phrases in comments.
- A `file_as_struct` rule enforcing the file capitalization convention for files with top-level fields.
- A `dupe_import` rule checking for when a file is needlessly imported multiple times.
- The unfinished const pointer enforcement rule has been removed for now.

### 0.0.6
- `ziglint` now utilizes exit codes.
- Logging verbosity has been decreased.

### 0.0.5
- `ziglint` no longer gets stuck in an infinite loop while attempting to lint certain symlink configurations on Windows.

### 0.0.4
- `.gitignore` files are now correctly parsed on Windows.
- Error reporting in the upgrade process has been improved.
- The automatic builds of `ziglint` on GitHub no longer include a faulty HTTP client.

### 0.0.3
- Support for the Windows operating system has been improved.
- [`exclude`](https://github.com/AnnikaCodes/ziglint#exclude) and [`include`](https://github.com/AnnikaCodes/ziglint#include) rules can now be specified with command-line options.

### 0.0.2
- New [`exclude`](https://github.com/AnnikaCodes/ziglint#exclude) and [`include`](https://github.com/AnnikaCodes/ziglint#include) rules have been implemented!
- [`max_line_length`](https://github.com/AnnikaCodes/ziglint#max_line_length) now defaults to a maximum of 100 characters per line.
- Command-line argument parsing was rewritten.
- Zig's `std.log` is no longer used for logging, fixing issues where information about upgrades wouldn't be printed properly.
- A bug in how [`max_line_length`](https://github.com/AnnikaCodes/ziglint#max_line_length) counts line lengths has been fixed. Newlines are no longer included in line length, and non-ASCII Unicode characters are no longer double-counted.

### 0.0.1
This is the first version of `ziglint`.
It's not too useful, but it supports two rules (`check_format` and `max_line_length`) and it can upgrade itself and follow directives from a `.gitignore`.