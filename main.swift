import Cocoa

// Pure usage logic (pricing, parsing, aggregation, formatting) lives in
// UsageCore.swift and is exercised by Tests.swift.

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let monthSymbols = DateFormatter().monthSymbols ?? []

    private var menuOpen = false
    private var statusItem: NSStatusItem!
    private let scanner = UsageScanner()
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "com.ellerywee.claudeusagebar.scan")
    private var scanning = false          // touched on main thread only
    private let refreshInterval: TimeInterval = 5
    private var entState: EnterpriseState = .notConfigured
    private var entTimer: Timer?
    private let entQueue = DispatchQueue(label: "com.ellerywee.claudeusagebar.enterprise")
    private var entFetching = false                  // main-thread only
    private let entInterval: TimeInterval = 1800     // 30 min
    private var entLastGood: OrgRollup?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Single instance: if another copy is already running, bow out so we never
        // show two menu-bar icons. Guard on a non-nil bundle id — when the bare
        // binary is run directly (e.g. while debugging) the id is nil, and matching
        // `bundleIdentifier == nil` would wrongly match unrelated daemons and make us
        // self-terminate. Only enforce when launched from the .app bundle.
        let me = NSRunningApplication.current
        if let myID = me.bundleIdentifier {
            let others = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == myID && $0.processIdentifier != me.processIdentifier
            }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persist the item's menu-bar position. Without this, dragging it out from
        // behind the notch (Cmd-drag) wouldn't survive a relaunch.
        statusItem.autosaveName = "com.ellerywee.claudeusagebar.item"
        statusItem.isVisible = true
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude usage")
            b.image?.isTemplate = true
            b.imagePosition = .imageLeading
            b.title = " …"
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        refresh()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)   // keep firing while the menu is open
        timer = t

        refreshEnterprise()
        let et = Timer(timeInterval: entInterval, repeats: true) { [weak self] _ in self?.refreshEnterprise() }
        et.tolerance = 60
        RunLoop.main.add(et, forMode: .common)
        entTimer = et
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc private func refresh() {
        // Serialize: skip if a scan is still running (first scan can take ~20s).
        guard !scanning else { return }
        scanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let entries = self.scanner.scan()
            let now = Date()
            let block = activeBlock(entries, now: now)
            let today = todayTotals(entries, now: now)
            let month = monthTotals(entries, now: now)
            DispatchQueue.main.async {
                self.scanning = false
                self.render(block: block, today: today, month: month, now: now)
            }
        }
    }

    private func render(block: BlockResult, today: Totals, month: Totals, now: Date) {
        // Menu bar title: current block cost (or today if idle). Always update — cheap
        // and doesn't disturb an open menu.
        let title = block.isActive ? " \(fmtCost(block.totals.cost))" : " \(fmtCost(today.cost))·d"
        statusItem.button?.title = title

        // Don't swap the menu while the user has it open (it would dismiss it);
        // the next refresh after they close it will show fresh numbers.
        if menuOpen { return }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // keep info rows full-contrast (not greyed as "disabled")

        menu.addItem(header("CURRENT 5-HOUR BLOCK"))
        if block.isActive {
            menu.addItem(row("Cost (API-equiv)", fmtCost(block.totals.cost)))
            if let reset = block.resetAt {
                menu.addItem(row("Resets in", fmtRemaining(reset, now: now)))
            }
            addTokenBreakdown(block.totals, to: menu)
            addModelBreakdown(block.totals, to: menu)
        } else {
            menu.addItem(info("Idle — no active block"))
        }

        menu.addItem(.separator())
        menu.addItem(header("TODAY"))
        menu.addItem(row("Cost (API-equiv)", fmtCost(today.cost)))
        addTokenBreakdown(today, to: menu)
        addModelBreakdown(today, to: menu)

        menu.addItem(.separator())
        menu.addItem(header("MONTH TO DATE — \(monthName(now).uppercased())"))
        menu.addItem(row("Cost (API-equiv)", fmtCost(month.cost)))
        menu.addItem(row("Projected month", fmtCost(projectedMonthCost(month.cost, now: now))))
        addTokenBreakdown(month, to: menu)
        addModelBreakdown(month, to: menu)

        menu.addItem(.separator())
        addEnterpriseSection(to: menu)

        menu.addItem(.separator())
        menu.addItem(info("Costs are API list-price equivalent,"))
        menu.addItem(info("not your subscription charge."))
        let updated = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium)
        menu.addItem(info("Updated \(updated)"))
        let r = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        if AnalyticsKeyStore.load() != nil {
            let c = NSMenuItem(title: "Clear Analytics key", action: #selector(clearAnalyticsKey), keyEquivalent: "")
            c.target = self
            menu.addItem(c)
        }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func monthName(_ now: Date) -> String {
        let idx = Calendar.current.component(.month, from: now) - 1
        return Self.monthSymbols.indices.contains(idx) ? Self.monthSymbols[idx] : ""
    }

    private func addTokenBreakdown(_ t: Totals, to menu: NSMenu) {
        menu.addItem(row("  Input", fmtTokens(t.input)))
        menu.addItem(row("  Output", fmtTokens(t.output)))
        menu.addItem(row("  Cache write", fmtTokens(t.cacheWrite)))
        menu.addItem(row("  Cache read", fmtTokens(t.cacheRead)))
        menu.addItem(row("Tokens (total)", fmtTokens(t.tokens)))
    }

    private func addModelBreakdown(_ t: Totals, to menu: NSMenu) {
        let models = t.byModel.sorted { $0.value.cost > $1.value.cost }
        for (name, v) in models {
            menu.addItem(info("   \(name): \(fmtTokens(v.tokens)) · \(fmtCost(v.cost))"))
        }
    }

    private func header(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return it
    }

    private func row(_ label: String, _ value: String) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = NSAttributedString(string: "\(label)   \(value)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        ])
        return it
    }

    private func info(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return it
    }

    @objc private func refreshEnterprise() {
        guard !entFetching else { return }
        guard let key = AnalyticsKeyStore.load() else {
            entState = .notConfigured
            return
        }
        entFetching = true
        let lastGood = entLastGood            // capture on main; don't read self.entLastGood off-thread
        entQueue.async { [weak self] in
            guard let self else { return }
            let client = URLSessionAnalyticsClient(apiKey: key)
            let state = fetchEnterpriseState(client, now: Date(), lastGood: lastGood)
            DispatchQueue.main.async {
                self.entFetching = false
                if case .ok(let r) = state { self.entLastGood = r }
                self.entState = state
                if !self.menuOpen { self.refresh() }
            }
        }
    }

    private func addEnterpriseSection(to menu: NSMenu) {
        switch entState {
        case .notConfigured:
            menu.addItem(header("ENTERPRISE"))
            menu.addItem(info("Not configured"))
            let set = NSMenuItem(title: "Set Analytics key…", action: #selector(setAnalyticsKey), keyEquivalent: "")
            set.target = self
            menu.addItem(set)
        case .authFailed:
            menu.addItem(header("ENTERPRISE"))
            menu.addItem(info("Auth failed — re-set key"))
            let set = NSMenuItem(title: "Set Analytics key…", action: #selector(setAnalyticsKey), keyEquivalent: "")
            set.target = self
            menu.addItem(set)
        case .offline(let lg):
            renderRollup(lg, to: menu, offline: true)
        case .ok(let r):
            renderRollup(r, to: menu, offline: false)
        }
    }

    private func renderRollup(_ rollup: OrgRollup?, to menu: NSMenu, offline: Bool) {
        guard let r = rollup else {
            menu.addItem(header("ENTERPRISE"))
            menu.addItem(info(offline ? "Offline — no data yet" : "No data"))
            return
        }
        menu.addItem(header("ENTERPRISE — MONTH TO DATE"))
        menu.addItem(row("Seats", "\(r.seatsAssigned) assigned · \(r.dau) active today"))
        menu.addItem(row("Active users", "DAU \(r.dau) · WAU \(r.wau) · MAU \(r.mau)"))
        if let req = r.requests { menu.addItem(row("Requests", fmtTokens(req))) }
        if let t = r.tokens { menu.addItem(row("Tokens", fmtTokens(t))) }
        menu.addItem(row("Cost", r.cost.map { fmtCost($0) } ?? "n/a"))
        if !r.activeSeats.isEmpty {
            menu.addItem(info("Active seats"))
            let capped = topSeats(r.activeSeats, limit: 10)
            for s in capped.shown {
                let label = s.name ?? s.email ?? s.userId
                let tok = s.tokens.map { fmtTokens($0) } ?? "—"
                let cost = s.cost.map { fmtCost($0) } ?? "—"
                menu.addItem(info("   \(label)   \(tok) · \(cost)"))
            }
            if capped.more > 0 { menu.addItem(info("   … +\(capped.more) more")) }
        }
        var asOf = "—"
        if let d = r.asOf { asOf = DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none) }
        let suffix = offline ? " · offline" : " · engagement ~3d lag"
        menu.addItem(info("As of \(asOf)\(suffix)"))
    }

    @objc private func setAnalyticsKey() {
        let alert = NSAlert()
        alert.messageText = "Enterprise Analytics key"
        alert.informativeText = "Paste a read:analytics key (sk-ant-api01-…). Stored only in your Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-ant-api01-") else {
            let bad = NSAlert(); bad.messageText = "That doesn't look like a read:analytics key (expected sk-ant-api01-…)."
            bad.runModal(); return
        }
        AnalyticsKeyStore.save(key)
        refreshEnterprise()
    }

    @objc private func clearAnalyticsKey() {
        AnalyticsKeyStore.clear()
        entLastGood = nil
        entState = .notConfigured
        refresh()
    }
}

