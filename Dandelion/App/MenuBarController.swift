//
//  MenuBarController.swift
//  Dandelion
//
//  Owns the NSStatusItem and the custom borderless NSPanel that hosts the
//  SwiftUI dashboard. Deliberately avoids NSMenu so the panel can draw
//  arbitrary SwiftUI content (ring gauges, custom fonts/colors). Also owns
//  the shared services/view models so the status bar summary label and the
//  panel/Settings window all reflect the same refreshed state.
//

import AppKit
import SwiftUI
import Observation

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var globalMouseDownMonitor: Any?

    private let appSettings = AppSettings()
    private let catalogViewModel = ModelCatalogViewModel()
    private lazy var zenBalanceViewModel = ZenBalanceViewModel(appSettings: appSettings)
    private lazy var goUsageViewModel = GoUsageViewModel(appSettings: appSettings)
    private lazy var refreshCoordinator = RefreshCoordinator(
        appSettings: appSettings,
        catalogViewModel: catalogViewModel,
        zenBalanceViewModel: zenBalanceViewModel,
        goUsageViewModel: goUsageViewModel
    )

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "circle.hexagongrid.circle",
                accessibilityDescription: "Dandelion"
            )
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        statusItem = item

        Task { await refreshCoordinator.refreshNow() }
    }

    @objc
    private func togglePanel(_ sender: Any?) {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel

        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func makePanel() -> NSPanel {
        let content = DashboardPanel(
            appSettings: appSettings,
            catalogViewModel: catalogViewModel,
            zenBalanceViewModel: zenBalanceViewModel,
            goUsageViewModel: goUsageViewModel,
            refreshCoordinator: refreshCoordinator,
            onOpenSettings: { [weak self] in self?.showSettingsWindow() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingController = NSHostingController(rootView: content)

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        let contentSize = panel.contentViewController?.view.fittingSize ?? panel.frame.size
        panel.setContentSize(contentSize)

        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)

        let panelSize = panel.frame.size
        let originX = screenFrame.midX - panelSize.width / 2
        let originY = screenFrame.minY - panelSize.height - 4
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseDownMonitor = nil
        }
    }

    // MARK: Settings window

    private func showSettingsWindow() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() -> NSWindow {
        let content = SettingsView(
            appSettings: appSettings,
            refreshCoordinator: refreshCoordinator,
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Dandelion Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        return window
    }
}
