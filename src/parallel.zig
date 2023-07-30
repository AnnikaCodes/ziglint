//! Parallelization code.
//!
//! The current architecture is that the main process iterates over the director(ies) and finds
//! the files that need to be linted.
//! It puts them into a queue, which each of the worker threads pulls from.
//! Each worker thread grabs files from the queue and lints them, incrementing its own local fault counter.
//! (These worker threads also print the faults in the files as they lint them.)
//!
//! When the files are all in the queue, the main process will put some sort of signal on the queue
//! that will instruct the worker threads to add their fault counters to the shared fault counter (protected by a RwLock).
//! ASTAnalyzers are not mutated during analysis, so one *const ASTAnalyzer pointer can be shared between threads.

const std = @import("std");
const analysis = @import("./analysis.zig");

const QueueElementTag = enum {
    file_to_lint,
    no_more_files,
};

const QueueElement = union(QueueElementTag) {
    file_to_lint: []const u8,
    no_more_files,
};

fn RwLockedInteger(T: type) type {
    return struct {
        value: T,
        lock: std.Thread.RwLock,

        fn init(value: T) RwLockedInteger(T) {
            return RwLockedInteger(T){
                .value = value,
                .lock = std.Thread.RwLock.init(),
            };
        }

        fn read(self: *const RwLockedInteger(T)) T {
            return self.value;
        }

        fn add(self: RwLockedInteger(T), to_add: T) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.value += to_add;
        }
    };
}

pub const ParallelLinter = struct {
    analyzer: *const analysis.ASTAnalyzer,
    queue: std.atomic.Queue(QueueElement),
    // this maybe could be an atomic?
    // but Zig's std.atomic.Atomic isn't well documented and I don't want to make a mistake
    shared_error_counter: RwLockedInteger(u64),

    /// Initializes a new ParallelLinter with a particular analysis configuration.
    ///
    /// Runs in the main process.
    fn init(analyzer: analysis.ASTAnalyzer) ParallelLinter {
        return ParallelLinter{
            .analyzer = &analyzer,
            .queue = std.atomic.Queue(QueueElement).init(),
            .shared_error_counter = std.Thread.RwLock(u32).init(0),
        };
    }

    /// Runs the linter on a particular file/directory, setting up threads and all.
    /// Returns the number of error-severity faults found.
    ///
    /// Runs in the main process.
    fn run(self: *ParallelLinter, allocator: std.mem.Allocator, file_or_directory: []const u8, workers: u32) !u64 {
        // first, spawn threads...
        const threads: [workers]std.Thread = allocator.alloc(std.Thread, workers);
        defer allocator.free(threads);

        var i = 0;
        while (i < workers) : (i += 1) {
            threads[i] = std.Thread.spawn(
                .{ .allocator = allocator },
                ParallelLinter.worker_thread,
                .{ &self.queue, self.analyzer, self.shared_error_counter },
            );
        }

        // then, iterate over the file/directory, putting files we should lint on the queue
        // TODO: should there be a case where if we're not given a directory we skip the thread stuff for performance?
        try self.handle_file(file_or_directory);

        // finally, put a signal on the queue to tell the threads to stop, and wait for them to finish
        // this should auto-synchronize self.shared_error_counter,
        // because each thread will add its local error counter in at the end.
        self.queue.put(QueueElement{.no_more_files});
        for (threads) |thread| {
            thread.join();
        }

        return self.shared_error_counter.read();
    }

    /// Handles a file or directory, putting files to lint on the queue.
    ///
    /// Runs in the main process.
    fn handle_file(self: *ParallelLinter, file_or_directory: []const u8) !void {
        _ = file_or_directory;
        _ = self;
        // TODO: copy-paste a bunch of this from main.zig
    }

    /// The function that runs within each worker thread
    fn worker_thread(
        queue: *const std.atomic.Queue(QueueElement),
        analyzer: *const analysis.ASTAnalyzer,
        shared_error_counter: RwLockedInteger(u64),
    ) void {
        _ = queue;
        _ = analyzer;
        _ = shared_error_counter;
    }
};
