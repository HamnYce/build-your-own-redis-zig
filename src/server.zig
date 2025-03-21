const std = @import("std");
const consts = @import("consts.zig");
const net = std.net;

const Conn = struct {
    connection: net.Server.Connection,
    incoming: std.ArrayList(u8),
    outgoing: std.ArrayList(u8),
    /// Communication flag for the event loop (poll)
    /// set as true so we read the first request from the connection
    want_read: bool = true,
    /// Communication flag for the event loop (poll)
    want_write: bool = false,
    /// Communication flag for the event loop (poll)
    want_close: bool = false,

    fn init(connection: net.Server.Connection) Conn {
        return .{
            .connection = connection,
            .incoming = std.ArrayList(u8).init(std.heap.page_allocator),
            .outgoing = std.ArrayList(u8).init(std.heap.page_allocator),
        };
    }

    fn deinit(conn: *Conn) void {
        conn.connection.stream.close();
        conn.incoming.deinit();
        conn.outgoing.deinit();
    }

    fn read(conn: *Conn) !void {
        var buffer: [1024]u8 = undefined;
        std.log.debug("waiting for read", .{});
        const n = conn.connection.stream.read(&buffer) catch {
            std.log.debug("error reading from connection", .{});
            conn.want_close = true;
            return;
        };
        if (n == 0) {
            std.log.debug("read 0 bytes closing connection", .{});
            conn.want_close = true;
            return;
        }

        std.log.debug("read {d} bytes", .{n});

        try conn.incoming.appendSlice(buffer[0..n]);

        const request_success = try conn.try_one_request();
        if (request_success) {
            conn.want_read = false;
            conn.want_write = true;
        }
    }

    fn write(conn: *Conn) !void {
        const n = try conn.connection.stream.write(conn.outgoing.items);
        std.log.debug("wrote {d} bytes to client", .{n});
        consume_buffer(&conn.outgoing, n);
        if (conn.outgoing.items.len == 0) {
            conn.want_read = true;
            conn.want_write = false;
        }
    }

    fn try_one_request(conn: *Conn) !bool {
        std.log.debug("trying request", .{});
        if (conn.incoming.items.len < 4) {
            std.log.debug("Do not have enough for a request", .{});
            return false; // do not have enough to get message length
        }

        const msg_len: u32 = @intCast(std.mem.readInt(u32, conn.incoming.items[0..4], .little));

        if (msg_len > consts.max_msg_len) {
            std.log.debug("message length greater than max messag length, len:{d}", .{msg_len});
            conn.want_close = true;
            return false;
        }

        if (conn.incoming.items.len < msg_len + 4) {
            std.log.debug("do not have enough", .{});
            return false; // do not have enough to try request
        }

        std.log.debug("adding message to outgoing buffer", .{});

        const msg_len_bytes: *align(4) const [4]u8 = std.mem.asBytes(&msg_len);
        try conn.outgoing.appendSlice(msg_len_bytes);
        try conn.outgoing.appendSlice(conn.incoming.items[4 .. 4 + msg_len]);
        consume_buffer(&conn.incoming, 4 + msg_len);
        return true;
    }
};

fn consume_buffer(buf: *std.ArrayList(u8), n: usize) void {
    buf.replaceRangeAssumeCapacity(0, buf.items[n..buf.items.len].len, buf.items[n..buf.items.len]);
    buf.shrinkRetainingCapacity(buf.items.len - n);
}

pub fn main() !void {
    var address = net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 6739);

    std.log.debug("server listening", .{});
    var server = try address.listen(.{ .reuse_address = true, .force_nonblocking = true });
    defer {
        server.deinit();
    }

    var conns: [100]?Conn = [_]?Conn{null} ** 100;
    var poll_args = std.ArrayList(std.posix.pollfd).init(std.heap.page_allocator);

    std.log.debug("polling", .{});
    while (true) {
        // region event loop
        poll_args.clearRetainingCapacity();
        std.debug.assert(poll_args.items.len == 0);

        // append the server as the first
        try poll_args.append(.{ .fd = server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 });
        std.debug.assert(poll_args.items.len == 1);

        // the rest of the connections
        for (conns) |conn| {
            if (conn == null) continue;

            var poll_arg: std.posix.pollfd = .{
                .fd = conn.?.connection.stream.handle,
                .events = std.posix.POLL.ERR,
                .revents = 0,
            };

            // application asking for readiness
            if (conn.?.want_read) poll_arg.events |= std.posix.POLL.IN;

            if (conn.?.want_write) poll_arg.events |= std.posix.POLL.OUT;

            try poll_args.append(poll_arg);
        }

        // program should crash if cannot poll
        _ = std.posix.poll(poll_args.items, -1) catch {
            std.log.debug("Could not poll", .{});
            std.posix.exit(0);
        };

        // region handle accept
        if (std.posix.POLL.IN == (poll_args.items[0].revents & std.posix.POLL.IN)) {
            // DO NOT TAKE MEMORY THAT ISN'T YOURS!
            // DO NOT TAKE THE REFERENCE OF THIS CONNECTION, the memory is reused for every accept
            var conn = try server.accept();
            const fd: usize = @intCast(conn.stream.handle);

            if (fd >= conns.len) {
                std.log.err("File descriptor {d} is too large for conns array of size {d}", .{ fd, conns.len });
                conn.stream.close();
                continue;
            }

            const addr_bytes: [4]u8 = @bitCast(conn.address.in.sa.addr);
            std.log.debug("connected to new client (fd:{d}) address: {}.{}.{}.{}:{}", .{
                conn.stream.handle,
                addr_bytes[0],
                addr_bytes[1],
                addr_bytes[2],
                addr_bytes[3],
                conn.address.in.sa.port,
            });

            conns[fd] = Conn.init(conn);
        }
        // endregion

        // region application code
        for (1..poll_args.items.len) |i| {
            const poll_arg: std.posix.pollfd = poll_args.items[i];
            // no need for null checks guaranteed to not be null
            var conn = &conns[@intCast(poll_arg.fd)].?;

            // can read
            if (std.posix.POLL.IN == poll_arg.revents & std.posix.POLL.IN) {
                std.debug.assert(conn.want_read);
                try conn.read();
            }

            // can write
            if (std.posix.POLL.OUT == poll_arg.revents & std.posix.POLL.OUT) {
                std.debug.assert(conn.want_write);
                try conn.write();
            }

            // should be closed
            if (conn.want_close or std.posix.POLL.ERR == poll_arg.revents & std.posix.POLL.ERR) {
                conn.deinit();

                const addr_bytes: [4]u8 = @bitCast(conn.connection.address.in.sa.addr);
                std.log.debug("disconnected from client with address: {}.{}.{}.{}:{}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3], conn.connection.address.in.sa.port });

                conns[@intCast(poll_arg.fd)] = null;
                continue;
            }
        }
        // endregion
    }

    // with defer
    std.log.debug("closing server", .{});
}
