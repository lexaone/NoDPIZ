const std = @import("std");
const yazap = @import("yazap");

const net = std.net;
const posix = std.posix;
const print = std.debug.print;
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const Random = std.Random;

const PORT = 8881;
const BUFFER_SIZE = 1500;

const App = yazap.App;
const Arg = yazap.Arg;

var blocked_sites: ?[][]u8 = null;
var allocator: std.mem.Allocator = undefined;
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    var app = App.init(allocator, "nodpiz", "NoDPIZ proxy");
    defer app.deinit();
    var nodpiz = app.rootCommand();
    // nodpiz.setProperty(.help_on_empty_args);
    try nodpiz.addArg(Arg.booleanOption("help", 'h', "Display help"));
    try nodpiz.addArg(Arg.booleanOption("version", 'v', "Display version"));
    try nodpiz.addArg(Arg.singleValueOption("blacklist", 'b', "blacklist file with hosts to bypass,optional, default \n is bypass to all hosts"));
    try nodpiz.addArg(Arg.singleValueOption("port", 'p', "Port Listening,optional, default is 8881"));
    try nodpiz.addArg(Arg.singleValueOption("interface", 'i', "interface listening, ex: 127.0.0.1 or 0.0.0.0, optional,default is 127.0.0.1"));

    const matches = try app.parseProcess();

    if (matches.containsArg("version")) {
        print("v0.1.0\n", .{});
        return;
    }
    if (matches.containsArg("help")) {
        try app.displayHelp();
        return;
    }
    // Инициализация генератора случайных чисел
    var prng = Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch @panic("Failed to get random seed");
        break :blk seed;
    });
    random = prng.random();
    // Запуск прокси сервера
    try startProxy();
}

fn startProxy() !void {
    const address = try net.Address.parseIp4("127.0.0.1", PORT);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    // print("Прокси запущено на 127.0.0.1:{}\n", .{PORT});
    // print("Не закрывайте окно\n", .{});

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
    // print("target:{s}\n", .{target});
    // Парсинг host:port
    const colon_pos = std.mem.lastIndexOf(u8, target, ":") orelse {
        print("Неверный формат target: {s}\n", .{target});
        return;
    };

    const host = target[0..colon_pos];
    // print("host:{s}\n", .{host});
    const port_str = target[colon_pos + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        print("Неверный порт: {s}\n", .{port_str});
        return;
    };
    // print("port(int):{d}\n", .{port});

    // Подключение к удаленному серверу
    const remote_address = blk: {
        if (net.Address.parseIp(host, port)) |addr| {
            break :blk addr;
        } else |_| {
            const list = try net.getAddressList(allocator, host, port);
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

    // Фрагментация данных
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

fn loadBlocklist() !void {
    const file = std.fs.cwd().openFile("blacklist.txt", .{}) catch return;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var sites = ArrayList([]u8).init(allocator);
    var iter = std.mem.split(u8, content, " ");

    while (iter.next()) |site| {
        if (site.len > 0) {
            const site_copy = try allocator.dupe(u8, site);
            try sites.append(site_copy);
        }
    }

    blocked_sites = try sites.toOwnedSlice();
}
