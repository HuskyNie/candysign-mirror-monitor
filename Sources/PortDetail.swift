import AppKit

@MainActor
final class DetailDocument: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

@MainActor
final class PowerChart: NSView {
    var watts: [Double] = [] { didSet { needsDisplay = true } }
    var period: Double = 10
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let plot = bounds.insetBy(dx: 45, dy: 28)
        let ceiling = max(5, ceil((watts.max() ?? 0) / 5) * 5)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for i in 0...2 {
            let y = plot.minY + plot.height * CGFloat(i) / 2
            NSColor.separatorColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
            (String(format: "%g W", ceiling * Double(i) / 2) as NSString).draw(at: NSPoint(x: 6, y: y - 6), withAttributes: attrs)
        }
        let minutes = Double(watts.count) * period / 60
        (String(format: "−%.1f 分钟", minutes) as NSString).draw(at: NSPoint(x: plot.minX, y: 7), withAttributes: attrs)
        ("最近采样" as NSString).draw(at: NSPoint(x: plot.maxX - 45, y: 7), withAttributes: attrs)
        guard !watts.isEmpty else {
            ("暂无历史数据" as NSString).draw(at: NSPoint(x: plot.midX - 40, y: plot.midY), withAttributes: attrs)
            return
        }
        let path = NSBezierPath()
        for (i, w) in watts.enumerated() {
            let point = NSPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(max(1, watts.count - 1)), y: plot.minY + plot.height * w / ceiling)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.systemTeal.setStroke(); path.lineWidth = 2; path.stroke()
    }
}

// Custom hover card; presented as an attached borderless child panel.
@MainActor
final class PortDetail: NSObject {
    let portID: Int
    var onResize: (() -> Void)?
    let card = DetailDocument(frame: NSRect(x: 0, y: 0, width: 430, height: 560))
    private let host: String
    private let status = NSTextField(labelWithString: "等待设备数据")
    private let session = NSTextField(wrappingLabelWithString: "本次输出  未获取\n充电时长  未获取\n功率上限  未获取")
    private let summary = NSTextField(wrappingLabelWithString: "悬浮展开时读取硬件历史")
    private let cable = NSTextField(wrappingLabelWithString: "未获取")
    private let pd = NSTextField(wrappingLabelWithString: "未获取")
    private let chart = PowerChart()
    private let stack = NSStackView()
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var cloudTimer: Timer?
    private var cloudRevision = 0
    private var cloudPD: CloudPD?
    private var cloudMessage = "官方 MCP · 展开后读取"
    private var lastPort: Port?
    private var sessionEstimate: Double?
    private var estimateAt: Date?
    private var estimateMessage = "等待硬件历史"
    var sessionText: String { session.stringValue }
    private var visible = false
    private var revision = 0
    private(set) var verifiedHistoryCount = 0
    private(set) var hasLiveData = false

