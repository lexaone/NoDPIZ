const std = @import("std");
const yazap = @import("yazap");

const net = std.net;
const print = std.debug.print;
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const Random = std.Random;
const stdout_stream = std.io.getStdOut().writer();

//default listen port
const PORT = 8881;

const BUFFER_SIZE = 1500;

const App = yazap.App;
const Arg = yazap.Arg;

var blocked_sites: ?[][]u8 = null;
var debug_flag = false;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

var random: Random = undefined;
const ConnectionPair = struct {
    local: net.Stream,
    remote: net.Stream,

    fn init(local: net.Stream, remote: net.Stream) ConnectionPair {
        return ConnectionPair{
            .local = local,
            .remote = remote,
        };
    }

    fn close(self: *ConnectionPair) void {
        self.local.close();
        self.remote.close();
    }
};

pub fn main() !void {
    defer arena.deinit();

    var listen_port: u16 = PORT;
    var iface: ?[]const u8 = null;

    var app = App.init(allocator, "nodpiz", "NoDPIZ proxy");
    defer app.deinit();
    var nodpiz = app.rootCommand();
    //option -h
    try nodpiz.addArg(Arg.booleanOption("help", 'h', "Display help"));
    //option -v
    try nodpiz.addArg(Arg.booleanOption("version", 'v', "Display version"));
    //option -d
    try nodpiz.addArg(Arg.booleanOption("debug", 'd', "Print debug information"));

    //option -b <blacklist>
    var blacklist_opt = Arg.singleValueOption("blacklist", 'b', "blacklist file with hosts to bypass,optional, default \n is bypass to all hosts");
    blacklist_opt.setValuePlaceholder("BLACKLIST_FILE");

    //option -p <port>
    var port_opt = Arg.singleValueOption("port", 'p', "Port Listening,optional, default is 8881");
    port_opt.setValuePlaceholder("TCP_PORT");

    //option -i <iface>
    var iface_opt = Arg.singleValueOption("iface", 'i', "interface listening, ex: 127.0.0.1 or 0.0.0.0, optional,default is 127.0.0.1");
    iface_opt.setValuePlaceholder("IFACE");

    try nodpiz.addArgs(&[_]Arg{ blacklist_opt, port_opt, iface_opt });

    const matches = try app.parseProcess();

    if (matches.containsArg("debug")) {
        debug_flag = true;
    }

    if (matches.containsArg("version")) {
        print("v0.2.0\n", .{});
        return;
    }
    if (matches.containsArg("help")) {
        try app.displayHelp();
        return;
    }

    if (matches.getSingleValue("blacklist")) |blacklist_file_name| {
        loadBlacklist(allocator, blacklist_file_name) catch |err| {
            print("Не удалось загрузить {s} {}\n", .{ blacklist_file_name, err });
            @panic("Не удалось загрузить файл со списком хостов!");
        };
    } else {
        try debugPrint(debug_flag, "All hosts fragmented\n", .{});
    }

    if (matches.getSingleValue("port")) |port_str| {
        try debugPrint(debug_flag, "port_str.port : {s}\n", .{port_str});
        listen_port = try std.fmt.parseUnsigned(u16, port_str, 10);

        if (listen_port < 1024) {
            print("Please use port >1024 and <65535\n", .{});
            return error.InvalidTCPPort;
        }

        try debugPrint(debug_flag, "listen_port.port : {d}\n", .{listen_port});
    } else {
        listen_port = 8881;
        try debugPrint(debug_flag, "use default value for port: {d}\n", .{listen_port});
    }

    if (matches.getSingleValue("iface")) |iface_str| {
        iface = try allocator.dupe(u8, iface_str);
        try debugPrint(debug_flag, "use interface: {s}\n", .{iface.?});
    } else {
        iface = "127.0.0.1";
        try debugPrint(debug_flag, "use default value for interface: {s}\n", .{iface.?});
    }

    // Инициализация генератора случайных чисел

    var prng = Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch @panic("Failed to get random seed");
        break :blk seed;
    });
    random = prng.random();
    // Запуск прокси сервера
    try startProxy(iface.?, listen_port);
}

