// TortoiseBar — macOS menu-bar front-end for the tortoise CLI.
//
// The bash CLI (scripts/tortoise/tortoise.sh) is the single source of truth: it owns the
// dummynet/pf shaping and writes its state to /tmp/tortoise.d. This app only:
//   • polls that state dir (cheap, no privileges) to show what's active,
//   • shows a menu-bar icon — subtle when idle, red + count when shaping is on,
//   • runs the embedded tortoise.sh through the native admin prompt for on/off.
//
// Self-contained: build.sh embeds a copy of tortoise.sh + README.md into the .app bundle.

import AppKit

let STATE_DIR = "/tmp/tortoise.d"
let PRESETS = ["perfect", "office-wifi", "home", "coffee-shop", "conference-wifi",
               "flaky", "slow-4g", "slow-3g", "very-slow", "super-slow"]

struct Entry {
    let id: String
    let host: String
    let preset: String
    let bw: String
    let delay: String
    let plr: String
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var entries: [Entry] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()   // gives the app standard Cut/Copy/Paste so ⌘V works in the input
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // A minimal main menu. LSUIElement apps have none by default, which is why ⌘C/⌘V/⌘A
    // don't reach the text field. These standard selectors route through the responder chain.
    func buildMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - state

    func scriptPath() -> String {
        Bundle.main.path(forResource: "tortoise", ofType: "sh") ?? "/usr/local/bin/tortoise.sh"
    }

    // Built-in presets + any the user defined in the shared config (live; matches the CLI).
    func presetNames() -> [String] {
        var names = PRESETS
        let path = ProcessInfo.processInfo.environment["TORTOISE_PRESETS"]
            ?? (NSHomeDirectory() + "/.config/tortoise/presets.conf")
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") { continue }
                if let name = t.split(separator: " ").first.map(String.init), !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names
    }

