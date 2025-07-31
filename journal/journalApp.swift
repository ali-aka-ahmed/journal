//
//  journalApp.swift
//  journal
//
//  Created by thorfinn on 2/14/25.
//

import SwiftUI

@main
struct journalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("colorScheme") private var colorSchemeString: String = "light"
    
    init() {
        // Register Lato font
        if let fontURL = Bundle.main.url(forResource: "Lato-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }
     
    var body: some Scene {
        WindowGroup {
            ContentView()
                .toolbar(.hidden, for: .windowToolbar)
                .preferredColorScheme(colorSchemeString == "dark" ? .dark : .light)
        }
        .windowStyle(.hiddenTitleBar)        
        .defaultSize(width: 1100, height: 600)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    // Send notification to toggle sidebar
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleSidebar"), object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            
            CommandGroup(after: .windowArrangement) {
                Button("Full Screen") {
                    // Send notification to toggle fullscreen
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleFullscreen"), object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

// Add AppDelegate to handle window configuration
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            // Ensure window starts in windowed mode
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            
            // Center the window on the screen
            window.center()
        }
    }
} 
