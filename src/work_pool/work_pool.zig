//! Most of this file is from the Bun project:
//! https://github.com/oven-sh/bun/blob/main/src/work_pool.zig

const std = @import("std");
const ThreadPool = @import("./ThreadPool.zig").ThreadPool;

pub const Batch = ThreadPool.Batch;
pub const Task = ThreadPool.Task;

pub fn NewWorkPool(comptime max_threads: ?usize) type {
    return struct {
        var pool: ThreadPool = undefined;
        var loaded: bool = false;
        var scheduled_tasks: u64 = 0;

        fn create() *ThreadPool {
            @setCold(true);

            pool = ThreadPool.init(.{
                .max_threads = max_threads orelse @max(@as(u32, @truncate(std.Thread.getCpuCount() catch 0)), 2),
                .stack_size = 2 * 1024 * 1024,
            });
            return &pool;
        }
        pub inline fn get() *ThreadPool {
            // lil racy
            if (loaded) return &pool;
            loaded = true;

            return create();
        }

        pub fn waitForCompletionAndDeinit() !void {
            while (scheduled_tasks > 0) {
                std.time.sleep(1); // TODO: optimal sleep interval here?
            } // wait for all scheduled tasks to complete
            pool.shutdown();
            pool.deinit();
        }

        fn schedule(task: *ThreadPool.Task) void {
            get().schedule(ThreadPool.Batch.from(task));
        }

        pub fn add_task(
            allocator: std.mem.Allocator,
            comptime Context: type,
            context: Context,
            comptime function: fn (Context) void,
        ) !void {
            const TaskType = struct {
                task: Task,
                context: Context,
                allocator: std.mem.Allocator,

                pub fn callback(task: *Task) void {
                    var this_task = @fieldParentPtr(@This(), "task", task);
                    function(this_task.context);
                    this_task.allocator.destroy(this_task);
                    scheduled_tasks -= 1;
                }
            };

            var task_ = try allocator.create(TaskType);
            task_.* = .{
                .task = .{ .callback = TaskType.callback },
                .context = context,
                .allocator = allocator,
            };
            schedule(&task_.task);
            scheduled_tasks += 1;
        }
    };
}

pub const WorkPool = NewWorkPool(null);
