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
