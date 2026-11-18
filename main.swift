// AirSnap — trigger iPhone/iPad Continuity Camera via a customizable global
// hotkey (default ⌥⌘C) or menu bar, store briefly in a private per-user temp
// folder, strip GPS EXIF, copy image to clipboard, and safely paste.

import AppKit
import ApplicationServices
import Carbon
import ImageIO
import ServiceManagement

// MARK: - Per-User Private Temp Directory & Logging

func darwinUserTempDir() -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let len = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
    if len > 0 {
        let dir = String(cString: buf)
        if !dir.isEmpty { return dir }
    }
    return NSTemporaryDirectory()
}

let privateTempBase = (darwinUserTempDir() as NSString).appendingPathComponent("airsnap-runtime")
let logPath: String = {
    try? FileManager.default.createDirectory(
        atPath: privateTempBase,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return (privateTempBase as NSString).appendingPathComponent("airsnap.log")
}()

let logQueue: FileHandle? = {
    FileManager.default.createFile(
        atPath: logPath,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
    )
    return FileHandle(forWritingAtPath: logPath)
}()

func emit(_ s: String, to h: FileHandle) {
    guard let d = (s + "\n").data(using: .utf8) else { return }
    try? h.write(contentsOf: d)
    try? logQueue?.write(contentsOf: d)
}

func log(_ s: String) { emit(s, to: FileHandle.standardOutput) }
func warn(_ s: String) { emit(s, to: FileHandle.standardError) }

// MARK: - Accessibility & Window Helpers

func focusedWindowTitle(pid: pid_t) -> String? {
    guard pid > 0, AXIsProcessTrusted() else { return nil }
    let appEl = AXUIElementCreateApplication(pid)
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
          let winEl = winRef,
          CFGetTypeID(winEl) == AXUIElementGetTypeID() else {
        return nil
    }
    var titleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(winEl as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
          let title = titleRef as? String else {
        return nil
    }
    return title
}

// MARK: - Image Privacy & Format Helpers

/// Strips sensitive GPS/location metadata from image data without re-encoding pixels.
func stripGPSMetadata(_ data: Data) -> Data {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let uti = CGImageSourceGetType(src) else {
        return data
    }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else {
        return data
    }
    let removeProps: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: NSNull()
    ]
    CGImageDestinationAddImageFromSource(dest, src, 0, removeProps as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        return data
    }
    return out as Data
}

/// Renders an upright PNG representation (baking EXIF orientation into pixels).
func uprightPNGData(from data: Data) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        return nil
    }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, cgImg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - HotKey KeyCode Mapping

enum HotKeyHelper {
    static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_C)
    static let defaultModifiers: UInt32 = UInt32(optionKey | cmdKey)

    private static let keyNames: [UInt16: (label: String, equiv: String)] = [
        0: ("A", "a"), 11: ("B", "b"), 8: ("C", "c"), 2: ("D", "d"),
        14: ("E", "e"), 3: ("F", "f"), 5: ("G", "g"), 4: ("H", "h"),
        34: ("I", "i"), 38: ("J", "j"), 40: ("K", "k"), 37: ("L", "l"),
        46: ("M", "m"), 45: ("N", "n"), 31: ("O", "o"), 35: ("P", "p"),
        12: ("Q", "q"), 15: ("R", "r"), 1: ("S", "s"), 17: ("T", "t"),
        32: ("U", "u"), 9: ("V", "v"), 13: ("W", "w"), 7: ("X", "x"),
        16: ("Y", "y"), 6: ("Z", "z"),
        29: ("0", "0"), 18: ("1", "1"), 19: ("2", "2"), 20: ("3", "3"),
        21: ("4", "4"), 23: ("5", "5"), 22: ("6", "6"), 26: ("7", "7"),
        28: ("8", "8"), 25: ("9", "9"),
        49: ("Space", " "), 36: ("Return", "\r"), 48: ("Tab", "\t"),
        27: ("-", "-"), 24: ("=", "="), 33: ("[", "["), 30: ("]", "]"),
        42: ("\\", "\\"), 41: (";", ";"), 39: ("'", "'"), 43: (",", ","),
        47: (".", "."), 44: ("/", "/"), 50: ("`", "`"),
        122: ("F1", ""), 120: ("F2", ""), 99: ("F3", ""), 118: ("F4", ""),
        96: ("F5", ""), 97: ("F6", ""), 98: ("F7", ""), 100: ("F8", ""),
        101: ("F9", ""), 109: ("F10", ""), 103: ("F11", ""), 111: ("F12", ""),
    ]

    private static let fnKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        fnKeyCodes.contains(keyCode)
    }

    static func isSupportedKey(_ keyCode: UInt16) -> Bool {
        keyNames[keyCode] != nil
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func cocoaModifiers(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if (carbon & UInt32(cmdKey)) != 0 { flags.insert(.command) }
        if (carbon & UInt32(optionKey)) != 0 { flags.insert(.option) }
        if (carbon & UInt32(controlKey)) != 0 { flags.insert(.control) }
        if (carbon & UInt32(shiftKey)) != 0 { flags.insert(.shift) }
        return flags
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var out = ""
        if (modifiers & UInt32(controlKey)) != 0 { out += "⌃" }
        if (modifiers & UInt32(optionKey)) != 0 { out += "⌥" }
        if (modifiers & UInt32(shiftKey)) != 0 { out += "⇧" }
        if (modifiers & UInt32(cmdKey)) != 0 { out += "⌘" }
        out += keyNames[UInt16(keyCode)]?.label ?? "Key(\(keyCode))"
        return out
    }

    static func menuKeyEquivalent(for keyCode: UInt32) -> String {
        keyNames[UInt16(keyCode)]?.equiv ?? ""
    }
}

