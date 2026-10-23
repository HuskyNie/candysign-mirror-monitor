import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let detail = PortDetail(portID: 4, host: "192.168.1.100")
    let fixture = """
    {"ports":[{"id":4,"active":true,"attached":true,"port_type":"C","fc_protocol":16,"current":381,"voltage":11976,"session_charge":225823684466,"charging_duration_seconds":1129419,"power_budget":100,"pd_status":{"has_emarker":true,"cable_max_vbus_voltage":3,"cable_max_vbus_current":2,"cable_usb_highest_speed":3,"cable_epr_mode_capable":true,"cable_is_active":false,"operating_voltage":2000,"operating_current":300,"pps_charging_supported":true}}]}
    """
    let port = try! Metrics.decode(Data(fixture.utf8)).ports[0]
    let samples = (0..<180).map { PortHistory.Sample(voltage: 12000, current: 350 + Double($0 % 15) * 10) }
    let history = PortHistory(sample_period_ms: 10000, ports: [.init(port: 4, samples: samples)])
    detail.showWindow(nil)
    detail.render(port)
    detail.render(history, samples: samples)
    detail.verifyLayout()
    print("PASS: full cable/PD, session values and 180-point chart fit detail document")
    let absent = fixture.replacingOccurrences(of: "\"has_emarker\":true", with: "\"has_emarker\":false")
    detail.render(try! Metrics.decode(Data(absent.utf8)).ports[0])
    detail.render(history, samples: [])
    detail.verifyLayout()
    print("PASS: unavailable cable fields and empty history layout")
    detail.render(port)
    detail.render(history, samples: samples)
    detail.verifyLayout()
    detail.close()
}
