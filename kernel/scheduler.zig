const physical = @import("physical");
const idt = @import("idt");

const max_threads = 64;
const max_cpus = 256;
const queue_capacity = 64;
const stack_pages = 4;

const Entry = *const fn () void;

const State = enum { ready, running, finished };

const Context = extern struct {
    rsp: u64 = 0,
    _padding: u64 = 0,
    fx_state: [512]u8 align(16) = undefined,
};

const Thread = struct {
    context: Context,
    entry: Entry,
    state: State,
};

const CpuQueue = struct {
    entries: [queue_capacity]Entry = undefined,
    write_index: u32 = 0,
    read_index: u32 = 0,
};

extern fn context_switch(old: *Context, new: *Context) callconv(.c) void;

var threads: [max_threads]Thread = undefined;
var thread_count: usize = 0;
var current: ?usize = null;
var kernel_context = Context{};
var cpu_ids: [max_cpus]u32 = undefined;
var cpu_queues: [max_cpus]CpuQueue = .{CpuQueue{}} ** max_cpus;
var cpu_count: usize = 0;
var secondary_workers_active = true;

pub fn addCpu(apic_id: u32) !void {
    if (cpu_count == max_cpus) return error.CpuLimit;
    cpu_ids[cpu_count] = apic_id;
    cpu_queues[cpu_count] = .{};
    cpu_count += 1;
}

pub fn enqueue(apic_id: u32, entry: Entry) !void {
    const queue = queueFor(apic_id) orelse return error.UnknownCpu;
    const write_index = @atomicLoad(u32, &queue.write_index, .monotonic);
    const read_index = @atomicLoad(u32, &queue.read_index, .acquire);
    if (write_index -% read_index == queue_capacity) return error.QueueFull;
    queue.entries[write_index % queue_capacity] = entry;
    @atomicStore(u32, &queue.write_index, write_index +% 1, .release);
}

pub fn runLocal(apic_id: u32) bool {
    const queue = queueFor(apic_id) orelse return false;
    return runOne(queue);
}

pub fn secondaryMain(apic_id: u32) callconv(.c) noreturn {
    const queue = queueFor(apic_id) orelse halt();
    while (@atomicLoad(bool, &secondary_workers_active, .acquire)) {
        if (!runOne(queue)) asm volatile ("pause");
    }
    halt();
}

pub fn stopSecondaryWorkers() void {
    @atomicStore(bool, &secondary_workers_active, false, .release);
}

pub fn spawn(entry: Entry, pages: *physical.Allocator) !void {
    if (thread_count == max_threads) return error.ThreadLimit;
    const stack = pages.allocate(stack_pages) orelse return error.OutOfMemory;
    const stack_top = stack + stack_pages * 4096;
    const saved_stack: [*]u64 = @ptrFromInt(stack_top - 80);
    @memset(saved_stack[0..10], 0);
    saved_stack[8] = @intFromPtr(&threadBootstrap);

    var thread = Thread{
        .context = .{ .rsp = stack_top - 80 },
        .entry = entry,
        .state = .ready,
    };
    saveFxState(&thread.context.fx_state);
    threads[thread_count] = thread;
    thread_count += 1;
}

pub fn enablePreemption() void {
    idt.setTimerHook(&preempt);
}

pub fn disablePreemption() void {
    idt.setTimerHook(null);
}

pub fn run() void {
    const next = nextReady(0) orelse return;
    current = next;
    threads[next].state = .running;
    context_switch(&kernel_context, &threads[next].context);
}

pub fn yieldNow() void {
    const previous = current orelse return;
    if (threads[previous].state == .running) threads[previous].state = .ready;

    if (nextReady((previous + 1) % thread_count)) |next| {
        current = next;
        threads[next].state = .running;
        context_switch(&threads[previous].context, &threads[next].context);
        return;
    }

    if (threads[previous].state == .finished) {
        current = null;
        context_switch(&threads[previous].context, &kernel_context);
        unreachable;
    }
    threads[previous].state = .running;
}

fn nextReady(start: usize) ?usize {
    if (thread_count == 0) return null;
    var offset: usize = 0;
    while (offset < thread_count) : (offset += 1) {
        const index = (start + offset) % thread_count;
        if (threads[index].state == .ready) return index;
    }
    return null;
}

fn queueFor(apic_id: u32) ?*CpuQueue {
    var index: usize = 0;
    while (index < cpu_count) : (index += 1) {
        if (cpu_ids[index] == apic_id) return &cpu_queues[index];
    }
    return null;
}

fn runOne(queue: *CpuQueue) bool {
    const read_index = @atomicLoad(u32, &queue.read_index, .monotonic);
    const write_index = @atomicLoad(u32, &queue.write_index, .acquire);
    if (read_index == write_index) return false;
    const entry = queue.entries[read_index % queue_capacity];
    @atomicStore(u32, &queue.read_index, read_index +% 1, .release);
    entry();
    return true;
}

fn threadBootstrap() callconv(.c) noreturn {
    const index = current orelse halt();
    threads[index].entry();
    threads[index].state = .finished;
    yieldNow();
    halt();
}

fn saveFxState(state: *[512]u8) void {
    asm volatile ("fxsave64 (%[state])"
        :
        : [state] "r" (state),
        : .{ .memory = true });
}

fn preempt() callconv(.c) void {
    yieldNow();
}

fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}