// MARK: - Preferences

enum AppPrefs {
    private static let domain = "com.airsnap.app" as CFString
    private static let autoPasteKey = "autoPasteEnabled" as CFString
    private static let promptedAXKey = "didPromptAccessibility" as CFString
    private static let hotKeyCodeKey = "hotKeyCode" as CFString
    private static let hotKeyModifiersKey = "hotKeyModifiers" as CFString

    static var autoPasteEnabled: Bool {
        get { (CFPreferencesCopyAppValue(autoPasteKey, domain) as? Bool) ?? true }
        set {
            CFPreferencesSetAppValue(autoPasteKey, newValue as CFBoolean, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    static var didPromptAccessibility: Bool {
        get { (CFPreferencesCopyAppValue(promptedAXKey, domain) as? Bool) ?? false }
        set {
            CFPreferencesSetAppValue(promptedAXKey, newValue as CFBoolean, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    static var hotKeyCode: UInt32 {
        get {
            if let num = CFPreferencesCopyAppValue(hotKeyCodeKey, domain) as? NSNumber {
                return num.uint32Value
            }
            return HotKeyHelper.defaultKeyCode
        }
        set {
            CFPreferencesSetAppValue(hotKeyCodeKey, NSNumber(value: newValue), domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    static var hotKeyModifiers: UInt32 {
        get {
            if let num = CFPreferencesCopyAppValue(hotKeyModifiersKey, domain) as? NSNumber {
                return num.uint32Value
            }
            return HotKeyHelper.defaultModifiers
        }
        set {
            CFPreferencesSetAppValue(hotKeyModifiersKey, NSNumber(value: newValue), domain)
            CFPreferencesAppSynchronize(domain)
        }
    }
}

// MARK: - Shortcut Recorder Window

final class HotKeyCaptureBox: NSView {
    var onCaptured: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?
    var onInvalidHint: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }

        let kc = event.keyCode
        let mods = HotKeyHelper.carbonModifiers(from: event.modifierFlags)
        let hasPrimaryMod = (mods & UInt32(cmdKey | optionKey | controlKey)) != 0

        guard HotKeyHelper.isSupportedKey(kc) else {
            onInvalidHint?("暂不支持该按键，请使用字母、数字、空格或 F1–F12")
            return
        }
        guard hasPrimaryMod || HotKeyHelper.isFunctionKey(kc) else {
            onInvalidHint?("请配合 ⌘ / ⌥ / ⌃ 组合键，或使用 F1–F12")
            return
        }

        onCaptured?(UInt32(kc), mods)
    }
}

final class HotKeyWindowController: NSWindowController, NSWindowDelegate {
    private var statusLabel: NSTextField!
    private var currentLabel: NSTextField!
    private let onApply: (UInt32, UInt32) -> Bool
    private let onClose: () -> Void

    init(onApply: @escaping (UInt32, UInt32) -> Bool, onClose: @escaping () -> Void) {
        self.onApply = onApply
        self.onClose = onClose

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 184),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "AirSnap 快捷键设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildUI(in panel: NSPanel) {
        let root = NSView(frame: panel.contentView!.bounds)
        panel.contentView = root

        currentLabel = NSTextField(labelWithString: "当前快捷键：\(HotKeyHelper.displayString(keyCode: AppPrefs.hotKeyCode, modifiers: AppPrefs.hotKeyModifiers))")
        currentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        currentLabel.alignment = .center
        currentLabel.frame = NSRect(x: 20, y: 142, width: 300, height: 20)
        root.addSubview(currentLabel)

        let captureBox = HotKeyCaptureBox(frame: NSRect(x: 30, y: 82, width: 280, height: 48))
        let prompt = NSTextField(labelWithString: "请直接按下新的快捷键组合（Esc 取消）")
        prompt.font = .systemFont(ofSize: 12.5)
        prompt.textColor = .labelColor
        prompt.alignment = .center
        prompt.frame = NSRect(x: 8, y: 15, width: 264, height: 18)
        captureBox.addSubview(prompt)

        captureBox.onCaptured = { [weak self] kc, mods in
            guard let self else { return }
            if self.onApply(kc, mods) {
                self.close()
            } else {
                self.statusLabel.stringValue = "\(HotKeyHelper.displayString(keyCode: kc, modifiers: mods)) 已被系统占用，请换一个组合"
                self.statusLabel.textColor = .systemRed
            }
        }
        captureBox.onCancel = { [weak self] in self?.close() }
        captureBox.onInvalidHint = { [weak self] msg in
            self?.statusLabel.stringValue = msg
            self?.statusLabel.textColor = .systemOrange
        }
        root.addSubview(captureBox)

        statusLabel = NSTextField(labelWithString: "推荐单手组合：⌥⌘C、⌃⌥A、⌥⌘A 或 F6")
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 16, y: 54, width: 308, height: 18)
        root.addSubview(statusLabel)

        let resetBtn = NSButton(title: "恢复默认 (⌥⌘C)", target: self, action: #selector(onReset))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: 30, y: 14, width: 140, height: 28)
        root.addSubview(resetBtn)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(onCancelBtn))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 230, y: 14, width: 80, height: 28)
        root.addSubview(cancelBtn)
    }

    @objc private func onReset() {
        if onApply(HotKeyHelper.defaultKeyCode, HotKeyHelper.defaultModifiers) {
            close()
        } else {
            statusLabel.stringValue = "默认快捷键 ⌥⌘C 当前被系统占用"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func onCancelBtn() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Config (Worker Mode)

struct Config {
    static let defaultOutDir = (privateTempBase as NSString).appendingPathComponent("captures")

    var workerMode = false
    var action = "photo"                 // photo | scan
    var outDir = Config.defaultOutDir
    var deviceHint = "iPhone"
    var dryRun = false
    var dryRunHold: TimeInterval = 1.6
    var autoTrigger = true
    var contextMenuMode = false
    var selfTest = false
    var clipboard = true
    var clipTest: String?
    var paste = AppPrefs.autoPasteEnabled
    var captureTimeout: TimeInterval = 90
    var targetPID: pid_t = 0
    var targetTitle: String?

    static func resolveOutDir(_ explicit: String?) -> String {
        if let d = explicit, !d.isEmpty { return NSString(string: d).expandingTildeInPath }
        if let d = CFPreferencesCopyAppValue("outDir" as CFString, "com.airsnap.app" as CFString) as? String,
           !d.isEmpty {
            return NSString(string: d).expandingTildeInPath
        }
        return Config.defaultOutDir
    }

    static func parse() -> Config {
        var c = Config()
        var explicitOut: String?
        var explicitPaste: Bool?
        var args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--worker": c.workerMode = true
            case "photo", "scan":
                c.action = a
                c.workerMode = true
            case "--out": if !args.isEmpty { explicitOut = args.removeFirst() }
            case "--device": if !args.isEmpty { c.deviceHint = args.removeFirst() }
            case "--dry-run":
                c.dryRun = true
                c.workerMode = true
            case "--hold": if !args.isEmpty { c.dryRunHold = Double(args.removeFirst()) ?? 1.6 }
            case "--context-menu":
                c.contextMenuMode = true
                c.workerMode = true
            case "--self-test":
                c.selfTest = true
                c.workerMode = true
            case "--no-clipboard": c.clipboard = false
            case "--clip-test":
                if !args.isEmpty {
                    c.clipTest = args.removeFirst()
                    c.workerMode = true
                }
            case "--paste": explicitPaste = true
            case "--no-paste": explicitPaste = false
            case "--no-auto": c.autoTrigger = false
            case "--timeout": if !args.isEmpty { c.captureTimeout = Double(args.removeFirst()) ?? 90 }
            case "--target-pid":
                if !args.isEmpty, let pid = pid_t(args.removeFirst()) { c.targetPID = pid }
            case "--target-title":
                if !args.isEmpty {
                    let t = args.removeFirst()
                    c.targetTitle = t.isEmpty ? nil : t
                }
            default: break
            }
        }
        if let explicitPaste { c.paste = explicitPaste }
        c.outDir = resolveOutDir(explicitOut)
        return c
    }

    var actionTitles: [String] {
        action == "photo"
            ? ["Take Photo", "사진 찍기", "拍照", "拍摄照片"]
            : ["Scan Documents", "문서 스캔", "扫描文稿", "扫描文檔"]
    }
}

// MARK: - Receiver TextView & Invisible Window

final class CaptureTextView: NSTextView {
    var logCount = 0
    var onMenuBuilt: ((NSMenu) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event)
        if let m { onMenuBuilt?(m) }
        return m
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if logCount < 12 {
            logCount += 1
            warn("validRequestor: send=\(sendType?.rawValue ?? "-") return=\(returnType?.rawValue ?? "-")")
        }
        if let rt = returnType,
           NSImage.imageTypes.contains(rt.rawValue) || rt.rawValue == "com.adobe.pdf" {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Menu Bar Host

final class MenuBarHost: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activeWorker: Process?
    private var lastExternalApp: NSRunningApplication?
    private var hotKeyController: HotKeyWindowController?
    private var hotKeyOK = false
    private var lockFD: Int32 = -1

    private var captureMenuItem: NSMenuItem!
    private var configKeyMenuItem: NSMenuItem!
    private var autoPasteMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        guard acquireSingleHostLock() else {
            NSApp.terminate(nil)
            return
        }

        if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != getpid() {
            lastExternalApp = current
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self.lastExternalApp = app
        }

        NSApp.setActivationPolicy(.accessory)
        installCarbonHandler()
        hotKeyOK = registerHotKey(code: AppPrefs.hotKeyCode, modifiers: AppPrefs.hotKeyModifiers)
        setupStatusBar()
        refreshMenuStates()
    }

    func applicationWillTerminate(_ note: Notification) {
        activeWorker?.terminate()
        unregisterHotKey()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if lockFD >= 0 { close(lockFD) }
    }

    private func acquireSingleHostLock() -> Bool {
        let path = (privateTempBase as NSString).appendingPathComponent("airsnap-host.lock")
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard err == noErr, hkID.id == 1 else { return noErr }
                let host = Unmanaged<MenuBarHost>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { host.triggerCapture(action: "photo") }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        if status != noErr {
            warn("InstallEventHandler failed: \(status)")
        }
    }

    @discardableResult
    private func registerHotKey(code: UInt32, modifiers: UInt32) -> Bool {
        unregisterHotKey()
        let hotKeyID = EventHotKeyID(signature: OSType(0x41534E50), id: 1) // 'ASNP'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            code,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            return true
        }
        warn("RegisterEventHotKey(\(HotKeyHelper.displayString(keyCode: code, modifiers: modifiers))) failed: \(status)")
        return false
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(capturing: false)

        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: "从 iPhone 拍照", action: #selector(onTakePhoto), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(captureMenuItem)

        let scanItem = NSMenuItem(title: "从 iPhone 扫描文档 (PDF)", action: #selector(onScanDoc), keyEquivalent: "")
        scanItem.target = self
        menu.addItem(scanItem)

        menu.addItem(.separator())

        configKeyMenuItem = NSMenuItem(title: "设置快捷键…", action: #selector(onConfigureHotKey), keyEquivalent: "")
        configKeyMenuItem.target = self
        menu.addItem(configKeyMenuItem)

        autoPasteMenuItem = NSMenuItem(title: "拍完自动写入当前对话框", action: #selector(onToggleAutoPaste), keyEquivalent: "")
        autoPasteMenuItem.target = self
        menu.addItem(autoPasteMenuItem)

        loginItemMenuItem = NSMenuItem(title: "开机自动启动", action: #selector(onToggleLoginItem), keyEquivalent: "")
        loginItemMenuItem.target = self
        menu.addItem(loginItemMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 AirSnap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        menu.delegate = self

        statusItem.menu = menu
    }

    private func setStatusIcon(capturing: Bool) {
        guard let btn = statusItem?.button else { return }
        let symbol = capturing ? "camera.metering.center.weighted" : "camera.viewfinder"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AirSnap")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "AirSnap")
        img?.isTemplate = true
        btn.image = img
        btn.toolTip = capturing ? "AirSnap — 正在等待 iPhone 拍照…" : "AirSnap (\(HotKeyHelper.displayString(keyCode: AppPrefs.hotKeyCode, modifiers: AppPrefs.hotKeyModifiers)))"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStates()
    }

    private func refreshMenuStates() {
        let code = AppPrefs.hotKeyCode
        let mods = AppPrefs.hotKeyModifiers
        let display = HotKeyHelper.displayString(keyCode: code, modifiers: mods)
        let equiv = HotKeyHelper.menuKeyEquivalent(for: code)

        captureMenuItem.title = hotKeyOK ? "从 iPhone 拍照" : "从 iPhone 拍照 (\(display) 被占用)"
        if !equiv.isEmpty {
            captureMenuItem.keyEquivalent = equiv
            captureMenuItem.keyEquivalentModifierMask = HotKeyHelper.cocoaModifiers(from: mods)
        } else {
            captureMenuItem.keyEquivalent = ""
            captureMenuItem.keyEquivalentModifierMask = []
            captureMenuItem.title = hotKeyOK ? "从 iPhone 拍照 (\(display))" : "从 iPhone 拍照 (\(display) 被占用)"
        }

        configKeyMenuItem.title = "设置快捷键… (\(display))"

        let axOK = AXIsProcessTrusted()
        autoPasteMenuItem.state = AppPrefs.autoPasteEnabled ? .on : .off
        autoPasteMenuItem.title = (AppPrefs.autoPasteEnabled && !axOK)
            ? "拍完自动写入当前对话框 (需辅助功能权限)"
            : "拍完自动写入当前对话框"
        loginItemMenuItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        setStatusIcon(capturing: activeWorker?.isRunning == true)
    }

    @objc private func onTakePhoto() { triggerCapture(action: "photo") }
    @objc private func onScanDoc() { triggerCapture(action: "scan") }

    @objc private func onConfigureHotKey() {
        if let existing = hotKeyController {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        unregisterHotKey()
        let prevCode = AppPrefs.hotKeyCode
        let prevMods = AppPrefs.hotKeyModifiers

        let ctrl = HotKeyWindowController(
            onApply: { [weak self] newCode, newMods in
                guard let self else { return false }
                if self.registerHotKey(code: newCode, modifiers: newMods) {
                    AppPrefs.hotKeyCode = newCode
                    AppPrefs.hotKeyModifiers = newMods
                    self.hotKeyOK = true
                    self.refreshMenuStates()
                    return true
                }
                return false
            },
            onClose: { [weak self] in
                guard let self else { return }
                if self.hotKeyRef == nil {
                    self.hotKeyOK = self.registerHotKey(code: prevCode, modifiers: prevMods)
                }
                self.hotKeyController = nil
                self.refreshMenuStates()
            }
        )
        hotKeyController = ctrl
        NSApp.activate(ignoringOtherApps: true)
        ctrl.showWindow(nil)
        ctrl.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func onToggleAutoPaste() {
        let next = !AppPrefs.autoPasteEnabled
        AppPrefs.autoPasteEnabled = next
        if next && !AXIsProcessTrusted() {
            AppPrefs.didPromptAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        refreshMenuStates()
    }

    @objc private func onToggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            warn("SMAppService toggle failed: \(error.localizedDescription)")
        }
        refreshMenuStates()
    }

    func triggerCapture(action: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let resolvedApp = (front?.processIdentifier != getpid()) ? front : lastExternalApp
        let targetPID: pid_t = resolvedApp?.processIdentifier ?? 0
        let targetTitle = focusedWindowTitle(pid: targetPID) ?? ""

        if let prev = activeWorker, prev.isRunning {
            prev.terminate()
        }

        guard let exePath = Bundle.main.executablePath else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exePath)
        var args = ["--worker", action]
        if targetPID > 0 {
            args += ["--target-pid", "\(targetPID)", "--target-title", targetTitle]
        }
        args.append(AppPrefs.autoPasteEnabled ? "--paste" : "--no-paste")
        proc.arguments = args
        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                if self?.activeWorker === finished {
                    self?.activeWorker = nil
                    self?.setStatusIcon(capturing: false)
                }
            }
        }

        do {
            try proc.run()
            activeWorker = proc
            setStatusIcon(capturing: true)
        } catch {
            warn("failed to launch capture worker: \(error.localizedDescription)")
            setStatusIcon(capturing: false)
        }
    }
}

// MARK: - Capture Worker Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextViewDelegate {
    var config: Config
    var window: NSWindow!
    var textView: CaptureTextView!
    var menu: NSMenu!
    var targetApp: NSRunningApplication?
    var invoked = false
    var received = false
    var ticks = 0

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationWillFinishLaunching(_ note: Notification) {
        terminatePreviousWorkerIfNeeded()

        if config.targetPID > 0 {
            targetApp = NSRunningApplication(processIdentifier: config.targetPID)
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != getpid() {
                targetApp = front
            }
        }
        if config.targetTitle == nil, let pid = targetApp?.processIdentifier {
            config.targetTitle = focusedWindowTitle(pid: pid)
        }

        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "AirSnap")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let magic = NSMenuItem(title: "Import from Device", action: nil, keyEquivalent: "")
        magic.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(magic)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let returnTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
            + [NSPasteboard.PasteboardType("com.adobe.pdf")]
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = config.contextMenuMode
            ? NSRect(x: screen.midX - 150, y: screen.midY - 60, width: 300, height: 120)
            : NSRect(x: screen.midX, y: screen.midY, width: 1, height: 1)

        window = KeyableWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0.001
        window.ignoresMouseEvents = !config.contextMenuMode
        window.level = .normal

        textView = CaptureTextView(frame: NSRect(origin: .zero, size: rect.size))
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .clear
        textView.isRichText = true
        textView.isEditable = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.delegate = self
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(someWindowClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + config.captureTimeout) { [weak self] in
            guard let self, !self.received else { return }
            warn("timeout: no capture received in \(Int(self.config.captureTimeout))s")
            self.dismissWindowAndRestoreTarget()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
        }

        if !config.dryRun && !config.selfTest && !config.contextMenuMode {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: config.outDir, withIntermediateDirectories: true)
            let probe = config.outDir + "/.airsnap-write-test"
            if !fm.createFile(atPath: probe, contents: Data()) {
                warn("cannot write to \(config.outDir)")
                NSSound(named: "Basso")?.play()
                dismissWindowAndRestoreTarget()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                return
            }
            try? fm.removeItem(atPath: probe)
        }

        if let testFile = config.clipTest {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: testFile)), saveData(d, suggestedName: nil) {
                return
            }
            warn("clip-test failed for \(testFile)")
            dismissWindowAndRestoreTarget()
            NSApp.terminate(nil)
        } else if config.contextMenuMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.popImportMenu() }
        } else if config.selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.selfTest() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.triggerFromMainMenu(attempt: 1) }
        }
    }

    private func terminatePreviousWorkerIfNeeded() {
        guard !config.selfTest else { return }
        let pidPath = (privateTempBase as NSString).appendingPathComponent("airsnap-worker.pid")
        if let raw = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let oldPid = pid_t(raw),
           oldPid > 1,
           oldPid != getpid(),
           let app = NSRunningApplication(processIdentifier: oldPid),
           app.bundleIdentifier == Bundle.main.bundleIdentifier {
            kill(oldPid, SIGTERM)
        }
        try? "\(getpid())\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    private func dismissWindowAndRestoreTarget() {
        textView?.string = ""
        for w in NSApp.windows {
            w.orderOut(nil)
        }
        NSApp.hide(nil)
        if let target = targetApp, target.processIdentifier != getpid() {
            target.activate(options: [])
        }
    }

    // MARK: - Headless Main Menu Trigger

    func triggerFromMainMenu(attempt: Int) {
        func retryOrFail(_ reason: String) {
            if attempt < 15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.triggerFromMainMenu(attempt: attempt + 1)
                }
            } else {
                warn("\(reason) — device not nearby/unlocked?")
                NSSound(named: "Basso")?.play()
                dismissWindowAndRestoreTarget()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
            }
        }

        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu,
              let magic = fileMenu.items.first(where: { $0.submenu != nil }),
              let sub = magic.submenu else {
            retryOrFail("import submenu never attached")
            return
        }
        sub.update()

        var best: Int?
        outer: for pass in 0..<2 {
            for (i, item) in sub.items.enumerated() {
                guard !item.isSeparatorItem, item.isEnabled,
                      config.actionTitles.contains(item.title) else { continue }
                if pass == 0 && !sectionMatchesDevice(owner: sub, idx: i) { continue }
                best = i; break outer
            }
        }
        guard let idx = best else {
            retryOrFail("no available '\(config.actionTitles[0])' item")
            return
        }
        log("ready after \(attempt) attempt(s) (~\(Double(attempt) * 0.2)s)")
        let item = sub.items[idx]
        log("firing '\(item.title)' (index \(idx))")
        invoked = true
        sub.performActionForItem(at: idx)
    }

    func selfTest() {
        log("outDir: \(config.outDir)")
        log("target: \(targetApp?.localizedName ?? "?") (\(targetApp?.bundleIdentifier ?? "?"))")
        log("accessibility: \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        log("paste enabled: \(config.paste)")
        guard let fileMenu = NSApp.mainMenu?.item(at: 1)?.submenu else {
            dismissWindowAndRestoreTarget()
            NSApp.terminate(nil)
            return
        }
        log("before update(): \(describe(fileMenu))")
        fileMenu.update()
        log("after update(): \(describe(fileMenu))")
        for item in fileMenu.items where item.submenu != nil {
            item.submenu!.update()
            log("submenu '\(item.title)' after update(): \(describe(item.submenu!))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            log("after 1.5s: \(self.describe(fileMenu))")
            for item in fileMenu.items where item.submenu != nil {
                log("  submenu '\(item.title)': \(self.describe(item.submenu!))")
            }
            self.dismissWindowAndRestoreTarget()
            NSApp.terminate(nil)
        }
    }

    func describe(_ m: NSMenu) -> String {
        m.items.map { "'\($0.title)'\($0.submenu != nil ? "+sub" : "")\($0.isEnabled ? "" : "(off)")" }.joined(separator: ", ")
    }

    // MARK: - Context Menu Fallback

    func popImportMenu() {
        textView.onMenuBuilt = { [weak self] m in
            guard let self else { return }
            self.menu = m
            m.delegate = self
            m.allowsContextMenuPlugIns = true
        }

        let t = Timer(timeInterval: 0.4, target: self, selector: #selector(menuTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .eventTracking)

        let pt = NSPoint(x: 150, y: 60)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: pt,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: Int.random(in: 1000...9999), clickCount: 1, pressure: 1
            )!
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.window.sendEvent(mouse(.rightMouseUp))
        }
        window.sendEvent(mouse(.rightMouseDown))
    }

    @objc func menuTick(_ t: Timer) {
        ticks += 1
        if invoked || received { t.invalidate(); return }
        guard menu != nil else {
            if ticks >= 8 {
                t.invalidate()
                if config.dryRun {
                    dismissWindowAndRestoreTarget()
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if config.autoTrigger {
            if tryTrigger() {
                t.invalidate()
            } else if ticks > 25 {
                t.invalidate()
            }
        }
    }

    func tryTrigger() -> Bool {
        var candidates: [(NSMenu, Int)] = []
        for (i, item) in menu.items.enumerated() {
            if let sub = item.submenu {
                for j in sub.items.indices { candidates.append((sub, j)) }
            }
            candidates.append((menu, i))
        }
        for pass in 0..<2 {
            for (owner, idx) in candidates {
                let item = owner.items[idx]
                guard !item.isSeparatorItem, item.isEnabled,
                      config.actionTitles.contains(item.title) else { continue }
                if pass == 0 && !sectionMatchesDevice(owner: owner, idx: idx) { continue }
                invoked = true
                menu.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    owner.performActionForItem(at: idx)
                }
                return true
            }
        }
        return false
    }

    func sectionMatchesDevice(owner: NSMenu, idx: Int) -> Bool {
        var i = idx - 1
        while i >= 0 {
            let it = owner.items[i]
            if it.isSeparatorItem { return false }
            if it.title.localizedCaseInsensitiveContains(config.deviceHint) { return true }
            i -= 1
        }
        return false
    }

    @objc func someWindowClosed(_ note: Notification) {
        guard invoked, !received, let w = note.object as? NSWindow, w !== window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if !self.received {
                warn("capture panel closed without data (cancelled)")
                self.dismissWindowAndRestoreTarget()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if !invoked && !config.dryRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.invoked && !self.received {
                    self.dismissWindowAndRestoreTarget()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Capture Arrival & Saving

    @objc func textStorageDidChange(_ note: Notification) {
        guard !received, let storage = textView.textStorage, storage.length > 0 else { return }
        DispatchQueue.main.async { self.extractAttachments() }
    }

    func extractAttachments() {
        guard !received, let storage = textView.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let att = value as? NSTextAttachment else { return }
            if saveAttachment(att) { stop.pointee = true }
        }
    }

    func saveAttachment(_ att: NSTextAttachment) -> Bool {
        var data: Data?
        var suggestedName: String?
        if let fw = att.fileWrapper, fw.isRegularFile {
            data = fw.regularFileContents
            suggestedName = fw.preferredFilename
        } else if let contents = att.contents {
            data = contents
        }
        guard let d = data, !d.isEmpty else { return false }
        return saveData(d, suggestedName: suggestedName)
    }

    func saveData(_ d: Data, suggestedName: String?) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: config.outDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if config.outDir == Config.defaultOutDir {
            if let items = try? fm.contentsOfDirectory(atPath: config.outDir) {
                for item in items {
                    try? fm.removeItem(atPath: "\(config.outDir)/\(item)")
                }
            }
        }

        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd_HHmmss"
            return f.string(from: Date())
        }()

        var ext = "bin"
        var base = config.action == "scan" ? "Scan_\(stamp)" : "IMG_\(stamp)"
        if d.starts(with: [0xFF, 0xD8, 0xFF]) { ext = "jpg" }
        else if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { ext = "png" }
        else if d.starts(with: [0x25, 0x50, 0x44, 0x46]) { ext = "pdf"; base = "Scan_\(stamp)" }
        else if let name = suggestedName, let e = name.split(separator: ".").last { ext = String(e).lowercased() }

        if ext == "bin" || ext == "heic" {
            if let rep = NSBitmapImageRep(data: d),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                return write(stripGPSMetadata(jpg), to: "IMG_\(stamp)", ext: "jpg")
            }
        }
        let cleaned = (ext == "jpg" || ext == "png") ? stripGPSMetadata(d) : d
        return write(cleaned, to: base, ext: ext)
    }

    func write(_ d: Data, to base: String, ext: String) -> Bool {
        let fm = FileManager.default
        var p = "\(config.outDir)/\(base).\(ext)"
        var n = 1
        while fm.fileExists(atPath: p) { p = "\(config.outDir)/\(base)-\(n).\(ext)"; n += 1 }
        do {
            try d.write(to: URL(fileURLWithPath: p), options: .atomic)
        } catch {
            warn("write failed: \(error.localizedDescription)")
            return false
        }
        received = true
        log("saved: \(p)")

        if config.clipboard {
            copyToClipboard(d, path: p)
        }

        dismissWindowAndRestoreTarget()

        if config.clipboard && config.paste {
            performSafePaste()
        } else {
            NSSound(named: "Glass")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSApp.terminate(nil) }
        }
        return true
    }

    func copyToClipboard(_ d: Data, path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)

        if d.starts(with: [0xFF, 0xD8, 0xFF]) {
            item.setData(d, forType: NSPasteboard.PasteboardType("public.jpeg"))
            if let png = uprightPNGData(from: d) {
                item.setData(png, forType: .png)
            }
        } else if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            item.setData(d, forType: .png)
        } else if d.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            item.setData(d, forType: NSPasteboard.PasteboardType("com.adobe.pdf"))
        }

        pb.writeObjects([item])
        log("clipboard: \(item.types.map(\.rawValue).joined(separator: ", "))")
    }

    // MARK: - Safe Auto-Paste

    func performSafePaste() {
        guard AXIsProcessTrusted() else {
            if !AppPrefs.didPromptAccessibility {
                AppPrefs.didPromptAccessibility = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            warn("accessibility not granted — copied to clipboard only (paste manually with ⌘V)")
            NSSound(named: "Glass")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSApp.terminate(nil) }
            return
        }

        guard let target = targetApp else {
            NSSound(named: "Glass")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSApp.terminate(nil) }
            return
        }

        waitForTargetActiveAndPaste(target: target, attempt: 0)
    }

    private func waitForTargetActiveAndPaste(target: NSRunningApplication, attempt: Int) {
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        if !isFront && attempt < 24 {
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                self.waitForTargetActiveAndPaste(target: target, attempt: attempt + 1)
            }
            return
        }

        if let expectedTitle = config.targetTitle, !expectedTitle.isEmpty,
           let currentTitle = focusedWindowTitle(pid: target.processIdentifier), !currentTitle.isEmpty,
           currentTitle != expectedTitle {
            warn("aborted auto-paste: window changed from '\(expectedTitle)' to '\(currentTitle)'")
            NSSound(named: "Pop")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSApp.terminate(nil) }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // kVK_ANSI_V
            vDown?.flags = .maskCommand
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            log("pasted into \(target.localizedName ?? "?")")
            NSSound(named: "Glass")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Entry Point

let parsedConfig = Config.parse()
let app = NSApplication.shared

if parsedConfig.workerMode {
    let delegate = AppDelegate(config: parsedConfig)
    app.delegate = delegate
    app.run()
} else {
    let host = MenuBarHost()
    app.delegate = host
    app.run()
}
