const std = @import("std");
const consts = @import("consts.zig");
const net = std.net;

const Conn = struct {
    connection: *net.Server.Connection,
    incoming: std.ArrayList(u8),
    outgoing: std.ArrayList(u8),

    /// Communication flag for the event loop (poll)
    /// set as true so we read the first request from the connection
    want_read: bool = true,
    /// Communication flag for the event loop (poll)
    want_write: bool = false,
    /// Communication flag for the event loop (poll)
    want_close: bool = false,

    fn init(connection: *net.Server.Connection) Conn {
        return .{
            .connection = connection,
            .incoming = std.ArrayList(u8).init(std.heap.page_allocator),
            .outgoing = std.ArrayList(u8).init(std.heap.page_allocator),
        };
    }

    fn deinit(conn: Conn) void {
        conn.connection.stream.close();
        conn.incoming.deinit();
        conn.outgoing.deinit();
    }

    fn read(conn: *Conn) !void {
        var buffer: [1024]u8 = undefined;
        const n = try conn.connection.stream.read(&buffer);
        if (n == 0) {
            conn.want_close = true;
            return;
        }
        std.log.debug("read {d} bytes", .{n});

        try conn.incoming.appendSlice(buffer[0..n]);

        if (conn.incoming.items.len < 4) {
            return; // do not have enough to get message length
        }

        const msg_len: usize = @intCast(std.mem.readInt(u32, buffer[0..4], .big));

        if (conn.incoming.items.len < msg_len + 4) {
            return; // do not have enough to try request
        }
        std.log.debug("msg_len={d}", .{msg_len});

        //TODO: not working, might be an endianess problem
        try_one_request(conn.incoming.items[4 .. 4 + msg_len]);

        consume_buffer(&conn.incoming, 4 + msg_len);

        std.log.debug("waiting to send message to client", .{});
        conn.want_read = false;
        conn.want_write = true;
    }

    fn write(conn: *Conn) !void {
        const n = try conn.connection.stream.write(conn.outgoing.items);
        consume_buffer(&conn.outgoing, n);
        if (conn.outgoing.items.len == 0) {
            std.log.debug("waiting for client to send message", .{});
            conn.want_read = true;
            conn.want_write = false;
        }
    }
};

fn consume_buffer(buf: *std.ArrayList(u8), n: usize) void {
    std.log.debug("Consuming buffer ", .{});
    // needs testing
    const rest = buf.items[n..];
    buf.clearRetainingCapacity();
    buf.appendSliceAssumeCapacity(rest);
    std.debug.assert(buf.items.len == 0);
}

fn try_one_request(request: []u8) void {
    std.log.debug("received from connection. msg_len={d}, msg={s}", .{ request.len, request });
}

pub fn main() !void {
    var address = net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 6739);

    std.log.debug("server listening", .{});
    var server = try address.listen(.{ .reuse_address = true, .force_nonblocking = true });
    defer {
        std.log.debug("closing server", .{});
        server.deinit();
    }

    std.log.debug("creating connections array", .{});
    var conns: [100]?*Conn = [_]?*Conn{null} ** 100;

    std.log.debug("creating polls array", .{});
    var poll_args = std.ArrayList(std.posix.pollfd).init(std.heap.page_allocator);

    while (true) {
        // region event loop
        poll_args.clearRetainingCapacity();
        // append the server as the first element to poll
        try poll_args.append(.{ .fd = server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 });

        for (&conns, 0..) |conn, i| {
            if (conn == null) {
                continue;
            }
            var poll_arg: std.posix.pollfd = .{ .fd = conn.?.connection.stream.handle, .events = std.posix.POLL.ERR, .revents = 0 };

            if (conn.?.want_read) {
                poll_arg.events |= std.posix.POLL.IN;
            }

            if (conn.?.want_write) {
                poll_arg.events |= std.posix.POLL.OUT;
            }

            if (conn.?.want_close) {
                conn.?.deinit();
                conns[i] = null;
                const addr_bytes = @as([4]u8, @bitCast(conn.?.connection.address.in.sa.addr));
                std.log.debug("disconnected from client with address: {}.{}.{}.{}:{}", .{
                    addr_bytes[0],
                    addr_bytes[1],
                    addr_bytes[2],
                    addr_bytes[3],
                    conn.?.connection.address.in.sa.port,
                });
                continue;
            }

            poll_args.append(poll_arg) catch {
                std.log.debug("Could not allocate extra space for poll_arg", .{});
                std.posix.exit(1);
            };
        }

        // program should crash if cannot poll
        _ = std.posix.poll(poll_args.items, -1) catch {
            std.log.debug("Could not poll", .{});
            std.posix.exit(1);
        };

        // server has a new connection
        if (std.posix.POLL.IN == poll_args.items[0].revents & std.posix.POLL.IN) {
            var conn = try server.accept();
            const addr_bytes = @as([4]u8, @bitCast(conn.address.in.sa.addr));
            std.log.debug("connected to new client address: {}.{}.{}.{}:{}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3], conn.address.in.sa.port });
            conns[@intCast(conn.stream.handle)] = @constCast(&Conn.init(&conn));
        }
        // endregion

        //region application code
        // TODO: implement read and write, using the protocol of first 4 bytes being the length of the message
        for (1..poll_args.items.len) |i| {
            const poll_arg: std.posix.pollfd = poll_args.items[i];
            var conn = conns[@as(usize, @intCast(poll_arg.fd))];

            if (std.posix.POLL.ERR == poll_arg.revents & std.posix.POLL.ERR) {
                conn.?.deinit();
                conns[@as(usize, @intCast(poll_arg.fd))] = null;
                const addr_bytes = @as([4]u8, @bitCast(conn.?.connection.address.in.sa.addr));
                std.log.debug("disconnected from client with address: {}.{}.{}.{}:{}", .{
                    addr_bytes[0],
                    addr_bytes[1],
                    addr_bytes[2],
                    addr_bytes[3],
                    conn.?.connection.address.in.sa.port,
                });
                continue;
            }

            if (std.posix.POLL.IN == poll_arg.revents & std.posix.POLL.IN) {
                try conn.?.read();
            }

            if (std.posix.POLL.OUT == poll_arg.revents & std.posix.POLL.OUT) {
                try conn.?.write();
            }
        }
        // endregion
    }
}
