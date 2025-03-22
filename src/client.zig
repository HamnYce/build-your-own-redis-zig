const std = @import("std");
const consts = @import("consts.zig");
const net = std.net;

fn send_req(server: std.net.Stream, req: []const u8) !void {
    // header
    var msg_len: u32 = @intCast(req.len);
    const msg_len_bytes: *align(4) const [4]u8 = std.mem.asBytes(&msg_len);
    try server.writeAll(msg_len_bytes);

    // body
    try server.writeAll(req);
}

fn recv_res(server: std.net.Stream, buffer: []u8) !usize {
    // header
    var n = try server.readAll(buffer[0..4]);
    const msg_len: u32 = @intCast(std.mem.readInt(u32, buffer[0..4], .little));

    // body
    n = try server.readAll(buffer[0..msg_len]);

    return n;
}

pub fn main() !void {
    const server_address = net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 6739);
    const server = net.tcpConnectToAddress(server_address) catch {
        std.log.debug("Could not connect to the server please make sure it is running on 127.0.0.1:6739", .{});
        std.posix.exit(0);
    };

    std.log.debug("Connected to server\n", .{});

    var requests = std.ArrayList([]const u8).init(std.heap.page_allocator);
    try requests.append("Hello world"); //len 11
    try requests.append("Good bye world"); //len 14
    try requests.append("hola mi amigo"); //len 13

    var buffer: [consts.max_msg_len]u8 = undefined;
    // write
    for (requests.items) |req| {
        try send_req(server, req);
        std.log.debug("wrote: {d}, {s}", .{ req.len, req });
    }

    // read
    for (0..requests.items.len) |_| {
        const n = try recv_res(server, &buffer);
        std.log.debug("received: {d} bytes, {s}", .{ n, buffer[0..n] });
    }

    server.close();
}
