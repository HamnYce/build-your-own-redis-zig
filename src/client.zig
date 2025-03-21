const std = @import("std");
const consts = @import("consts.zig");
const net = std.net;

pub fn main() !void {
    const server_address = net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 6739);
    const server = net.tcpConnectToAddress(server_address) catch {
        std.log.debug("Could not connect to the server please make sure it is running on 127.0.0.1:6739", .{});
        std.posix.exit(0);
    };
    const stdin = std.io.getStdIn();

    std.log.debug("Connected to server\n", .{});

    var buffer: [consts.max_msg_len]u8 = undefined;
    while (true) {
        // write
        {
            // user input
            const n = try stdin.read(&buffer);
            const msg = std.mem.trim(u8, buffer[0..n], &std.ascii.whitespace);
            // header
            var msg_len: u32 = @intCast(msg.len);
            const msg_len_bytes: *align(4) const [4]u8 = std.mem.asBytes(&msg_len);
            try server.writeAll(msg_len_bytes);

            // body
            try server.writeAll(msg);

            std.log.debug("wrote: {d}, {s}", .{ msg_len, msg });
        }

        // read
        {
            // header
            var n = try server.readAll(buffer[0..4]);
            const msg_len: u32 = @intCast(std.mem.readInt(u32, buffer[0..4], .little));

            // body
            n = try server.readAll(buffer[0..msg_len]);
            std.debug.assert(n == msg_len);

            std.log.debug("Server: {s}\n", .{buffer[0..msg_len]});
        }
    }

    server.close();
}
