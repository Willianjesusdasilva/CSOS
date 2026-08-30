const physical = @import("physical");
const idt = @import("idt");

const max_threads = 64;
const max_cpus = 256;
const queue_capacity = 64;
const stack_pages = 4;

const Entry = *const fn () void;

const State = enum { ready, running, sleeping, frozen, finished };

pub const Policy = enum { keep_alive, freeze, standby, auto };
pub const Lifecycle = enum { running, background, frozen, standby, resuming, finished };
pub const Mode = enum { normal, game, match };
pub const Workload = enum { system, game, input, network, audio, display, background };

const Context = extern struct {
    rsp: u64 = 0,
    _padding: u64 = 0,
    fx_state: [512]u8 align(16) = undefined,
};

const Thread = struct {
    context: Context,
    entry: Entry,
    state: State,
    process_id: u32 = 0,
    group: u16 = 0,
    policy: Policy = .auto,
    lifecycle: Lifecycle = .running,
    workload: Workload = .system,
    resume_state: State = .ready,
    sleep_ticks: u64 = 0,
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
var system_mode: Mode = .normal;

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
    while (true) asm volatile ("sti; hlt");
}

pub fn stopSecondaryWorkers() void {
    @atomicStore(bool, &secondary_workers_active, false, .release);
}

pub fn spawn(entry: Entry, pages: *physical.Allocator) !void {
    _ = try spawnManaged(entry, pages, 0, .auto);
}

pub fn spawnManaged(entry: Entry, pages: *physical.Allocator, group: u16, policy: Policy) !usize {
    return spawnClassified(entry, pages, group, policy, .system);
}

pub fn spawnClassified(entry: Entry, pages: *physical.Allocator, group: u16, policy: Policy, workload: Workload) !usize {
    return spawnProcess(entry, pages, 0, group, policy, workload);
}

pub fn spawnProcess(entry: Entry, pages: *physical.Allocator, process_id: u32, group: u16, policy: Policy, workload: Workload) !usize {
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
        .process_id = process_id,
        .group = group,
        .policy = policy,
        .workload = workload,
    };
    saveFxState(&thread.context.fx_state);
    threads[thread_count] = thread;
    const index = thread_count;
    thread_count += 1;
    return index;
}

pub fn backgroundGroup(group: u16) usize {
    var changed: usize = 0;
    for (threads[0..thread_count]) |*thread| {
        if (thread.group != group or thread.state == .finished or thread.state == .frozen) continue;
        thread.lifecycle = .background;
        changed += 1;
    }
    return changed;
}

pub fn freezeGroup(group: u16) usize {
    var changed: usize = 0;
    for (threads[0..thread_count]) |*thread| {
        if (thread.group != group or thread.policy == .keep_alive or
            (thread.state != .ready and thread.state != .sleeping)) continue;
        thread.resume_state = thread.state;
        thread.state = .frozen;
        thread.lifecycle = .frozen;
        changed += 1;
    }
    return changed;
}

pub fn freezeCurrent() !void {
    const index = current orelse return error.NoCurrentThread;
    if (threads[index].policy == .keep_alive) return error.KeepAlive;
    threads[index].resume_state = .ready;
    threads[index].state = .frozen;
    threads[index].lifecycle = .frozen;
    yieldNow();
}

pub fn standbyGroup(group: u16) usize {
    var changed: usize = 0;
    for (threads[0..thread_count]) |*thread| {
        if (thread.group != group or thread.state != .frozen or thread.policy == .keep_alive) continue;
        thread.lifecycle = .standby;
        changed += 1;
    }
    return changed;
}

pub fn setMode(value: Mode) void {
    system_mode = value;
}

pub fn mode() Mode {
    return system_mode;
}

pub fn applyMode(group: u16) usize {
    return switch (system_mode) {
        .normal => 0,
        .game => freezeGroup(group),
        .match => blk: {
            const frozen = freezeGroup(group);
            break :blk frozen + standbyGroup(group);
        },
    };
}

