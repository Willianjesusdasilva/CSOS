//! Deterministic process-FD ownership gate, independent of kernel syscalls.
const std = @import("std");

pub const Pipe = struct {
    const capacity = 4096;
    buffer: [capacity]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
    pub fn write(self: *Pipe, data: []const u8) usize {
        const count = @min(data.len, capacity - self.len);
        for (data[0..count], 0..) |byte, i| self.buffer[(self.head + self.len + i) % capacity] = byte;
        self.len += count;
        return count;
    }
    pub fn read(self: *Pipe, out: []u8) usize {
        const count = @min(out.len, self.len);
        for (out[0..count], 0..) |*byte, i| byte.* = self.buffer[(self.head + i) % capacity];
        self.head = (self.head + count) % capacity;
        self.len -= count;
        return count;
    }
};

pub const Description = struct {
    refs: usize = 0,
    pipe: *Pipe,
    readable: bool,
    writable: bool,
};
const Entry = struct { description: *Description, cloexec: bool };

pub const Table = struct {
    entries: [64]?Entry = .{null} ** 64,
    pub fn fork(self: *const Table) Table {
        const child = self.*;
        for (self.entries) |entry| {
            if (entry) |value| value.description.refs += 1;
        }
        return child;
    }
    pub fn install(self: *Table, fd: usize, description: *Description, cloexec: bool) !void {
        if (fd >= self.entries.len or self.entries[fd] != null) return error.BadFd;
        description.refs += 1;
        self.entries[fd] = .{ .description = description, .cloexec = cloexec };
    }
    pub fn dup2(self: *Table, old: usize, new: usize) !void {
        if (old >= self.entries.len or new >= self.entries.len) return error.BadFd;
        const source = self.entries[old] orelse return error.BadFd;
        if (old == new) return;
        self.close(new);
        source.description.refs += 1;
        self.entries[new] = .{ .description = source.description, .cloexec = false };
    }
    pub fn dup(self: *Table, old: usize, minimum: usize) !usize {
        if (old >= self.entries.len) return error.BadFd;
        const source = self.entries[old] orelse return error.BadFd;
        var fd = minimum;
        while (fd < self.entries.len and self.entries[fd] != null) : (fd += 1) {}
        if (fd == self.entries.len) return error.TooManyFiles;
        source.description.refs += 1;
        self.entries[fd] = .{ .description = source.description, .cloexec = false };
        return fd;
    }
    pub fn exec(self: *Table) void {
        var fd: usize = 0;
        while (fd < self.entries.len) : (fd += 1) {
            if (self.entries[fd]) |entry| if (entry.cloexec) self.close(fd);
        }
    }
    pub fn close(self: *Table, fd: usize) void {
        if (fd >= self.entries.len) return;
        const entry = self.entries[fd] orelse return;
        self.entries[fd] = null;
        entry.description.refs -= 1;
    }
    pub fn write(self: *const Table, fd: usize, data: []const u8) !usize {
        const entry = self.entries[fd] orelse return error.BadFd;
        if (!entry.description.writable) return error.NotWritable;
        return entry.description.pipe.write(data);
    }
    pub fn read(self: *const Table, fd: usize, out: []u8) !usize {
        const entry = self.entries[fd] orelse return error.BadFd;
        if (!entry.description.readable) return error.NotReadable;
        return entry.description.pipe.read(out);
    }
};

/// A process owns one descriptor table for the lifetime of its workspace.
/// Threads may share the table, while fork creates a new table that retains
/// the same open-file descriptions.  Keeping the workspace identity beside
/// the table makes accidental cross-process descriptor lookups impossible in
/// tests and mirrors the ownership contract used by the kernel runtime.
pub const WorkspaceTable = struct {
    workspace_id: u32,
    table: Table = .{},

    pub fn init(workspace_id: u32) WorkspaceTable {
        return .{ .workspace_id = workspace_id };
    }

    pub fn fork(self: *const WorkspaceTable, child_workspace_id: u32) WorkspaceTable {
        return .{ .workspace_id = child_workspace_id, .table = self.table.fork() };
    }

    pub fn closeAll(self: *WorkspaceTable) void {
        for (self.table.entries, 0..) |entry, fd| if (entry != null) self.table.close(fd);
    }
};