fn startProxy(listen_iface: []const u8, listen_port: u16) !void {
    try debugPrint(debug_flag, "startProxy.Daemon listen on: {s}:{d}\n", .{ listen_iface, listen_port });

    // const address = try net.Address.parseIp4("127.0.0.1", PORT);
    const address = net.Address.parseIp4(listen_iface, listen_port) catch @panic("Can't parse address");

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        const connection = listener.accept() catch |err| {
            print("Ошибка принятия соединения: {}\n", .{err});
            continue;
        };

        // Создание нового потока для обработки соединения
        const thread = Thread.spawn(.{}, handleConnection, .{connection.stream}) catch |err| {
            print("Не удалось создать поток: {}\n", .{err});
            connection.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(local_stream: net.Stream) !void {
    var arena_local = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_local.deinit();
    const allocator_local = arena_local.allocator();
    defer local_stream.close();

    var buffer: [BUFFER_SIZE]u8 = undefined;
    const bytes_read = local_stream.read(&buffer) catch |err| {
        print("Ошибка чтения HTTP данных: {}\n", .{err});
        return;
    };

    if (bytes_read == 0) return;

    const http_data = buffer[0..bytes_read];

    // Парсинг HTTP CONNECT запроса
    const first_line_end = std.mem.indexOf(u8, http_data, "\r\n") orelse {
        print("Неверный HTTP запрос\n", .{});
        return;
    };

    const first_line = http_data[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');

    const method = parts.next() orelse return;
    const target = parts.next() orelse return;

    // Проверка на CONNECT метод
    if (!std.mem.eql(u8, method, "CONNECT")) {
        print("Поддерживается только CONNECT метод\n", .{});
        return;
    }
    // Парсинг host:port
    const colon_pos = std.mem.lastIndexOf(u8, target, ":") orelse {
        print("Неверный формат target: {s}\n", .{target});
        return;
    };

    const host = target[0..colon_pos];
    const port_str = target[colon_pos + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        print("Неверный порт: {s}\n", .{port_str});
        return;
    };

    // Подключение к удаленному серверу
    const remote_address = blk: {
        if (net.Address.parseIp(host, port)) |addr| {
            break :blk addr;
        } else |_| {
            const list = try net.getAddressList(allocator_local, host, port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.NoAddressFound;
            break :blk list.addrs[0];
        }
    };

    const remote_stream = net.tcpConnectToAddress(remote_address) catch |err| {
        print("Не удалось подключиться к {s}:{}: {}\n", .{ host, port, err });
        return;
    };

    // Отправка ответа об успешном подключении
    const response = "HTTP/1.1 200 OK\n\n";
    _ = local_stream.writeAll(response) catch |err| {
        print("Не удалось отправить ответ: {}\n", .{err});
        remote_stream.close();
        return;
    };

    // Если это HTTPS (порт 443), выполняем фрагментацию
    if (port == 443) {
        fragmentData(local_stream, remote_stream) catch |err| {
            print("Ошибка фрагментации данных: {}\n", .{err});
            remote_stream.close();
            return;
        };
    }

    // Создание потоков для пересылки данных в обе стороны
    var connection_pair = ConnectionPair.init(local_stream, remote_stream);

    const local_to_remote_thread = Thread.spawn(.{}, pipe, .{ &connection_pair, true }) catch |err| {
        print("Не удалось создать поток local->remote: {}\n", .{err});
        connection_pair.close();
        return;
    };

    const remote_to_local_thread = Thread.spawn(.{}, pipe, .{ &connection_pair, false }) catch |err| {
        print("Не удалось создать поток remote->local: {}\n", .{err});
        local_to_remote_thread.detach();
        connection_pair.close();
        return;
    };

    local_to_remote_thread.join();
    remote_to_local_thread.join();
}

fn pipe(pair: *ConnectionPair, local_to_remote: bool) void {
    var buffer: [BUFFER_SIZE]u8 = undefined;

    const source = if (local_to_remote) pair.local else pair.remote;
    const destination = if (local_to_remote) pair.remote else pair.local;

    while (true) {
        const bytes_read = source.read(&buffer) catch break;
        if (bytes_read == 0) break;

        _ = destination.writeAll(buffer[0..bytes_read]) catch break;
    }
}

fn fragmentData(local_stream: net.Stream, remote_stream: net.Stream) !void {
    var head_buffer: [5]u8 = undefined;
    var data_buffer: [BUFFER_SIZE]u8 = undefined;

    const head_bytes = try local_stream.readAll(&head_buffer);
    if (head_bytes != 5) return;

    const data_bytes = local_stream.read(&data_buffer) catch |err| {
        print("Ошибка чтения данных для фрагментации: {}\n", .{err});
        return;
    };

    const data = data_buffer[0..data_bytes];

    // Проверка на заблокированные сайты
    if (blocked_sites) |sites| {
        var is_blocked = false;
        for (sites) |site| {
            if (std.mem.indexOf(u8, data, site) != null) {
                try debugPrint(debug_flag, "Host contains in blacklist: {s}\n", .{site});
                is_blocked = true;
                break;
            }
        }

        if (!is_blocked) {
            // Отправляем данные как есть
            _ = try remote_stream.writeAll(&head_buffer);
            _ = try remote_stream.writeAll(data);
            return;
        }
    }
    // // Фрагментация данных
    var parts = ArrayList(u8).init(allocator);
    defer parts.deinit();

    var remaining_data = data;

    while (remaining_data.len > 0) {
        const part_len = random.intRangeAtMost(usize, 1, remaining_data.len);
        // Добавляем TLS Record header: 0x1603 + random byte + length
        try parts.appendSlice(&[_]u8{ 0x16, 0x03 });
        try parts.append(random.int(u8));

        // Добавляем длину (big-endian)
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(part_len)));
        try parts.appendSlice(&len_bytes);

        // Добавляем часть данных
        try parts.appendSlice(remaining_data[0..part_len]);

        remaining_data = remaining_data[part_len..];
    }
    _ = try remote_stream.writeAll(parts.items);
}

fn loadBlacklist(alloc: std.mem.Allocator, blacklist_file_name: []const u8) !void {
    // Освобождаем предыдущий список сайтов
    try debugPrint(debug_flag, "loadBlacklist.blacklist_file_name:{s}\n", .{blacklist_file_name});

    if (blocked_sites) |sites| {
        for (sites) |site| alloc.free(site);
        alloc.free(sites);
    }

    const file = std.fs.cwd().openFile(blacklist_file_name, .{}) catch |err| {
        print("Ошибка открытия файла {s}: {}\n", .{ blacklist_file_name, err });
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    var sites = ArrayList([]u8).init(alloc);
    defer {
        if (sites.items.len > 0) {
            for (sites.items) |site| alloc.free(site);
            sites.deinit();
        }
    }

    var lines = std.mem.tokenizeAny(u8, content, "\n\r");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        try debugPrint(debug_flag, "loadBlacklist:{s}\n", .{trimmed});
        const site_copy = try alloc.dupe(u8, trimmed);
        errdefer alloc.free(site_copy); // Освобождение при ошибке

        try sites.append(site_copy);
    }

    blocked_sites = try sites.toOwnedSlice();
}
inline fn debugPrint(debug: bool, comptime fmt_str: []const u8, args: anytype) !void {
    if (debug) {
        try stdout_stream.print("DEBUG: ", .{});
        try stdout_stream.print(fmt_str, args);
    }
}
