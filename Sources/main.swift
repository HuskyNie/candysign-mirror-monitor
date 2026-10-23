import AppKit

@MainActor
final class PortRow: NSView {
    let id: Int
    var onHover: ((Int) -> Void)?
    var onExit: ((Int) -> Void)?
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "等待设备数据")
    private let power = NSTextField(labelWithString: "— W")
    private let arrow = NSTextField(labelWithString: "›")
    var selected = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    init(id: Int) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        name.stringValue = id == 0 ? "USB-A" : "C\(id)"
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        power.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium); power.alignment = .right
        arrow.font = .systemFont(ofSize: 22, weight: .light); arrow.textColor = .tertiaryLabelColor
        for label in [name, subtitle, power, arrow] { addSubview(label) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(name.stringValue) 充电详情")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        name.frame = NSRect(x: 14, y: 29, width: 110, height: 19)
        subtitle.frame = NSRect(x: 14, y: 10, width: 200, height: 16)
        power.frame = NSRect(x: bounds.width - 127, y: 22, width: 95, height: 23)
        arrow.frame = NSRect(x: bounds.width - 24, y: 17, width: 14, height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.13) : NSColor.labelColor.withAlphaComponent(0.035)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { onHover?(id) }
    override func mouseExited(with event: NSEvent) { onExit?(id) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onHover?(id) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 || event.keyCode == 36 || event.keyCode == 49 { onHover?(id) }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onHover?(id); return true }
    func render(_ port: Port?) {
        subtitle.stringValue = port.map { $0.attached ? String(format: "%@ · %.2f V", $0.protocolName, $0.volts) : ($0.active ? "未连接" : "已关闭") } ?? "未获取 · 等待连接"
        power.stringValue = port.map { $0.attached ? String(format: "%.2f W", $0.watts) : "— W" } ?? "— W"
    }
}

