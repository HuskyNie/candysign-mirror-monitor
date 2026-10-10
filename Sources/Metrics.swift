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
