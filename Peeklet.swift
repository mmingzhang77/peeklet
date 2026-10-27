import AppKit
import Foundation
import UniformTypeIdentifiers

// A local, non-activating, press-to-peek viewer. No networking, keyboard
// monitoring, screen recording, accessibility automation, or account access.
struct PeekSession {
    enum Phase { case hidden, armed, visible }
    private(set) var phase: Phase = .hidden
    private var startedAt: TimeInterval = 0
    let holdDelay: TimeInterval = 0.16
    let maximumHold: TimeInterval = 10

    mutating func begin(at now: TimeInterval) {
        startedAt = now
        phase = .armed
    }

    mutating func end() { phase = .hidden }

    mutating func update(at now: TimeInterval, buttonDown: Bool,
                         pointerInside: Bool) -> Phase {
        guard phase != .hidden else { return .hidden }
        guard buttonDown, pointerInside, now - startedAt < maximumHold else {
            end()
            return .hidden
        }
        if now - startedAt >= holdDelay { phase = .visible }
        return phase
    }
}

struct Photo {
    let image: NSImage
    var sourceRect: NSRect {
        NSRect(origin: .zero, size: image.size)
    }
}

func fittedRect(_ rectangle: NSRect, within available: NSRect) -> NSRect {
    let width = min(rectangle.width, available.width)
    let height = min(rectangle.height, available.height)
    return NSRect(x: min(max(rectangle.minX, available.minX), available.maxX - width),
                  y: min(max(rectangle.minY, available.minY), available.maxY - height),
                  width: width, height: height)
}

enum ViewerLayout {
    // These are logical screen points, just like the macOS desktop icon setting.
    static let entranceEdges: [CGFloat] = [24, 36, 44]
    static let defaultEntranceIndex = 1
    // Stay above ordinary full-screen presentation windows, but below system
    // pop-up menus and screen-saver/security surfaces. Never use screenSaver.
    static let portraitLevel = NSWindow.Level.statusBar
    static let entranceLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let portraitSizes = [NSSize(width: 150, height: 225),
                                NSSize(width: 180, height: 270),
                                NSSize(width: 230, height: 345)]
}

enum OrbCorner: Int, CaseIterable {
    case upperLeft, upperRight, lowerLeft, lowerRight

    var title: String {
        switch self {
        case .upperLeft: return "Upper left"
        case .upperRight: return "Upper right"
        case .lowerLeft: return "Lower left"
        case .lowerRight: return "Lower right"
        }
    }

    func rectangle(size: NSSize, within available: NSRect) -> NSRect {
        let margin: CGFloat = 12
        let onRight = self == .upperRight || self == .lowerRight
        let onTop = self == .upperLeft || self == .upperRight
        let x = onRight ? available.maxX - size.width - margin : available.minX + margin
        let y = onTop ? available.maxY - size.height - margin : available.minY + margin
        return fittedRect(NSRect(x: x, y: y, width: size.width, height: size.height),
                          within: available)
    }
}

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(rectangle: NSRect, level: NSWindow.Level) {
        super.init(contentRect: rectangle,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
                              .canJoinAllApplications, .ignoresCycle]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        title = "Peeklet"
    }
}

