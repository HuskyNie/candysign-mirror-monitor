import Foundation

struct Metrics: Decodable {
    let ports: [Port]
    var totalWatts: Double { ports.filter { $0.attached }.reduce(0) { $0 + $1.watts } }

    static func decode(_ data: Data) throws -> Metrics {
        let value = try JSONDecoder().decode(Metrics.self, from: data)
        guard !value.ports.isEmpty, value.ports.count <= 16,
              Set(value.ports.map(\.id)).count == value.ports.count,
              value.ports.allSatisfy({ $0.id >= 0 && $0.voltage.isFinite && $0.current.isFinite && $0.voltage >= 0 && $0.current >= 0 }) else {
            throw MonitorError.invalidMetrics
        }
        return value
    }
}

struct Port: Decodable {
    let id: Int
    let active: Bool
    let attached: Bool
    let port_type: String
    let fc_protocol: Int
    let current: Double
    let voltage: Double
    let session_charge: Double?
    let session_id: Int?
    let charging_duration_seconds: Double?
    let power_budget: Double?
    let pd_status: PDStatus?
    var sessionWh: Double? { session_charge.flatMap { $0.isFinite && $0 >= 0 ? $0 / 3_600_000_000 : nil } }
    var durationText: String {
        guard let seconds = charging_duration_seconds, seconds.isFinite, seconds >= 0, seconds < 1e10 else { return "未获取" }
        let minutes = Int(seconds / 60)
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
    var volts: Double { voltage / 1000 }
    var amps: Double { current / 1000 }
    var watts: Double { volts * amps }
    var name: String { port_type == "A" ? "USB-A" : "C\(id)" }
    var protocolName: String {
        guard attached else { return "—" }
        let names = [0: "普通充电", 1: "QC 2.0", 2: "QC 3.0", 3: "QC 3+",
                     4: "SFCP", 5: "AFC", 6: "FCP", 7: "SCP", 8: "VOOC 1.0",
                     9: "VOOC 4.0", 10: "SuperVOOC 2.0", 11: "TFCP", 12: "UFCS",
                     13: "PE 1.0", 14: "PE 2.0", 15: "PD · 5V", 16: "PD · 固定高压",
                     17: "PD · SPR AVS", 18: "PD · PPS", 19: "PD · EPR 高压",
                     20: "PD · AVS", 21: "PD · 小米 PPS", 255: "未充电"]
        return names[fc_protocol] ?? "未知协议 (\(fc_protocol))"
    }
}

enum MonitorError: LocalizedError {
    case invalidHost, invalidMetrics, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidHost: return "请输入局域网 IP 或 .local 主机名，不含端口和路径。"
        case .invalidMetrics: return "设备返回的端口数据不完整。"
        case .http(let code): return "设备接口返回 HTTP \(code)。"
        }
    }
}

enum Endpoint {
    static func url(host: String) throws -> URL {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        let privateIP = octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && (octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254))
        let localName = host.hasSuffix(".local") && host.count > 6
            && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.").contains($0) }
        guard privateIP || localName, let url = URL(string: "http://\(host)/metrics.json") else { throw MonitorError.invalidHost }
        return url
    }
}

// Reject redirects: the configured local device is the only data source.
final class LocalSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum MetricsClient {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: LocalSessionDelegate(), delegateQueue: nil)
    }()

    static func fetch(host: String) async throws -> Metrics {
        let (data, response) = try await session.data(from: Endpoint.url(host: host))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw MonitorError.http(code) }
        return try Metrics.decode(data)
    }
}

