const std = @import("std");
const consts = @import("consts.zig");
const net = std.net;

pub fn main() !void {
    const server_address = net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 6739);
    const server = try net.tcpConnectToAddress(server_address);
    const stdin = std.io.getStdIn();

    std.log.debug("Connected to server\n", .{});

    var buffer: [consts.max_msg_len]u8 = undefined;
    while (true) {
        var n = try stdin.read(&buffer);
        _ = try server.write(buffer[0..n]);
        n = try server.read(&buffer);

        std.log.debug("Received from server: {s}\n", .{buffer[0..n]});
    }

    server.close();
}