final class PortraitView: NSView {
    var photo: Photo? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.06, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        guard let photo = photo else { return }
        let imageArea = bounds.insetBy(dx: 4, dy: 4)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageArea, xRadius: 8, yRadius: 8).addClip()
        NSColor.black.setFill()
        imageArea.fill()
        let source = photo.sourceRect
        let scale = min(imageArea.width / source.width, imageArea.height / source.height)
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        let destination = NSRect(x: imageArea.midX - size.width / 2,
                                 y: imageArea.midY - size.height / 2,
                                 width: size.width, height: size.height)
        photo.image.draw(in: destination, from: source, operation: .sourceOver,
                         fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class OrbView: NSView {
    weak var controller: ViewerController?
    var locating = false { didSet { needsDisplay = true } }
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var downEvent: NSEvent?
    private var dragging = false
    private var pressed = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var lastScroll: TimeInterval = 0
    private(set) var pointerInside = false
    private(set) var usePhysicalPolling = false
    var holding: Bool { pressed && !dragging }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Hold to view, release to hide; scroll to switch; drag to move; right-click for options")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? {
        let frame = window?.frame ?? self.frame
        let activeSpace = window?.isOnActiveSpace == true ? "current space" : "another space"
        let visibility = window?.occlusionState.contains(.visible) == true ? "visible" : "occluded"
        let appState = NSApp.isHidden ? "application hidden" : "application shown"
        return "Entrance \(Int(frame.width)) × \(Int(frame.height)); \(activeSpace); \(visibility); \(appState)"
    }

    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        // A faint filled hit area keeps the borderless window clickable, without
        // making the visible mark or its hover decoration desktop-icon-sized.
        let emphasized = hovered || (pressed && !dragging)
        NSColor(calibratedWhite: locating ? 0.16 : 0.5,
                alpha: locating ? 0.95 : (emphasized ? 0.10 : 0.035)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let width: CGFloat = emphasized ? 14 : 12
        let height: CGFloat = 3
        NSColor(calibratedWhite: locating ? 0.92 : 0.52,
                alpha: (locating || emphasized) ? 0.90 : 0.42).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - width / 2,
                                       y: bounds.midY - height / 2,
                                       width: width, height: height),
                     xRadius: height / 2, yRadius: height / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        downEvent = event
        pointerInside = true
        // Trust our own mouse-down/up events. Global mouse state is an extra
        // fail-safe only when physical input was actually observed at mouse-down.
        usePhysicalPolling = NSEvent.pressedMouseButtons & 1 != 0
        dragging = false
        pressed = true
        needsDisplay = true
        controller?.beginPeek()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed || dragging, let panel = window else { return }
        // Use the event's coordinates, rather than sampling the desktop pointer.
        // This also handles targeted input that does not move that pointer.
        let location = panel.convertPoint(toScreen: event.locationInWindow)
        let dx = location.x - startMouse.x
        let dy = location.y - startMouse.y
        guard dragging || hypot(dx, dy) > 4 else { return }
        if !dragging {
            // Cancel before the native hand-off: mouse-up may not return here.
            dragging = true
            pressed = false
            controller?.endPeek()
            needsDisplay = true
            if let originalEvent = downEvent, NSEvent.pressedMouseButtons & 1 != 0 {
                panel.performDrag(with: originalEvent)
            }
            downEvent = nil
        }
        // A local fallback for environments that continue delivering drag
        // events instead of letting the Window Server take over the gesture.
        controller?.moveOrb(to: NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
        pressed = false
        dragging = false
        usePhysicalPolling = false
        needsDisplay = true
        controller?.endPeek()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hovered = false
        needsDisplay = true
        controller?.endPeek()
    }

    override func scrollWheel(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScroll > 0.2, abs(event.scrollingDeltaY) > 0.2 else { return }
        lastScroll = now
        controller?.cyclePhoto()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.endPeek()
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // Assistive clicks open options, never reveal a private photo accidentally.
    override func accessibilityPerformPress() -> Bool { showOptions() }
    override func accessibilityPerformShowMenu() -> Bool { showOptions() }

    private func showOptions() -> Bool {
        controller?.endPeek()
        guard let menu = controller?.makeMenu() else { return false }
        return menu.popUp(positioning: nil,
                          at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
    }
}

final class ViewerController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let library: PhotoLibrary
    private let orbPanel: PassivePanel
    private let portraitPanel: PassivePanel
    private let orb: OrbView
    private let portrait: PortraitView
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var session = PeekSession()
    private var observers: [NSObjectProtocol] = []
    private(set) var selectedIndex = 0
    private var selectedSize = 0
    private var selectedEntrance = ViewerLayout.defaultEntranceIndex

    init(library: PhotoLibrary) {
        self.library = library
        let edge = ViewerLayout.entranceEdges[ViewerLayout.defaultEntranceIndex]
        let initialPhotoSize = ViewerLayout.portraitSizes[0]
        orbPanel = PassivePanel(rectangle: NSRect(x: 0, y: 0, width: edge, height: edge),
                                level: ViewerLayout.entranceLevel)
        portraitPanel = PassivePanel(rectangle: NSRect(origin: .zero, size: initialPhotoSize),
                                     level: ViewerLayout.portraitLevel)
        orb = OrbView(frame: NSRect(x: 0, y: 0, width: edge, height: edge))
        portrait = PortraitView(frame: NSRect(origin: .zero, size: initialPhotoSize))
        super.init()
        orb.controller = self
        orbPanel.contentView = orb
        orbPanel.hasShadow = false
        orbPanel.ignoresMouseEvents = false
        orbPanel.isMovable = true
        orbPanel.isMovableByWindowBackground = false
        portraitPanel.contentView = portrait
        portraitPanel.ignoresMouseEvents = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Peeklet")
        statusItem?.button?.toolTip = "Peeklet"
        restoreEntrance()

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.willSleepNotification,
                                         NSWorkspace.screensDidSleepNotification,
                                         NSWorkspace.sessionDidResignActiveNotification,
                                         NSWorkspace.activeSpaceDidChangeNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.endPeek()
            })
        }
        // No inspection of the activating application's identity or windows.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.endPeek()
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Finder double-click must do something even if the agent is already
        // running, the entrance is hidden, or it has been moved out of sight.
        restoreEntrance()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        endPeek()
    }

    private func restoreEntrance() {
        endPeek()
        resetPosition()
        NSApp.unhideWithoutActivation()
        orbPanel.orderFrontRegardless()
        orb.locating = true
        refreshMenu()
    }

    func beginPeek() {
        endPeek()
        // An empty library is a normal first-run state, not a reason to open
        // a file picker or produce a blank floating panel.
        guard library.count > 0 else { return }
        session.begin(at: ProcessInfo.processInfo.systemUptime)
        let poll = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            self?.updatePeek()
        }
        timer = poll
        RunLoop.main.add(poll, forMode: .common)
    }

    private func updatePeek() {
        let physicalDown = NSEvent.pressedMouseButtons & 1 != 0
        let buttonDown = orb.holding && (!orb.usePhysicalPolling || physicalDown)
        let inside = orb.usePhysicalPolling
            ? orbPanel.frame.contains(NSEvent.mouseLocation) : orb.pointerInside
        let phase = session.update(at: ProcessInfo.processInfo.systemUptime,
                                   buttonDown: buttonDown, pointerInside: inside)
        switch phase {
        case .hidden: endPeek()
        case .armed: break
        case .visible:
            if !portraitPanel.isVisible {
                guard selectedIndex >= 0, selectedIndex < library.count else { endPeek(); return }
                do {
                    let image = try library.image(at: selectedIndex)
                    guard placePortrait() else { endPeek(); return }
                    orb.locating = false
                    portrait.photo = Photo(image: image)
                    portraitPanel.orderFrontRegardless()
                } catch {
                    endPeek()
                    showError("The selected photo could not be opened.")
                }
            }
        }
    }

    func endPeek() {
        session.end()
        timer?.invalidate()
        timer = nil
        portraitPanel.orderOut(nil)
        // Remove the image from the hidden view, not just its on-screen opacity.
        portrait.photo = nil
    }

    func moveOrb(to point: NSPoint) {
        let candidate = NSRect(origin: point, size: orbPanel.frame.size)
        guard let screen = screenFor(point: NSPoint(x: candidate.midX, y: candidate.midY)) else { return }
        orbPanel.setFrame(fittedRect(candidate, within: screen.visibleFrame), display: true)
    }

    private func screenFor(point: NSPoint) -> NSScreen? {
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func placePortrait() -> Bool {
        let frame = orbPanel.frame
        guard let screen = screenFor(point: NSPoint(x: frame.midX, y: frame.midY)) else { return false }
        let width = ViewerLayout.portraitSizes[selectedSize].width
        let height = ViewerLayout.portraitSizes[selectedSize].height
        let x = frame.midX > screen.visibleFrame.midX ? frame.minX - width - 10 : frame.maxX + 10
        let proposed = NSRect(x: x, y: frame.midY - height / 2, width: width, height: height)
        let fitted = fittedRect(proposed, within: screen.visibleFrame.insetBy(dx: 8, dy: 8))
        portraitPanel.setFrame(fitted, display: true)
        portrait.frame = NSRect(origin: .zero, size: fitted.size)
        return true
    }

    func cyclePhoto() {
        guard library.count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % library.count
        if portraitPanel.isVisible {
            do { portrait.photo = Photo(image: try library.image(at: selectedIndex)) }
            catch { endPeek(); showError("The selected photo could not be opened.") }
        }
        orb.needsDisplay = true
        refreshMenu()
    }

    private func refreshMenu() { statusItem?.menu = makeMenu() }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let add = NSMenuItem(title: "Add Photos…", action: #selector(addPhotos), keyEquivalent: "")
        add.target = self
        add.isEnabled = library.count < 30
        menu.addItem(add)
        for index in 0..<library.count {
            let item = NSMenuItem(title: "Photo \(index + 1)", action: #selector(selectPhoto(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selectedIndex == index ? .on : .off
            menu.addItem(item)
        }
        let remove = NSMenuItem(title: "Remove Current Photo…", action: #selector(removeCurrentPhoto), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = library.count > 0
        menu.addItem(remove)
        let removeAll = NSMenuItem(title: "Remove All Photos…", action: #selector(removeAllPhotos), keyEquivalent: "")
        removeAll.target = self
        removeAll.isEnabled = library.count > 0
        menu.addItem(removeAll)
        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Preview Size", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (index, title) in ["Small · 150 × 225", "Medium · 180 × 270", "Large · 230 × 345"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selectedSize == index ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        let entranceItem = NSMenuItem(title: "Entrance Size", action: nil, keyEquivalent: "")
        let entrances = NSMenu()
        for (index, title) in ["Small · 24 × 24", "Default · 36 × 36", "Large · 44 × 44"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectEntrance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selectedEntrance == index ? .on : .off
            entrances.addItem(item)
        }
        entranceItem.submenu = entrances
        menu.addItem(entranceItem)
        let quiet = NSMenuItem(title: orb.locating ? "Use Subtle Appearance" : "Use Bright Appearance",
                               action: #selector(quietOrb), keyEquivalent: "")
        quiet.target = self
        menu.addItem(quiet)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Peeklet", action: #selector(quitViewer), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { endPeek() }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Peeklet"
        // Never display an underlying file-system error containing a path.
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func addPhotos() {
        endPeek()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Add Photos to Peeklet"
        panel.message = "Choose JPEG, PNG, HEIC or TIFF images. Peeklet keeps local copies."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        // Open panels grant temporary sandbox access to the chosen URLs.
        defer { for url in urls { url.stopAccessingSecurityScopedResource() } }
        guard !urls.isEmpty else { return }
        do {
            let previousCount = library.count
            try library.importPhotos(from: urls)
            if library.count > previousCount { selectedIndex = previousCount }
        } catch {
            showError("Could not add these photos. Choose up to 30 supported images, each no larger than 50 MB and 100 megapixels.")
        }
        refreshMenu()
    }

    private func confirmRemoval(all: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = all ? "Remove all imported photos?" : "Remove the current imported photo?"
        alert.informativeText = "Peeklet will remove its imported copies. Your original photos will not be changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func afterRemoval() {
        selectedIndex = max(0, min(selectedIndex, library.count - 1))
        refreshMenu()
    }

    @objc private func removeCurrentPhoto() {
        endPeek()
        guard selectedIndex >= 0, selectedIndex < library.count, confirmRemoval(all: false) else { return }
        do { try library.remove(at: selectedIndex) }
        catch { showError("The imported copy could not be removed completely. Please try again.") }
        afterRemoval()
    }

    @objc private func removeAllPhotos() {
        endPeek()
        guard library.count > 0, confirmRemoval(all: true) else { return }
        do { try library.removeAll() }
        catch { showError("The imported copies could not be removed completely. Please try again.") }
        afterRemoval()
    }

    @objc private func selectPhoto(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < library.count else { return }
        endPeek()
        selectedIndex = sender.tag
        orb.needsDisplay = true
        refreshMenu()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard ViewerLayout.portraitSizes.indices.contains(sender.tag) else { return }
        endPeek()
        selectedSize = sender.tag
        refreshMenu()
    }

    @objc private func selectEntrance(_ sender: NSMenuItem) {
        guard ViewerLayout.entranceEdges.indices.contains(sender.tag) else { return }
        endPeek()
        selectedEntrance = sender.tag
        let oldFrame = orbPanel.frame
        let edge = ViewerLayout.entranceEdges[selectedEntrance]
        let proposed = NSRect(x: oldFrame.midX - edge / 2, y: oldFrame.midY - edge / 2,
                              width: edge, height: edge)
        guard let screen = screenFor(point: NSPoint(x: oldFrame.midX, y: oldFrame.midY)) else { return }
        orbPanel.setFrame(fittedRect(proposed, within: screen.visibleFrame), display: true)
        orb.frame = NSRect(origin: .zero, size: orbPanel.frame.size)
        refreshMenu()
    }

    private func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        orbPanel.setFrame(OrbCorner.upperRight.rectangle(size: orbPanel.frame.size,
                                                        within: screen.visibleFrame), display: true)
    }

    @objc private func quietOrb() {
        orb.locating.toggle()
        refreshMenu()
    }

    @objc private func quitViewer() { NSApp.terminate(nil) }
}

@main
struct PeekletApp {
    static func main() {
        do {
            if CommandLine.arguments.contains("--self-test") {
                try runSelfTests()
                return
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let library = try PhotoLibrary.openDefault()
            let delegate = ViewerController(library: library)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            // Keep file paths and original photo names out of diagnostics.
            fputs("Peeklet could not start or complete its tests.\n", stderr)
            if !CommandLine.arguments.contains("--self-test") {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Peeklet Could Not Start"
                alert.informativeText = "The photo library could not be read. Your existing library has not been replaced."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            exit(1)
        }
    }
}
