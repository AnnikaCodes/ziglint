//! Parallelization code.

const std = @import("std");

const analysis = @import("./analysis.zig");
const main = @import("./main.zig");

const stderr_print = main.stderr_print;
const Configuration = main.Configuration;

const WorkPool = @import("./work_pool/work_pool.zig").WorkPool;
const IgnoreTracker = @import("./gitignore.zig").IgnoreTracker;

const MAX_FILE_SIZE = 1024 * 1024 * 1024 * 1024; // 1 TB

fn less_than(_: @TypeOf(.{}), a: analysis.SourceCodeFault, b: analysis.SourceCodeFault) bool {
    return a.line_number < b.line_number;
}

fn RwLockedInteger(comptime T: type) type {
    return struct {
        value: T,
        lock: std.Thread.RwLock,

        fn init(value: T) RwLockedInteger(T) {
            return RwLockedInteger(T){
                .value = value,
                .lock = std.Thread.RwLock{},
            };
        }

        fn read(self: *const RwLockedInteger(T)) T {
            return self.value;
        }

        fn add(self: *RwLockedInteger(T), to_add: T) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.value += to_add;
        }
    };
}

const WorkerThreadContext = struct {
    analyzer: *const analysis.ASTAnalyzer,
    configuration: *const Configuration,
    shared_error_counter: *RwLockedInteger(u64),
    allocator: std.mem.Allocator,
    file_name: []const u8,
    stdout_lock: *std.Thread.RwLock,
};