// Debug: `ClaudeUsageBar --once` prints totals to stdout and exits (no GUI).
if CommandLine.arguments.contains("--once") {
    let entries = UsageScanner().scan()
    let now = Date()
    let block = activeBlock(entries, now: now)
    let today = todayTotals(entries, now: now)
    let month = monthTotals(entries, now: now)
    print("entries parsed: \(entries.count)")
    print("--- 5h block (active=\(block.isActive)) ---")
    if let r = block.resetAt { print("reset: \(r)  in \(fmtRemaining(r, now: now))") }
    print("cost: \(fmtCost(block.totals.cost))  tokens: \(fmtTokens(block.totals.tokens))")
    print("--- today ---  cost: \(fmtCost(today.cost))  tokens: \(fmtTokens(today.tokens))")
    print("--- month ---  cost: \(fmtCost(month.cost))  proj: \(fmtCost(projectedMonthCost(month.cost, now: now)))")
    exit(0)
}

if CommandLine.arguments.contains("--once-enterprise") {
    let withPII = CommandLine.arguments.contains("--with-pii")
    guard let key = AnalyticsKeyStore.load() else { print("enterprise: not configured (no key)"); exit(0) }
    let state = fetchEnterpriseState(URLSessionAnalyticsClient(apiKey: key), now: Date(), lastGood: nil)
    switch state {
    case .notConfigured: print("enterprise: not configured")
    case .authFailed: print("enterprise: auth failed")
    case .offline: print("enterprise: offline / fetch failed")
    case .ok(let r):
        print("enterprise: seats=\(r.seatsAssigned) dau=\(r.dau) wau=\(r.wau) mau=\(r.mau)")
        print("  requests=\(r.requests.map(String.init) ?? "—") tokens=\(r.tokens.map(fmtTokens) ?? "—") cost=\(r.cost.map(fmtCost) ?? "n/a")")
        print("  active seats: \(r.activeSeats.count)")
        if withPII {
            for s in topSeats(r.activeSeats, limit: 10).shown {
                print("    \(s.name ?? s.email ?? s.userId)  \(s.tokens.map(fmtTokens) ?? "—") · \(s.cost.map(fmtCost) ?? "—")")
            }
        } else {
            print("  (names hidden; pass --with-pii to show)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