pub const ChildState = struct { exited: bool = false, status: u8 = 0 };
pub fn waitpid(child: *const ChildState) !u8 {
    if (!child.exited) return error.WouldBlock;
    return child.status;
}

test "isolated two-pipe fork dup2 exec close waitpid gate" {
    var pipe_a = Pipe{}; var pipe_b = Pipe{};
    var a_read = Description{ .pipe = &pipe_a, .readable = true, .writable = false };
    var a_write = Description{ .pipe = &pipe_a, .readable = false, .writable = true };
    var b_read = Description{ .pipe = &pipe_b, .readable = true, .writable = false };
    var b_write = Description{ .pipe = &pipe_b, .readable = false, .writable = true };
    var parent = Table{};
    try parent.install(3, &a_write, false); try parent.install(4, &b_read, false);
    try parent.install(5, &a_read, false); try parent.install(6, &b_write, false);
    var child = parent.fork();
    try child.dup2(5, 0); try child.dup2(6, 1);
    const duplicated = try child.dup(1, 10);
    try std.testing.expectEqual(@as(usize, 10), duplicated);
    try std.testing.expectEqual(@as(usize, 4), try child.write(duplicated, "echo"));
    var echoed: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try parent.read(4, &echoed));
    try std.testing.expectEqualStrings("echo", &echoed);
    const refs_before_alias_close = b_write.refs;
    child.close(10);
    try std.testing.expectEqual(refs_before_alias_close - 1, b_write.refs);
    try child.install(9, &a_read, true);
    const inherited = try child.dup(9, 11);
    try std.testing.expectEqual(@as(usize, 11), inherited);
    child.exec();
    try std.testing.expect(child.entries[9] == null);
    try std.testing.expect(child.entries[11] != null);
    try std.testing.expectEqual(@as(usize, 4), try parent.write(3, "ping"));
    var input: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try child.read(0, &input));
    try std.testing.expectEqualStrings("ping", &input);
    try std.testing.expectEqual(@as(usize, 4), try child.write(1, "pong"));
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try parent.read(4, &output));
    try std.testing.expectEqualStrings("pong", &output);
    var state = ChildState{ .exited = true, .status = 0 };
    try std.testing.expectEqual(@as(u8, 0), try waitpid(&state));
    parent.close(3); parent.close(4); parent.close(5); parent.close(6);
    child.close(0); child.close(1); child.close(3); child.close(4); child.close(5); child.close(6); child.close(11);
    try std.testing.expectEqual(@as(usize, 0), a_read.refs);
    try std.testing.expectEqual(@as(usize, 0), a_write.refs);
    try std.testing.expectEqual(@as(usize, 0), b_read.refs);
    try std.testing.expectEqual(@as(usize, 0), b_write.refs);
}

test "workspace tables isolate numeric fds while sharing descriptions on fork" {
    var pipe = Pipe{};
    var read_description = Description{ .pipe = &pipe, .readable = true, .writable = false };
    var write_description = Description{ .pipe = &pipe, .readable = false, .writable = true };
    var parent = WorkspaceTable.init(10);
    try parent.table.install(3, &write_description, false);
    try parent.table.install(4, &read_description, false);
    var child = parent.fork(11);
    defer child.closeAll();
    try std.testing.expectEqual(@as(u32, 10), parent.workspace_id);
    try std.testing.expectEqual(@as(u32, 11), child.workspace_id);
    try std.testing.expectEqual(@as(usize, 2), write_description.refs);
    try std.testing.expectEqual(@as(usize, 2), read_description.refs);
    var isolated = WorkspaceTable.init(12);
    var isolated_buffer: [1]u8 = undefined;
    try std.testing.expectError(error.BadFd, isolated.table.read(3, &isolated_buffer));
    try std.testing.expectEqual(@as(usize, 3), try child.table.write(3, "ok!"));
    var bytes: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try parent.table.read(4, &bytes));
    try std.testing.expectEqualStrings("ok!", &bytes);
    child.table.close(3);
    try std.testing.expectEqual(@as(usize, 1), write_description.refs);
    parent.table.close(3);
    parent.table.close(4);
    try std.testing.expectEqual(@as(usize, 0), write_description.refs);
    try std.testing.expectEqual(@as(usize, 1), read_description.refs);
    child.table.close(4);
    try std.testing.expectEqual(@as(usize, 0), read_description.refs);
}