    func readEntries() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: STATE_DIR) else { return [] }
        var result: [Entry] = []
        for f in files where f.hasPrefix("host_") && f.hasSuffix(".conf") {
            guard let content = try? String(contentsOfFile: STATE_DIR + "/" + f, encoding: .utf8)
            else { continue }
            var kv: [String: String] = [:]
            for line in content.split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") {
                    kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
                }
            }
            if let host = kv["host"] {
                result.append(Entry(id: kv["id"] ?? "?", host: host, preset: kv["preset"] ?? "?",
                                    bw: kv["bw"] ?? "", delay: kv["delay"] ?? "", plr: kv["plr"] ?? ""))
            }
        }
        return result.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    func refresh() {
        entries = readEntries()
        let active = !entries.isEmpty
        if let button = statusItem.button {
            let symbol = active ? "tortoise.fill" : "tortoise"
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tortoise")
            img?.isTemplate = !active
            button.image = img
            button.imagePosition = .imageLeading
            button.title = active ? " \(entries.count)" : ""
            button.contentTintColor = active ? NSColor.systemRed : nil
            button.toolTip = active
                ? "Tortoise — slowing \(entries.count) site\(entries.count == 1 ? "" : "s")"
                : "Tortoise — off (network is normal)"
        }
        rebuildMenu(active: active)
    }

    // MARK: - menu

    func rtt(_ delay: String) -> String { Int(delay).map { "\($0 * 2)ms" } ?? "\(delay)ms" }
    func lossPct(_ plr: String) -> String { Double(plr).map { "\(Int($0 * 100))%" } ?? plr }

    func rebuildMenu(active: Bool) {
        let menu = NSMenu()

        let header = NSMenuItem(
            title: active
                ? "Slowing \(entries.count) site\(entries.count == 1 ? "" : "s")"
                : "Network is at normal speed",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if active {
            for e in entries {
                let item = NSMenuItem(title: "●  \(e.host) — \(e.preset)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let detail = NSMenuItem(
                    title: "\(e.bw), \(rtt(e.delay)) RTT, \(lossPct(e.plr)) loss",
                    action: nil, keyEquivalent: "")
                detail.isEnabled = false
                sub.addItem(detail)
                sub.addItem(.separator())
                // preset picker — click another to switch this domain instantly (✓ = current)
                for p in presetNames() {
                    let pi = NSMenuItem(title: p, action: #selector(switchPreset(_:)), keyEquivalent: "")
                    pi.target = self
                    pi.representedObject = ["host": e.host, "preset": p]
                    pi.state = (p == e.preset) ? .on : .off
                    sub.addItem(pi)
                }
                sub.addItem(.separator())
                let off = NSMenuItem(title: "Back to normal: \(e.host)",
                                     action: #selector(turnOffDomain(_:)), keyEquivalent: "")
                off.target = self
                off.representedObject = e.host
                sub.addItem(off)
                item.submenu = sub
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let offAll = NSMenuItem(title: "Back to normal (all sites)", action: #selector(turnOffAll), keyEquivalent: "")
            offAll.target = self
            menu.addItem(offAll)
            menu.addItem(.separator())
        }

        let add = NSMenuItem(title: "Slow down a site…", action: nil, keyEquivalent: "")
        let addSub = NSMenu()
        for p in presetNames() {
            let pItem = NSMenuItem(title: p, action: #selector(addShaping(_:)), keyEquivalent: "")
            pItem.target = self
            pItem.representedObject = p
            addSub.addItem(pItem)
        }
        add.submenu = addSub
        menu.addItem(add)

        menu.addItem(.separator())
        // Define a reusable custom speed (params only — apply it to sites separately).
        let newPreset = NSMenuItem(title: "New custom speed…", action: #selector(newCustomPreset), keyEquivalent: "")
        newPreset.target = self
        menu.addItem(newPreset)
        let readme = NSMenuItem(title: "Open README", action: #selector(openReadme), keyEquivalent: "")
        readme.target = self
        menu.addItem(readme)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - actions

    @objc func turnOffDomain(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        runPrivileged(["off", host])
    }

    @objc func turnOffAll() { runPrivileged(["off", "all"]) }

    @objc func switchPreset(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: String],
              let host = d["host"], let preset = d["preset"] else { return }
        runPrivileged(["on", preset, host])   // 'on' replaces the domain's current preset
    }

    @objc func addShaping(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Slow down a site — \(preset)"
        alert.informativeText = "Enter the website address to slow down (e.g. example.com).\nFor local dev, use the backend address, not localhost:3000."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "example.com"
        field.isEditable = true
        field.isSelectable = true
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field   // focus the field so typing/paste land in it
        if alert.runModal() == .alertFirstButtonReturn {
            let domain = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !domain.isEmpty { runPrivileged(["on", preset, domain]) }
        }
    }

    // Define a REUSABLE custom preset (params only — no domain). It then shows up in every
    // preset menu, applyable to any domain(s) like a built-in. Defining needs no admin rights.
    @objc func newCustomPreset() {
        let nameField  = NSTextField(); nameField.placeholderString  = "office"
        let bwField    = NSTextField(); bwField.placeholderString    = "20Mbit/s"
        let delayField = NSTextField(); delayField.placeholderString = "40"
        let lossField  = NSTextField(); lossField.placeholderString  = "0.5"
        let rows: [(String, NSTextField)] =
            [("Name:", nameField), ("Bandwidth:", bwField), ("Delay (ms):", delayField), ("Loss (%):", lossField)]

        let rowH: CGFloat = 24, gap: CGFloat = 8, labelW: CGFloat = 90, fieldW: CGFloat = 200
        let totalH = CGFloat(rows.count) * (rowH + gap)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: labelW + 8 + fieldW, height: totalH))
        for (i, (label, field)) in rows.enumerated() {
            let y = totalH - CGFloat(i + 1) * (rowH + gap) + gap
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 0, y: y, width: labelW, height: rowH)
            l.alignment = .right
            field.frame = NSRect(x: labelW + 8, y: y, width: fieldW, height: rowH)
            field.isEditable = true; field.isSelectable = true
            container.addSubview(l); container.addSubview(field)
        }
        nameField.nextKeyView = bwField; bwField.nextKeyView = delayField
        delayField.nextKeyView = lossField; lossField.nextKeyView = nameField

        let alert = NSAlert()
        alert.messageText = "New custom speed"
        alert.informativeText = "Give it a name and the network settings — then apply it to any site afterwards (loss is a %)."
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        func t(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = t(nameField), bw = t(bwField), delay = t(delayField), loss = t(lossField)
        if name.isEmpty || bw.isEmpty || delay.isEmpty || loss.isEmpty {
            showError("Fill in all four fields."); return
        }
        if Int(delay) == nil { showError("Delay must be a whole number of milliseconds."); return }
        if Double(loss) == nil { showError("Loss must be a number (percent), e.g. 0.5 or 5."); return }
        if PRESETS.contains(name) { showError("‘\(name)’ is a built-in name — pick another."); return }
        runScript(["define", name, bw, delay, loss])   // unprivileged; refresh shows it in menus
    }

    private func showError(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Couldn’t save"
        a.informativeText = msg
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func openReadme() {
        if let p = Bundle.main.path(forResource: "README", ofType: "md") {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
    }

    // Quitting does NOT auto-stop shaping (it lives in pf, not the app), so warn if active.
    @objc func quit() {
        if entries.isEmpty { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = "\(entries.count) site\(entries.count == 1 ? " is" : "s are") still slowed."
        alert.informativeText = "Quitting won't restore them — your network stays slow until you set it back to normal."
        alert.addButton(withTitle: "Restore & Quit")
        alert.addButton(withTitle: "Quit anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                if !self.runSilent(["off", "all"]) { _ = self.runAdminSync(["off", "all"]) }
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break   // Cancel
        }
    }

    // MARK: - privileged runner — asks for the password ONCE, then never again
    //
    // First try the installed root-owned helper via passwordless sudo (no prompt). If that
    // fails (not installed yet), show ONE native admin prompt that installs the sudoers rule
    // *and* runs the requested action. Every later on/off is then silent.

    let helperPath = "/usr/local/bin/tortoise"

    func runPrivileged(_ args: [String]) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            // Use the silent helper only if it matches the version bundled in THIS app.
            // After an app update the installed helper is stale → reinstall it (one prompt),
            // so bug fixes actually reach the privileged path.
            if self.helperIsCurrent() && self.runSilent(args) {
                DispatchQueue.main.async { self.refresh() }
            } else {
                self.installThenRun(args)   // installs/refreshes the helper, then runs
            }
        }
    }

    // True iff the installed root helper is byte-identical to the script bundled in this app.
    private func helperIsCurrent() -> Bool {
        guard let bundled = try? Data(contentsOf: URL(fileURLWithPath: scriptPath())),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: helperPath))
        else { return false }
        return bundled == installed
    }

    // Unprivileged run of the embedded CLI (for `define`, which only writes the user config).
    func runScript(_ args: [String]) {
        let task = Process()
        task.launchPath = scriptPath()
        task.arguments = args
        task.standardError = Pipe(); task.standardOutput = Pipe()
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        do { try task.run() } catch { NSLog("tortoise: define failed: \(error)") }
    }

    // sudo -n: succeeds silently iff the NOPASSWD sudoers rule is already installed.
    private func runSilent(_ args: [String]) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-n", helperPath] + args
        task.standardError = Pipe(); task.standardOutput = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // One admin prompt: install passwordless control, then run the action via the helper.
    private func installThenRun(_ args: [String]) {
        func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let user = NSUserName()
        let install = ([scriptPath(), "install", user]).map(shq).joined(separator: " ")
        let action  = ([helperPath] + args).map(shq).joined(separator: " ")
        let cmd = install + " && " + action
        let appleScript = "do shell script \""
            + cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            + "\" with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        do { try task.run() } catch { NSLog("tortoise: failed to run script: \(error)") }
    }

    // Synchronous admin run (used on quit, where we must finish before terminating).
    @discardableResult
    private func runAdminSync(_ args: [String]) -> Bool {
        func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = ([helperPath] + args).map(shq).joined(separator: " ")
        let appleScript = "do shell script \""
            + cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            + "\" with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", appleScript]
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar agent: no Dock icon, no main window
app.run()
