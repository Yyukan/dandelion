//
//  DandelionApp.swift
//  Dandelion
//
//  Menu bar only app entry point: no Dock icon, no main window - the
//  NSApplicationDelegate boots the MenuBarController which owns the
//  NSStatusItem and the custom dashboard panel.
//

import SwiftUI

@main
struct DandelionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window group is needed for a menu-bar-only app; Settings is a
        // no-op placeholder so SwiftUI's App protocol has at least one scene.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarController = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController.start()
    }
}
