const std = @import("std");
const consts = @import(" consts.zig");
const net = std.net;

pub fn main() !void {
    var address = net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 6739);

    std.log.debug("server listening", .{});
    var server = try address.listen(.{
        .reuse_address = true,
        .force_nonblocking = true,
    });

    var buffer: [consts.max_msg_len]u8 = undefined;
    while (true) {
        const client = try server.accept();
        one_request(&client, &buffer) catch {
            std.log.debug("client disconnected", .{});
        };
        client.stream.close();
    }

    std.log.debug("closing server", .{});
    server.deinit();
}

fn one_request(client: *std.net.Server.Connection, buffer: *[]u8) !void {
    const n = try client.stream.readAll(&buffer);
    std.log.debug("received from client: {s}\n", .{buffer[0..n]});

    _ = std.ascii.upperString(buffer[0..n], buffer[0..n]);

    _ = try client.stream.writeAll(buffer[0..n]);
}

fn read_full(client: *std.net.Server.Connection, buffer: *[]u8) void {
    _ = client;
    _ = buffer;
}
