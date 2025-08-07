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
            CommandGroup(replacing: .newItem) {
                Button("New Entry") {
                    // Send notification to create new entry
                    NotificationCenter.default.post(name: NSNotification.Name("CreateNewEntry"), object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
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
            
            CommandGroup(after: .appSettings) {
                Button("Toggle Settings Modal") {
                    // Send notification to toggle settings
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleSettings"), object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

// Add AppDelegate to handle window configuration
class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        // Register for all possible termination signals
        setupTerminationHandlers()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            // Ensure window starts in windowed mode
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            
            // Center the window on the screen
            window.center()
        }
        
        // Start Ollama server if user has local mode selected
        startOllamaIfNeeded()
    }
    
    private func startOllamaIfNeeded() {
        // Load settings to check LLM mode
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Journal")
        let settingsURL = documentsDirectory.appendingPathComponent("Settings.json")
        
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return // No settings file exists yet
        }
        
        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            
            // Only start Ollama if user has local mode selected
            if settings.llmMode == "local" {
                DispatchQueue.global(qos: .background).async {
                    OllamaManager.shared.ensureServerRunning { success, error in
                        if success {
                            print("✅ Ollama server started successfully at app launch")
                            // Fetch available models
                            OllamaManager.shared.fetchAvailableModels { _ in }
                        } else {
                            print("❌ Failed to start Ollama server at app launch: \(error ?? "Unknown error")")
                        }
                    }
                }
            }
        } catch {
            print("Error loading settings for Ollama startup: \(error)")
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Stop the Ollama server when the app is terminating
        print("🔴 App terminating, stopping Ollama server...")
        OllamaManager.shared.stopServer()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ensure cleanup happens before app quits
        print("🔴 App preparing to terminate, cleaning up Ollama server...")
        OllamaManager.shared.forceStopServer()
        return .terminateNow
    }
    
    // Additional cleanup for when app becomes inactive
    func applicationDidResignActive(_ notification: Notification) {
        // Optional: Could add logic here if you want to stop server when app goes to background
        // For now, we'll keep it running for better user experience
    }
    
    // Setup handlers for all possible termination scenarios
    private func setupTerminationHandlers() {
        // Handle SIGTERM (normal termination)
        signal(SIGTERM) { _ in
            print("🔴 Received SIGTERM, killing Ollama server...")
            AppDelegate.emergencyCleanup()
            exit(0)
        }
        
        // Handle SIGINT (Ctrl+C, force quit)
        signal(SIGINT) { _ in
            print("🔴 Received SIGINT, killing Ollama server...")
            AppDelegate.emergencyCleanup()
            exit(0)
        }
        
        // Handle SIGHUP (terminal closed)
        signal(SIGHUP) { _ in
            print("🔴 Received SIGHUP, killing Ollama server...")
            AppDelegate.emergencyCleanup()
            exit(0)
        }
        
        // Handle SIGQUIT (quit signal)
        signal(SIGQUIT) { _ in
            print("🔴 Received SIGQUIT, killing Ollama server...")
            AppDelegate.emergencyCleanup()
            exit(0)
        }
        
        // Register for window close notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        
        // Use atexit for absolute final cleanup
        atexit {
            AppDelegate.emergencyCleanup()
        }
    }
    
    // Handle window close (X button)
    @objc func windowWillClose(_ notification: Notification) {
        print("🔴 Main window closing, killing Ollama server...")
        AppDelegate.emergencyCleanup()
        
        // Check if this is the last window
        if NSApplication.shared.windows.count <= 1 {
            print("🔴 Last window closing, terminating app...")
            NSApplication.shared.terminate(nil)
        }
    }
    
    // Emergency cleanup that must ALWAYS work
    static func emergencyCleanup() {
        let manager = OllamaManager.shared
        
        // Get the PID if we have a process
        if let process = manager.serverProcess {
            let pid = process.processIdentifier
            print("🔴 Emergency cleanup: Killing Ollama PID \(pid)")
            
            // Force kill the process immediately
            kill(pid, SIGKILL)
            
            // Also try system kill as backup
            let killTask = Process()
            killTask.executableURL = URL(fileURLWithPath: "/bin/kill")
            killTask.arguments = ["-9", "\(pid)"]
            try? killTask.run()
            
            print("🔴 Emergency cleanup completed for PID \(pid)")
        } else {
            print("🔴 Emergency cleanup: No Ollama process found")
        }
        
        // Clean up the manager state
        manager.serverProcess = nil
        manager.isServerRunning = false
    }
} 