pub fn resumeGroup(group: u16) usize {
    var changed: usize = 0;
    for (threads[0..thread_count]) |*thread| {
        if (thread.group != group or thread.state != .frozen) continue;
        thread.state = thread.resume_state;
        thread.lifecycle = .resuming;
        changed += 1;
    }
    return changed;
}

pub fn sleepCurrent(ticks: u64) !void {
    const index = current orelse return error.NoCurrentThread;
    if (ticks == 0) return;
    threads[index].sleep_ticks = ticks;
    threads[index].state = .sleeping;
    threads[index].resume_state = .sleeping;
    yieldNow();
}

pub fn tick() void {
    for (threads[0..thread_count]) |*thread| {
        if (thread.state != .sleeping or thread.sleep_ticks == 0) continue;
        thread.sleep_ticks -= 1;
        if (thread.sleep_ticks == 0) thread.state = .ready;
    }
}

pub fn groupSleepTicks(group: u16) u64 {
    var remaining: u64 = 0;
    for (threads[0..thread_count]) |thread| {
        if (thread.group == group) remaining = @max(remaining, thread.sleep_ticks);
    }
    return remaining;
}

pub fn groupLifecycle(group: u16) ?Lifecycle {
    var result: ?Lifecycle = null;
    for (threads[0..thread_count]) |thread| {
        if (thread.group != group) continue;
        if (result == null or lifecyclePriority(thread.lifecycle) > lifecyclePriority(result.?)) result = thread.lifecycle;
    }
    return result;
}

pub fn groupProcessCount(group: u16) usize {
    var process_ids: [max_threads]u32 = undefined;
    var count: usize = 0;
    for (threads[0..thread_count]) |thread| {
        if (thread.group != group or thread.process_id == 0) continue;
        var known = false;
        for (process_ids[0..count]) |process_id| {
            if (process_id == thread.process_id) {
                known = true;
                break;
            }
        }
        if (!known) {
            process_ids[count] = thread.process_id;
            count += 1;
        }
    }
    return count;
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
    if (threads[next].lifecycle == .resuming) threads[next].lifecycle = .running;
    context_switch(&kernel_context, &threads[next].context);
}

pub fn yieldNow() void {
    const previous = current orelse return;
    if (threads[previous].state == .running) threads[previous].state = .ready;

    if (nextReady((previous + 1) % thread_count)) |next| {
        current = next;
        threads[next].state = .running;
        if (threads[next].lifecycle == .resuming) threads[next].lifecycle = .running;
        context_switch(&threads[previous].context, &threads[next].context);
        return;
    }

    if (threads[previous].state == .finished or threads[previous].state == .frozen or threads[previous].state == .sleeping) {
        const permanently_finished = threads[previous].state == .finished;
        current = null;
        context_switch(&threads[previous].context, &kernel_context);
        if (permanently_finished) unreachable;
        return;
    }
    threads[previous].state = .running;
}

fn nextReady(start: usize) ?usize {
    if (thread_count == 0) return null;
    var selected: ?usize = null;
    var selected_priority: u8 = 0;
    var offset: usize = 0;
    while (offset < thread_count) : (offset += 1) {
        const index = (start + offset) % thread_count;
        if (threads[index].state != .ready) continue;
        const priority = workloadPriority(threads[index].workload);
        if (selected == null or priority > selected_priority) {
            selected = index;
            selected_priority = priority;
        }
    }
    return selected;
}

fn workloadPriority(workload: Workload) u8 {
    if (system_mode == .normal) return 1;
    return switch (workload) {
        .input => 7,
        .display => 6,
        .audio => 5,
        .network => 4,
        .game => 3,
        .system => 2,
        .background => 1,
    };
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
    threads[index].lifecycle = .finished;
    yieldNow();
    halt();
}

fn lifecyclePriority(value: Lifecycle) u8 {
    return switch (value) {
        .running => 5,
        .resuming => 4,
        .background => 3,
        .frozen => 2,
        .standby => 2,
        .finished => 1,
    };
}

fn saveFxState(state: *[512]u8) void {
    asm volatile ("fxsave64 (%[state])"
        :
        : [state] "r" (state),
        : .{ .memory = true });
}

fn preempt() callconv(.c) void {
    tick();
    yieldNow();
}

fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}