    init(portID: Int, host: String) {
        self.portID = portID; self.host = host
        super.init()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14)
        ])
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(label)
        }
        func body(_ label: NSTextField) {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.maximumNumberOfLines = 0
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        heading("\(portID == 0 ? "USB-A" : "C\(portID)")  ·  充电详情")
        status.textColor = .secondaryLabelColor
        body(status)
        body(session)
        heading("近 30 分钟")
        stack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 136).isActive = true
        body(summary)
        heading("线材")
        body(cable)
        heading("PD 协商")
        body(pd)
        let note = NSTextField(wrappingLabelWithString: "本地历史 10 秒 · 云端详情 30 秒 · 仅保留内存")
        note.textColor = .secondaryLabelColor
        body(note)
        let refresh = NSButton(title: "刷新详情", target: self, action: #selector(refreshAll))
        refresh.bezelStyle = .rounded
        stack.addArrangedSubview(refresh)
        resizeCard()
    }

    private func resizeCard() {
        card.layoutSubtreeIfNeeded()
        card.setFrameSize(NSSize(width: 430, height: stack.fittingSize.height + 28))
        card.layoutSubtreeIfNeeded()
        onResize?()
    }
    func start() {
        visible = true
        refreshCloud()
        cloudTimer?.invalidate()
        cloudTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCloud() }
        }
        RunLoop.main.add(cloudTimer!, forMode: .common)
        refreshHistory()
        timer?.invalidate()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHistory() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }
    func stop() {
        visible = false
        cloudTimer?.invalidate(); cloudTimer = nil
        clearCloud()
        revision += 1
        task?.cancel(); task = nil
        timer?.invalidate(); timer = nil
        clearEnergy()
    }
    func markStale(time: String) {
        status.stringValue = "本地更新延迟 · 上次成功 \(time)"
        status.textColor = .systemOrange
    }
    func markOffline() {
        clearCloud(); lastPort = nil
        clearEnergy()
        hasLiveData = false
        status.stringValue = "连接中断 · 等待恢复"
        status.textColor = .systemOrange
        session.stringValue = "本次输出  未获取\n充电时长  未获取\n功率上限  未获取"
        cable.stringValue = "未获取"; pd.stringValue = "未获取"
        resizeCard()
    }
    func render(_ port: Port) {
        let durationReset = (port.charging_duration_seconds ?? 0) < (lastPort?.charging_duration_seconds ?? 0)
        let changed = lastPort?.attached != port.attached || lastPort?.session_id != port.session_id || durationReset
        if changed {
            clearCloud(); clearEnergy()
            revision += 1; task?.cancel(); task = nil
        }
        lastPort = port
        renderSession()
        renderCloud()
        if changed && visible { refreshCloud(); refreshHistory() }
        status.stringValue = "\(port.attached ? port.protocolName : "未连接") · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) 更新"
        status.textColor = .secondaryLabelColor
        hasLiveData = true
        resizeCard()
    }
    private func clearEnergy() {
        sessionEstimate = nil; estimateAt = nil; estimateMessage = "等待硬件历史"
        renderSession()
    }
    private func renderSession() {
        guard let port = lastPort else { return }
        let fresh = estimateAt.map { Date().timeIntervalSince($0) <= 25 } ?? false
        let energy: String
        if !port.attached { energy = "本次输出  未连接" }
        else if fresh, let value = sessionEstimate { energy = String(format: "本次估算输出  %.3f Wh", value) }
        else { energy = "本次输出  未获取（\(fresh ? estimateMessage : "等待硬件历史")）" }
        let budget = port.power_budget.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.0f W", $0) : nil } ?? "未获取"
        session.stringValue = "\(energy)\n本次时长  \(port.durationText)\n当前功率  \(String(format: "%.2f W", port.watts))    ·    功率上限  \(budget)"
        session.toolTip = "本次输出按充电时长截取硬件历史估算，边界误差约一个采样周期。会话超过历史范围时不显示完整本次电量。设备累计字段与功率积分不一致，未用于显示。"
    }
    private func clearCloud() {
        cloudRevision += 1; cloudTask?.cancel(); cloudTask = nil
        cloudPD = nil; cloudMessage = "官方 MCP · 展开后读取"
    }
    private func renderCloud() {
        guard let port = lastPort else { return }
        if port.port_type == "A" || !port.attached {
            cable.stringValue = port.cableDescription
            pd.stringValue = port.attached ? "不适用 · USB-A 无 PD 协商" : "未连接"
        } else if let cloudPD {
            cable.stringValue = cloudPD.cableText
            pd.stringValue = cloudPD.pdText + "\n" + cloudMessage
        } else {
            cable.stringValue = "未获取 · " + cloudMessage
            pd.stringValue = "当前协议：\(port.protocolName)\n" + cloudMessage
        }
        resizeCard()
    }
    @objc private func refreshAll() { refreshHistory(); refreshCloud() }
    private func refreshCloud() {
        guard visible, cloudTask == nil, let port = lastPort, port.attached, port.port_type != "A" else { return }
        let revision = cloudRevision
        cloudMessage = "官方 MCP · 正在读取"
        renderCloud()
        cloudTask = Task { @MainActor in
            defer { if cloudRevision == revision { cloudTask = nil } }
            do {
                let snapshot = try await CloudPDClient.fetch()
                guard !Task.isCancelled, visible, cloudRevision == revision else { return }
                cloudPD = snapshot[portID]
                cloudMessage = cloudPD == nil ? "官方 MCP 未返回该端口详情" : "官方 MCP · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) 更新"
            } catch {
                guard !Task.isCancelled, visible, cloudRevision == revision else { return }
                cloudPD = nil
                cloudMessage = (error as? CloudError)?.localizedDescription ?? "官方 MCP 请求失败，可刷新重试"
            }
            renderCloud()
        }
    }
    func verifyCloud(_ value: CloudPD) {
        cloudPD = value; cloudMessage = "官方 MCP · 测试数据"
        renderCloud(); if let lastPort { render(lastPort) }; verifyLayout()
        precondition(pd.stringValue.contains("12.00 V") && pd.stringValue.contains("3.00 A"))
        precondition(cable.stringValue.contains("unknown(2)"))
    }

    func render(_ history: PortHistory, samples: [PortHistory.Sample]) {
        sessionEstimate = history.sessionEnergyWh(samples, duration: lastPort?.charging_duration_seconds)
        estimateAt = Date()
        estimateMessage = samples.isEmpty ? "暂无历史" : "历史未覆盖完整会话或时长不足一个采样周期"
        renderSession()
        chart.period = history.sample_period_ms / 1000
        chart.watts = samples.map(\.watts)
        verifiedHistoryCount = samples.count
        if samples.isEmpty { summary.stringValue = "暂无历史数据 · 等待硬件采样" }
        else {
            let average = samples.reduce(0) { $0 + $1.watts } / Double(samples.count)
            summary.stringValue = String(format: "最近 %.1f 分钟 · %d 点\n此时间段估算输出 %.3f Wh\n平均 %.2f W    采样峰值 %.2f W", Double(samples.count) * chart.period / 60, samples.count, history.energyWh(samples), average, samples.map(\.watts).max() ?? 0)
        }
        resizeCard()
    }
    @objc func refreshHistory() {
        guard task == nil else { return }
        let current = revision
        task = Task { @MainActor in
            defer { if revision == current { task = nil } }
            do {
                let history = try await MetricsClient.history(host: host)
                guard !Task.isCancelled, revision == current else { return }
                guard let samples = history.recent(portID) else { throw MonitorError.invalidMetrics }
                render(history, samples: samples)
            } catch {
                guard !Task.isCancelled, revision == current else { return }
                clearEnergy()
                chart.watts = []; verifiedHistoryCount = 0
                summary.stringValue = "历史未获取 · 可点击下方刷新重试"
                resizeCard()
            }
        }
    }
    func verifyLayout() {
        resizeCard()
        for label in [session, summary, cable, pd] {
            precondition(card.bounds.contains(label.convert(label.bounds, to: card)))
            precondition(label.bounds.height >= label.fittingSize.height - 1)
        }
        if portID == 4, let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
            card.cacheDisplay(in: card.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/mirror-detail-preview.png"))
        }
    }
}
