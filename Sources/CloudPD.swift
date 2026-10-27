import Foundation
import Security

enum CloudError: LocalizedError {
    case configuration, authorization, unavailable, invalidData
    var errorDescription: String? {
        switch self {
        case .configuration: return "未配置官方 MCP 授权"
        case .authorization: return "官方 MCP 授权失效，请重新配置"
        case .unavailable: return "官方 MCP 暂不可用，请稍后重试"
        case .invalidData: return "官方 MCP 返回数据无法识别"
        }
    }
}

enum CloudCredential {
    static func endpoint(_ text: String) throws -> URL {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "https", c.host == "mcp.thecandysign.com", c.port == nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw CloudError.configuration }
        let parts = c.path.split(separator: "/")
        guard parts.count == 3, parts[0].allSatisfy(\.isNumber), !parts[1].isEmpty,
              ["mcp", "sse"].contains(String(parts[2])) else { throw CloudError.configuration }
        c.path = "/\(parts[0])/\(parts[1])/mcp"
        guard let url = c.url else { throw CloudError.configuration }
        return url
    }
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.husky.mirror-monitor.mcp", kSecAttrAccount as String: "official-endpoint"] }
    static func read() throws -> URL {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw CloudError.configuration }
        return try endpoint(text)
    }
    static func save(_ text: String) throws {
        let data = Data(try endpoint(text).absoluteString.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CloudError.configuration }
        } else if status != errSecSuccess { throw CloudError.configuration }
    }
}

struct CloudPD {
    let values: [String: Any]
    func text(_ key: String) -> String {
        if let s = values[key] as? String, !s.isEmpty { return s }
        if let n = values[key] as? NSNumber { return "未知编号 \(n)" }
        return "未获取"
    }
    func flag(_ key: String) -> Bool? {
        guard let n = values[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    func yesNo(_ key: String) -> String { flag(key).map { $0 ? "支持" : "不支持" } ?? "未获取" }
    func identifier(_ key: String) -> String {
        guard let n = values[key] as? Int, n > 0, n <= 65535 else { return "未获取" }
        return String(format: "0x%04X", n)
    }
    func operating(_ key: String, unit: String) -> String {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue > 0 else { return "未获取" }
        let n = value.doubleValue
        // MQTT protobuf preserves chip units: 10 mV / 10 mA, unlike HTTP JSON.
        return String(format: "%.2f %@", n / 100, unit)
    }
    var cableText: String {
        guard flag("has_emarker") == true else {
            return "eMarker：\(flag("has_emarker") == false ? "未检测到" : "未获取")\n线材能力：未获取"
        }
        let raw = text("cable_max_vbus_current")
        let current = raw == "unknown(2)" ? "5 A（固件枚举；云端 unknown(2)）" : raw
        return ["eMarker：已检测到", "额定电流：\(current)", "额定电压：\(text("cable_max_vbus_voltage"))",
                "USB 能力：\(text("cable_usb_highest_speed"))", "EPR：\(yesNo("cable_epr_mode_capable"))",
                "线材类型：" + (flag("cable_is_active").map { $0 ? "有源" : "无源" } ?? "未获取"),
                "VID / PID：\(identifier("cable_vid")) / \(identifier("cable_pid"))"].joined(separator: "\n")
    }
    var pdText: String {
        ["PD 修订：\(text("pd_revision"))", "协商电压：\(operating("operating_voltage", unit: "V"))",
         "协商电流：\(operating("operating_current", unit: "A"))", "PPS：\(yesNo("pps_charging_supported"))",
         "受电端 EPR：\(yesNo("request_epr_mode_capable"))",
         "能力不匹配：" + (flag("request_capability_mismatch").map { $0 ? "是" : "否" } ?? "未获取")].joined(separator: "\n")
    }
    static func decode(ports: [[String: Any]], mapping: [[String: Any]]) throws -> [Int: CloudPD] {
        var indices: [Int: Int] = [:]
        let names = ["A": 0, "C1": 1, "C2": 2, "C3": 3, "C4": 4]
        for m in mapping {
            guard let index = m["index"] as? Int, let name = m["name"] as? String,
                  let local = names[name], indices[index] == nil, !indices.values.contains(local) else { throw CloudError.invalidData }
            indices[index] = local
        }
        guard indices.count == 5 else { throw CloudError.invalidData }
        var result: [Int: CloudPD] = [:]
        for p in ports {
            guard let index = p["port"] as? Int, let local = indices[index], result[local] == nil else { throw CloudError.invalidData }
            result[local] = CloudPD(values: p)
        }
        return result
    }
}

// Ephemeral session per detail refresh: credentials and PD snapshots are never logged/cached.
final class CloudPDClient {
    let endpoint: URL
    let session: URLSession
    var sessionID: String?
    var protocolVersion = "2024-11-05"
    init(endpoint: URL) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 40; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: LocalSessionDelegate(), delegateQueue: nil)
    }
    func rpc(_ method: String, _ params: [String: Any], id: Int?) async throws -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { body["id"] = id }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw CloudError.unavailable }
        if [401, 403].contains(http.statusCode) { throw CloudError.authorization }
        guard (200...299).contains(http.statusCode) else { throw CloudError.unavailable }
        sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        guard let id else { return [:] }
        func unpack(_ data: Data) throws -> [String: Any]? {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.invalidData }
            guard obj["id"] as? Int == id else { return nil }
            guard obj["error"] == nil, let result = obj["result"] as? [String: Any] else { throw CloudError.unavailable }
            return result
        }
        var data = Data()
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.hasPrefix("data:") {
                    data.append(contentsOf: line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                    if let result = try unpack(data) { return result }
                    data.removeAll()
                }
                guard data.count < 1_000_000 else { throw CloudError.invalidData }
            }
        } else {
            for try await byte in bytes {
                data.append(byte)
                guard data.count < 1_000_000 else { throw CloudError.invalidData }
            }
            if let result = try unpack(data) { return result }
        }
        throw CloudError.invalidData
    }
    func tool(_ name: String, id: Int) async throws -> [String: Any] {
        let result = try await rpc("tools/call", ["name": name, "arguments": [:]], id: id)
        guard result["isError"] as? Bool != true else { throw CloudError.unavailable }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw CloudError.invalidData }
        return object
    }
    static func fetch() async throws -> [Int: CloudPD] {
        let client = CloudPDClient(endpoint: try CloudCredential.read())
        defer { client.session.invalidateAndCancel() }
        let result = try await client.rpc("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:],
            "clientInfo": ["name": "MirrorMonitor", "version": "1.3.0"]], id: 1)
        client.protocolVersion = result["protocolVersion"] as? String ?? "2024-11-05"
        _ = try await client.rpc("notifications/initialized", [:], id: nil)
        let facts = try await client.tool("get_machine_facts", id: 2)
        let pd = try await client.tool("get_port_pd_status", id: 3)
        guard let mapping = facts["ports"] as? [[String: Any]], let ports = pd["ports"] as? [[String: Any]] else { throw CloudError.invalidData }
        return try CloudPD.decode(ports: ports, mapping: mapping)
    }
}
