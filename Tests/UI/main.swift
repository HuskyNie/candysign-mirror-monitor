import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let detail = PortDetail(portID: 4, host: "192.168.1.100")
    let fixture = """
    {"ports":[{"id":4,"active":true,"attached":true,"port_type":"C","fc_protocol":16,"current":381,"voltage":11976,"session_charge":225823684466,"charging_duration_seconds":1129419,"power_budget":100,"pd_status":{"has_emarker":true,"cable_max_vbus_voltage":3,"cable_max_vbus_current":2,"cable_usb_highest_speed":3,"cable_epr_mode_capable":true,"cable_is_active":false,"operating_voltage":20000,"operating_current":3000,"pd_revision":2,"pps_charging_supported":true}}]}
    """
    let port = try! Metrics.decode(Data(fixture.utf8)).ports[0]
    let samples = (0..<180).map { PortHistory.Sample(voltage: 12000, current: 350 + Double($0 % 15) * 10) }
    let history = PortHistory(sample_period_ms: 10000, ports: [.init(port: 4, samples: samples)])
    precondition(detail.card.bounds.width == 430)
    detail.render(port)
    detail.render(history, samples: samples)
    detail.verifyLayout()
    precondition(detail.sessionText.contains("未获取") && !detail.sessionText.contains("62.729"))
    let shortSession = fixture.replacingOccurrences(of: "1129419", with: "120")
    detail.render(try! Metrics.decode(Data(shortSession.utf8)).ports[0])
    detail.render(history, samples: samples)
    precondition(detail.sessionText.contains("本次估算输出"))
    detail.verifyLayout()
    let nextSession = shortSession.replacingOccurrences(of: "\"active\":true", with: "\"session_id\":2,\"active\":true")
    detail.render(try! Metrics.decode(Data(nextSession.utf8)).ports[0])
    precondition(detail.sessionText.contains("等待硬件历史"))
    print("PASS: unreliable hardware total hidden, session estimate shown, session change clears estimate")
    print("PASS: custom hover card: full cable/PD, session values and 180-point chart fit")
    let absent = fixture.replacingOccurrences(of: "\"has_emarker\":true", with: "\"has_emarker\":false")
    detail.render(try! Metrics.decode(Data(absent.utf8)).ports[0])
    detail.render(history, samples: [])
    detail.verifyLayout()
    print("PASS: unavailable cable fields and empty history layout")
    detail.render(port)
    detail.render(history, samples: samples)
    detail.verifyLayout()
    detail.verifyCloud(CloudPD(values: ["has_emarker": true, "operating_voltage": 1200,
        "operating_current": 300, "pd_revision": "PD 3.0", "cable_max_vbus_current": "unknown(2)",
        "cable_max_vbus_voltage": "20V", "cable_usb_highest_speed": "USB 2.0"]))
    print("PASS: cloud cable/PD layout and chip-unit conversion")
    detail.stop()
}
