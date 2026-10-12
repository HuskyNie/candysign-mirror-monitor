import AppKit

@MainActor
final class Monitor: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let total = NSTextField(labelWithString: "— W")
    private let state = NSTextField(labelWithString: "等待连接")
    private let updated = NSTextField(labelWithString: "每 2 秒更新 · 本地连接")
    private var rows: [Int: (NSTextField, NSTextField, NSTextField)] = [:]
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var lastSuccess: Date?
    private var verificationSamples = 0
    private var footer: NSView?
    private var host = UserDefaults.standard.string(forKey: "deviceHost") ?? ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--host"), CommandLine.arguments.count > i + 1 {
            let candidate = CommandLine.arguments[i + 1]
            if (try? Endpoint.url(host: candidate)) != nil {
                host = candidate
                UserDefaults.standard.set(host, forKey: "deviceHost")
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(connected: false)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        buildPopover()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        start()
        if host.isEmpty { settings() }
        if CommandLine.arguments.contains("--show") { toggle() }
    }

    private func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: size)
        view.textColor = color
        return view
    }

    private func buildPopover() {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 530))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 20)
        ])
        let title = label("MIRROR  /  小电拼", size: 13, color: .secondaryLabelColor)
        stack.addArrangedSubview(title)
        total.font = .monospacedDigitSystemFont(ofSize: 36, weight: .semibold)
        stack.addArrangedSubview(total)
        stack.addArrangedSubview(label("USB 总输出功率", color: .secondaryLabelColor))
        state.font = .systemFont(ofSize: 12)
        state.lineBreakMode = .byTruncatingTail
        state.widthAnchor.constraint(equalToConstant: 396).isActive = true
        stack.addArrangedSubview(state)
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 396).isActive = true
        stack.addArrangedSubview(divider)
        for id in [1, 2, 3, 4, 0] {
            let name = label(id == 0 ? "USB-A" : "C\(id)", size: 14)
            name.font = .systemFont(ofSize: 14, weight: .semibold)
            name.widthAnchor.constraint(equalToConstant: 55).isActive = true
            let details = label("等待数据", size: 12, color: .secondaryLabelColor)
            details.widthAnchor.constraint(equalToConstant: 233).isActive = true
            details.maximumNumberOfLines = 2
            details.lineBreakMode = .byTruncatingTail
            let power = label("— W", size: 15)
            power.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            power.alignment = .right
            power.widthAnchor.constraint(equalToConstant: 88).isActive = true
            let row = NSStackView(views: [name, details, power])
            row.spacing = 10
            row.heightAnchor.constraint(equalToConstant: 38).isActive = true
            stack.addArrangedSubview(row)
            rows[id] = (name, details, power)
        }
        updated.font = .systemFont(ofSize: 11)
        updated.textColor = .secondaryLabelColor
        stack.addArrangedSubview(updated)
        let settingsButton = NSButton(title: "设备地址…", target: self, action: #selector(settings))
        let refreshButton = NSButton(title: "立即刷新", target: self, action: #selector(refresh))
        let quitButton = NSButton(title: "退出", target: self, action: #selector(quit))
        let buttons = NSStackView(views: [settingsButton, refreshButton, quitButton])
        footer = buttons
        buttons.spacing = 12
        stack.addArrangedSubview(buttons)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 440, height: 530)
        popover.behavior = .transient
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func start() {
        timer?.invalidate()
        timer = Timer(timeInterval: 2, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }

    @objc private func refresh() {
        guard request == nil, !host.isEmpty else { return }
        let currentGeneration = generation
        let currentHost = host
        request = Task { @MainActor in
            defer { if currentGeneration == generation { request = nil } }
            do {
                let metrics = try await MetricsClient.fetch(host: currentHost)
                guard !Task.isCancelled, currentGeneration == generation else { return }
                lastSuccess = Date()
                total.stringValue = String(format: "%.2f W", metrics.totalWatts)
                total.textColor = .labelColor
                updateStatusIcon(connected: true, watts: metrics.totalWatts)
                item.button?.toolTip = "小电拼 · \(currentHost) · 每 2 秒更新"
                state.stringValue = "● 已连接  ·  \(currentHost)"
                state.textColor = .systemGreen
                state.toolTip = nil
                for (id, row) in rows {
                    guard let port = metrics.ports.first(where: { $0.id == id }) else {
                        row.1.stringValue = "设备未返回此端口"
                        row.2.stringValue = "— W"
                        continue
                    }
                    row.0.stringValue = port.name
                    row.0.textColor = port.attached ? .labelColor : .secondaryLabelColor
                    row.1.stringValue = port.attached
                        ? String(format: "%@\n%.3f V  ·  %.3f A", port.protocolName, port.volts, port.amps)
                        : (port.active ? "未连接" : "已关闭")
                    row.2.stringValue = port.attached ? String(format: "%.2f W", port.watts) : "— W"
                    row.2.textColor = port.attached ? .labelColor : .secondaryLabelColor
                }
                updated.stringValue = "\(DateFormatter.localizedString(from: lastSuccess!, dateStyle: .none, timeStyle: .medium)) 更新 · 每 2 秒刷新"
                if CommandLine.arguments.contains("--verify") { verifyRenderedState(metrics) }
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                markOffline(error.localizedDescription)
                if CommandLine.arguments.contains("--verify") {
                    fputs("Live verification failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
        }
    }

    // Bounded integration check against real device data; never changes device state.
    private func verifyRenderedState(_ metrics: Metrics) {
        verificationSamples += 1
        let root = popover.contentViewController!.view
        root.layoutSubtreeIfNeeded()
        precondition(rows.count == 5)
        precondition(item.button!.title == String(format: " %.1f W", metrics.totalWatts))
        precondition(state.stringValue.hasPrefix("● 已连接"))
        for port in metrics.ports {
            guard let row = rows[port.id] else { continue }
            precondition(row.2.stringValue == (port.attached ? String(format: "%.2f W", port.watts) : "— W"))
            if port.attached { precondition(row.1.stringValue.contains(port.protocolName)) }
        }
        let footerRect = footer!.convert(footer!.bounds, to: root)
        print("Layout: footer \(footerRect), content \(root.bounds)")
        fflush(stdout)
        precondition(root.bounds.contains(footerRect), "Footer must fit in popover: \(footerRect) vs \(root.bounds)")
        print("Live UI sample \(verificationSamples): \(item.button!.title), five rows and layout OK")
        if verificationSamples == 1 {
            let previous = total.stringValue
            markOffline("Integration test: simulated disconnect")
            precondition(item.button!.title.isEmpty && item.button!.image?.isTemplate == true && state.stringValue.contains("过期"))
            precondition(total.stringValue == previous && updated.stringValue.contains("上次成功"))
            print("PASS: stale values explicitly marked after simulated disconnect")
        }
        if verificationSamples >= 3 {
            print("PASS: real-device polling, rendered labels, layout bounds and recovery")
            NSApp.terminate(nil)
        }
    }

    private func updateStatusIcon(connected: Bool, watts: Double = 0) {
        item.button?.image = Artwork.status(connected: connected)
        item.button?.imagePosition = connected ? .imageLeading : .imageOnly
        item.button?.title = connected ? String(format: " %.1f W", watts) : ""
        item.button?.setAccessibilityLabel(connected ? "小电拼，USB 总功率" : "小电拼未连接")
        item.button?.toolTip = connected ? "小电拼已连接" : "小电拼未连接，点击查看详情"
    }

    private func markOffline(_ message: String) {
        updateStatusIcon(connected: false)
        item.button?.toolTip = message
        state.stringValue = "● 连接中断 · 数据已过期"
        state.textColor = .systemOrange
        state.toolTip = message
        total.textColor = .tertiaryLabelColor
        for row in rows.values { row.0.textColor = .tertiaryLabelColor; row.2.textColor = .tertiaryLabelColor }
        if let date = lastSuccess {
            updated.stringValue = "上次成功：\(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)) · 自动重连中"
        } else {
            state.stringValue = "● 尚未连接 · 请检查设备地址或本地网络权限"
            updated.stringValue = "\(host) · 每 2 秒重试"
        }
    }

    @objc private func sleep() {
        timer?.invalidate()
        generation += 1
        request?.cancel()
        request = nil
        markOffline("电脑睡眠，等待唤醒后重新连接。")
    }
    @objc private func wake() { start() }

    @objc private func settings() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "连接小电拼"
        alert.informativeText = "输入同一局域网中的设备 IP 或 .local 主机名。只读取端口状态。"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = host
        input.placeholderString = "例如：192.168.1.100"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let candidate = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? Endpoint.url(host: candidate)) != nil else {
            let error = NSAlert()
            error.messageText = MonitorError.invalidHost.localizedDescription
            error.runModal()
            return
        }
        generation += 1
        request?.cancel()
        request = nil
        host = candidate
        UserDefaults.standard.set(host, forKey: "deviceHost")
        lastSuccess = nil
        total.stringValue = "— W"
        updateStatusIcon(connected: false)
        state.stringValue = "正在连接 · \(host)"
        state.textColor = .secondaryLabelColor
        state.toolTip = nil
        updated.stringValue = "等待首次数据 · 每 2 秒刷新"
        for row in rows.values { row.1.stringValue = "等待数据"; row.2.stringValue = "— W" }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }
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