@MainActor
final class DetailHoverScrollView: NSScrollView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
final class Monitor: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let total = NSTextField(labelWithString: "— W")
    private let state = NSTextField(labelWithString: "正在连接设备…")
    private var rows: [Int: PortRow] = [:]
    private var details: [Int: PortDetail] = [:]
    private var panel: NSPanel?
    private var selected: Int?
    private var pendingDismissal: Task<Void, Never>?
    private var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var verificationSamples = 0
    private var host = UserDefaults.standard.string(forKey: "deviceHost") ?? ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--host"), CommandLine.arguments.count > i + 1 {
            let candidate = CommandLine.arguments[i + 1]
            if (try? Endpoint.url(host: candidate)) != nil {
                host = candidate; UserDefaults.standard.set(host, forKey: "deviceHost")
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = self; item.button?.action = #selector(toggle)
        buildPopover(); buildDetails(); updateIcon(connected: false)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        if CommandLine.arguments.contains("--verify-ui") {
            Task { @MainActor in
                let ports = (0...4).map { id in
                    "{\"id\":\(id),\"active\":true,\"attached\":true,\"port_type\":\"\(id == 0 ? "A" : "C")\",\"fc_protocol\":16,\"current\":400,\"voltage\":12000,\"session_charge\":3600000000,\"charging_duration_seconds\":3600,\"power_budget\":100}"
                }.joined(separator: ",")
                let metrics = try! Metrics.decode(Data("{\"ports\":[\(ports)]}".utf8))
                let samples = (0..<180).map { PortHistory.Sample(voltage: 12000, current: 300 + Double($0 % 15) * 10) }
                let history = PortHistory(sample_period_ms: 10000, ports: (0...4).map { .init(port: $0, samples: samples) })
                apply(metrics); await verify(history: history)
                apply(metrics); await verify(history: history)
            }
        } else { start() }
        if host.isEmpty && !CommandLine.arguments.contains("--verify-ui") { settings() }
        if CommandLine.arguments.contains("--show") { DispatchQueue.main.async { self.toggle() } }
    }
    private func buildPopover() {
        let controller = NSViewController()
        controller.view = DetailDocument(frame: NSRect(x: 0, y: 0, width: 360, height: 508))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 18)
        ])
        let title = NSTextField(labelWithString: "MIRROR  /  小电拼")
        title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        total.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
        stack.addArrangedSubview(total)
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor
        stack.addArrangedSubview(state)
        for id in [1, 2, 3, 4, 0] {
            let row = PortRow(id: id)
            row.onHover = { [weak self] id in self?.showDetail(id) }
            row.onExit = { [weak self] id in
                guard self?.selected == id else { return }
                self?.scheduleDetailDismissal()
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 56).isActive = true
            rows[id] = row
        }
        let settings = NSButton(title: "设备地址", target: self, action: #selector(settings))
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refresh))
        let quit = NSButton(title: "退出", target: self, action: #selector(quit))
        for button in [settings, refresh, quit] { button.bezelStyle = .rounded }
        let footer = NSStackView(views: [settings, refresh, quit]); footer.spacing = 12
        stack.addArrangedSubview(footer)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 508)
        popover.behavior = .applicationDefined
        popover.animates = false
    }
    private func buildDetails() {
        for detail in details.values { detail.stop() }
        details.removeAll()
        for id in [1, 2, 3, 4, 0] {
            let detail = PortDetail(portID: id, host: host)
            detail.onResize = { [weak self] in if self?.selected == id { self?.positionDetail() } }
            details[id] = detail
        }
    }
    @objc private func toggle() {
        if popover.isShown { closeMenus(); return }
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeMenus() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.closeMenus(); return nil }
            if event.type != .keyDown && event.window !== self.popover.contentViewController?.view.window && event.window !== self.panel {
                // Leave the status button to toggle its own menu.
                if event.window !== self.item.button?.window { self.closeMenus() }
            }
            return event
        }
    }
    private func showDetail(_ id: Int) {
        cancelDetailDismissal()
        guard popover.isShown, let detail = details[id], selected != id else { return }
        hideDetail()
        selected = id; rows[id]?.selected = true
        let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: detail.card.bounds.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        child.isOpaque = false; child.backgroundColor = .clear; child.hasShadow = true
        child.isReleasedWhenClosed = false
        child.level = .popUpMenu
        let scroll = DetailHoverScrollView(frame: child.contentView!.bounds)
        scroll.onEnter = { [weak self] in self?.cancelDetailDismissal() }
        scroll.onExit = { [weak self] in self?.scheduleDetailDismissal() }
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 16; scroll.layer?.masksToBounds = true
        scroll.documentView = detail.card
        child.contentView = scroll
        panel = child
        popover.contentViewController?.view.window?.addChildWindow(child, ordered: .above)
        positionDetail()
        child.orderFront(nil)
        if !CommandLine.arguments.contains("--verify-ui") { detail.start() }
    }
    private func positionDetail() {
        guard let panel, let id = selected, let detail = details[id], let row = rows[id], let parent = row.window else { return }
        let visible = parent.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let anchor = parent.convertToScreen(row.convert(row.bounds, to: nil))
        let height = min(detail.card.bounds.height, visible.height - 20)
        let width: CGFloat = 430
        var x = parent.frame.maxX + 6
        if x + width > visible.maxX - 6 { x = parent.frame.minX - width - 6 }
        x = max(visible.minX + 6, min(x, visible.maxX - width - 6))
        let y = max(visible.minY + 6, min(anchor.maxY - height + 4, visible.maxY - height - 6))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    private func cancelDetailDismissal() {
        pendingDismissal?.cancel()
        pendingDismissal = nil
    }
    private func pointerIsInsideDetailOrRow() -> Bool {
        guard let id = selected, let row = rows[id], let parent = row.window else { return false }
        let point = pointerLocation()
        let rowFrame = parent.convertToScreen(row.convert(row.bounds, to: nil))
        return rowFrame.contains(point) || (panel?.frame.contains(point) ?? false)
    }
    private func scheduleDetailDismissal() {
        cancelDetailDismissal()
        guard let id = selected else { return }
        pendingDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
            guard let self, self.selected == id, !Task.isCancelled else { return }
            if !self.pointerIsInsideDetailOrRow() { self.hideDetail() }
        }
    }
    private func hideDetail() {
        cancelDetailDismissal()
        if let id = selected { details[id]?.stop(); rows[id]?.selected = false }
        selected = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }
    private func closeMenus() {
        hideDetail(); popover.performClose(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    private func start() {
        timer?.invalidate()
        timer = Timer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common); refresh()
    }
    @objc private func refresh() {
        guard request == nil, !host.isEmpty else { return }
        let current = generation
        let currentHost = host
        request = Task { @MainActor in
            defer { if generation == current { request = nil } }
            do {
                let metrics = try await MetricsClient.fetch(host: currentHost)
                guard !Task.isCancelled, generation == current else { return }
                apply(metrics)
                if CommandLine.arguments.contains("--verify") { await verify() }
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                markOffline()
                if CommandLine.arguments.contains("--verify") { fputs("Live verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        }
    }
    private func apply(_ metrics: Metrics) {
                total.stringValue = String(format: "%.2f W", metrics.totalWatts)
                state.stringValue = "USB 总输出 · 悬浮端口查看详情"
                updateIcon(connected: true, watts: metrics.totalWatts)
                for (id, row) in rows {
                    let port = metrics.ports.first { $0.id == id }
                    row.render(port)
                    if let port { details[id]?.render(port) } else { details[id]?.markOffline() }
                }
    }

    private func verify(history supplied: PortHistory? = nil) async {
        verificationSamples += 1
        if !popover.isShown {
            try? await Task.sleep(nanoseconds: 300_000_000)
            toggle()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(rows.count == 5 && item.menu == nil)
        do {
            let history: PortHistory
            if let supplied { history = supplied } else { history = try await MetricsClient.history(host: host) }
            for id in [1, 2, 3, 4, 0] {
                let detail = details[id]!
                guard let samples = history.recent(id) else { preconditionFailure("Missing history") }
                detail.render(history, samples: samples)
                detail.verifyLayout()
                rows[id]?.onHover?(id)
                precondition(panel != nil && !panel!.styleMask.contains(.titled) && selected == id, "Hover panel missing for \(id), shown=\(popover.isShown), selected=\(String(describing: selected))")
                precondition(rows[id]!.selected)
                detail.stop()
            }
            if supplied != nil { await verifyHoverDismissal() }
            hideDetail()
            let root = popover.contentViewController!.view
            root.layoutSubtreeIfNeeded()
            for row in rows.values { precondition(root.bounds.contains(row.convert(row.bounds, to: root))) }
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/mirror-main-preview.png"))
            }
        } catch { fputs("History verification failed: \(error.localizedDescription)\n", stderr); exit(1) }
        print("PASS: custom popover, five hover row handlers, attached borderless detail panels, history and layout (\(supplied == nil ? "real device" : "fixture"))")
        if verificationSamples == 1 { markOffline(); print("PASS: offline values cleared") }
        if verificationSamples >= 2 { closeMenus(); precondition(panel == nil && !popover.isShown); print("PASS: recovery and combined dismissal"); NSApp.terminate(nil) }
    }
    private func verifyHoverDismissal() async {
        let outside = NSPoint(x: -100_000, y: -100_000)
        pointerLocation = { outside }
        defer { pointerLocation = { NSEvent.mouseLocation }; hideDetail() }
        showDetail(4)
        rows[4]?.onExit?(4)
        try? await Task.sleep(nanoseconds: 360_000_000)
        precondition(panel == nil && selected == nil && rows[4]?.selected == false, "Leaving row must close detail and clear highlight")

        showDetail(4)
        rows[4]?.onExit?(4)
        let inside = NSPoint(x: panel!.frame.midX, y: panel!.frame.midY)
        pointerLocation = { inside }
        (panel?.contentView as? DetailHoverScrollView)?.onEnter?()
        try? await Task.sleep(nanoseconds: 360_000_000)
        precondition(selected == 4 && panel != nil, "Crossing the gap into detail must keep it open")
        pointerLocation = { outside }
        (panel?.contentView as? DetailHoverScrollView)?.onExit?()
        try? await Task.sleep(nanoseconds: 360_000_000)
        precondition(panel == nil, "Leaving detail must close it")

        showDetail(4)
        rows[4]?.onExit?(4)
        rows[4]?.onHover?(4)
        try? await Task.sleep(nanoseconds: 360_000_000)
        precondition(selected == 4, "Reentering row must cancel dismissal")
        rows[4]?.onExit?(4)
        rows[3]?.onHover?(3)
        try? await Task.sleep(nanoseconds: 360_000_000)
        precondition(selected == 3, "Old row dismissal must not close a new port")
        print("PASS: row exit, detail entry/exit, gap crossing, row reentry and switching cancellation")
    }

    private func updateIcon(connected: Bool, watts: Double = 0) {
        item.button?.image = Artwork.status(connected: connected)
        item.button?.imagePosition = connected ? .imageLeading : .imageOnly
        item.button?.title = connected ? String(format: " %.1f W", watts) : ""
        item.button?.toolTip = connected ? "小电拼 · 点击后悬浮端口查看详情" : "小电拼未连接 · 点击检查设备地址"
    }
    private func markOffline() {
        updateIcon(connected: false)
        total.stringValue = "— W"; state.stringValue = "设备不可达 · 自动重试中"
        for (id, row) in rows { row.render(nil); details[id]?.markOffline() }
    }
    @objc private func sleep() {
        closeMenus(); timer?.invalidate(); generation += 1; request?.cancel(); request = nil; markOffline()
    }
    @objc private func wake() { start() }
    @objc private func settings() {
        closeMenus()
        let alert = NSAlert(); alert.messageText = "连接小电拼"
        alert.informativeText = "输入局域网 IP 或设备 .local 名称。使用 .local 名称可跟随设备 IP 变化。"
        alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); input.stringValue = host
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let candidate = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? Endpoint.url(host: candidate)) != nil else {
            let error = NSAlert(); error.messageText = MonitorError.invalidHost.localizedDescription; error.runModal(); return
        }
        generation += 1; request?.cancel(); request = nil
        host = candidate; UserDefaults.standard.set(host, forKey: "deviceHost")
        buildDetails(); markOffline(); refresh()
    }
    @objc private func quit() { closeMenus(); NSApp.terminate(nil) }
}

if let index = CommandLine.arguments.firstIndex(of: "--probe"), CommandLine.arguments.count > index + 1 {
    let host = CommandLine.arguments[index + 1]
    Task {
        do {
            let value = try await MetricsClient.fetch(host: host)
            for port in value.ports.sorted(by: { $0.id < $1.id }) {
                print(String(format: "%@ | %@ | %.3f V | %.3f A | %.3f W", port.name, port.protocolName, port.volts, port.amps, port.watts))
            }
            print(String(format: "USB total: %.3f W", value.totalWatts))
            exit(0)
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = Monitor()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
