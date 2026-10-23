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
            (String(format: "%.0f W", ceiling * Double(i) / 2) as NSString).draw(at: NSPoint(x: 6, y: y - 6), withAttributes: attrs)
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

@MainActor
final class PortDetail: NSWindowController, NSWindowDelegate {
    let portID: Int
    private let host: String
    private let status = NSTextField(labelWithString: "正在读取硬件…")
    private let session = NSTextField(wrappingLabelWithString: "本次电量：未获取\n充电时长：未获取\n功率上限：未获取")
    private let summary = NSTextField(wrappingLabelWithString: "正在读取历史…")
    private let cable = NSTextField(wrappingLabelWithString: "未获取")
    private let pd = NSTextField(wrappingLabelWithString: "未获取")
    private let chart = PowerChart()
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var revision = 0
    private(set) var verifiedHistoryCount = 0
    private(set) var hasLiveData = false

    init(portID: Int, host: String) {
        self.portID = portID; self.host = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "小电拼 · \(portID == 0 ? "USB-A" : "C\(portID)") 端口详情"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        window.contentView!.addSubview(scroll)
        let document = DetailDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            stack.addArrangedSubview(label)
        }
        func body(_ label: NSTextField) {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.maximumNumberOfLines = 0
            label.isSelectable = true
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)
        heading("本次充电")
        body(session)
        heading("近 30 分钟 · 硬件历史")
        stack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 170).isActive = true
        body(summary)
        heading("线材信息")
        body(cable)
        heading("PD 协商")
        body(pd)
        let note = NSTextField(wrappingLabelWithString: "数据来自充电器；详情打开时每 10 秒刷新，不保存历史到磁盘。\n电量为 USB 输出量；历史电量为采样估算，功率上限不代表实际输出。")
        note.textColor = .secondaryLabelColor
        body(note)
        stack.addArrangedSubview(NSButton(title: "立即刷新", target: self, action: #selector(refresh)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func verifyLayout() {
        guard let content = window?.contentView, let scroll = content.subviews.first as? NSScrollView,
              let document = scroll.documentView else { preconditionFailure("Missing detail document") }
        content.layoutSubtreeIfNeeded()
        precondition(document.bounds.width > 500 && document.bounds.height > 500)
        precondition(chart.bounds.height == 170 && chart.bounds.width > 400)
        for label in [session, summary, cable, pd] {
            let rect = label.convert(label.bounds, to: document)
            precondition(document.bounds.contains(rect), "Detail text clipped: \(rect)")
            precondition(label.bounds.height >= label.fittingSize.height - 1, "Detail label truncated")
        }
        if portID == 4, let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
            document.cacheDisplay(in: document.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/mirror-detail-preview.png"))
        }
    }

    func stop() {
        revision += 1
        task?.cancel(); task = nil
        timer?.invalidate(); timer = nil
    }
    func windowWillClose(_ notification: Notification) { stop() }

    func render(_ port: Port) {
                    let energy = port.sessionWh.map { String(format: "%.3f Wh", $0) } ?? "未获取"
                    let budget = port.power_budget.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.0f W", $0) : nil } ?? "未获取"
                    session.stringValue = "本次累计输出：\(energy)    ·    充电时长：\(port.durationText)\n当前功率：\(String(format: "%.2f W", port.watts))    ·    分配功率上限：\(budget)"
                    cable.stringValue = port.pd_status?.cableText ?? "未获取 · 设备未返回线材信息"
                    pd.stringValue = port.pd_status?.pdText ?? "未获取 · 设备未返回 PD 详情"
                    status.stringValue = "\(port.attached ? "已连接" : "未连接") · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) 更新"
                    status.textColor = .secondaryLabelColor
                    hasLiveData = true
    }

    func render(_ history: PortHistory, samples: [PortHistory.Sample]) {
                chart.period = history.sample_period_ms / 1000
                chart.watts = samples.map(\.watts)
                verifiedHistoryCount = samples.count
                if samples.isEmpty { summary.stringValue = "暂无历史数据 · 等待硬件积累采样" }
                else {
                    let average = samples.reduce(0) { $0 + $1.watts } / Double(samples.count)
                    summary.stringValue = String(format: "已获取 %.1f 分钟 · %d 个采样点 · 间隔 %.0f 秒\n估算输出 %.3f Wh    平均 %.2f W    采样峰值 %.2f W", Double(samples.count) * chart.period / 60, samples.count, chart.period, history.energyWh(samples), average, samples.map(\.watts).max() ?? 0)
                }
    }

    @objc private func refresh() {
        guard task == nil else { return }
        let current = revision
        task = Task { @MainActor in
            defer { if revision == current { task = nil } }
            do {
                let metrics = try await MetricsClient.fetch(host: host)
                guard !Task.isCancelled, revision == current else { return }
                if let port = metrics.ports.first(where: { $0.id == portID }) {
                    render(port)
                } else { throw MonitorError.invalidMetrics }
            } catch {
                guard !Task.isCancelled, revision == current else { return }
                hasLiveData = false
                status.stringValue = "实时数据未获取 · 请检查设备连接"
                status.textColor = .systemOrange
                session.stringValue = "本次电量：未获取\n充电时长：未获取\n功率上限：未获取"
                cable.stringValue = "未获取"; pd.stringValue = "未获取"
            }
            do {
                let history = try await MetricsClient.history(host: host)
                guard !Task.isCancelled, revision == current else { return }
                guard let samples = history.recent(portID) else { throw MonitorError.invalidMetrics }
                render(history, samples: samples)
            } catch {
                guard !Task.isCancelled, revision == current else { return }
                chart.watts = []; verifiedHistoryCount = 0
                summary.stringValue = "历史未获取 · \(error.localizedDescription)\n可点击立即刷新重试"
            }
        }
    }
}
