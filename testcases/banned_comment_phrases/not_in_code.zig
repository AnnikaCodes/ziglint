// This phrase will be banned: chicken soup.
//! Here too, main.

/// Even substrings within doc-comments have remained subject to bans.
fn main() void {
    _ = "Note that only comments are subject to bans.";
    _ = "Within the warm confines of a string I am free to discuss chicken soup.";
    _ = "I can say get warned lol here."; // and I still won't error!
    // but not here:
    // get warned lol!
}
