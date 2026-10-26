import Foundation

let fixture = """
{"ports":[
{"id":0,"active":true,"attached":false,"port_type":"A","fc_protocol":255,"current":0,"voltage":0},
{"id":1,"active":true,"attached":true,"port_type":"C","fc_protocol":0,"current":36,"voltage":4992},
{"id":4,"active":true,"attached":true,"port_type":"C","fc_protocol":16,"current":447,"voltage":11976}]}
"""
let metrics = try Metrics.decode(Data(fixture.utf8))
precondition(abs(metrics.totalWatts - 5.532984) < 0.000001, "mV/mA conversion must preserve power")
precondition(metrics.ports[2].protocolName == "PD · 固定高压")
precondition(metrics.ports[0].name == "USB-A")
precondition(metrics.ports[1].name == "C1")
precondition(metrics.ports[0].protocolName == "—")
let unknown = fixture.replacingOccurrences(of: "\"fc_protocol\":16", with: "\"fc_protocol\":99")
let unknownMetrics = try Metrics.decode(Data(unknown.utf8))
precondition(unknownMetrics.ports[2].protocolName == "未知协议 (99)")
for invalid in ["{}", "{\"ports\":[]}", fixture.replacingOccurrences(of: "\"id\":4", with: "\"id\":1"), fixture.replacingOccurrences(of: "11976", with: "-1")] {
    precondition((try? Metrics.decode(Data(invalid.utf8))) == nil)
}
for host in ["192.168.1.100", "10.0.0.1", "172.16.0.1", "charger.local"] {
    precondition((try? Endpoint.url(host: host)) != nil)
}
for host in ["example.com", "8.8.8.8", "192.168.999.1", "192.168.1.1/reset", "user@charger.local", "", "http://192.168.1.1"] {
    precondition((try? Endpoint.url(host: host)) == nil)
}
print("PASS: unit conversion, protocol mapping, unknown protocol, missing/invalid metrics, local endpoint validation")

let extra = fixture.replacingOccurrences(of: "\"fc_protocol\":16", with: "\"session_charge\":3600000000,\"charging_duration_seconds\":3661,\"power_budget\":100,\"pd_status\":null,\"fc_protocol\":16")
let extraPort = try Metrics.decode(Data(extra.utf8)).ports[2]
precondition(extraPort.sessionWh == 1)
precondition(extraPort.durationText == "1 小时 1 分钟")
precondition(extraPort.power_budget == 100 && extraPort.pd_status == nil)
precondition(metrics.ports[2].sessionWh == nil && metrics.ports[2].durationText == "未获取")
let h = try PortHistory.decode(Data("""
{"sample_period_ms":10000,"ports":[{"port":4,"samples":[{"voltage":20000,"current":3000},{"voltage":20000,"current":3000}]}]}
""".utf8))
precondition(abs(h.energyWh(h.recent(4)!) - 1.0 / 3.0) < 1e-10)
precondition(h.recent(1) == nil)
for bad in ["{\"sample_period_ms\":0,\"ports\":[]}", "{\"sample_period_ms\":10000,\"ports\":[{\"port\":0,\"samples\":[{\"voltage\":-1,\"current\":0}]}]}"] {
    precondition((try? PortHistory.decode(Data(bad.utf8))) == nil)
}
let validPD = try JSONDecoder().decode(PDStatus.self, from: Data("""
{"has_emarker":true,"cable_max_vbus_voltage":3,"cable_max_vbus_current":2,"cable_usb_highest_speed":3,"cable_epr_mode_capable":true,"operating_voltage":20000,"operating_current":3000,"pd_revision":2,"pps_charging_supported":false}
""".utf8))
precondition(validPD.cableText.contains("50 V") && validPD.cableText.contains("5 A") && validPD.cableText.contains("USB4 Gen 3"))
precondition(validPD.pdText.contains("20.00 V") && validPD.pdText.contains("3.00 A") && validPD.pdText.contains("PPS：不支持"))
let emptyPD = try JSONDecoder().decode(PDStatus.self, from: Data("{}".utf8))
precondition(emptyPD.cableText.contains("未获取") && !emptyPD.cableText.contains("USB 2.0"))
let noMarker = try JSONDecoder().decode(PDStatus.self, from: Data("{\"has_emarker\":false,\"cable_usb_highest_speed\":0}".utf8))
precondition(noMarker.cableText.contains("未检测到") && !noMarker.cableText.contains("USB 2.0"))
print("PASS: hardware session units, absent data, history energy/validation, cable capability and PD units")

precondition(validPD.pdText.contains("PD 修订：3.0"), "HTTP JSON follows official dashboard revision mapping")

precondition(metrics.ports[0].cableDescription.contains("不适用"))
precondition(extraPort.cableDescription.contains("暂未上报"))
let unplugged = try Metrics.decode(Data(extra.replacingOccurrences(of: "\"attached\":true", with: "\"attached\":false").utf8)).ports[2]
precondition(unplugged.cableDescription.contains("未连接") && !unplugged.cableDescription.contains("暂未上报"))
print("PASS: USB-A, unplugged USB-C and absent device cable data are distinct")