// Optional fields must not turn an otherwise valid live snapshot into an error.
struct PDStatus: Decodable {
    let values: [String: Scalar]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = (try? container.decode([String: Scalar].self)) ?? [:]
    }
    enum Scalar: Decodable {
        case number(Double), flag(Bool), other
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .flag(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .other }
        }
    }
    func number(_ key: String) -> Double? {
        if case .number(let n) = values[key], n.isFinite { return n }
        return nil
    }
    func flag(_ key: String) -> Bool? {
        if case .flag(let b) = values[key] { return b }
        if let n = number(key), n == 0 || n == 1 { return n == 1 }
        return nil
    }
    func yesNo(_ key: String) -> String { flag(key).map { $0 ? "支持" : "不支持" } ?? "未获取" }
    func mapped(_ key: String, _ mapping: [Int: String]) -> String {
        guard let n = number(key), n >= 0, n < 65536, n.rounded() == n else { return "未获取" }
        return mapping[Int(n)] ?? "未知编号 \(Int(n))"
    }
    func identifier(_ key: String) -> String {
        guard let n = number(key), n > 0, n < 65535 else { return "未获取" }
        return String(format: "0x%04X", Int(n))
    }
    var cableText: String {
        // Zero-filled cable descriptors are not evidence of a USB 2.0 / 20 V cable.
        guard flag("has_emarker") == true else {
            return "eMarker：\(flag("has_emarker") == false ? "未检测到" : "未获取")\n线材能力：未获取"
        }
        return [
            "eMarker：已检测到",
            "额定电流：" + mapped("cable_max_vbus_current", [1: "3 A", 2: "5 A"]),
            "额定电压：" + mapped("cable_max_vbus_voltage", [0: "20 V", 1: "30 V", 2: "40 V", 3: "50 V"]),
            "EPR：" + yesNo("cable_epr_mode_capable"),
            "USB 能力：" + mapped("cable_usb_highest_speed", [0: "USB 2.0", 1: "USB 3.2 Gen 1", 2: "USB 3.2 / USB4 Gen 2", 3: "USB4 Gen 3", 4: "USB4 Gen 4"]),
            "线材类型：" + (flag("cable_is_active").map { $0 ? "有源" : "无源" } ?? "未获取"),
            "VID / PID：\(identifier("cable_vid")) / \(identifier("cable_pid"))"
        ].joined(separator: "\n")
    }
    var pdText: String {
        func operating(_ key: String, unit: String) -> String {
            guard let n = number(key), n > 0 else { return "未获取" }
            return String(format: "%.2f %@", n / 1000, unit)
        }
        return [
            "PD 修订：" + mapped("pd_revision", [0: "1.0", 1: "2.0", 2: "3.0", 3: "保留值"]),
            "协商电压：" + operating("operating_voltage", unit: "V"),
            "协商电流：" + operating("operating_current", unit: "A"),
            "PPS：" + yesNo("pps_charging_supported"),
            "受电端 EPR：" + yesNo("request_epr_mode_capable"),
            "能力不匹配：" + (flag("request_capability_mismatch").map { $0 ? "是" : "否" } ?? "未获取"),
            "设备 VID / PID：\(identifier("manufacturer_vid")) / \(identifier("manufacturer_pid"))"
        ].joined(separator: "\n")
    }
}

struct PortHistory: Decodable {
    struct Sample: Decodable {
        let voltage: Double
        let current: Double
        var watts: Double { voltage * current / 1_000_000 }
    }
    struct Entry: Decodable {
        let port: Int
        let samples: [Sample]
    }
    let sample_period_ms: Double
    let ports: [Entry]
    static func decode(_ data: Data) throws -> PortHistory {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.sample_period_ms.isFinite, value.sample_period_ms > 0, value.sample_period_ms <= 120_000,
              value.ports.count <= 16, Set(value.ports.map(\.port)).count == value.ports.count,
              value.ports.allSatisfy({ $0.port >= 0 && $0.samples.count <= 1000 && $0.samples.allSatisfy {
                  $0.voltage.isFinite && $0.current.isFinite && $0.voltage >= 0 && $0.current >= 0 && $0.watts.isFinite
              } }) else { throw MonitorError.invalidMetrics }
        return value
    }
    func recent(_ id: Int) -> [Sample]? {
        ports.first { $0.port == id }.map { Array($0.samples.suffix(Int(1_800_000 / sample_period_ms))) }
    }
    func energyWh(_ samples: [Sample]) -> Double {
        // Each firmware sample is an interval average; do not bridge missing intervals.
        samples.reduce(0) { $0 + $1.watts } * sample_period_ms / 3_600_000
    }
}

extension MetricsClient {
    static func history(host: String) async throws -> PortHistory {
        var components = URLComponents(url: try Endpoint.url(host: host), resolvingAgainstBaseURL: false)!
        components.path = "/porthistoryz"
        components.queryItems = [URLQueryItem(name: "limit", value: "180")]
        let (data, response) = try await session.data(from: components.url!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw MonitorError.http(code) }
        return try PortHistory.decode(data)
    }
}