pub const ParallelLinter = struct {
    analyzer: *const analysis.ASTAnalyzer,
    configuration: *const Configuration,
    // this maybe could be an atomic?
    // but Zig's std.atomic.Atomic isn't well documented and I don't want to make a mistake
    shared_error_counter: RwLockedInteger(u64),
    /// Non-arena allocator for things like files. Only for the main process.
    allocator: std.mem.Allocator,
    /// Thread-safe allocator that threads can use.
    thread_safe_allocator: std.heap.ThreadSafeAllocator,
    /// tracks seen files; never used in threads
    seen: std.StringHashMap(void),
    /// tracks files to ignore; never used in threads
    ignore_tracker: *const IgnoreTracker,
    /// Lock for stdout for threads
    stdout_lock: std.Thread.RwLock = std.Thread.RwLock{},

    /// Initializes a new ParallelLinter with a particular analysis configuration.
    ///
    /// Runs in the main process.
    pub fn init(
        arena_allocator: std.mem.Allocator,
        normal_allocator: std.mem.Allocator,
        analyzer: *const analysis.ASTAnalyzer,
        configuration: *const Configuration,
        ignore_tracker: *const IgnoreTracker,
    ) ParallelLinter {
        return .{
            .analyzer = analyzer,
            .configuration = configuration,
            .shared_error_counter = RwLockedInteger(u64).init(0),
            .seen = std.StringHashMap(void).init(arena_allocator),
            .allocator = normal_allocator,
            .thread_safe_allocator = std.heap.ThreadSafeAllocator{
                .child_allocator = normal_allocator,
            },
            .ignore_tracker = ignore_tracker,
        };
    }

    /// Runs the linter on a particular file/directory, setting up threads and all.
    /// Returns the number of error-severity faults found.
    ///
    /// Runs in the main process.
    pub fn run(self: *ParallelLinter, file_or_directory: []const u8) !u64 {
        // iterate over the file/directory, sending files we should lint to the WorkPool
        // TODO: should there be a case where if we're not given a directory we skip the thread stuff for performance?
        try self.handle_file_or_directory(file_or_directory, false);

        // finally, wait for the work pool to be done and return the # of errors
        try WorkPool.waitForCompletionAndDeinit();
        return self.shared_error_counter.read();
    }

    /// Handles a file or directory, putting files to lint on the queue.
    ///
    /// Runs in the main process.
    fn handle_file_or_directory(
        self: *ParallelLinter,
        file_or_directory: []const u8,
        is_top_level: bool,
    ) !void {
        // we need the full, not relative, path to make sure we avoid symlink loops
        const real_path = try std.fs.realpathAlloc(self.allocator, file_or_directory);
        if (self.seen.contains(real_path)) {
            // we need to free the `real_path` memory here since we're not adding it to the hashmap
            self.allocator.free(real_path);
            return;
        } else {
            try self.seen.put(real_path, {});
        }

        const file = std.fs.cwd().openFile(file_or_directory, .{}) catch |err| {
            switch (err) {
                error.AccessDenied => try stderr_print("error: access denied: '{s}'", .{file_or_directory}),
                error.DeviceBusy => try stderr_print("error: device busy: '{s}'", .{file_or_directory}),
                error.FileNotFound => try stderr_print("error: file not found: '{s}'", .{file_or_directory}),
                error.FileTooBig => try stderr_print("error: file too big: '{s}'", .{file_or_directory}),

                error.SymLinkLoop => {
                    // symlink loops should be caught by our hashmap of seen files
                    // if not, we have a problem, so let's check
                    if (!self.seen.contains(real_path)) {
                        try stderr_print(
                            "error: couldn't open '{s}' due to a symlink loop, " ++
                                "but it still hasn't been linted (full path: {s})",
                            .{ file_or_directory, real_path },
                        );
                    }
                },

                // Windows can't open a directory with openFile, apparently.
                error.IsDir => return try self.handle_directory(file_or_directory),

                else => try stderr_print("error: couldn't open '{s}': {}", .{ file_or_directory, err }),
            }

            // exit the program if the *user* specified an inaccessible file;
            // otherwise, just skip it
            if (is_top_level) {
                std.os.exit(1);
            } else {
                return;
            }
        };
        defer file.close();

        const metadata = try file.metadata(); // TODO: is .stat() faster?
        const kind = metadata.kind();
        switch (kind) {
            .file => {
                if (!is_top_level) {
                    // not a Zig file + not directly specified by the user
                    if (!std.mem.endsWith(u8, file_or_directory, ".zig")) return;
                    // ignored by a .gitignore
                    if (try self.ignore_tracker.is_ignored(file_or_directory)) return;
                }

                // send it to the work pool
                const threadsafe_allocator = self.thread_safe_allocator.allocator();
                const file_name_for_thread = try threadsafe_allocator.alloc(u8, file_or_directory.len);
                @memcpy(file_name_for_thread, file_or_directory);

                try WorkPool.add_task(
                    self.allocator,
                    WorkerThreadContext,
                    WorkerThreadContext{
                        .analyzer = self.analyzer,
                        .configuration = self.configuration,
                        .shared_error_counter = &self.shared_error_counter,
                        .allocator = threadsafe_allocator,
                        .file_name = file_name_for_thread,
                        .stdout_lock = &self.stdout_lock,
                    },
                    ParallelLinter.worker_thread,
                );
            },
            .directory => try self.handle_directory(file_or_directory),
            else => {
                try stderr_print(
                    "ignoring '{s}', which is not a file or directory, but a(n) {}.",
                    .{ file_or_directory, kind },
                );
            },
        }
    }

    /// This is its own helper function because of W*ndows.
    fn handle_directory(self: *ParallelLinter, directory_name: []const u8) anyerror!void {
        var dir = try std.fs.cwd().openIterableDir(directory_name, .{});
        defer dir.close();

        var iterable = dir.iterate();
        var entry = try iterable.next();
        while (entry != null) : (entry = try iterable.next()) {
            const full_name = try std.fs.path.join(self.allocator, &[_][]const u8{ directory_name, entry.?.name });
            defer self.allocator.free(full_name);
            try self.handle_file_or_directory(full_name, false);
        }
    }

    /// The function that runs within each thread in the worker pool
    fn worker_thread(context: WorkerThreadContext) void {
        // ahora estamos en la thread
        // we need to free stuff from the context
        defer context.allocator.free(context.file_name);
        var error_count: u64 = 0;

        const contents = std.fs.cwd().readFileAllocOptions(
            context.allocator,
            context.file_name,
            MAX_FILE_SIZE,
            null,
            @alignOf(u8),
            0,
        ) catch |err| {
            stderr_print("error: couldn't read '{s}': {}", .{ context.file_name, err }) catch unreachable;
            return;
        };
        defer context.allocator.free(contents);

        // std.debug.print("FILE: '{s}'\n", .{contents});

        var ast = std.zig.Ast.parse(context.allocator, contents, .zig) catch |err| {
            stderr_print("error: couldn't parse '{s}' into Zig AST: {}", .{ context.file_name, err }) catch unreachable;
            return;
        };
        defer ast.deinit(context.allocator);

        var faults = context.analyzer.analyze(context.allocator, context.file_name, ast) catch |err| {
            stderr_print("error: couldn't analyze '{s}': {}", .{ context.file_name, err }) catch unreachable;
            return;
        };
        defer faults.deinit();

        // TODO just return faults.items

        _ = std.sort.insertion(analysis.SourceCodeFault, faults.faults.items, .{}, less_than);
        const stdout = std.io.getStdOut();
        const stdout_writer = stdout.writer();

        const use_color: bool = stdout.supportsAnsiEscapeCodes();
        const bold_text: []const u8 = if (use_color) "\x1b[1m" else "";
        const red_text: []const u8 = if (use_color) "\x1b[31m" else "";
        const yellow_text: []const u8 = if (use_color) "\x1b[33m" else "";

        // currently not used but makes for a nice highlight!
        // const bold_magenta: []const u8 = if (use_color) "\x1b[1;35m" else "";
        const end_text_fmt: []const u8 = if (use_color) "\x1b[0m" else "";
        for (faults.faults.items) |fault| {
            // TODO: is it faster to just pass the faults back up to the main process and avoid locking stdout?
            context.stdout_lock.lock();
            stdout_writer.print("{s}{s}:{}:{}{s}: ", .{
                bold_text,
                context.file_name,
                fault.line_number,
                fault.column_number,
                end_text_fmt,
            }) catch unreachable;
            var warning = false;
            var fault_formatting = red_text;
            switch (fault.fault_type) {
                .LineTooLong => |len| {
                    if (context.configuration.max_line_length != null and
                        context.configuration.max_line_length.?.severity == .Warning)
                    {
                        warning = true;
                        fault_formatting = yellow_text;
                    }

                    stdout_writer.print(
                        "line is {s}{} characters long{s}; the maximum is {}",
                        .{ fault_formatting, len, end_text_fmt, context.analyzer.max_line_length },
                    ) catch unreachable;
                },
                .BannedCommentPhrase => |phrase_info| {
                    if (phrase_info.severity_level == .Warning) {
                        warning = true;
                        fault_formatting = yellow_text;
                    }

                    stdout_writer.print(
                        "comment includes banned phrase '{s}{s}{s}':\n    {s}=> {s}{s}",
                        .{
                            fault_formatting, phrase_info.phrase, end_text_fmt,
                            fault_formatting, end_text_fmt,       phrase_info.comment,
                        },
                    ) catch unreachable;
                },
                .DupeImport => |name| {
                    // TODO: can we do some shenanigans with @field to make this if not have to be in every switch?
                    if (context.configuration.dupe_import == .Warning) {
                        warning = true;
                        fault_formatting = yellow_text;
                    }

                    stdout_writer.print(
                        "found {s}duplicate import{s} of {s}",
                        .{ fault_formatting, end_text_fmt, name },
                    ) catch unreachable;
                },
                .FileAsStruct => |capitalize| {
                    if (context.configuration.file_as_struct == .Warning) {
                        warning = true;
                        fault_formatting = yellow_text;
                    }

                    if (capitalize) {
                        stdout_writer.print(
                            "found top level fields, file name should be {s}capitalized{s}",
                            .{ fault_formatting, end_text_fmt },
                        ) catch unreachable;
                    } else {
                        stdout_writer.print(
                            "found no top level fields, file name should be {s}lowercase{s}",
                            .{ fault_formatting, end_text_fmt },
                        ) catch unreachable;
                    }
                },
                .ImproperlyFormatted => {
                    if (context.configuration.check_format == .Warning) {
                        warning = true;
                        fault_formatting = yellow_text;
                    }
                    stdout_writer.print(
                        "the file is {s}improperly formatted{s}; try using `zig fmt` to fix it",
                        .{ fault_formatting, end_text_fmt },
                    ) catch unreachable;
                },
                .ASTError => {
                    stdout_writer.print("Zig's code parser detected an error: {s}", .{red_text}) catch unreachable;
                    ast.renderError(fault.ast_error.?, stdout_writer) catch |err| {
                        stderr_print(
                            "error: couldn't render AST error for {s}: {}",
                            .{ context.file_name, err },
                        ) catch unreachable;
                    };
                    stdout_writer.print("{s}", .{end_text_fmt}) catch unreachable;
                },
            }
            stdout_writer.writeAll("\n") catch unreachable;
            context.stdout_lock.unlock();

            if (!warning) error_count += 1;
        }

        // increment *global* error count
        if (error_count != 0) {
            context.shared_error_counter.add(error_count);
        }
        return;
    }
};
