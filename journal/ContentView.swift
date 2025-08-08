// Swift 5.0
//
//  ContentView.swift
//  journal
//
//  Created by thorfinn on 2/14/25.
//

import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
import Security
import Network

extension Color {
    static let lightModeBackground = Color(red: 247/255, green: 246/255, blue: 243/255)
    
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct HumanEntry: Identifiable {
    let id: UUID
    let date: String
    let filename: String
    var previewText: String
    
    static func createNew() -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
        let dateString = dateFormatter.string(from: now)
        
        // For display
        dateFormatter.dateFormat = "MMM d"
        let displayDate = dateFormatter.string(from: now)
        
        let dateParts = dateString.split(separator: "-")
        let dateComponent = "\(dateParts[0])-\(dateParts[1])-\(dateParts[2])"
        let timeComponent = "\(dateParts[3])-\(dateParts[4])-\(dateParts[5])"
        
        return HumanEntry(
            id: id,
            date: displayDate,
            filename: "[Daily]-[\(dateComponent)]-[\(timeComponent)].md",
            previewText: ""
        )
    }
}

enum SettingsTab: String, CaseIterable {
    case reflections = "Reflection"
    case apiKeys = "LLM"
    case transcription = "Voice"
}

enum ReflectionTimeframe {
    case week
    case month
}

// Settings data structure for JSON persistence
struct AppSettings: Codable {
    var llmMode: String // "local" or "remote"
    var selectedOllamaModel: String?
    
    static let `default` = AppSettings(
        llmMode: "remote",
        selectedOllamaModel: nil
    )
}

// Settings manager for JSON persistence
class SettingsManager: ObservableObject {
    @Published var settings: AppSettings
    private let settingsURL: URL
    
    init() {
        // Create settings file in the same directory as journal entries
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Journal")
        self.settingsURL = documentsDirectory.appendingPathComponent("Settings.json")
        
        // Ensure the Journal directory exists
        if !FileManager.default.fileExists(atPath: documentsDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
                print("Created Journal directory at: \(documentsDirectory.path)")
            } catch {
                print("Error creating Journal directory: \(error)")
            }
        }
        
        // Load existing settings or create default
        self.settings = Self.loadSettings(from: settingsURL)
        
        // Save default settings if file doesn't exist
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            saveSettings()
            print("Created default Settings.json at: \(settingsURL.path)")
        }
    }
    
    private static func loadSettings(from url: URL) -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Settings file not found, using defaults")
            return AppSettings.default
        }
        
        do {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            print("Successfully loaded settings from: \(url.path)")
            return settings
        } catch {
            print("Error loading settings: \(error), using defaults")
            return AppSettings.default
        }
    }
    
    func saveSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL)
            print("Settings saved to: \(settingsURL.path)")
        } catch {
            print("Error saving settings: \(error)")
        }
    }
    
}

struct HeartEmoji: Identifiable {
    let id = UUID()
    var position: CGPoint
    var offset: CGFloat = 0
}

// MARK: - Keychain Helper for secure API key storage
// Using Keychain instead of UserDefaults for security - API keys are encrypted and protected
class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}
    
    private let service = "com.journal.apikeys"
    
    enum KeyType: String {
        case openAI = "openai_api_key"
    }
    
    func saveAPIKey(_ key: String, for type: KeyType) {
        let data = key.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: type.rawValue,
            kSecAttrSynchronizable as String: false
        ]
        
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        
        // Try to update existing item first
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        
        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, create new one
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: type.rawValue,
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: false,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]
            
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("🔴 Failed to add API key to Keychain for account \(type.rawValue): \(addStatus)")
            } else {
                print("✅ Successfully added API key to Keychain for account \(type.rawValue)")
            }
        } else if updateStatus == errSecSuccess {
            print("✅ Successfully updated API key in Keychain for account \(type.rawValue)")
        } else {
            print("🔴 Failed to update API key in Keychain for account \(type.rawValue): \(updateStatus)")
        }
    }
    
    func loadAPIKey(for type: KeyType) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: type.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        print("🔍 KeychainHelper.loadAPIKey: status = \(status) for account \(type.rawValue)")
        
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            print("🔍 Successfully loaded API key from keychain: '\(key)'")
            return key
        } else if status == errSecItemNotFound {
            print("🔍 API key not found in keychain")
        } else {
            print("🔍 Failed to load API key from keychain: \(status)")
        }
        
        return nil
    }
    
    func isKeychainAccessDenied(for type: KeyType) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: type.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        // Check for user cancellation (keychain access denied)
        return status == -128 // errSecUserCancel
    }
    
    
    func deleteAPIKey(for type: KeyType) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: type.rawValue,
            kSecAttrSynchronizable as String: false
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        print("🗑️ KeychainHelper.deleteAPIKey: status = \(status) for account \(type.rawValue)")
        
        if status == errSecSuccess {
            print("🗑️ Successfully deleted API key from keychain")
        } else if status == errSecItemNotFound {
            print("🗑️ API key not found in keychain (already deleted)")
        } else {
            print("🗑️ Failed to delete API key from keychain: \(status)")
        }
    }
}

// MARK: - Ollama Manager for local LLM integration
class OllamaManager: ObservableObject {
    static let shared = OllamaManager()
    private init() {}
    
    @Published var availableModels: [String] = []
    @Published var isServerRunning: Bool = false
    @Published var isPulling: Bool = false
    @Published var pullProgress: String = ""
    @Published var pullPercentage: Double = 0.0
    @Published var isOllamaInstalled: Bool = true  // Assume installed initially
    @Published var isFetchingModels: Bool = false
    
    private let baseURL = "http://localhost:11434"
    internal var serverProcess: Process?
    private var pullTask: URLSessionDataTask?
    var streamBuffer = ""
    weak var settingsManager: SettingsManager?
    
    // Check if Ollama is installed
    func checkOllamaInstalled() -> Bool {
        let installed = findOllamaExecutable() != nil
        print("🔍 Checking if Ollama is installed: \(installed ? "✅ Found" : "❌ Not found")")
        return installed
    }
    
    // Check if Ollama server is running
    func checkServerStatus(completion: @escaping (Bool) -> Void) {
        print("🔍 Checking Ollama server status...")
        
        // First check if Ollama is installed
        let installed = checkOllamaInstalled()
        DispatchQueue.main.async {
            self.isOllamaInstalled = installed
        }
        
        guard installed else {
            print("❌ Ollama not installed, server cannot be running")
            DispatchQueue.main.async {
                self.isServerRunning = false
                completion(false)
            }
            return
        }
        
        let url = URL(string: "\(baseURL)/api/tags")!
        print("🔗 Testing connection to: \(url)")
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Connection error: \(error.localizedDescription)")
                    self.isServerRunning = false
                    completion(false)
                } else if let httpResponse = response as? HTTPURLResponse {
                    print("📡 HTTP Response: \(httpResponse.statusCode)")
                    if httpResponse.statusCode == 200 {
                        print("✅ Ollama server is running and responding")
                        self.isServerRunning = true
                        completion(true)
                    } else {
                        print("❌ Ollama server returned status code: \(httpResponse.statusCode)")
                        self.isServerRunning = false
                        completion(false)
                    }
                } else {
                    print("❌ No HTTP response received")
                    self.isServerRunning = false
                    completion(false)
                }
            }
        }
        task.resume()
    }
    
    // Start Ollama server
    func startServer(completion: @escaping (Bool, String?) -> Void) {
        print("🟡 Starting Ollama server...")
        
        // First check if it's already running
        checkServerStatus { isRunning in
            if isRunning {
                print("✅ Ollama server is already running")
                completion(true, nil)
                return
            }
            
            print("🟡 Server not running, attempting to start...")
            
            // Check if port 11434 is already in use
            if self.isPortInUse(11434) {
                let error = "Port 11434 is already in use by another process. Please stop the conflicting process or restart your system."
                print("❌ \(error)")
                completion(false, error)
                return
            }
            
            // Find Ollama executable
            guard let ollamaPath = self.findOllamaExecutable() else {
                let error = "Ollama executable not found in common paths"
                print("❌ \(error)")
                completion(false, error)
                return
            }
            
            print("🟢 Found Ollama at: \(ollamaPath)")
            
            // Try to start the server
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ollamaPath)
            process.arguments = ["serve"]
            
            // Use default environment (network entitlements handle binding)
            process.environment = ProcessInfo.processInfo.environment
            
            // Capture output for debugging
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            do {
                print("🟡 Launching: \(ollamaPath) serve")
                process.launch()  // Use launch() instead of run() for non-blocking execution
                self.serverProcess = process
                
                print("🟡 Process launched with PID: \(process.processIdentifier)")
                print("🟡 Server starting in background...")
                
                // Return immediately to avoid blocking UI
                completion(true, nil)
                
                // Check server health asynchronously after a brief delay
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
                    self.checkServerHealth()
                }
                
            } catch {
                let errorMsg = "Failed to launch Ollama: \(error.localizedDescription)"
                print("❌ \(errorMsg)")
                print("📝 Error details: \(error)")
                completion(false, errorMsg)
            }
        }
    }
    
    // Helper function to check if port is already in use
    private func isPortInUse(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        task.arguments = ["-i", ":\(port)", "-sTCP:LISTEN"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // If lsof finds processes using the port, output will not be empty
            let isInUse = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            
            if isInUse {
                print("⚠️ Port \(port) is already in use:")
                print(output)
            } else {
                print("✅ Port \(port) is available")
            }
            
            return isInUse
        } catch {
            print("📝 Failed to check port status: \(error)")
            return false
        }
    }
    
    // Helper function to find Ollama executable
    private func findOllamaExecutable() -> String? {
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
            "/bin/ollama"
        ]
        
        // Check common installation paths
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // Try using 'which' command to find in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ollama"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            print("📝 Failed to run 'which ollama': \(error)")
        }
        
        return nil
    }
    
    // Asynchronous server health check that doesn't block UI
    private func checkServerHealth(retryCount: Int = 0, maxRetries: Int = 10) {
        let retryDelay = min(2.0 + Double(retryCount) * 0.5, 10.0) // Exponential backoff, max 10s
        
        checkServerStatus { isRunning in
            DispatchQueue.main.async {
                if isRunning {
                    print("✅ Ollama server is healthy and responding!")
                    self.isServerRunning = true
                    // Optionally fetch available models
                    self.fetchAvailableModels { _ in }
                } else if retryCount < maxRetries {
                    print("🔄 Server not ready yet, retrying in \(retryDelay)s... (attempt \(retryCount + 1)/\(maxRetries))")
                    
                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + retryDelay) {
                        self.checkServerHealth(retryCount: retryCount + 1, maxRetries: maxRetries)
                    }
                } else {
                    print("❌ Server failed to start after \(maxRetries) attempts")
                    self.isServerRunning = false
                    
                    // Check if process is still running for diagnostics
                    if let process = self.serverProcess {
                        if process.isRunning {
                            print("📝 Process is running but not responding to API calls")
                        } else {
                            let exitCode = process.terminationStatus
                            print("📝 Process has terminated, exit code: \(exitCode)")
                            print("💡 \(self.getOllamaErrorMessage(exitCode: exitCode))")
                        }
                    }
                }
            }
        }
    }
    
    // Helper function to provide specific error messages based on exit codes
    private func getOllamaErrorMessage(exitCode: Int32) -> String {
        switch exitCode {
        case 1:
            return "Ollama server failed to start (exit code 1). This is often caused by port binding issues or configuration problems. The OLLAMA_HOST fix should resolve this. If the problem persists, try restarting your system or manually running 'ollama serve' in Terminal to see detailed error messages."
        case 126:
            return "Ollama executable found but cannot be executed (exit code 126). This may be a permissions issue. Try running 'chmod +x \(findOllamaExecutable() ?? "/path/to/ollama")' in Terminal."
        case 127:
            return "Ollama command not found (exit code 127). Please ensure Ollama is properly installed from https://ollama.com"
        case 130:
            return "Ollama server was interrupted (exit code 130). This usually happens when the process receives a termination signal."
        default:
            return "Ollama server failed with exit code \(exitCode). Try running 'ollama serve' manually in Terminal to see detailed error messages, or restart your system if the problem persists."
        }
    }
    
    // Fetch available models
    func fetchAvailableModels(completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async {
            self.isFetchingModels = true
        }
        checkServerStatus { isRunning in
            guard isRunning else {
                DispatchQueue.main.async {
                    self.isFetchingModels = false
                }
                completion([])
                return
            }
            
            let url = URL(string: "\(self.baseURL)/api/tags")!
            
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let models = json["models"] as? [[String: Any]] else {
                        self.isFetchingModels = false
                        completion([])
                        return
                    }
                    
                    let modelNames = models.compactMap { $0["name"] as? String }
                    self.availableModels = modelNames
                    self.isFetchingModels = false
                    completion(modelNames)
                }
            }
            task.resume()
        }
    }
    
    // Fetch models from local ollama without requiring server
    func fetchLocalModels(completion: @escaping ([String]) -> Void) {
        DispatchQueue.main.async {
            self.isFetchingModels = true
        }
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
            task.arguments = ["list"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe() // Silence errors
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                // Parse the output - skip the header line and extract model names
                let lines = output.split(separator: "\n")
                var modelNames: [String] = []
                
                for (index, line) in lines.enumerated() {
                    if index == 0 { continue } // Skip header
                    let components = line.split(separator: " ", maxSplits: 1)
                    if let modelName = components.first {
                        modelNames.append(String(modelName))
                    }
                }
                
                DispatchQueue.main.async {
                    self.availableModels = modelNames
                    self.isFetchingModels = false
                    completion(modelNames)
                    print("📦 Found \(modelNames.count) local models: \(modelNames)")
                }
            } catch {
                print("❌ Failed to fetch local models: \(error)")
                DispatchQueue.main.async {
                    self.isFetchingModels = false
                    completion([])
                }
            }
        }
    }
    
    // Ensure server is running with retries
    func ensureServerRunning(retries: Int = 3, completion: @escaping (Bool, String?) -> Void) {
        checkServerStatus { isRunning in
            if isRunning {
                completion(true, nil)
                return
            }
            
            if retries > 0 {
                self.startServer { success, error in
                    if success {
                        // Server launch initiated successfully (non-blocking)
                        completion(true, nil)
                    } else {
                        // Retry with exponential backoff
                        let delay = Double(4 - retries) * 2.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.ensureServerRunning(retries: retries - 1, completion: completion)
                        }
                    }
                }
            } else {
                completion(false, "Ollama server is not starting. Please start it manually.")
            }
        }
    }
    
    // Stop the Ollama server
    func stopServer() {
        guard let process = serverProcess else {
            print("🔴 No Ollama server process to stop")
            return
        }
        
        print("🔴 Stopping Ollama server (PID: \(process.processIdentifier))...")
        
        // First try gentle termination
        process.terminate()
        
        // Wait a moment for graceful shutdown
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
            if process.isRunning {
                print("⚠️ Process still running, forcing termination...")
                // Force kill if still running
                kill(process.processIdentifier, SIGKILL)
            } else {
                print("✅ Ollama server stopped gracefully")
            }
        }
        
        serverProcess = nil
        DispatchQueue.main.async {
            self.isServerRunning = false
        }
        print("🔴 Ollama server cleanup completed")
    }
    
    // Force stop with immediate termination
    func forceStopServer() {
        guard let process = serverProcess else { return }
        
        print("💥 Force stopping Ollama server (PID: \(process.processIdentifier))")
        kill(process.processIdentifier, SIGKILL)
        
        serverProcess = nil
        DispatchQueue.main.async {
            self.isServerRunning = false
        }
        print("💥 Ollama server force stopped")
    }
    
    // Reset all OllamaManager state (useful when switching configurations)
    func resetState() {
        print("🔄 Resetting OllamaManager state")
        
        // Cancel any ongoing pull task
        pullTask?.cancel()
        pullTask = nil
        
        // Reset pull-related state
        isPulling = false
        pullProgress = ""
        pullPercentage = 0.0
        
        // Clear models list and set loading state
        availableModels = []
        isFetchingModels = true
        
        // Clear stream buffer
        streamBuffer = ""
        
        print("✅ OllamaManager state reset complete")
    }
    
    // Pull a model from Ollama
    func pullModel(_ modelName: String) async {
        guard !isPulling else { 
            print("🔴 Already pulling a model, ignoring request")
            return 
        }
        
        print("🟢 Starting pull for model: \(modelName)")
        print("🌐 Base URL: \(baseURL)")
        
        await MainActor.run {
            self.isPulling = true
            self.pullProgress = "Starting download..."
            self.pullPercentage = 0.0
        }
        
        guard let url = URL(string: "\(baseURL)/api/pull") else { 
            print("🔴 Failed to create URL for: \(baseURL)/api/pull")
            return 
        }
        
        print("🟢 Created URL: \(url)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": modelName,
            "stream": true  // Enable streaming for progress updates
        ]
        
        print("🟢 Request body: \(body)")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            print("🟢 Request body serialized successfully")
        } catch {
            print("🔴 Failed to serialize request body: \(error)")
            await MainActor.run {
                self.isPulling = false
                self.pullProgress = "Error: Failed to create request"
            }
            return
        }
        
        // Create a delegate to handle streaming
        print("🟢 Creating URLSession with delegate")
        let session = URLSession(configuration: .default, delegate: OllamaStreamDelegate(manager: self), delegateQueue: nil)
        pullTask = session.dataTask(with: request)
        print("🟢 Starting data task")
        pullTask?.resume()
    }
}

// Delegate to handle streaming responses from Ollama
class OllamaStreamDelegate: NSObject, URLSessionDataDelegate {
    private weak var manager: OllamaManager?
    private var totalBytes: Int = 0
    private var completedBytes: Int = 0
    
    init(manager: OllamaManager) {
        self.manager = manager
        super.init()
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let manager = manager else { 
            print("🔴 URLSession delegate: manager is nil")
            return 
        }
        
        print("📡 RECEIVED DATA CHUNK: \(data.count) bytes")
        
        // Append data to buffer
        if let string = String(data: data, encoding: .utf8) {
            print("📝 RAW STRING CHUNK: '\(string)'")
            manager.streamBuffer += string
            print("📦 CURRENT BUFFER: '\(manager.streamBuffer)'")
            
            // Process complete lines
            let lines = manager.streamBuffer.components(separatedBy: "\n")
            print("📋 SPLIT INTO \(lines.count) LINES")
            
            for i in 0..<lines.count - 1 {
                let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    print("🔄 PROCESSING LINE \(i): '\(line)'")
                    processJSONLine(line)
                } else {
                    print("⚪ EMPTY LINE \(i) SKIPPED")
                }
            }
            
            // Keep the incomplete line in buffer
            let remainingBuffer = lines.last ?? ""
            print("💾 REMAINING IN BUFFER: '\(remainingBuffer)'")
            manager.streamBuffer = remainingBuffer
        } else {
            print("🔴 Failed to convert data to UTF-8 string")
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let manager = manager else { 
            return 
        }
        
        DispatchQueue.main.async {
            if let error = error {
                // Handle connection errors appropriately
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost {
                    manager.pullProgress = "Error: Cannot connect to Ollama server"
                    print("🔴 Pull failed - server not running: \(error.localizedDescription)")
                } else {
                    manager.pullProgress = "Error: \(error.localizedDescription)"
                    print("🔴 Pull failed: \(error.localizedDescription)")
                }
                manager.isPulling = false
            } else {
                // Process any remaining data in buffer
                if !manager.streamBuffer.isEmpty {
                    self.processJSONLine(manager.streamBuffer)
                }
                manager.streamBuffer = ""
            }
        }
    }
    
    private func capitalizeFirstWord(_ text: String) -> String {
        let words = text.split(separator: " ")
        if words.isEmpty { return text }
        
        var result = words[0].prefix(1).uppercased() + words[0].dropFirst()
        for i in 1..<words.count {
            result += " " + words[i]
        }
        return result
    }
    
    private func processJSONLine(_ line: String) {
        print("🔍 RAW LINE RECEIVED: '\(line)'")
        
        guard let manager = manager,
              let data = line.data(using: .utf8) else { 
            print("🔴 Failed to get manager or convert line to data")
            return 
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { 
            print("🔴 Failed to parse JSON from line: '\(line)'")
            return 
        }
        
        print("📊 PARSED JSON: \(json)")
        
        DispatchQueue.main.async {
            if let status = json["status"] as? String {
                print("✅ Status found: '\(status)'")
                
                // Log all available fields
                if let digest = json["digest"] as? String {
                    print("🔑 Digest: \(digest)")
                }
                if let total = json["total"] as? Int {
                    print("📏 Total: \(total)")
                }
                if let completed = json["completed"] as? Int {
                    print("✨ Completed: \(completed)")
                }
                
                // Handle different status types
                switch status {
                case "success":
                    print("🎉 SUCCESS: Download complete")
                    manager.isPulling = false
                    manager.pullProgress = ""
                    manager.pullPercentage = 0.0
                    // Refresh available models and auto-select smollm2:latest
                    manager.fetchAvailableModels { _ in
                        // Auto-select smollm2:latest if it was just downloaded
                        if let settingsManager = manager.settingsManager {
                            DispatchQueue.main.async {
                                if manager.availableModels.contains("smollm2:latest") {
                                    settingsManager.settings.selectedOllamaModel = "smollm2:latest"
                                    settingsManager.saveSettings()
                                }
                            }
                        }
                    }
                    
                case "pulling manifest":
                    print("📄 PULLING MANIFEST")
                    manager.pullProgress = "Pulling manifest"
                    manager.pullPercentage = 0.0
                    
                case "verifying sha256 digest":
                    print("🔐 VERIFYING DIGEST")
                    manager.pullProgress = "Verifying download"
                    manager.pullPercentage = 95.0
                    
                case "writing manifest":
                    print("💾 WRITING MANIFEST")
                    manager.pullProgress = "Writing manifest"
                    manager.pullPercentage = 98.0
                    
                case "removing any unused layers":
                    print("🧹 CLEANING UP")
                    manager.pullProgress = "Cleaning up"
                    manager.pullPercentage = 99.0
                    
                case let status where status.starts(with: "downloading") || status.starts(with: "pulling"):
                    print("⬇️ DOWNLOAD/PULL STATUS: '\(status)'")
                    
                    // Extract progress from downloading/pulling status
                    if let total = json["total"] as? Int,
                       let completed = json["completed"] as? Int {
                        print("📊 Progress data - Total: \(total), Completed: \(completed)")
                        
                        self.totalBytes = total
                        self.completedBytes = completed
                        let percentage = total > 0 ? (Double(completed) / Double(total)) * 100 : 0
                        let cappedPercentage = min(percentage, 90.0) // Cap at 90% for download phase
                        
                        print("🔢 Calculated percentage: \(percentage)% -> Capped: \(cappedPercentage)%")
                        manager.pullPercentage = cappedPercentage
                        
                        // Extract digest for better progress message
                        if let digest = json["digest"] as? String {
                            let shortDigest = String(digest.prefix(12))
                            manager.pullProgress = "Pulling \(shortDigest)"
                            print("🏷️ Updated progress message to: 'Pulling \(shortDigest)'")
                        } else {
                            manager.pullProgress = "Downloading model"
                            print("🏷️ Updated progress message to: 'Downloading model'")
                        }
                        
                        print("📈 UI UPDATED - Progress: '\(manager.pullProgress)', Percentage: \(manager.pullPercentage)%")
                        
                    } else {
                        print("⚠️ No progress data found in download/pull status")
                        print("   - total field: \(json["total"] ?? "missing")")
                        print("   - completed field: \(json["completed"] ?? "missing")")
                        
                        // Fallback for downloading/pulling status without progress data
                        manager.pullProgress = "Downloading model"
                        print("🏷️ Fallback: Updated progress message to: 'Downloading model'")
                    }
                    
                default:
                    print("❓ OTHER STATUS: '\(status)'")
                    // For other statuses, just show the capitalized status
                    let capitalizedStatus = self.capitalizeFirstWord(status)
                    manager.pullProgress = capitalizedStatus
                    print("🏷️ Updated progress message to: '\(capitalizedStatus)'")
                }
            } else {
                print("⚠️ No status field in JSON response")
                print("📋 Available keys: \(Array(json.keys))")
            }
        }
    }
}

class ContentViewController: NSObject, URLSessionDataDelegate {
    // You can move the URLSession delegate methods here if you prefer
    // to keep ContentView cleaner. For now, we'll keep them in the extension.
}

// Section type for alternating user/reflection
enum EntrySectionType {
    case user
    case reflection
}

struct EntrySection: Identifiable, Equatable {
    let id = UUID()
    var type: EntrySectionType
    var text: String
    static func == (lhs: EntrySection, rhs: EntrySection) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.text == rhs.text
    }
}

struct ContentView: View {
    // Global navigation height constant
    private let navHeight: CGFloat = 59
    
    @State private var entries: [HumanEntry] = []
    @State private var text: String = ""  // Initialize as empty string without "\n\n"
    
    @State private var isFullscreen = false
    @State private var userSelectedFont: String = "Lato-Regular" // Renamed from selectedFont
    @State private var currentRandomFont: String = "" 
    @State private var currentAIRandomFont: String = ""
    @State private var timeRemaining: Int = 600  // Changed to 600 seconds (10 minutes)
    @State private var timerIsRunning = false
    @State private var isHoveringTimer = false
    @State private var isHoveringTheme = false
    @State private var userFontSize: CGFloat = 18 // Renamed from fontSize
    @State private var aiFontSize: CGFloat = 18 // For AI reflections
    @State private var blinkCount = 0
    @State private var isBlinking = false
    @State private var opacity: Double = 1.0
    @State private var shouldShowGray = true // New state to control color
    @State private var lastClickTime: Date? = nil
    @State private var bottomNavOpacity: Double = 1.0
    @State private var isHoveringBottomNav = false
    @State private var selectedEntryIndex: Int = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedEntryId: UUID? = nil
    @State private var manuallySelectedEntryId: UUID? = nil
    @State private var hoveredEntryId: UUID? = nil
    @State private var showingChatMenu = false
    @State private var chatMenuAnchor: CGPoint = .zero
    @State private var showingSidebar = false  // Add this state variable
    @State private var hoveredTrashId: UUID? = nil
    @State private var hoveredExportId: UUID? = nil
    @State private var placeholderText: String = ""  // Add this line
    @State private var isHoveringNewEntry = false
    @State private var isHoveringFullscreen = false
    @State private var isHoveringClock = false
    @State private var isHoveringHistory = false
    @State private var isHoveringHistoryText = false
    @State private var isHoveringHistoryPath = false
    @State private var isHoveringHistoryArrow = false

    @State private var isHoveringReflect = false
    @State private var isHoveringSidebar = false
    @State private var isHoveringReflectWeek = false
    @State private var isHoveringReflectMonth = false
    @State private var isHoveringReflectCustom = false
    @State private var colorScheme: ColorScheme = .light // Add state for color scheme

    @State private var didCopyPrompt: Bool = false // Add state for copy prompt feedback
    @State private var showingSettings = false // Add state for settings menu
    @State private var isHoveringSettings = false // Add state for settings hover
    @State private var selectedSettingsTab: SettingsTab = .reflections // Add state for selected tab
    @State private var showingCommandBar = false // Add state for command bar
    @State private var commandBarText = "" // Add state for command bar text
    @FocusState private var isCommandBarFocused: Bool // Add focus state for command bar
    @State private var searchResults: [(entry: HumanEntry, matchContext: String, range: Range<String.Index>)] = [] // Search results with context
    @State private var selectedSearchIndex: Int = 0 // Selected index in search results dropdown
    @State private var openAIAPIKey: String = ""
    @StateObject private var reflectionViewModel = ReflectionViewModel()
    @State private var followUpText: String = ""
    @StateObject private var settingsManager = SettingsManager()
    @State private var isNavbarHidden: Bool = false
    
    // Add state for reflection functionality
    @State private var showReflectionPanel: Bool = false
    @State private var isWeeklyReflection: Bool = false
    @State private var hasInitiatedReflection: Bool = false
    
    @State private var sections: [EntrySection] = [] // All USER and REFLECTION sections
    @State private var editingText: String = "" // Current text being edited (always the latest USER section)
    @State private var isStreamingReflection: Bool = false // Freeze text editor during streaming
    @State private var forceRefresh: Bool = false // Force UI refresh after streaming completion
    
    @State private var shouldScrollToBottom: Bool = false
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    let entryHeight: CGFloat = 40
    
    
    
    // Toast notification states
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastType = .error
    
    // Focus states for text editors
    @FocusState private var isFollowUpFocused: Bool
    @FocusState private var isUserEditorFocused: Bool

    let availableFonts = NSFontManager.shared.availableFontFamilies
    let placeholderOptions = [
        "\n\nBegin writing",
        "\n\nPick a thought and go",
        "\n\nStart typing",
        "\n\nWhat's on your mind",
        "\n\nJust start",
        "\n\nType your first thought",
        "\n\nStart with one sentence",
        "\n\nJust say it"
    ]
    
    // Add file manager and save timer
    private let fileManager = FileManager.default
    private let saveTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    // Add cached documents directory
    private let documentsDirectory: URL = {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Journal")
        
        // Create Journal directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                print("Successfully created Journal directory")
            } catch {
                print("Error creating directory: \(error)")
            }
        }
        
        return directory
    }()
    
    // Initialize with saved theme preference if available
    init() {
        // Load saved color scheme preference
        let savedScheme = UserDefaults.standard.string(forKey: "colorScheme") ?? "light"
        _colorScheme = State(initialValue: savedScheme == "dark" ? .dark : .light)
        
        // Initialize API keys as empty - will be loaded lazily when needed
        _openAIAPIKey = State(initialValue: "")
        
    }
    
    // MARK: - Lazy Keychain Loading Functions
    
    /// Loads OpenAI API key directly from keychain for reflection functionality
    private func getOpenAIKeyFromKeychain() -> String? {
        return KeychainHelper.shared.loadAPIKey(for: .openAI)
    }
    
    /// Checks if LLM is properly configured based on the current mode (local or remote)
    /// Returns a tuple with configuration status and an optional error message
    private func isLLMConfigured() -> (isConfigured: Bool, errorMessage: String?) {
        if settingsManager.settings.llmMode == "local" {
            // For local mode, check if a model is selected
            guard let selectedModel = settingsManager.settings.selectedOllamaModel,
                  !selectedModel.isEmpty else {
                return (false, "Setup your LLM :)")
            }
            
            // Check if the selected model is available
            if OllamaManager.shared.availableModels.isEmpty {
                // If models list is empty, we need to fetch it first
                return (false, "Setup your LLM :)")
            }
            
            if !OllamaManager.shared.availableModels.contains(selectedModel) {
                return (false, "Selected model '\(selectedModel)' is not available")
            }
            
            return (true, nil)
        } else {
            // For remote mode, check if OpenAI API key exists
            guard let apiKey = getOpenAIKeyFromKeychain(),
                  !apiKey.isEmpty else {
                return (false, "Setup your LLM :)")
            }
            return (true, nil)
        }
    }
    
    /// Asynchronously checks if local models are available and updates the models list
    private func checkLocalModelAvailability(completion: @escaping (Bool) -> Void) {
        if settingsManager.settings.llmMode == "local" {
            // Use fetchLocalModels which doesn't require server
            OllamaManager.shared.fetchLocalModels { models in
                if let selectedModel = self.settingsManager.settings.selectedOllamaModel {
                    completion(models.contains(selectedModel))
                } else {
                    completion(false)
                }
            }
        } else {
            // For remote mode, just check API key
            let hasKey = getOpenAIKeyFromKeychain() != nil && !getOpenAIKeyFromKeychain()!.isEmpty
            completion(hasKey)
        }
    }
    
    
    private func buildFullConversationContext() -> String {
        var context = ""
        
        // Add all previous sections chronologically
        for section in sections {
            if section.type == .user {
                if !context.isEmpty {
                    context += "\n\n--- PREVIOUS USER ENTRY ---\n\n"
                } else {
                    context += "--- PREVIOUS USER ENTRY ---\n\n"
                }
                context += section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                context += "\n\n--- PREVIOUS REFLECTION ---\n\n"
                context += section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Add current editing text as the new entry to reflect on
        if !context.isEmpty {
            context += "\n\n--- CURRENT NEW ENTRY ---\n\n"
        } else {
            context += "--- CURRENT NEW ENTRY ---\n\n"
        }
        context += editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return context
    }
    
    // Modify getDocumentsDirectory to use cached value
    private func getDocumentsDirectory() -> URL {
        return documentsDirectory
    }
    
    // Add function to save text
    private func saveText() {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent("entry.md")
        
        print("Attempting to save file to: \(fileURL.path)")
        
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Successfully saved file")
        } catch {
            print("Error saving file: \(error)")
            print("Error details: \(error.localizedDescription)")
        }
    }
    
    // Add function to load text
    private func loadText() {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent("entry.md")
        
        print("Attempting to load file from: \(fileURL.path)")
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                text = try String(contentsOf: fileURL, encoding: .utf8)
                print("Successfully loaded file")
            } else {
                print("File does not exist yet")
            }
        } catch {
            print("Error loading file: \(error)")
            print("Error details: \(error.localizedDescription)")
        }
    }
    
    // Function to run date range reflection (replaces runWeeklyReflection)
    private func runDateRangeReflection(fromDate: Date, toDate: Date, type: String) {
        // Check if LLM is properly configured based on current mode
        let llmConfig = isLLMConfigured()
        if !llmConfig.isConfigured {
            // If in local mode and models haven't been fetched yet, try fetching them first
            if settingsManager.settings.llmMode == "local" && OllamaManager.shared.availableModels.isEmpty {
                checkLocalModelAvailability { isConfigured in
                    if isConfigured {
                        // Retry the reflection now that models are loaded
                        self.runDateRangeReflection(fromDate: fromDate, toDate: toDate, type: type)
                    } else {
                        self.showToast(message: llmConfig.errorMessage ?? "setup your LLM :)", type: .error)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.showingSettings = true
                            self.selectedSettingsTab = .apiKeys
                        }
                    }
                }
                return
            }
            
            showToast(message: llmConfig.errorMessage ?? "setup your LLM :)", type: .error)
            withAnimation(.easeInOut(duration: 0.2)) {
                showingSettings = true
                selectedSettingsTab = .apiKeys
            }
            return
        }
        
        // Get API key for remote mode, or empty string for local mode
        let apiKey = settingsManager.settings.llmMode == "remote" ? (getOpenAIKeyFromKeychain() ?? "") : ""
        
        // Gather entries from the specified date range
        let rangeContent = gatherEntriesInDateRange(from: fromDate, to: toDate)
        
        // Check if there are any entries for the date range
        if rangeContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showToast(message: "No entries found for the selected date range", type: .error)
            return
        }
        
        // Format the date range for the title
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d"
        let startDateString = dateFormatter.string(from: fromDate)
        let endDateString = dateFormatter.string(from: toDate)
        
        // Count the number of entries for the "Read x entries" text
        let entryCount = countEntriesInRange(from: fromDate, to: toDate)
        
        // Map timeframe type from UI strings to standardized format
        let timeframeType: String
        switch type {
        case "Last Week", "This Week":
            timeframeType = "Week"
        case "Last Month", "This Month":
            timeframeType = "Month"
        case "Last Year", "This Year":
            timeframeType = "Year"
        case "Week":
            timeframeType = "Week"
        case "Month":
            timeframeType = "Month"
        default:
            timeframeType = "Custom"
        }
        
        // Create title with date range
        let reflectionTitle = "\(type): \(startDateString)-\(endDateString)"
        
        // Create new reflection entry with proper format
        let newEntry = createReflectionEntry(title: reflectionTitle, fromDate: fromDate, toDate: toDate, entryCount: entryCount, timeframeType: timeframeType)
        
        // Select the new entry and set up the reflection UI like "New Entry + Reflect"
        selectedEntryId = newEntry.id
        entries.insert(newEntry, at: 0)
        
        // Set up sections with the initial USER section containing the "Read x entries" text
        sections = [EntrySection(type: .user, text: "Read \(entryCount) entries from \(startDateString) - \(endDateString)")]
        editingText = "" // Don't show the "Read x entries" text in the editor, only in the right panel
        
        // Add REFLECTION section and start streaming
        sections.append(EntrySection(type: .reflection, text: ""))
        
        // Show reflection panel and freeze text editor
        showReflectionPanel = true
        hasInitiatedReflection = true
        isStreamingReflection = true
        
        // Start reflection with the gathered content
        reflectionViewModel.start(apiKey: apiKey, entryText: rangeContent, llmMode: settingsManager.settings.llmMode, selectedOllamaModel: settingsManager.settings.selectedOllamaModel) {
            // On complete: add new empty USER section, unfreeze editor, and save
            self.sections.append(EntrySection(type: .user, text: "\n\n"))
            self.editingText = "\n\n"
            self.isStreamingReflection = false
            
            // Force UI refresh to ensure final chunk renders
            DispatchQueue.main.async {
                self.forceRefresh.toggle()
            }
            
            if let currentId = self.selectedEntryId,
               let entry = self.entries.first(where: { $0.id == currentId }) {
                self.saveEntry(entry: entry)
            }
        } onStream: { streamedText in
            // Update the latest REFLECTION section as it streams
            if let lastReflectionIndex = self.sections.lastIndex(where: { $0.type == .reflection }) {
                self.sections[lastReflectionIndex].text = streamedText
            }
            // Save to file during streaming
            if let currentId = self.selectedEntryId,
               let entry = self.entries.first(where: { $0.id == currentId }) {
                self.saveEntry(entry: entry)
            }
        }
        
        // Close settings
        showingSettings = false
    }
    
    // Function to start reflection for specified timeframe
    private func startReflection(timeframe: ReflectionTimeframe) {
        let calendar = Calendar.current
        let now = Date()
        let toDate = now
        var fromDate: Date
        var type: String
        
        switch timeframe {
        case .week:
            let weekday = calendar.component(.weekday, from: now)
            let daysToSubtract = weekday == 1 ? 7 : weekday - 1 // Sunday = 1, so if today is Sunday, go back 7 days
            fromDate = calendar.date(byAdding: .day, value: -daysToSubtract, to: now) ?? now
            type = "This Week"
        case .month:
            let year = calendar.component(.year, from: now)
            let month = calendar.component(.month, from: now)
            fromDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            type = "This Month"
        }
        
        runDateRangeReflection(fromDate: fromDate, toDate: toDate, type: type)
    }
    
    // Function to run question response
    private func runQuestionResponse(question: String) {
        // Check if LLM is properly configured based on current mode
        let llmConfig = isLLMConfigured()
        if !llmConfig.isConfigured {
            // If in local mode and models haven't been fetched yet, try fetching them first
            if settingsManager.settings.llmMode == "local" && OllamaManager.shared.availableModels.isEmpty {
                checkLocalModelAvailability { isConfigured in
                    if isConfigured {
                        // Retry the question now that models are loaded
                        self.runQuestionResponse(question: question)
                    } else {
                        self.showToast(message: llmConfig.errorMessage ?? "setup your LLM :)", type: .error)
                        
                        // Close command bar first before opening settings
                        withAnimation(.easeInOut(duration: 0.1)) {
                            self.showingCommandBar = false
                            self.commandBarText = ""
                            self.isCommandBarFocused = false
                            self.searchResults = []
                            self.selectedSearchIndex = 0
                        }
                        
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.showingSettings = true
                            self.selectedSettingsTab = .apiKeys
                        }
                    }
                }
                return
            }
            
            showToast(message: llmConfig.errorMessage ?? "setup your LLM :)", type: .error)
            
            // Close command bar first before opening settings
            withAnimation(.easeInOut(duration: 0.1)) {
                showingCommandBar = false
                commandBarText = ""
                isCommandBarFocused = false
                searchResults = []
                selectedSearchIndex = 0
            }
            
            withAnimation(.easeInOut(duration: 0.2)) {
                showingSettings = true
                selectedSettingsTab = .apiKeys
            }
            return
        }
        
        // Get API key for remote mode, or empty string for local mode
        let apiKey = settingsManager.settings.llmMode == "remote" ? (getOpenAIKeyFromKeychain() ?? "") : ""
        
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(message: "Please enter a question", type: .error)
            return
        }
        
        // Gather all entries by using a very wide date range
        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .year, value: -10, to: now) ?? now // 10 years ago
        let endDate = now
        
        let allContent = gatherEntriesInDateRange(from: startDate, to: endDate)
        
        // Check if there are any entries
        if allContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showToast(message: "No journal entries found", type: .error)
            
            // Close command bar when no entries are found
            withAnimation(.easeInOut(duration: 0.1)) {
                showingCommandBar = false
                commandBarText = ""
                isCommandBarFocused = false
                searchResults = []
                selectedSearchIndex = 0
            }
            return
        }
        
        // Create new question entry
        let newEntry = createQuestionEntry(question: question)
        
        // Select the new entry and set up the question UI
        selectedEntryId = newEntry.id
        entries.insert(newEntry, at: 0)
        
        // Set up sections with the initial USER section containing the question
        sections = [EntrySection(type: .user, text: question)]
        editingText = "" // Don't show the question text in the editor, only in the right panel
        
        // Add REFLECTION section and start streaming
        sections.append(EntrySection(type: .reflection, text: ""))
        
        // Show reflection panel and freeze text editor
        showReflectionPanel = true
        hasInitiatedReflection = true
        isStreamingReflection = true
        
        // Start question response with the gathered content
        reflectionViewModel.startQuestionResponse(apiKey: apiKey, allEntries: allContent, question: question, llmMode: settingsManager.settings.llmMode, selectedOllamaModel: settingsManager.settings.selectedOllamaModel) {
            // On complete: add new empty USER section, unfreeze editor, and save
            self.sections.append(EntrySection(type: .user, text: "\n\n"))
            self.editingText = "\n\n"
            self.isStreamingReflection = false
            
            // Force UI refresh to ensure final chunk renders
            DispatchQueue.main.async {
                self.forceRefresh.toggle()
            }
            
            // Save the completed entry
            if let currentId = self.selectedEntryId,
               let currentEntry = self.entries.first(where: { $0.id == currentId }) {
                self.saveEntry(entry: currentEntry)
            }
        } onStream: { streamedText in
            // Update the latest REFLECTION section as it streams
            if let lastReflectionIndex = self.sections.lastIndex(where: { $0.type == .reflection }) {
                self.sections[lastReflectionIndex].text = streamedText
            }
            // Save to file during streaming
            if let currentId = self.selectedEntryId,
               let currentEntry = self.entries.first(where: { $0.id == currentId }) {
                self.saveEntry(entry: currentEntry)
            }
        }
        
        // Close command bar
        withAnimation(.easeInOut(duration: 0.1)) {
            showingCommandBar = false
            commandBarText = ""
            isCommandBarFocused = false
            searchResults = []
            selectedSearchIndex = 0
        }
    }
    
    // Function to create highlighted text with search term matches
    private func highlightedText(_ text: String, searchTerm: String) -> Text {
        guard !searchTerm.isEmpty else { return Text(text) }
        
        // Create attributed string for highlighting
        var attributedString = AttributedString(text)
        let lowercaseText = text.lowercased()
        let lowercaseSearchTerm = searchTerm.lowercased()
        
        var searchStartIndex = lowercaseText.startIndex
        while let range = lowercaseText.range(of: lowercaseSearchTerm, range: searchStartIndex..<lowercaseText.endIndex) {
            // Convert string indices to AttributedString indices
            let startIndex = AttributedString.Index(range.lowerBound, within: attributedString)!
            let endIndex = AttributedString.Index(range.upperBound, within: attributedString)!
            let attributedRange = startIndex..<endIndex
            
            // Apply highlight styling
            attributedString[attributedRange].backgroundColor = Color(red: 0.8, green: 0.7, blue: 0.6)
            attributedString[attributedRange].foregroundColor = .black
            
            searchStartIndex = range.upperBound
        }
        
        return Text(attributedString)
    }
    
    // Function to search entries for exact string match
    private func searchEntries(_ searchText: String) {
        guard !searchText.isEmpty else {
            searchResults = []
            selectedSearchIndex = 0
            return
        }
        
        searchResults = []
        selectedSearchIndex = 0
        
        for entry in entries {
            // Get the full content of the entry
            let documentsDirectory = getDocumentsDirectory()
            let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
            
            if let content = try? String(contentsOf: fileURL) {
                // Clean content by removing separators before searching
                let cleanedContent = removeReflectionSeparators(from: content)
                
                // Search for exact string match (case-insensitive) in cleaned content
                let searchRange = cleanedContent.range(of: searchText, options: .caseInsensitive)
                
                if let range = searchRange {
                    // Get context around the match (50 characters before and after)
                    let contextStart = cleanedContent.index(range.lowerBound, offsetBy: -50, limitedBy: cleanedContent.startIndex) ?? cleanedContent.startIndex
                    let contextEnd = cleanedContent.index(range.upperBound, offsetBy: 50, limitedBy: cleanedContent.endIndex) ?? cleanedContent.endIndex
                    
                    let contextRange = contextStart..<contextEnd
                    var matchContext = String(cleanedContent[contextRange])
                    
                    // Add ellipsis if we're not at the beginning/end
                    if contextStart != cleanedContent.startIndex {
                        matchContext = "..." + matchContext
                    }
                    if contextEnd != cleanedContent.endIndex {
                        matchContext = matchContext + "..."
                    }
                    
                    // Clean up the match context to remove any remaining separators and extra whitespace
                    matchContext = matchContext
                        .replacingOccurrences(of: "\n\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    searchResults.append((entry: entry, matchContext: matchContext, range: range))
                }
            }
        }
    }
    
    // Function to gather entries from the last 7 days
    private func gatherEntriesInDateRange(from startDate: Date, to endDate: Date) -> String {
        let documentsDirectory = getDocumentsDirectory()
        var weeklyContent = ""
        var processedFiles: [String] = []
        
        print("=== GATHERING WEEKLY ENTRIES ===")
        print("Target date range: \(startDate) to \(endDate)")
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" }
            
            print("Found \(mdFiles.count) .md files to process")
            
            let calendar = Calendar.current
            let startOfStartDate = calendar.startOfDay(for: startDate)
            let startOfEndDate = calendar.startOfDay(for: endDate)
            
            for fileURL in mdFiles {
                let filename = fileURL.lastPathComponent
                var shouldInclude = false
                var displayDate = ""
                
                // Handle Daily entries: [Daily]-[MM-dd-yyyy]-[HH-mm-ss].md
                if filename.hasPrefix("[Daily]-") {
                    if let dateMatch = filename.range(of: "\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]", options: .regularExpression) {
                        let matchString = String(filename[dateMatch])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 2 {
                            let dateComponent = components[0].replacingOccurrences(of: "[", with: "")
                            let timeComponent = components[1].replacingOccurrences(of: "]", with: "")
                            
                            let dateTimeString = "\(dateComponent)-\(timeComponent)"
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
                            
                            if let fileDate = dateFormatter.date(from: dateTimeString) {
                                let startOfFileDate = calendar.startOfDay(for: fileDate)
                                
                                // Check if file date is within our 7-day range
                                if startOfFileDate >= startOfStartDate && startOfFileDate <= startOfEndDate {
                                    shouldInclude = true
                                    dateFormatter.dateFormat = "MMMM d"
                                    displayDate = dateFormatter.string(from: fileDate)
                                }
                            }
                        }
                    }
                }
                // Handle Weekly entries: [Weekly]-[MM-dd-yyyy]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Weekly]-") {
                    let pattern = "\\[Weekly\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 4 {
                            let weeklyStartDateString = components[1]
                            let weeklyEndDateString = components[2]
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let weeklyStartDate = dateFormatter.date(from: weeklyStartDateString),
                               let weeklyEndDate = dateFormatter.date(from: weeklyEndDateString) {
                                
                                let startOfWeeklyStart = calendar.startOfDay(for: weeklyStartDate)
                                let startOfWeeklyEnd = calendar.startOfDay(for: weeklyEndDate)
                                
                                // Check if weekly entry's date range overlaps with our target 7-day range
                                // Overlap exists if: weeklyStart <= targetEnd AND weeklyEnd >= targetStart
                                if startOfWeeklyStart <= startOfEndDate && startOfWeeklyEnd >= startOfStartDate {
                                    shouldInclude = true
                                    dateFormatter.dateFormat = "MMMM d"
                                    let startDisplay = dateFormatter.string(from: weeklyStartDate)
                                    let endDisplay = dateFormatter.string(from: weeklyEndDate)
                                    displayDate = "Weekly: \(startDisplay) - \(endDisplay)"
                                }
                            }
                        }
                    }
                }
                // Handle Reflection entries: [Reflection]-[timeframeType]-[MM-dd-yyyy]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Reflection]-") {
                    let pattern = "\\[Reflection\\]-\\[([^\\]]+)\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 5 {
                            let timeframeType = components[1]
                            let reflectionStartDateString = components[2]
                            let reflectionEndDateString = components[3]
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let reflectionStartDate = dateFormatter.date(from: reflectionStartDateString),
                               let reflectionEndDate = dateFormatter.date(from: reflectionEndDateString) {
                                
                                let startOfReflectionStart = calendar.startOfDay(for: reflectionStartDate)
                                let startOfReflectionEnd = calendar.startOfDay(for: reflectionEndDate)
                                
                                // Check if reflection entry's date range overlaps with our target range
                                // Overlap exists if: reflectionStart <= targetEnd AND reflectionEnd >= targetStart
                                if startOfReflectionStart <= startOfEndDate && startOfReflectionEnd >= startOfStartDate {
                                    shouldInclude = true
                                    dateFormatter.dateFormat = "MMM d"
                                    let startDisplay = dateFormatter.string(from: reflectionStartDate)
                                    let endDisplay = dateFormatter.string(from: reflectionEndDate)
                                    displayDate = "\(timeframeType)): \(startDisplay) - \(endDisplay)"
                                }
                            }
                        }
                    }
                }
                // Handle Question entries: [Question]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Question]-") {
                    let pattern = "\\[Question\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 3 {
                            let questionDateString = components[1]
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let questionDate = dateFormatter.date(from: questionDateString) {
                                let startOfQuestionDate = calendar.startOfDay(for: questionDate)
                                
                                // Check if question date is within our range
                                if startOfQuestionDate >= startOfStartDate && startOfQuestionDate <= startOfEndDate {
                                    shouldInclude = true
                                    dateFormatter.dateFormat = "MMMM d"
                                    displayDate = "Question: \(dateFormatter.string(from: questionDate))"
                                }
                            }
                        }
                    }
                }
                
                if shouldInclude {
                    do {
                        let content = try String(contentsOf: fileURL, encoding: .utf8)
                        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if !cleanContent.isEmpty {
                            print("✓ Including file: \(filename)")
                            print("  Display date: \(displayDate)")
                            print("  Content length: \(cleanContent.count) characters")
                            print("  Content preview: \(String(cleanContent.prefix(100)))...")
                            
                            weeklyContent += "\n\nNEW ENTRY \(displayDate)\n\n"
                            
                            // Process content to replace separators with proper labels
                            let processedContent = cleanContent
                                .replacingOccurrences(of: "--- USER ---", with: "User Input")
                                .replacingOccurrences(of: "--- REFLECTION ---", with: "User Reflection")
                            
                            weeklyContent += processedContent
                            processedFiles.append(filename)
                        } else {
                            print("⚠ Skipping empty file: \(filename)")
                        }
                    } catch {
                        print("❌ Error reading file \(filename): \(error)")
                    }
                } else {
                    print("⏭ Skipping file (outside date range): \(filename)")
                }
            }
        } catch {
            print("❌ Error gathering weekly entries: \(error)")
        }
        
        print("\n=== WEEKLY REFLECTION SUMMARY ===")
        print("Processed \(processedFiles.count) files:")
        for file in processedFiles {
            print("  - \(file)")
        }
        print("Total content length: \(weeklyContent.count) characters")
        
        return weeklyContent
    }
    
    // Function to count entries in a date range
    private func countEntriesInRange(from startDate: Date, to endDate: Date) -> Int {
        let documentsDirectory = getDocumentsDirectory()
        var entryCount = 0
        
        print("=== COUNTING ENTRIES IN RANGE ===")
        print("Date range: \(startDate) to \(endDate)")
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" }
            
            print("Found \(mdFiles.count) .md files total")
            
            let calendar = Calendar.current
            let startOfStartDate = calendar.startOfDay(for: startDate)
            let startOfEndDate = calendar.startOfDay(for: endDate)
            
            for fileURL in mdFiles {
                let filename = fileURL.lastPathComponent
                
                // Handle Daily entries: [Daily]-[MM-dd-yyyy]-[HH-mm-ss].md
                if filename.hasPrefix("[Daily]-") {
                    print("Checking Daily file: \(filename)")
                    if let dateMatch = filename.range(of: "\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]", options: .regularExpression) {
                        let matchString = String(filename[dateMatch])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 2 {
                            let dateComponent = components[0].replacingOccurrences(of: "[", with: "")
                            let timeComponent = components[1].replacingOccurrences(of: "]", with: "")
                            
                            let dateTimeString = "\(dateComponent)-\(timeComponent)"
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
                            
                            if let fileDate = dateFormatter.date(from: dateTimeString) {
                                let startOfFileDate = calendar.startOfDay(for: fileDate)
                                print("File date: \(fileDate), in range: \(startOfFileDate >= startOfStartDate && startOfFileDate <= startOfEndDate)")
                                
                                if startOfFileDate >= startOfStartDate && startOfFileDate <= startOfEndDate {
                                    entryCount += 1
                                    print("Added to count, total now: \(entryCount)")
                                }
                            } else {
                                print("Failed to parse date from: \(dateTimeString)")
                            }
                        } else {
                            print("Invalid components: \(components)")
                        }
                    } else {
                        print("No date match found")
                    }
                }
                // Handle Weekly entries: [Weekly]-[MM-dd-yyyy]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Weekly]-") {
                    print("Checking Weekly file: \(filename)")
                    let pattern = "\\[Weekly\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 4 {
                            let weeklyStartDateString = components[1]
                            let weeklyEndDateString = components[2]
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let weeklyStartDate = dateFormatter.date(from: weeklyStartDateString),
                               let weeklyEndDate = dateFormatter.date(from: weeklyEndDateString) {
                                
                                let startOfWeeklyStart = calendar.startOfDay(for: weeklyStartDate)
                                let startOfWeeklyEnd = calendar.startOfDay(for: weeklyEndDate)
                                
                                // Check if weekly entry's date range overlaps with our target range
                                if startOfWeeklyStart <= startOfEndDate && startOfWeeklyEnd >= startOfStartDate {
                                    entryCount += 1
                                    print("Added Weekly entry to count, total now: \(entryCount)")
                                }
                            }
                        }
                    }
                }
                // Handle Reflection entries: [Reflection]-[timeframeType]-[MM-dd-yyyy]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Reflection]-") {
                    print("Checking Reflection file: \(filename)")
                    let pattern = "\\[Reflection\\]-\\[([^\\]]+)\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 5 {
                            _ = components[1]  // timeframeType (unused in this context)
                            let reflectionStartDateString = components[2]
                            let reflectionEndDateString = components[3]
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let reflectionStartDate = dateFormatter.date(from: reflectionStartDateString),
                               let reflectionEndDate = dateFormatter.date(from: reflectionEndDateString) {
                                
                                let startOfReflectionStart = calendar.startOfDay(for: reflectionStartDate)
                                let startOfReflectionEnd = calendar.startOfDay(for: reflectionEndDate)
                                
                                // Check if reflection entry's date range overlaps with our target range
                                if startOfReflectionStart <= startOfEndDate && startOfReflectionEnd >= startOfStartDate {
                                    entryCount += 1
                                    print("Added Reflection entry to count, total now: \(entryCount)")
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            print("Error counting entries: \(error)")
        }
        
        print("Final entry count: \(entryCount)")
        return entryCount
    }
    
    // Function to extract date range from reflection filename
    private func extractDateRangeFromReflectionFilename(_ filename: String) -> (startDate: Date, endDate: Date, timeframeType: String)? {
        guard filename.hasPrefix("[Reflection]-") else { return nil }
        
        let pattern = "\\[Reflection\\]-\\[([^\\]]+)\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
        
        guard let match = filename.range(of: pattern, options: .regularExpression) else {
            print("Failed to match reflection filename pattern: \(filename)")
            return nil
        }
        
        let matchString = String(filename[match])
        let components = matchString.components(separatedBy: "]-[")
        
        guard components.count >= 5 else {
            print("Insufficient components in reflection filename: \(filename)")
            return nil
        }
        
        let timeframeType = components[1]
        let startDateString = components[2]
        let endDateString = components[3]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd-yyyy"
        
        guard let startDate = dateFormatter.date(from: startDateString),
              let endDate = dateFormatter.date(from: endDateString) else {
            print("Failed to parse dates from reflection filename: \(filename)")
            return nil
        }
        
        return (startDate: startDate, endDate: endDate, timeframeType: timeframeType)
    }
    
    // Function to create a new reflection entry
    private func createReflectionEntry(title: String, fromDate: Date, toDate: Date, entryCount: Int, timeframeType: String) -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        
        // Create filename with reflection format
        dateFormatter.dateFormat = "MM-dd-yyyy"
        let startDateString = dateFormatter.string(from: fromDate)
        let endDateString = dateFormatter.string(from: toDate)
        
        // Create time string separately (only time, not date)
        dateFormatter.dateFormat = "HH-mm-ss"
        let timeString = dateFormatter.string(from: now)
        
        let filename = "[Reflection]-[\(timeframeType)]-[\(startDateString)]-[\(endDateString)]-[\(timeString)].md"
        
        // Create date range for sidebar display (like "Week: Jul 11 - Jul 18")
        dateFormatter.dateFormat = "MMM d"
        let displayStartDate = dateFormatter.string(from: fromDate)
        let displayEndDate = dateFormatter.string(from: toDate)
        let displayDateRange = "\(timeframeType): \(displayStartDate) - \(displayEndDate)"
        
        // Create preview text with just the entry count for reflections
        let previewText = "Read \(entryCount) entries"
        
        return HumanEntry(
            id: id,
            date: displayDateRange,
            filename: filename,
            previewText: previewText
        )
    }
    
    // Function to create a new question entry
    private func createQuestionEntry(question: String) -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        
        // Create filename with question format [Question]-[MM-dd-yyyy]-[HH-mm-ss].md
        dateFormatter.dateFormat = "MM-dd-yyyy"
        let dateString = dateFormatter.string(from: now)
        
        dateFormatter.dateFormat = "HH-mm-ss"
        let timeString = dateFormatter.string(from: now)
        
        let filename = "[Question]-[\(dateString)]-[\(timeString)].md"
        
        // Create display date for sidebar
        dateFormatter.dateFormat = "MMM d"
        let displayDate = dateFormatter.string(from: now)
        
        // Create preview text with the question (truncated to match updatePreviewText behavior)
        let previewText = question.isEmpty ? "" : (question.count > 24 ? String(question.prefix(24)) + "..." : question)
        
        return HumanEntry(
            id: id,
            date: displayDate,
            filename: filename,
            previewText: previewText
        )
    }
    
    // Function to create a new weekly entry
    private func createWeeklyEntry(title: String, startDate: Date, endDate: Date) -> HumanEntry {
        let id = UUID()
        let now = Date()
        let dateFormatter = DateFormatter()
        
        // Create filename with new format [Weekly]-[start-date]-[end-date]-[time]
        dateFormatter.dateFormat = "MM-dd-yyyy"
        let startDateString = dateFormatter.string(from: startDate)
        let endDateString = dateFormatter.string(from: endDate)
        
        dateFormatter.dateFormat = "HH-mm-ss"
        let timeString = dateFormatter.string(from: now)
        
        let filename = "[Weekly]-[\(startDateString)]-[\(endDateString)]-[\(timeString)].md"
        
        // For display date
        dateFormatter.dateFormat = "MMM d"
        let startDisplayDate = dateFormatter.string(from: startDate)
        let endDisplayDate = dateFormatter.string(from: endDate)
        let displayDate = "\(startDisplayDate) - \(endDisplayDate)"
        
        let newEntry = HumanEntry(
            id: id,
            date: displayDate,
            filename: filename,
            previewText: title
        )
        
        // Add to entries and select it
        entries.insert(newEntry, at: 0)
        selectedEntryId = newEntry.id
        
        return newEntry
    }
    
    // Add function to load existing entries
    private func loadExistingEntries() {
        let documentsDirectory = getDocumentsDirectory()
        print("Looking for entries in: \(documentsDirectory.path)")
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil)
            let mdFiles = fileURLs.filter { $0.pathExtension == "md" }
            
            print("Found \(mdFiles.count) .md files")
            
            // Process each file
            let entriesWithDates = mdFiles.compactMap { fileURL -> (entry: HumanEntry, date: Date, content: String)? in
                let filename = fileURL.lastPathComponent
                print("Processing: \(filename)")
                
                var fileDate: Date?
                var displayDate: String = ""
                let uuid = UUID() // Generate new UUID for each entry
                
                // Handle Daily entries: [Daily]-[MM-dd-yyyy]-[HH-mm-ss].md
                if filename.hasPrefix("[Daily]-") {
                    if let dateMatch = filename.range(of: "\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]", options: .regularExpression) {
                        let matchString = String(filename[dateMatch])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 2 {
                            let dateComponent = components[0].replacingOccurrences(of: "[", with: "")
                            let timeComponent = components[1].replacingOccurrences(of: "]", with: "")
                            
                            let dateTimeString = "\(dateComponent)-\(timeComponent)"
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
                            
                            if let parsedDate = dateFormatter.date(from: dateTimeString) {
                                fileDate = parsedDate
                                dateFormatter.dateFormat = "MMM d"
                                displayDate = dateFormatter.string(from: parsedDate)
                            }
                        }
                    }
                }
                // Handle Weekly entries: [Weekly]-[MM-dd-yyyy]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Weekly]-") {
                    let pattern = "\\[Weekly\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 4 {
                            let startDateString = components[1]
                            let endDateString = components[2]
                            let timeString = components[3].replacingOccurrences(of: "]", with: "")
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let startDate = dateFormatter.date(from: startDateString),
                               let endDate = dateFormatter.date(from: endDateString) {
                                // Combine end date with time for proper sorting
                                dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
                                let endDateWithTime = "\(endDateString)-\(timeString)"
                                fileDate = dateFormatter.date(from: endDateWithTime)
                                
                                // Format display date as range
                                dateFormatter.dateFormat = "MMM d"
                                let startDisplay = dateFormatter.string(from: startDate)
                                let endDisplay = dateFormatter.string(from: endDate)
                                displayDate = "\(startDisplay) - \(endDisplay)"
                            }
                        }
                    }
                }
                // Handle Reflection entries: [Reflection]-[timeframeType]-[MM-dd-yyyy]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Reflection]-") {
                    let pattern = "\\[Reflection\\]-\\[([^\\]]+)\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 5 {
                            let timeframeType = components[1]
                            let startDateString = components[2]
                            let endDateString = components[3]
                            let timeString = components[4].replacingOccurrences(of: "]", with: "")
                            
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy"
                            
                            if let startDate = dateFormatter.date(from: startDateString),
                               let endDate = dateFormatter.date(from: endDateString) {
                                // Combine end date with time for proper sorting
                                dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
                                let endDateWithTime = "\(endDateString)-\(timeString)"
                                fileDate = dateFormatter.date(from: endDateWithTime)
                                
                                // Format display date as range
                                dateFormatter.dateFormat = "MMM d"
                                let startDisplay = dateFormatter.string(from: startDate)
                                let endDisplay = dateFormatter.string(from: endDate)
                                displayDate = "\(timeframeType): \(startDisplay) - \(endDisplay)"
                            }
                        }
                    }
                }
                // Handle Question entries: [Question]-[MM-dd-yyyy]-[HH-mm-ss].md
                else if filename.hasPrefix("[Question]-") {
                    let pattern = "\\[Question\\]-\\[(\\d{2}-\\d{2}-\\d{4})\\]-\\[(\\d{2}-\\d{2}-\\d{2})\\]"
                    if let match = filename.range(of: pattern, options: .regularExpression) {
                        let matchString = String(filename[match])
                        let components = matchString.components(separatedBy: "]-[")
                        
                        if components.count >= 3 {
                            let dateString = components[1]
                            let timeString = components[2].replacingOccurrences(of: "]", with: "")
                            
                            let dateTimeString = "\(dateString)-\(timeString)"
                            let dateFormatter = DateFormatter()
                            dateFormatter.dateFormat = "MM-dd-yyyy-HH-mm-ss"
                            
                            if let parsedDate = dateFormatter.date(from: dateTimeString) {
                                fileDate = parsedDate
                                dateFormatter.dateFormat = "MMM d"
                                displayDate = dateFormatter.string(from: parsedDate)
                            }
                        }
                    }
                }
                
                guard let validFileDate = fileDate else {
                    print("Failed to parse date from filename: \(filename)")
                    return nil
                }
                
                // Read file contents for preview
                do {
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    
                    let truncated: String
                    
                    // Special handling for question entries - extract question from USER section
                    if filename.hasPrefix("[Question]-") {
                        // Find the first USER section and extract the question
                        let userSeparator = "--- USER ---"
                        let reflectionSeparator = "--- REFLECTION ---"
                        
                        if let userStart = content.range(of: userSeparator)?.upperBound {
                            let afterUserSeparator = String(content[userStart...])
                            let userContent: String
                            
                            if let reflectionStart = afterUserSeparator.range(of: reflectionSeparator)?.lowerBound {
                                userContent = String(afterUserSeparator[..<reflectionStart])
                            } else {
                                userContent = afterUserSeparator
                            }
                            
                            let question = userContent
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "\n", with: " ")
                            
                            truncated = question.isEmpty ? "" : (question.count > 30 ? String(question.prefix(30)) + "..." : question)
                        } else {
                            truncated = ""
                        }
                    } else {
                        // Handle other entry types as before
                        let separator = "\n\n--- REFLECTION ---\n\n"
                        let contentForPreview = content.replacingOccurrences(of: separator, with: " ")
                        // Remove separators from preview
                        let cleanedPreview = removeReflectionSeparators(from: contentForPreview)
                        
                        let preview = cleanedPreview
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        truncated = preview.isEmpty ? "" : (preview.count > 30 ? String(preview.prefix(30)) + "..." : preview)
                    }
                    
                    return (
                        entry: HumanEntry(
                            id: uuid,
                            date: displayDate,
                            filename: filename,
                            previewText: truncated
                        ),
                        date: validFileDate,
                        content: content  // Store the full content to check for welcome message
                    )
                } catch {
                    print("Error reading file: \(error)")
                    return nil
                }
            }
            
            // Sort and extract entries
            entries = entriesWithDates
                .sorted { $0.date > $1.date }  // Sort by actual date from filename
                .map { $0.entry }
            
            print("Successfully loaded and sorted \(entries.count) entries")
            
            // Ensure previewText is always cleaned of section headers
            for entry in entries {
                updatePreviewText(for: entry)
            }
            
            // Check if we need to create a new entry
            let calendar = Calendar.current
            let today = Date()
            let todayStart = calendar.startOfDay(for: today)
            
            // Check if there's an empty entry from today
            let hasEmptyEntryToday = entries.contains { entry in
                // Convert the display date (e.g. "Mar 14") to a Date object
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMM d"
                if let entryDate = dateFormatter.date(from: entry.date) {
                    // Set year component to current year since our stored dates don't include year
                    var components = calendar.dateComponents([.year, .month, .day], from: entryDate)
                    components.year = calendar.component(.year, from: today)
                    
                    // Get start of day for the entry date
                    if let entryDateWithYear = calendar.date(from: components) {
                        let entryDayStart = calendar.startOfDay(for: entryDateWithYear)
                        return calendar.isDate(entryDayStart, inSameDayAs: todayStart) && entry.previewText.isEmpty
                    }
                }
                return false
            }
            
            // Check if we have only one entry and it's the welcome message
            let hasOnlyWelcomeEntry = entries.count == 1 && entriesWithDates.first?.content.contains("Welcome to Journal.") == true
            
            if entries.isEmpty {
                // First time user - create entry with welcome message
                print("First time user, creating welcome entry")
                createNewEntry()
            } else if !hasEmptyEntryToday && !hasOnlyWelcomeEntry {
                // No empty entry for today and not just the welcome entry - create new entry
                print("No empty entry for today, creating new entry")
                createNewEntry()
            } else {
                // Select the most recent empty entry from today or the welcome entry
                if let todayEntry = entries.first(where: { entry in
                    // Convert the display date (e.g. "Mar 14") to a Date object
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "MMM d"
                    if let entryDate = dateFormatter.date(from: entry.date) {
                        // Set year component to current year since our stored dates don't include year
                        var components = calendar.dateComponents([.year, .month, .day], from: entryDate)
                        components.year = calendar.component(.year, from: today)
                        
                        // Get start of day for the entry date
                        if let entryDateWithYear = calendar.date(from: components) {
                            let entryDayStart = calendar.startOfDay(for: entryDateWithYear)
                            return calendar.isDate(entryDayStart, inSameDayAs: todayStart) && entry.previewText.isEmpty
                        }
                    }
                    return false
                }) {
                    selectedEntryId = todayEntry.id
                    loadEntry(entry: todayEntry)
                } else if hasOnlyWelcomeEntry {
                    // If we only have the welcome entry, select it
                    selectedEntryId = entries[0].id
                    loadEntry(entry: entries[0])
                }
            }
            
        } catch {
            print("Error loading directory contents: \(error)")
            print("Creating default entry after error")
            createNewEntry()
        }
    }
    

    
    var timerButtonTitle: String {
        if !timerIsRunning && timeRemaining == 900 {
            return "15:00"
        }
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var timerColor: Color {
        if isHoveringTimer {
            return colorScheme == .light ? .black : .white
        } else {
            return colorScheme == .light ? .gray : .gray.opacity(0.8)
        }
    }
    
    var userLineHeight: CGFloat {
        let font = NSFont(name: userSelectedFont, size: userFontSize) ?? .systemFont(ofSize: userFontSize)
        let defaultLineHeight = getLineHeight(font: font)
        return (userFontSize * 1.5) - defaultLineHeight
    }
    
    var placeholderOffset: CGFloat {
        // Instead of using calculated line height, use a simple offset
        // Add extra offset to account for line spacing and positioning differences
        // In fullscreen mode, compensate for TextEditor's internal inset changes
        return isFullscreen ? userFontSize * 0.6 : userFontSize * 2.2
    }
    
    var aiLineHeight: CGFloat {
        return userFontSize * 1.5
    }
    
    // Add a color utility computed property
    var popoverBackgroundColor: Color {
        return colorScheme == .light ? Color.lightModeBackground : Color(NSColor.darkGray)
    }
    
    var popoverTextColor: Color {
        return colorScheme == .light ? Color.primary : Color.white
    }
    
    // Add missing computed properties from reference file
    var fontSizeButtonTitle: String {
        return "\(Int(userFontSize))px"
    }
    
    var randomButtonTitle: String {
        return currentRandomFont.isEmpty ? "Random" : "Random [\(currentRandomFont)]"
    }
    
    // Add state variables for font hover states
    @State private var isHoveringSize = false
    @State private var hoveredFont: String? = nil
    
    @ViewBuilder
    private var bottomNavigationView: some View {
        let textColor = colorScheme == .light ? Color.gray : Color.gray.opacity(0.8)
        let textHoverColor = colorScheme == .light ? Color.black : Color.white
        
        ZStack(alignment: .center) {
            VStack(spacing: 0) {
                
                // Main navigation bar
                ZStack(alignment: .center) {
                if !isNavbarHidden {
                    HStack(alignment: .center) {
                    // Left side - Navigation Controls: Sidebar, New Entry, Timer
                    HStack(spacing: 8) {
                        // History/sidebar button with new icon
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingSidebar.toggle()
                            }
                        }) {
                            Image(systemName: "book.fill")
                                .foregroundColor(isHoveringClock ? textHoverColor : textColor)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isHoveringClock = hovering
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button(action: {
                            if !isStreamingReflection {
                                createNewEntry()
                            }
                        }) {
                            Text("New Entry")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(isHoveringNewEntry ? textHoverColor : textColor)
                        .onHover { hovering in
                            if !isStreamingReflection {
                                isHoveringNewEntry = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button("Fullscreen") {
                            if !isFullscreen {
                                // Close sidebar first
                                if showingSidebar {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showingSidebar = false
                                    }
                                }
                                // Then activate fullscreen after a brief delay
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if let window = NSApplication.shared.windows.first {
                                        window.toggleFullScreen(nil)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(isHoveringFullscreen ? textHoverColor : textColor)
                        .onHover { hovering in
                            isHoveringFullscreen = hovering
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        // Timer button
                        if !isWeeklyReflection {
                            Text("•")
                                .foregroundColor(.gray)
                            
                            Button(timerButtonTitle) {
                                if timerIsRunning {
                                    timerIsRunning = false
                                    if !isHoveringBottomNav {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            bottomNavOpacity = 1.0
                                        }
                                    }
                                } else {
                                    timerIsRunning = true
                                    withAnimation(.easeOut(duration: 0.4)) {
                                        bottomNavOpacity = 0.0
                                    }
                                }
                                
                                // Force reset hover state after clicking
                                isHoveringTimer = false
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(timerColor)
                            .onHover { hovering in
                                isHoveringTimer = hovering
                                isHoveringBottomNav = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        // This ensures we're actually over the button when scrolling
                                    }
                            )
                            .onAppear {
                                NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                                    // Only process scroll if we're actually hovering AND the button is visible
                                    if isHoveringTimer && !isWeeklyReflection {
                                        let scrollBuffer = event.deltaY * 0.25
                                        
                                        if abs(scrollBuffer) >= 0.1 {
                                            let currentMinutes = timeRemaining / 60
                                            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                            let direction = -scrollBuffer > 0 ? 5 : -5
                                            let newMinutes = currentMinutes + direction
                                            let roundedMinutes = (newMinutes / 5) * 5
                                            let newTime = roundedMinutes * 60
                                            timeRemaining = min(max(newTime, 0), 2700)
                                        }
                                    }
                                    return event
                                }
                            }
                        }
                    }
                    .padding(8)
                    .cornerRadius(6)
                    .onHover { hovering in
                        isHoveringBottomNav = hovering
                    }
                    Spacer()
                    // Right side - Style Controls: Reflect, Dark Mode, Size, Fonts
                    HStack(spacing: 8) {
                        // Only show Reflect button for non-weekly entries
                        if !isWeeklyReflection {
                            // Toggle reflection panel button (only show if reflection has been initiated)
                            if hasInitiatedReflection {
                                
                                Button(action: {
                                    showReflectionPanel.toggle()
                                }) {
                                    Image(systemName: showReflectionPanel ? "sidebar.right" : "sidebar.left")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(isHoveringSidebar ? textHoverColor : textColor)
                                .onHover { hovering in
                                    isHoveringSidebar = hovering
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }

                                Text("•")
                                    .foregroundColor(.gray)
                            }
                            
                            Button(action: {
                                // Check if LLM is properly configured based on current mode
                                let llmConfig = isLLMConfigured()
                                if !llmConfig.isConfigured {
                                    // If in local mode and models haven't been fetched yet, try fetching them first
                                    if settingsManager.settings.llmMode == "local" && OllamaManager.shared.availableModels.isEmpty {
                                        checkLocalModelAvailability { isConfigured in
                                            if !isConfigured {
                                                self.showToast(message: llmConfig.errorMessage ?? "setup your LLM :)", type: .error)
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    self.showingSettings = true
                                                    self.selectedSettingsTab = .apiKeys
                                                }
                                            }
                                            // Note: We don't retry here because button clicks should be explicit
                                        }
                                        return
                                    }
                                    
                                    showToast(message: llmConfig.errorMessage ?? "setup your LLM :)", type: .error)
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showingSettings = true
                                        selectedSettingsTab = .apiKeys
                                    }
                                    return
                                }
                                
                                // Get API key for remote mode, or empty string for local mode
                                let apiKey = settingsManager.settings.llmMode == "remote" ? (getOpenAIKeyFromKeychain() ?? "") : ""
                                
                                if editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    showToast(message: "Empty! Write something and try again.", type: .error)
                                    return
                                }
                                
                                // Update the latest USER section with current editing text
                                if let lastIndex = sections.lastIndex(where: { $0.type == .user }) {
                                    sections[lastIndex].text = editingText
                                }
                                
                                // Add new REFLECTION section (will be filled during streaming)
                                sections.append(EntrySection(type: .reflection, text: ""))
                                
                                // Show reflection panel and freeze text editor
                                showReflectionPanel = true
                                hasInitiatedReflection = true
                                isStreamingReflection = true
                                
                                // Check if current entry is a reflection file and handle accordingly
                                if let currentId = selectedEntryId,
                                   let entry = entries.first(where: { $0.id == currentId }),
                                   let dateRange = extractDateRangeFromReflectionFilename(entry.filename) {
                                    
                                    // This is a reflection file - gather original entries and combine with current content
                                    print("Detected reflection file followup: \(entry.filename)")
                                    let originalEntries = gatherEntriesInDateRange(from: dateRange.startDate, to: dateRange.endDate)
                                    let currentReflectionContent = buildFullConversationContext()
                                    
                                    // Start reflection followup with full context
                                    reflectionViewModel.startReflectionFollowup(
                                        apiKey: apiKey,
                                        originalEntries: originalEntries,
                                        reflectionContent: currentReflectionContent,
                                        llmMode: settingsManager.settings.llmMode,
                                        selectedOllamaModel: settingsManager.settings.selectedOllamaModel,
                                        onComplete: {
                                            // On complete: add new empty USER section, unfreeze editor, and save
                                            sections.append(EntrySection(type: .user, text: "\n\n"))
                                            editingText = "\n\n"
                                            isStreamingReflection = false
                                            
                                            // Force UI refresh to ensure final chunk renders
                                            DispatchQueue.main.async {
                                                forceRefresh.toggle()
                                            }
                                            
                                            if let currentId = selectedEntryId,
                                               let entry = entries.first(where: { $0.id == currentId }) {
                                                saveEntry(entry: entry)
                                            }
                                        },
                                        onStream: { streamedText in
                                            // Update the latest REFLECTION section as it streams
                                            if let lastReflectionIndex = sections.lastIndex(where: { $0.type == .reflection }) {
                                                sections[lastReflectionIndex].text = streamedText
                                            }
                                            
                                            // Save entry as it streams with the partial content
                                            if let currentId = selectedEntryId,
                                               let entry = entries.first(where: { $0.id == currentId }) {
                                                saveEntry(entry: entry)
                                            }
                                        }
                                    )
                                } else {
                                    // Regular single-entry reflection
                                    let fullContext = buildFullConversationContext()
                                    
                                    // Start reflection with streaming to file
                                    reflectionViewModel.start(apiKey: apiKey, entryText: fullContext, llmMode: settingsManager.settings.llmMode, selectedOllamaModel: settingsManager.settings.selectedOllamaModel) {
                                        // On complete: add new empty USER section, unfreeze editor, and save
                                        sections.append(EntrySection(type: .user, text: "\n\n"))
                                        editingText = "\n\n"
                                        isStreamingReflection = false
                                        
                                        // Force UI refresh to ensure final chunk renders
                                        DispatchQueue.main.async {
                                            forceRefresh.toggle()
                                        }
                                        
                                        if let currentId = selectedEntryId,
                                           let entry = entries.first(where: { $0.id == currentId }) {
                                            saveEntry(entry: entry)
                                        }
                                    } onStream: { streamedText in
                                        // Update the latest REFLECTION section as it streams
                                        if let lastReflectionIndex = sections.lastIndex(where: { $0.type == .reflection }) {
                                            sections[lastReflectionIndex].text = streamedText
                                        }
                                        // Save to file during streaming
                                        if let currentId = selectedEntryId,
                                           let entry = entries.first(where: { $0.id == currentId }) {
                                            saveEntry(entry: entry)
                                        }
                                    }
                                }
                            }) {
                                Text("Reflect")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isHoveringReflect ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringReflect = hovering
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            
                            Text("•")
                                .foregroundColor(.gray)
                        }
                        
                        // Theme toggle
                        Button(action: {
                            colorScheme = colorScheme == .light ? .dark : .light
                            UserDefaults.standard.set(colorScheme == .light ? "light" : "dark", forKey: "colorScheme")
                        }) {
                            Image(systemName: colorScheme == .light ? "moon.fill" : "sun.max.fill")
                                .foregroundColor(isHoveringTheme ? textHoverColor : textColor)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isHoveringTheme = hovering
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        // Font size button
                        Button(fontSizeButtonTitle) {
                            let fontSizes: [CGFloat] = [16, 18, 20, 22, 24, 26]
                            if let currentIndex = fontSizes.firstIndex(of: userFontSize) {
                                let nextIndex = (currentIndex + 1) % fontSizes.count
                                let newSize = fontSizes[nextIndex]
                                userFontSize = newSize
                                aiFontSize = newSize
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(isHoveringSize ? textHoverColor : textColor)
                        .onHover { hovering in
                            isHoveringSize = hovering
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button("Lato") {
                            userSelectedFont = "Lato-Regular"
                            currentRandomFont = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(hoveredFont == "Lato" ? textHoverColor : textColor)
                        .onHover { hovering in
                            hoveredFont = hovering ? "Lato" : nil
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button("Arial") {
                            userSelectedFont = "Arial"
                            currentRandomFont = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(hoveredFont == "Arial" ? textHoverColor : textColor)
                        .onHover { hovering in
                            hoveredFont = hovering ? "Arial" : nil
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button("System") {
                            userSelectedFont = ".AppleSystemUIFont"
                            currentRandomFont = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(hoveredFont == "System" ? textHoverColor : textColor)
                        .onHover { hovering in
                            hoveredFont = hovering ? "System" : nil
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button("Serif") {
                            userSelectedFont = "Times New Roman"
                            currentRandomFont = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(hoveredFont == "Serif" ? textHoverColor : textColor)
                        .onHover { hovering in
                            hoveredFont = hovering ? "Serif" : nil
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Button(randomButtonTitle) {
                            if let randomFont = availableFonts.randomElement() {
                                userSelectedFont = randomFont
                                currentRandomFont = randomFont
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(hoveredFont == "Random" ? textHoverColor : textColor)
                        .onHover { hovering in
                            hoveredFont = hovering ? "Random" : nil
                            isHoveringBottomNav = hovering
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                    .padding(8)
                    .cornerRadius(6)
                    .onHover { hovering in
                        isHoveringBottomNav = hovering
                    }
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .background(colorScheme == .light ? Color.lightModeBackground : Color.black)
            .opacity(bottomNavOpacity)
            .animation(.easeOut(duration: 0.4), value: bottomNavOpacity)
            .onHover { hovering in
                isHoveringBottomNav = hovering
                if hovering {
                    withAnimation(.easeIn(duration: 0.2)) {
                        bottomNavOpacity = 1.0
                    }
                } else if timerIsRunning {
                    withAnimation(.easeOut(duration: 0.3).delay(0.5)) {
                        bottomNavOpacity = 0.0
                    }
                }
            }
            }
        }
        .frame(height: navHeight)
    }
    
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Sidebar
                if showingSidebar {
                    sidebar
                }
                
                ZStack {
                    // Main content area
                    Group {
                        if isWeeklyReflection {
                            centeredReflectionView
                        } else {
                            mainContent
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: showReflectionPanel)
                    
                    // Navigation is an overlay within each of those views
                }
                .background(colorScheme == .light ? Color.lightModeBackground : Color.black)
            }
            
            // Invisible hover zone at the bottom to trigger navbar appearance
            if timerIsRunning && bottomNavOpacity == 0 {
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                withAnimation(.easeIn(duration: 0.2)) {
                                    bottomNavOpacity = 1.0
                                }
                            }
                        }
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 600)
        .animation(.easeInOut(duration: 0.2), value: showingSidebar)
        .preferredColorScheme(colorScheme)
        .onAppear {
            showingSidebar = false  // Hide sidebar by default
            loadExistingEntries()
            
        }
        .onDisappear {
        }
        .onChange(of: text) { _ in
            // Save current entry when text changes
            if let currentId = selectedEntryId,
               let currentEntry = entries.first(where: { $0.id == currentId }) {
                saveEntry(entry: currentEntry)
            }
        }
        .onChange(of: userFontSize) { newValue in
            aiFontSize = newValue
        }
        .onReceive(timer) { _ in
            if timerIsRunning && timeRemaining > 0 {
                timeRemaining -= 1
            } else if timeRemaining == 0 {
                timerIsRunning = false
                if !isHoveringBottomNav {
                    withAnimation(.easeInOut(duration: 1.0)) {
                        bottomNavOpacity = 1.0
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        .overlay(
            // Settings Menu Overlay
            Group {
                if showingSettings {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingSettings = false
                            }
                        }
                    
                    SettingsModal(
                        showingSettings: $showingSettings,
                        selectedSettingsTab: $selectedSettingsTab,
                        openAIAPIKey: $openAIAPIKey,
                        settingsManager: settingsManager,
                        runDateRangeReflection: runDateRangeReflection
                    )
                }
            }
        )
        .overlay(
            // Command Bar Overlay
            Group {
                if showingCommandBar {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                showingCommandBar = false
                                commandBarText = ""
                                isCommandBarFocused = false
                                searchResults = []
                                selectedSearchIndex = 0
                            }
                        }
                    
                    ZStack(alignment: .top) {
                        // Command bar input
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                                .font(.system(size: userFontSize))
                            
                            TextField("Search journal entries or ask a question...", text: $commandBarText)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.custom(userSelectedFont, size: userFontSize))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(colorScheme == .dark ? Color.black : Color.white)
                                .cornerRadius(4)
                                .focused($isCommandBarFocused)
                                .onChange(of: commandBarText) { newValue in
                                    searchEntries(newValue)
                                }
                                .onSubmit {
                                    // Enter key - select the highlighted entry
                                    if selectedSearchIndex < searchResults.count {
                                        let selectedResult = searchResults[selectedSearchIndex]
                                        
                                        // Save current entry before switching (like sidebar does)
                                        if let currentId = selectedEntryId,
                                           let currentEntry = entries.first(where: { $0.id == currentId }) {
                                            saveEntry(entry: currentEntry)
                                            updatePreviewText(for: currentEntry)
                                        }
                                        
                                        // Select and load the entry (like sidebar does)
                                        selectedEntryId = selectedResult.entry.id
                                        loadEntry(entry: selectedResult.entry)
                                    } else if selectedSearchIndex == searchResults.count {
                                        // Handle "Ask Journal" action
                                        runQuestionResponse(question: commandBarText)
                                        return // Don't close command bar here, it's handled in runQuestionResponse
                                    }
                                    
                                    // Close the command bar
                                    withAnimation(.easeInOut(duration: 0.1)) {
                                        showingCommandBar = false
                                        commandBarText = ""
                                        isCommandBarFocused = false
                                        searchResults = []
                                        selectedSearchIndex = 0
                                    }
                                }
                                .onExitCommand {
                                    withAnimation(.easeInOut(duration: 0.1)) {
                                        showingCommandBar = false
                                        commandBarText = ""
                                        isCommandBarFocused = false
                                        searchResults = []
                                        selectedSearchIndex = 0
                                    }
                                }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(colorScheme == .dark ? Color.black : Color.white)
                                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .frame(maxWidth: 600)
                        .offset(y: -100) // Fix search bar position at center
                        
                        // Search results dropdown - positioned below search bar
                        if !commandBarText.isEmpty {
                            ScrollView {
                                ScrollViewReader { proxy in
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(Array(searchResults.enumerated()), id: \.element.entry.id) { index, result in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(result.entry.date)
                                                .font(.custom(userSelectedFont, size: userFontSize * 0.8))
                                                .foregroundColor(.gray)
                                            
                                            highlightedMatchText(result.matchContext, searchTerm: commandBarText)
                                                .font(.custom(userSelectedFont, size: userFontSize * 0.9))
                                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                                .lineLimit(2)
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            index == selectedSearchIndex 
                                                ? Color(red: 0.925, green: 0.925, blue: 0.925)
                                                : Color.white
                                        )
                                        .onTapGesture {
                                            // Save current entry before switching (like sidebar does)
                                            if let currentId = selectedEntryId,
                                               let currentEntry = entries.first(where: { $0.id == currentId }) {
                                                saveEntry(entry: currentEntry)
                                                updatePreviewText(for: currentEntry)
                                            }
                                            
                                            // Select and load the entry (like sidebar does)
                                            selectedEntryId = result.entry.id
                                            loadEntry(entry: result.entry)
                                            
                                            withAnimation(.easeInOut(duration: 0.1)) {
                                                showingCommandBar = false
                                                commandBarText = ""
                                                isCommandBarFocused = false
                                                searchResults = []
                                                selectedSearchIndex = 0
                                            }
                                        }
                                        .id("search-result-\(index)")
                                        
                                        Divider()
                                            .background(Color(red: 0.95, green: 0.95, blue: 0.95))
                                    }
                                    
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("✨ Ask Journal")
                                            .font(.custom(userSelectedFont, size: userFontSize * 0.8))
                                            .foregroundColor(.gray)
                                        
                                        Text(commandBarText)
                                            .font(.custom(userSelectedFont, size: userFontSize * 0.9))
                                            .foregroundColor(colorScheme == .dark ? .white : .black)
                                            .lineLimit(2)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedSearchIndex == searchResults.count
                                            ? Color(red: 0.925, green: 0.925, blue: 0.925)
                                            : Color.white
                                    )
                                    .onTapGesture {
                                        // Handle "Ask Journal" action here
                                        runQuestionResponse(question: commandBarText)
                                    }
                                    .id("ask-journal-entry")
                                }
                                .onChange(of: selectedSearchIndex) { newIndex in
                                    // Auto-scroll to keep selected item visible
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if newIndex < searchResults.count {
                                            proxy.scrollTo("search-result-\(newIndex)", anchor: .bottom)
                                        } else {
                                            proxy.scrollTo("ask-journal-entry", anchor: .bottom)
                                        }
                                    }
                                    
                                }
                            }
                        }
                            .scrollIndicators(.hidden)
                            .frame(maxWidth: 600, maxHeight: min(400, CGFloat(min(searchResults.count + 1, 8)) * 80))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(red: 0.8863, green: 0.8471, blue: 0.8078))
                                    .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .offset(y: -25) // Position dropdown with more space below search bar
                            .transition(.opacity)
                        }
                    }
                    .transition(.opacity)
                }
            }
        )
        .overlay(
            // Toast Overlay
            toastOverlay
        )
        .onChange(of: reflectionViewModel.isLoading) { isLoading in
            if isLoading {
                isUserEditorFocused = false
            }
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Check for Command+K
                if event.modifierFlags.contains(.command) && event.keyCode == 40 { // 40 is the keycode for 'k'
                    withAnimation(.easeInOut(duration: 0.1)) {
                        showingCommandBar.toggle()
                        if showingCommandBar {
                            commandBarText = ""
                            searchResults = []
                            selectedSearchIndex = 0
                            // Delay focus slightly to ensure the view is visible
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isCommandBarFocused = true
                            }
                        } else {
                            isCommandBarFocused = false
                            searchResults = []
                            selectedSearchIndex = 0
                        }
                    }
                    return nil // Consume the event
                }
                
                // Check for Command+T (toggle sidebar)
                if event.modifierFlags.contains(.command) && event.keyCode == 17 { // 17 is the keycode for 't'
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSidebar.toggle()
                    }
                    return nil // Consume the event
                }
                
                // Check for Command+Shift+F (toggle fullscreen)
                if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 3 { // 3 is the keycode for 'f'
                    if !isFullscreen {
                        // Close sidebar first
                        if showingSidebar {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingSidebar = false
                            }
                        }
                        // Then activate fullscreen after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let window = NSApplication.shared.windows.first {
                                window.toggleFullScreen(nil)
                            }
                        }
                    }
                    return nil // Consume the event
                }
                
                // Handle arrow keys when command bar is open and focused
                if showingCommandBar && isCommandBarFocused && !commandBarText.isEmpty {
                    if event.keyCode == 125 { // Down arrow
                        if selectedSearchIndex == searchResults.count {
                            selectedSearchIndex = 0 // Wrap to first entry
                        } else {
                            selectedSearchIndex += 1
                        }
                        return nil // Consume the event
                    } else if event.keyCode == 126 { // Up arrow
                        if selectedSearchIndex == 0 {
                            selectedSearchIndex = searchResults.count // Wrap to "Ask Journal" entry
                        } else {
                            selectedSearchIndex -= 1
                        }
                        return nil // Consume the event
                    }
                }
                
                // Handle arrow keys for entry navigation when an entry is manually selected
                if manuallySelectedEntryId != nil && !showingCommandBar {
                    if event.keyCode == 125 { // Down arrow
                        navigateToNextEntry()
                        return nil // Consume the event
                    } else if event.keyCode == 126 { // Up arrow
                        navigateToPreviousEntry()
                        return nil // Consume the event
                    }
                }
                
                return event
            }
            
            // Global click monitor - default to clearing selection, sidebar entries will override
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                manuallySelectedEntryId = nil
                return event // Let the event continue to reach button actions
            }
            
            // Add notification listeners for menu commands
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ToggleSidebar"),
                object: nil,
                queue: .main
            ) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSidebar.toggle()
                }
            }
            
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ToggleFullscreen"),
                object: nil,
                queue: .main
            ) { _ in
                if !isFullscreen {
                    // Close sidebar first
                    if showingSidebar {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSidebar = false
                        }
                    }
                    // Then activate fullscreen after a brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let window = NSApplication.shared.windows.first {
                            window.toggleFullScreen(nil)
                        }
                    }
                }
            }
            
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ToggleSettings"),
                object: nil,
                queue: .main
            ) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSettings.toggle()
                }
            }
            
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("CreateNewEntry"),
                object: nil,
                queue: .main
            ) { _ in
                createNewEntry()
            }
        }
    }
    
    private var mainContent: some View {
        ZStack {
            (colorScheme == .light ? Color.lightModeBackground : Color.black)
                .ignoresSafeArea()
            
            HStack(alignment: .top, spacing: 0) {
                // Left side - Text Editor
                VStack(spacing: 0) {
                    TextEditor(text: Binding(
                        get: { editingText },
                        set: { newValue in
                            // Always ensure the text starts with exactly two newlines
                            var processedValue = newValue
                            
                            // Handle empty or whitespace-only content
                            if processedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                processedValue = "\n\n"
                            } else if !processedValue.hasPrefix("\n\n") {
                                // Remove any leading newlines and add exactly two
                                let trimmedLeading = processedValue.trimmingCharacters(in: .newlines)
                                processedValue = "\n\n" + trimmedLeading
                            } else if processedValue.hasPrefix("\n") && !processedValue.hasPrefix("\n\n") {
                                // If starts with single newline, add one more
                                processedValue = "\n" + processedValue
                            }
                            
                            // Additional safety check: ensure we have at least \n\n
                            if processedValue.count < 2 || !processedValue.hasPrefix("\n\n") {
                                processedValue = "\n\n" + processedValue.trimmingCharacters(in: .newlines)
                            }
                            
                            editingText = processedValue
                            
                            // Update the last user section
                            if let lastUserIdx = sections.lastIndex(where: { $0.type == .user }) {
                                sections[lastUserIdx].text = editingText
                            }
                            if let currentId = selectedEntryId,
                               let currentEntry = entries.first(where: { $0.id == currentId }) {
                                saveEntry(entry: currentEntry)
                                updatePreviewText(for: currentEntry)
                            }
                        }
                    ))
                    .font(.custom(userSelectedFont, size: userFontSize))
                    .foregroundColor(colorScheme == .light ? Color(red: 0.20, green: 0.20, blue: 0.20) : Color(red: 0.90, green: 0.90, blue: 0.90))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .lineSpacing(userLineHeight)
                    .frame(maxWidth: showReflectionPanel ? .infinity : 650)
                    .padding(.horizontal, showReflectionPanel ? 24 : 16)
                    .padding(.bottom, navHeight)
                    .background(Color.clear)
                    .textSelection(.enabled)
                    .disabled(reflectionViewModel.isLoading || isStreamingReflection)
                    .focused($isUserEditorFocused)
                    .onChange(of: editingText) { _ in
                    }
                    .overlay(
                        ZStack(alignment: .topLeading) {
                            if editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(placeholderText)
                                    .font(.custom(userSelectedFont, size: userFontSize))
                                    .foregroundColor(colorScheme == .light ? .gray.opacity(0.5) : .gray.opacity(0.6))
                                    .allowsHitTesting(false)
                                    .offset(x: showReflectionPanel ? 29 : 21, y: placeholderOffset)
                            }
                        }, alignment: .topLeading
                    )
                    .ignoresSafeArea()
                }
                
                // Divider (only show when reflection panel is visible)
                if showReflectionPanel {
                    Divider()
                        .opacity(showReflectionPanel ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.2), value: showReflectionPanel)
                }
                
                // Right side - Reflection Panel
                if showReflectionPanel {
                    VStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    // Show all sections except the latest USER section
                                    let sectionsToShow = sections.dropLast(sections.last?.type == .user ? 1 : 0)
                                    
                                    ForEach(Array(sectionsToShow.enumerated()), id: \.element.id) { index, section in
                                        VStack(alignment: .leading, spacing: 0) {
                                            if section.type == .user {
                                                // Show user text (no background, gray color) with padding to match reflection text
                                                Text(section.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                                    .font(.custom(userSelectedFont, size: userFontSize))
                                                    .foregroundColor(colorScheme == .light ? Color.gray : Color.gray.opacity(0.8))
                                                    .lineSpacing(userLineHeight)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(.horizontal, 16) // Add horizontal padding to match reflection text
                                                    .padding(.top, 16) // Add top padding to match bottom
                                                    .padding(.bottom, 16)
                                                    .textSelection(.enabled)
                                            } else {
                                                // Show reflection content with proper styling
                                                VStack(alignment: .leading, spacing: 0) {
                                                    if section.text.isEmpty && reflectionViewModel.isLoading {
                                                        // Show loading for empty reflection being streamed
                                                        HStack(alignment: .top, spacing: 0) {
                                                            OscillatingDotView(colorScheme: colorScheme)
                                                            Spacer()
                                                        }
                                                    } else if !section.text.isEmpty {
                                                        // Show reflection content with user's line height (not AI line height)
                                                        MarkdownTextView(
                                                            content: section.text,
                                                            font: userSelectedFont,
                                                            fontSize: userFontSize,
                                                            colorScheme: colorScheme,
                                                            lineHeight: userLineHeight  // Use user line height for proper spacing
                                                        )
                                                        .id(userFontSize)
                                                        .id(userSelectedFont)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .frame(minHeight: userFontSize * 1.5 + 32)
                                                    }
                                                }
                                                .padding()
                                                .frame(minHeight: userFontSize * 1.5 + 32)
                                                .background(Color.gray.opacity(0.1))
                                                .cornerRadius(12)
                                            }
                                        }
                                    }
                                    
                                    VStack(spacing: 0) { EmptyView() }.id("reflectionBottomAnchor")
                                }
                                .id(forceRefresh)
                                .padding(.horizontal, 24)
                                .padding(.top, 38)
                                .padding(.bottom, navHeight)
                            }
                            .scrollIndicators(.never)
                            .onChange(of: sections) { _ in
                                // Only scroll when we're actively streaming a reflection
                                if isStreamingReflection || reflectionViewModel.isLoading {
                                    withAnimation {
                                        // If navbar is visible, scroll to top of anchor (content above navbar)
                                        // If navbar is hidden, scroll to bottom of anchor (bottom of page)
                                        let anchor: UnitPoint = bottomNavOpacity > 0 ? .top : .bottom
                                        proxy.scrollTo("reflectionBottomAnchor", anchor: anchor)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(showReflectionPanel ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.3), value: showReflectionPanel)
                }
            }
            
            VStack {
                Spacer()
                bottomNavigationView
            }
            .animation(nil, value: showReflectionPanel)
            .ignoresSafeArea(.keyboard)
        }
    }
    
    @ViewBuilder
    private var sidebar: some View {
        if showingSidebar {
            sidebarContent
        }
    }
    
    @ViewBuilder
    private var sidebarContent: some View {
        Group {
            let textColor = colorScheme == .light ? Color.gray : Color.gray.opacity(0.8)
            let textHoverColor = colorScheme == .light ? Color.black : Color.white
            
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    sidebarHeader(textColor: textColor, textHoverColor: textHoverColor)
                    Divider().padding(.horizontal, 12)
                    sidebarEntriesList
                    // Spacer()
                    sidebarReflectionSection(textColor: textColor, textHoverColor: textHoverColor)
                }
                .frame(width: 200)
                .background(colorScheme == .light ? Color.lightModeBackground : Color.black)
                
                // Add right border
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 1)
                    .edgesIgnoringSafeArea(.vertical)
            }
        }
    }
    
    @ViewBuilder
    private func sidebarHeader(textColor: Color, textHoverColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Button(action: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: getDocumentsDirectory().path)
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Journal")
                            .font(.system(size: 16))
                            .foregroundColor(isHoveringHistory ? textHoverColor : textColor)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundColor(isHoveringHistory ? textHoverColor : textColor)
                    }
                    Text(getDocumentsDirectory().path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringHistory = hovering
            }
            
            Spacer()
            
            // Settings button moved to sidebar - aligned with journal title
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingSettings = true
                }
            }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(isHoveringSettings ? textHoverColor : textColor)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringSettings = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    @ViewBuilder
    private var sidebarEntriesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        sidebarEntryRow(entry: entry)
                            .id(entry.id)

                        // let isHovered = entry.id == hoveredEntryId || entries[index + 1].id == hoveredEntryId
                        let nextEntryExists = index + 1 < entries.count
                        let isSelected = entry.id == selectedEntryId || (nextEntryExists && entries[index + 1].id == selectedEntryId)
                        let isManuallySelected = entry.id == manuallySelectedEntryId || (nextEntryExists && entries[index + 1].id == manuallySelectedEntryId)

                        if index != entries.indices.last {
                            Divider()
                                .opacity(isManuallySelected ? 0 : 1)
                                .padding(.horizontal, isSelected ? 0 : 12)
                        }
                        
                    }
                    
                    VStack {
                        Spacer().frame(height: 50)
                    }
                    .id("bottom-padding")
                }
            }
            .scrollIndicators(.never)
            .onChange(of: selectedEntryId) { newEntryId in
                if let entryId = newEntryId {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        // If this is the last entry, scroll to bottom padding
                        if entryId == entries.last?.id {
                            proxy.scrollTo("bottom-padding", anchor: .bottom)
                        } else {
                            proxy.scrollTo(entryId, anchor: .center)
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func sidebarEntryRow(entry: HumanEntry) -> some View {
        Button(action: {
            // Set manual selection when entry is clicked
            manuallySelectedEntryId = entry.id
            
            if !isStreamingReflection && selectedEntryId != entry.id {
                // Save current entry before switching
                if let currentId = selectedEntryId,
                   let currentEntry = entries.first(where: { $0.id == currentId }) {
                    saveEntry(entry: currentEntry)
                    updatePreviewText(for: currentEntry)
                }
                
                selectedEntryId = entry.id
                loadEntry(entry: entry)
            }
        }) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.filename.hasPrefix("[Question]-") ? "Question" : entry.date)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        // Export/Trash icons that appear on hover
                        if hoveredEntryId == entry.id {
                            HStack(spacing: 8) {
                                // Export PDF button
                                Button(action: {
                                    exportEntryAsPDF(entry: entry)
                                }) {
                                    let exportIconColor: Color = {
                                        if hoveredExportId == entry.id {
                                            return colorScheme == .light ? .black : .white
                                        } else {
                                            return colorScheme == .light ? .gray : .gray.opacity(0.8)
                                        }
                                    }()
                                    
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 11))
                                        .foregroundColor(exportIconColor)
                                }
                                .buttonStyle(.plain)
                                .help("Export entry as PDF")
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        hoveredExportId = hovering ? entry.id : nil
                                    }
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                
                                // Trash icon
                                Button(action: {
                                    deleteEntry(entry: entry)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(hoveredTrashId == entry.id ? .red : .gray)
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        hoveredTrashId = hovering ? entry.id : nil
                                    }
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            }
                        }
                    }
                    
                    Text(entry.previewText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor(for: entry))
                    .padding(.horizontal, entry.id == manuallySelectedEntryId ? 8 : 0)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering in
            if !isStreamingReflection {
                withAnimation(.easeInOut(duration: 0.2)) {
                    hoveredEntryId = hovering ? entry.id : nil
                }
            }
        }
        .onAppear {
            NSCursor.pop()  // Reset cursor when button appears
        }
        .help("Click to select this entry")  // Add tooltip
    }
    
    @ViewBuilder
    private func sidebarReflectionSection(textColor: Color, textHoverColor: Color) -> some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            VStack(spacing: 8) {
                // First line: "Reflect"
                HStack {
                    Text("Run Reflection ↓")
                        .font(.system(size: 13))
                        .foregroundColor(textColor)
                        .padding(.top, 8)
                    Spacer()
                }
                
                // Second line: "Week Month Custom"
                HStack(spacing: 4) {
                    Button("Week") {
                        startReflection(timeframe: .week)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringReflectWeek ? textHoverColor : textColor)
                    .font(.system(size: 13))
                    .onHover { hovering in
                        isHoveringReflectWeek = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    
                    Text("•")
                        .foregroundColor(.gray)
                        .font(.system(size: 13))
                    
                    Button("Month") {
                        startReflection(timeframe: .month)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringReflectMonth ? textHoverColor : textColor)
                    .font(.system(size: 13))
                    .onHover { hovering in
                        isHoveringReflectMonth = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    
                    Text("•")
                        .foregroundColor(.gray)
                        .font(.system(size: 13))
                    
                    Button("Custom") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSettings = true
                            selectedSettingsTab = .reflections
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isHoveringReflectCustom ? textHoverColor : textColor)
                    .font(.system(size: 13))
                    .onHover { hovering in
                        isHoveringReflectCustom = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            
            // Bottom spacer for alignment with navbar
            Rectangle()
                .fill(Color.clear)
                .frame(height: 16) // Increased to push content up higher
        }
    }
    
    private func backgroundColor(for entry: HumanEntry) -> Color {
        if entry.id == manuallySelectedEntryId {
            return Color(red: 0.8863, green: 0.8471, blue: 0.8078)
        } else if entry.id == selectedEntryId {
            return Color.gray.opacity(0.1)  // More subtle selection highlight
        } else if entry.id == hoveredEntryId {
            return Color.gray.opacity(0.05)  // Even more subtle hover state
        } else {
            return Color.clear
        }
    }
    
    private func highlightedMatchText(_ text: String, searchTerm: String) -> Text {
        if searchTerm.isEmpty {
            return Text(text)
        }
        
        // Create an AttributedString for inline highlighting
        var attributedString = AttributedString(text)
        
        // Find all matches case-insensitively
        let nsText = text as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)
        
        while searchRange.location < nsText.length {
            let foundRange = nsText.range(of: searchTerm, options: .caseInsensitive, range: searchRange)
            
            if foundRange.location == NSNotFound {
                break
            }
            
            // Convert NSRange to AttributedString range
            if let stringRange = Range(foundRange, in: text) {
                let attrRange = AttributedString.Index(stringRange.lowerBound, within: attributedString)!..<AttributedString.Index(stringRange.upperBound, within: attributedString)!
                
                // Apply background color to the match with slightly rounded appearance
                attributedString[attrRange].backgroundColor = Color.brown.opacity(0.35)
                // Add slight padding effect by using a slightly darker background
                attributedString[attrRange].foregroundColor = Color.primary
            }
            
            // Move search range past this match
            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = nsText.length - searchRange.location
        }
        
        return Text(attributedString)
    }
    
    private func updatePreviewText(for entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        do {
            let fullContent = try String(contentsOf: fileURL, encoding: .utf8)
            let userSeparator = "--- USER ---"
            let reflectionSeparator = "--- REFLECTION ---"
            let userRange = (fullContent as NSString).range(of: userSeparator)
            let reflectionRange = (fullContent as NSString).range(of: reflectionSeparator)
            var preview = ""
            if userRange.location != NSNotFound {
                if reflectionRange.location != NSNotFound {
                    let userStart = userRange.location + userRange.length
                    let userEnd = reflectionRange.location
                    if userEnd > userStart {
                        let userText = (fullContent as NSString).substring(with: NSRange(location: userStart, length: userEnd - userStart)).trimmingCharacters(in: .whitespacesAndNewlines)
                        preview = userText
                    } else {
                        // If reflection comes before user, or range is invalid, just take from user start to end of string.
                        let userStart = userRange.location + userRange.length
                        preview = (fullContent as NSString).substring(from: userStart)
                    }
                } else {
                    let userStart = userRange.location + userRange.length
                    let userText = (fullContent as NSString).substring(from: userStart).trimmingCharacters(in: .whitespacesAndNewlines)
                    preview = userText
                }
            } else {
                preview = fullContent.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Special handling for reflection entries - show only "Read x entries"
            if entry.filename.hasPrefix("[Reflection]-") {
                // Use regex to extract "Read x entries" from the preview text
                let readPattern = "Read \\d+ entries"
                if let range = preview.range(of: readPattern, options: .regularExpression) {
                    preview = String(preview[range])
                } else {
                    // Fallback: just show "Read entries" if regex fails
                    preview = "Read entries"
                }
            } 
            // Special handling for question entries - show the question itself
            else if entry.filename.hasPrefix("[Question]-") {
                // Extract the question from the first USER section
                if userRange.location != NSNotFound {
                    let userStart = userRange.location + userRange.length
                    let userContent: String
                    
                    if reflectionRange.location != NSNotFound && reflectionRange.location > userStart {
                        userContent = (fullContent as NSString).substring(with: NSRange(location: userStart, length: reflectionRange.location - userStart))
                    } else {
                        userContent = (fullContent as NSString).substring(from: userStart)
                    }
                    
                    preview = userContent
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                }
            } else {
                // For non-reflection entries, remove separators and clean up as before
                preview = preview.replacingOccurrences(of: userSeparator, with: "")
                preview = preview.replacingOccurrences(of: reflectionSeparator, with: "")
                preview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
                preview = preview.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            let truncated = preview.isEmpty ? "" : (preview.count > 24 ? String(preview.prefix(24)) + "..." : preview)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].previewText = truncated
            }
        } catch {
            print("Error updating preview text: \(error)")
        }
    }
    
    private func saveEntry(entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        var contentToSave = ""
        
        // Ensure the latest USER section is updated with current editing text
        // But skip the first USER section if this is a reflection or question entry
        let userIndices = sections.enumerated().compactMap { index, section in
            section.type == .user ? index : nil
        }
        
        let isReflectionOrQuestion = entry.filename.hasPrefix("[Reflection]-") || entry.filename.hasPrefix("[Question]-")
        
        if let lastUserIndex = userIndices.last, userIndices.count > 1 {
            // Only update if there are multiple USER sections (skip the first one for reflection/question entries)
            sections[lastUserIndex].text = editingText
        } else if userIndices.count == 1, !isReflectionOrQuestion {
            // Only update if this is not a reflection or question entry (preserve their initial content)
            sections[userIndices[0]].text = editingText
        }
        
        // Add all sections in order with proper markers
        for (index, section) in sections.enumerated() {
            if index > 0 {
                contentToSave += "\n\n"
            }
            
            if section.type == .user {
                contentToSave += "--- USER ---\n\n"
            } else {
                contentToSave += "--- REFLECTION ---\n\n"
            }
            contentToSave += section.text
            
            if section.type == .user {
                contentToSave += "\n"
            }
        }
        
        do {
            try contentToSave.trimmingCharacters(in: .whitespacesAndNewlines).write(to: fileURL, atomically: true, encoding: .utf8)
            print("Successfully saved entry: \(entry.filename)")
        } catch {
            print("Error saving entry: \(error)")
        }
    }
    
    private func loadEntry(entry: HumanEntry) {
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)

        // Reset reflection state
        hasInitiatedReflection = false
        showReflectionPanel = false
        reflectionViewModel.reflectionResponse = ""
        isStreamingReflection = false
        sections.removeAll()
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                let fullContent = try String(contentsOf: fileURL, encoding: .utf8)
                
                // Parse new section-based format
                if fullContent.contains("--- USER ---") || fullContent.contains("--- REFLECTION ---") {
                    // Split content by section markers
                    _ = "(--- USER ---|--- REFLECTION ---)"  // sectionPattern (unused)
                    let parts = fullContent.components(separatedBy: .newlines)
                    
                    var currentSectionType: EntrySectionType? = nil
                    var currentSectionText = ""
                    
                    for line in parts {
                        if line == "--- USER ---" {
                            // Save previous section if it exists
                            if let sectionType = currentSectionType, !currentSectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                sections.append(EntrySection(type: sectionType, text: currentSectionText.trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                            currentSectionType = .user
                            currentSectionText = ""
                        } else if line == "--- REFLECTION ---" {
                            // Save previous section if it exists
                            if let sectionType = currentSectionType, !currentSectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                sections.append(EntrySection(type: sectionType, text: currentSectionText.trimmingCharacters(in: .whitespacesAndNewlines)))
                            }
                            currentSectionType = .reflection
                            currentSectionText = ""
                            hasInitiatedReflection = true
                        } else if currentSectionType != nil {
                            // Add line to current section
                            if !currentSectionText.isEmpty {
                                currentSectionText += "\n"
                            }
                            currentSectionText += line
                        }
                    }
                    
                    // Add the final section (including empty ones)
                    if let sectionType = currentSectionType {
                        sections.append(EntrySection(type: sectionType, text: currentSectionText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    
                    // Find the latest USER section for editing (must be the last section)
                    if let lastSection = sections.last, lastSection.type == .user {
                        editingText = lastSection.text.isEmpty ? "\n\n" : "\n\n" + lastSection.text
                    } else {
                        // If last section is not USER or no sections exist, create new USER section
                        editingText = "\n\n"
                        sections.append(EntrySection(type: .user, text: "\n\n"))
                    }
                    
                    // Show reflection panel if we have reflections
                    if hasInitiatedReflection {
                        showReflectionPanel = true
                    }
                    
                } else {
                    // Legacy format or new entry
                    editingText = fullContent.hasPrefix("\n\n") ? fullContent : "\n\n" + fullContent
                    sections = [EntrySection(type: .user, text: editingText)]
                }
                
                print("Successfully loaded entry: \(entry.filename)")
            } else {
                // New entry
                editingText = "\n\n"
                sections = [EntrySection(type: .user, text: "\n\n")]
            }
        } catch {
            print("Error loading entry: \(error)")
            // Fallback: start with empty entry
            editingText = "\n\n"
            sections = [EntrySection(type: .user, text: "\n\n")]
        }
    }
    
    private func createNewEntry() {
        let newEntry = HumanEntry.createNew()
        entries.insert(newEntry, at: 0) // Add to the beginning
        selectedEntryId = newEntry.id

        // Reset all reflection-related state for a clean slate
        reflectionViewModel.reflectionResponse = ""
        reflectionViewModel.isLoading = false
        reflectionViewModel.error = nil
        reflectionViewModel.hasBeenRun = false
        showReflectionPanel = false
        isWeeklyReflection = false
        hasInitiatedReflection = false
        isStreamingReflection = false
        followUpText = ""

        // Always start with a user section
        sections = [EntrySection(type: .user, text: "\n\n")]
        editingText = "\n\n"

        // If this is the first entry (entries was empty before adding this one)
        if entries.count == 1 {
            // Read welcome message from default.md
            if let defaultMessageURL = Bundle.main.url(forResource: "default", withExtension: "md"),
               let defaultMessage = try? String(contentsOf: defaultMessageURL, encoding: .utf8) {
                editingText = "\n\n" + defaultMessage
                sections[0].text = "\n\n" + defaultMessage
            }
            // Save the welcome message immediately
            saveEntry(entry: newEntry)
            // Update the preview text
            updatePreviewText(for: newEntry)
        } else {
            // Regular new entry starts with newlines
            editingText = "\n\n"
            sections[0].text = "\n\n"
            // Randomize placeholder text for new entry
            placeholderText = placeholderOptions.randomElement() ?? "\n\nBegin writing"
            // Save the empty entry
            saveEntry(entry: newEntry)
        }
        // Focus the text editor for the new entry with a slight delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isUserEditorFocused = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isUserEditorFocused = true
        }
    }
    
    private func navigateToNextEntry() {
        guard let currentId = manuallySelectedEntryId,
              let currentIndex = entries.firstIndex(where: { $0.id == currentId }) else {
            return
        }
        
        let nextIndex = currentIndex + 1
        
        // Stop at the bottom instead of wrapping
        if nextIndex >= entries.count {
            return
        }
        
        let nextEntry = entries[nextIndex]
        
        // Update both manual selection and load the entry
        manuallySelectedEntryId = nextEntry.id
        
        // Save current entry before switching
        if let currentEntry = entries.first(where: { $0.id == selectedEntryId }) {
            saveEntry(entry: currentEntry)
            updatePreviewText(for: currentEntry)
        }
        
        selectedEntryId = nextEntry.id
        loadEntry(entry: nextEntry)
    }
    
    private func navigateToPreviousEntry() {
        guard let currentId = manuallySelectedEntryId,
              let currentIndex = entries.firstIndex(where: { $0.id == currentId }) else {
            return
        }
        
        let previousIndex = currentIndex - 1
        
        // Stop at the top instead of wrapping
        if previousIndex < 0 {
            return
        }
        
        let previousEntry = entries[previousIndex]
        
        // Update both manual selection and load the entry
        manuallySelectedEntryId = previousEntry.id
        
        // Save current entry before switching
        if let currentEntry = entries.first(where: { $0.id == selectedEntryId }) {
            saveEntry(entry: currentEntry)
            updatePreviewText(for: currentEntry)
        }
        
        selectedEntryId = previousEntry.id
        loadEntry(entry: previousEntry)
    }
    
    private func deleteEntry(entry: HumanEntry) {
        // Delete the file from the filesystem
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            try fileManager.removeItem(at: fileURL)
            print("Successfully deleted file: \(entry.filename)")
            
            // Remove the entry from the entries array
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries.remove(at: index)
                
                // If the deleted entry was selected, select the first entry or create a new one
                if selectedEntryId == entry.id {
                    if let firstEntry = entries.first {
                        selectedEntryId = firstEntry.id
                        loadEntry(entry: firstEntry)
                    } else {
                        createNewEntry()
                    }
                }
            }
        } catch {
            print("Error deleting file: \(error)")
        }
    }
    
    // Extract a title from entry content for PDF export
    private func extractTitleFromContent(_ content: String, date: String) -> String {
        // Clean up content by removing leading/trailing whitespace and newlines
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If content is empty, just use the date
        if trimmedContent.isEmpty {
            return "Entry \(date)"
        }
        
        // Split content into words, ignoring newlines and removing punctuation
        let words = trimmedContent
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { word in
                word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}<>"))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
        
        // If we have at least 4 words, use them
        if words.count >= 4 {
            return "\(words[0])-\(words[1])-\(words[2])-\(words[3])"
        }
        
        // If we have fewer than 4 words, use what we have
        if !words.isEmpty {
            return words.joined(separator: "-")
        }
        
        // Fallback to date if no words found
        return "Entry \(date)"
    }
    
    private func exportEntryAsPDF(entry: HumanEntry) {
        // First make sure the current entry is saved
        if selectedEntryId == entry.id {
            saveEntry(entry: entry)
        }
        
        // Get entry content
        let documentsDirectory = getDocumentsDirectory()
        let fileURL = documentsDirectory.appendingPathComponent(entry.filename)
        
        do {
            // Read the content of the entry
            let entryContent = try String(contentsOf: fileURL, encoding: .utf8)
            
            // Extract a title from the entry content and add .pdf extension
            let suggestedFilename = extractTitleFromContent(entryContent, date: entry.date) + ".pdf"
            
            // Create save panel
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [UTType.pdf]
            savePanel.nameFieldStringValue = suggestedFilename
            savePanel.isExtensionHidden = false  // Make sure extension is visible
            
            // Show save dialog
            if savePanel.runModal() == .OK, let url = savePanel.url {
                // Create PDF data
                if let pdfData = createPDFFromText(text: entryContent) {
                    try pdfData.write(to: url)
                    print("Successfully exported PDF to: \(url.path)")
                }
            }
        } catch {
            print("Error in PDF export: \(error)")
        }
    }
    
    private func createPDFFromText(text: String) -> Data? {
        // Letter size page dimensions
        let pageWidth: CGFloat = 612.0  // 8.5 x 72
        let pageHeight: CGFloat = 792.0 // 11 x 72
        let margin: CGFloat = 72.0      // 1-inch margins
        
        // Calculate content area
        let contentRect = CGRect(
            x: margin,
            y: margin,
            width: pageWidth - (margin * 2),
            height: pageHeight - (margin * 2)
        )
        
        // Create PDF data container
        let pdfData = NSMutableData()
        
        // Configure text formatting attributes
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = userLineHeight
        
        let font = NSFont(name: userSelectedFont, size: userFontSize) ?? .systemFont(ofSize: userFontSize)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ]
        
        // Trim the initial newlines before creating the PDF
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Create the attributed string with formatting
        let attributedString = NSAttributedString(string: trimmedText, attributes: textAttributes)
        
        // Create a Core Text framesetter for text layout
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        
        // Create a PDF context with the data consumer
        guard let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData as CFMutableData)!, mediaBox: nil, nil) else {
            print("Failed to create PDF context")
            return nil
        }
        
        // Track position within text
        var currentRange = CFRange(location: 0, length: 0)
        var pageIndex = 0
        
        // Create a path for the text frame
        let framePath = CGMutablePath()
        framePath.addRect(contentRect)
        
        // Continue creating pages until all text is processed
        while currentRange.location < attributedString.length {
            // Begin a new PDF page
            pdfContext.beginPage(mediaBox: nil)
            
            // Fill the page with white background
            pdfContext.setFillColor(NSColor.white.cgColor)
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            
            // Create a frame for this page's text
            let frame = CTFramesetterCreateFrame(
                framesetter, 
                currentRange, 
                framePath, 
                nil
            )
            
            // Draw the text frame
            CTFrameDraw(frame, pdfContext)
            
            // Get the range of text that was actually displayed in this frame
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            
            // Move to the next block of text for the next page
            currentRange.location += visibleRange.length
            
            // Finish the page
            pdfContext.endPage()
            pageIndex += 1
            
            // Safety check - don't allow infinite loops
            if pageIndex > 1000 {
                print("Safety limit reached - stopping PDF generation")
                break
            }
        }
        
        // Finalize the PDF document
        pdfContext.closePDF()
        
        return pdfData as Data
    }

    // --- Audio Recording and Whisper API ---
    func toggleNavbarVisibility() {
        // If navbar is currently visible, hide it
        if !isNavbarHidden {
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavbarHidden = true
            }
        } else {
            // If navbar is hidden, show it again
            withAnimation(.easeInOut(duration: 0.3)) {
                isNavbarHidden = false
            }
        }
    }
    
    
    
    
    
    
    
    
    func showToast(message: String, type: ToastType) {
        toastMessage = message
        toastType = type
        withAnimation(.easeInOut(duration: 0.6)) {
            showToast = true
        }
        
        // Auto-hide after 3 seconds for success/info, 5 seconds for errors
        let duration: Double = type == .error ? 5.0 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation(.easeInOut(duration: 0.6)) {
                showToast = false
            }
        }
    }
    
    
    
    // --- Reflection Functionality ---
    
    class ReflectionViewModel: NSObject, ObservableObject, URLSessionDataDelegate {
        @Published var reflectionResponse: String = ""
        @Published var isLoading: Bool = false
        @Published var error: String? = nil
        @Published var hasBeenRun: Bool = false
        
        private var streamingTask: URLSessionDataTask?
        private var onComplete: (() -> Void)?
        private var onStream: ((String) -> Void)?
        
        // Thinking tag state for Ollama responses
        private var isInThinkingBlock: Bool = false
        private var currentThinkingTag: String? = nil
        private var bufferedContent: String = ""
        private var waitingForFirstContent: Bool = false

        func start(apiKey: String, entryText: String, llmMode: String, selectedOllamaModel: String?, onComplete: @escaping () -> Void, onStream: ((String) -> Void)? = nil) {
            if llmMode == "remote" {
                guard !apiKey.isEmpty else {
                    self.error = "Please enter your OpenAI API key in Settings"
                    return
                }
            } else {
                guard let model = selectedOllamaModel, !model.isEmpty else {
                    self.error = "Please select an Ollama model in Settings"
                    return
                }
            }
            
            guard !entryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.error = "Cannot reflect on an empty entry."
                return
            }

            self.reflectionResponse = ""
            self.isLoading = true
            self.error = nil
            self.hasBeenRun = true
            self.onComplete = onComplete
            self.onStream = onStream
            
            // Reset thinking tag state
            self.isInThinkingBlock = false
            self.currentThinkingTag = nil
            self.bufferedContent = ""
            self.waitingForFirstContent = false

            if llmMode == "remote" {
                streamOpenAIResponse(apiKey: apiKey, entryText: entryText)
            } else {
                streamOllamaResponse(model: selectedOllamaModel!, entryText: entryText)
            }
        }
        
        func startReflectionFollowup(apiKey: String, originalEntries: String, reflectionContent: String, llmMode: String, selectedOllamaModel: String?, onComplete: @escaping () -> Void, onStream: ((String) -> Void)? = nil) {
            if llmMode == "remote" {
                guard !apiKey.isEmpty else {
                    self.error = "Please enter your OpenAI API key in Settings"
                    return
                }
            } else {
                guard let model = selectedOllamaModel, !model.isEmpty else {
                    self.error = "Please select an Ollama model in Settings"
                    return
                }
            }
            
            guard !originalEntries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.error = "No original entries found for reflection followup."
                return
            }

            self.reflectionResponse = ""
            self.isLoading = true
            self.error = nil
            self.hasBeenRun = true
            self.onComplete = onComplete
            self.onStream = onStream
            
            // Reset thinking tag state
            self.isInThinkingBlock = false
            self.currentThinkingTag = nil
            self.bufferedContent = ""
            self.waitingForFirstContent = false
            
            // Combine original entries with current reflection content
            let combinedContent = originalEntries + "\n\n=== PREVIOUS REFLECTION AND NEW THOUGHTS ===\n\n" + reflectionContent
            
            if llmMode == "remote" {
                streamOpenAIResponse(apiKey: apiKey, entryText: combinedContent)
            } else {
                streamOllamaResponse(model: selectedOllamaModel!, entryText: combinedContent)
            }
        }
        
        func startQuestionResponse(apiKey: String, allEntries: String, question: String, llmMode: String, selectedOllamaModel: String?, onComplete: @escaping () -> Void, onStream: ((String) -> Void)? = nil) {
            if llmMode == "remote" {
                guard !apiKey.isEmpty else {
                    self.error = "Please enter your OpenAI API key in Settings"
                    return
                }
            } else {
                guard let model = selectedOllamaModel, !model.isEmpty else {
                    self.error = "Please select an Ollama model in Settings"
                    return
                }
            }
            
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.error = "Please provide a question."
                return
            }

            self.reflectionResponse = ""
            self.isLoading = true
            self.error = nil
            self.hasBeenRun = true
            self.onComplete = onComplete
            self.onStream = onStream
            
            // Reset thinking tag state
            self.isInThinkingBlock = false
            self.currentThinkingTag = nil
            self.bufferedContent = ""
            self.waitingForFirstContent = false
            
            if llmMode == "remote" {
                streamQuestionResponse(apiKey: apiKey, allEntries: allEntries, question: question)
            } else {
                streamOllamaQuestionResponse(model: selectedOllamaModel!, allEntries: allEntries, question: question)
            }
        }

        private func streamOpenAIResponse(apiKey: String, entryText: String) {
            let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
            
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let systemPrompt = """
            below are my journal entries as well as my reflections on them. wyt? talk through it with me like a friend. don't therapize me and give me a whole breakdown, don't repeat my thoughts with headings. really take all of this, and tell me back stuff truly as if you're an old homie.

            Keep it casual, don't say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with headings if needed. use new paragrahs to make what you say more readable.

            do not just go through every single thing i say, and say it back to me. you need to process everything i say, make connections i don't see it, and deliver it all back to me as a story that makes me feel what you think i wanna feel. thats what the best therapists do.

            the length should match the intensity of thought. if it's a light entry, be more concise. if it's a heavy entry, really dive in.
            
            ideally, you're style/tone should sound like the user themselves. it's as if the user is hearing their own tone but it should still feel different, because you have different things to say and don't just repeat back what i say.

            don't use markdown or any other formatting. just use text.

            else, start by saying, "hey, thanks for showing me this :) my thoughts:" or "more thoughts:"
            """
            
            let payload: [String: Any] = [
                "model": "gpt-4o",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": entryText]
                ],
                "stream": true
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.error = "Failed to prepare request."
                }
                return
            }
            
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            streamingTask = session.dataTask(with: request)
            streamingTask?.resume()
        }
        
        private func streamOllamaResponse(model: String, entryText: String) {
            let endpoint = URL(string: "http://localhost:11434/api/chat")!
            
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let systemPrompt = """
            below are my journal entries as well as my reflections on them. wyt? talk through it with me like a friend. don't therapize me and give me a whole breakdown, don't repeat my thoughts with headings. really take all of this, and tell me back stuff truly as if you're an old homie.

            Keep it casual, don't say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with headings if needed. use new paragrahs to make what you say more readable.

            do not just go through every single thing i say, and say it back to me. you need to process everything i say, make connections i don't see it, and deliver it all back to me as a story that makes me feel what you think i wanna feel. thats what the best therapists do.

            the length should match the intensity of thought. if it's a light entry, be more concise. if it's a heavy entry, really dive in.
            
            ideally, you're style/tone should sound like the user themselves. it's as if the user is hearing their own tone but it should still feel different, because you have different things to say and don't just repeat back what i say.

            don't use markdown or any other formatting. just use text.
            
            else, start by saying, "hey, thanks for showing me this :) my thoughts:" or "more thoughts:"
            """

            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": entryText]
            ]
            
            let payload: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": true
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.error = "Failed to prepare request."
                }
                return
            }
            
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            streamingTask = session.dataTask(with: request)
            streamingTask?.resume()
        }
        
        private func processOllamaContent(_ content: String) {
            print("🔍 processOllamaContent called with: '\(content.replacingOccurrences(of: "\n", with: "\\n"))'")
            print("📊 Current state - isInThinkingBlock: \(isInThinkingBlock), waitingForFirstContent: \(waitingForFirstContent), currentTag: \(currentThinkingTag ?? "nil")")
            print("📝 Current bufferedContent length: \(bufferedContent.count)")
            
            // If we're waiting for first content after closing tag, continue buffering
            if waitingForFirstContent {
                print("⏳ In waitingForFirstContent mode, adding to buffer")
                bufferedContent += content
                
                // Look for first non-whitespace character
                let trimmed = bufferedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                print("✂️ Trimmed content: '\(trimmed)'")
                if !trimmed.isEmpty {
                    // Found first actual content, start streaming from here
                    print("✅ Found first real content, starting to stream: '\(trimmed)'")
                    waitingForFirstContent = false
                    let contentToStream = trimmed
                    bufferedContent = ""
                    
                    DispatchQueue.main.async {
                        self.reflectionResponse += contentToStream
                        self.onStream?(self.reflectionResponse)
                    }
                } else {
                    print("⏸️ Still only whitespace, continuing to wait")
                }
                return
            }
            
            // Add content to buffer
            bufferedContent += content
            print("📝 Updated bufferedContent: '\(bufferedContent.replacingOccurrences(of: "\n", with: "\\n"))'")
            
            // If we're not in a thinking block yet, check if we're starting one
            if !isInThinkingBlock {
                print("🔄 Not in thinking block, checking for opening tags")
                // Check if content starts with '<' and we might be entering a thinking block
                if bufferedContent.hasPrefix("<") {
                    print("🏷️ Buffer starts with '<', looking for opening tag")
                    // Look for complete opening tags like <think>, <reasoning>, etc.
                    let openTagPattern = #"<([a-zA-Z][a-zA-Z0-9_\-]*)>"#
                    if let regex = try? NSRegularExpression(pattern: openTagPattern),
                       let match = regex.firstMatch(in: bufferedContent, range: NSRange(bufferedContent.startIndex..., in: bufferedContent)) {
                        if let tagRange = Range(match.range(at: 1), in: bufferedContent) {
                            currentThinkingTag = String(bufferedContent[tagRange])
                            isInThinkingBlock = true
                            print("🎯 Found opening tag: '\(currentThinkingTag!)', entering thinking block")
                            return // Don't stream content yet
                        }
                    }
                    // If we start with '<' but haven't found a complete tag yet, don't stream
                    print("⏸️ Starts with '<' but no complete tag found yet, not streaming")
                    return
                }
                
                print("📤 No thinking tag detected, streaming normally: '\(content)'")
                // No thinking tag detected, stream normally
                DispatchQueue.main.async {
                    self.reflectionResponse += content
                    self.onStream?(self.reflectionResponse)
                }
            } else {
                print("🧠 In thinking block, looking for closing tag")
                // We're in a thinking block, look for the closing tag
                if let tag = currentThinkingTag {
                    let closeTag = "</\(tag)>"
                    print("🔍 Looking for closing tag: '\(closeTag)'")
                    if let closeRange = bufferedContent.range(of: closeTag) {
                        print("🎉 Found closing tag!")
                        // Found closing tag, extract content after it
                        let afterThinkingContent = String(bufferedContent[closeRange.upperBound...])
                        print("📄 Content after thinking tag: '\(afterThinkingContent.replacingOccurrences(of: "\n", with: "\\n"))'")
                        
                        // Reset thinking block state
                        isInThinkingBlock = false
                        currentThinkingTag = nil
                        
                        // Check if there's actual content after the tag
                        let trimmedContent = afterThinkingContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("✂️ Trimmed after-tag content: '\(trimmedContent)'")
                        
                        if !trimmedContent.isEmpty {
                            print("✅ Found actual content after tag, streaming immediately: '\(trimmedContent)'")
                            // There's actual content, stream it immediately
                            bufferedContent = ""
                            DispatchQueue.main.async {
                                self.reflectionResponse += trimmedContent
                                self.onStream?(self.reflectionResponse)
                            }
                        } else {
                            print("⏳ Only whitespace after tag, entering waitingForFirstContent mode")
                            // Only whitespace after tag, wait for first real content
                            waitingForFirstContent = true
                            bufferedContent = afterThinkingContent
                        }
                    } else {
                        print("🔄 Closing tag not found yet, continuing to buffer")
                    }
                    // If we haven't found the closing tag yet, keep buffering
                }
            }
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }
        
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let stringData = String(data: data, encoding: .utf8) ?? ""
            print("🔗 URL Session received data: '\(stringData.replacingOccurrences(of: "\n", with: "\\n"))'")
            let lines = stringData.split(separator: "\n")
            print("📝 Split into \(lines.count) lines")
            
            for line in lines {
                // Handle OpenAI format (SSE with "data: " prefix)
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    
                    if jsonString == "[DONE]" {
                        DispatchQueue.main.async {
                            self.isLoading = false
                            self.onComplete?()
                        }
                        return
                    }
                    
                    if let jsonData = jsonString.data(using: .utf8) {
                        do {
                            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]],
                               let firstChoice = choices.first,
                               let delta = firstChoice["delta"] as? [String: Any],
                               let content = delta["content"] as? String {
                                DispatchQueue.main.async {
                                    self.reflectionResponse += content
                                    self.onStream?(self.reflectionResponse)
                                }
                            }
                        } catch {
                            // JSON parsing error
                        }
                    }
                } else {
                    // Handle Ollama format (JSON lines)
                    let trimmedLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    print("🌐 Ollama line received: '\(trimmedLine)'")
                    if !trimmedLine.isEmpty,
                       let jsonData = trimmedLine.data(using: .utf8) {
                        do {
                            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                print("📦 Parsed Ollama JSON: \(json)")
                                // Updated for /api/chat endpoint: extract message.content
                                if let message = json["message"] as? [String: Any],
                                   let content = message["content"] as? String {
                                    print("📨 Ollama response chunk: '\(content.replacingOccurrences(of: "\n", with: "\\n"))'")
                                    self.processOllamaContent(content)
                                }
                                // Remove old /api/generate 'response' field handling
                                // if let response = json["response"] as? String {
                                //     print("📨 Ollama response chunk: '\(response.replacingOccurrences(of: "\n", with: "\\n"))'")
                                //     self.processOllamaContent(response)
                                // }
                                if let done = json["done"] as? Bool, done {
                                    print("🏁 Ollama stream completed, processing remaining buffer")
                                    // Handle any remaining buffered content when stream completes
                                    print("🧹 Checking for remaining buffer content. Buffer empty: \(self.bufferedContent.isEmpty), inThinking: \(self.isInThinkingBlock), waitingForContent: \(self.waitingForFirstContent)")
                                    if !self.bufferedContent.isEmpty && (self.isInThinkingBlock || self.waitingForFirstContent) {
                                        // If we're still in a thinking block or waiting for content, stream the remaining content anyway
                                        let contentToStream = self.bufferedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                                        print("🔚 Streaming remaining buffer content: '\(contentToStream)'")
                                        if !contentToStream.isEmpty {
                                            DispatchQueue.main.async {
                                                self.reflectionResponse += contentToStream
                                                self.onStream?(self.reflectionResponse)
                                            }
                                        }
                                    }
                                    
                                    DispatchQueue.main.async {
                                        self.isLoading = false
                                        self.onComplete?()
                                    }
                                    return
                                }
                            }
                        } catch {
                            // JSON parsing error
                        }
                    }
                }
            }
        }
        
        private func streamQuestionResponse(apiKey: String, allEntries: String, question: String) {
            let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
            
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let systemPrompt = """
            below are my journal entries as well as my reflections on them. i will be asking a question and below is all the information you know about me. use this to answer the question.in your answer talk through it with me like a friend. don't therapize me and give me a whole breakdown, don't repeat my thoughts with headings. really take all of this, and answer the question as if you're an old homie.

            keep it casual, don't say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with headings if needed. use new paragrahs to make what you say more readable.

            do not just go through every single thing i say, and say it back to me. you need to process everything said, making connections i don't see it, and then use the relevant bits to answer the question

            don't use markdown or any other formatting. just use text.

            my entries: 
            """
            
            let payload: [String: Any] = [
                "model": "gpt-4o",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "system", "content": allEntries],
                    ["role": "user", "content": question]
                ],
                "stream": true
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.error = "Failed to prepare request."
                }
                return
            }
            
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            streamingTask = session.dataTask(with: request)
            streamingTask?.resume()
        }
        
        private func streamOllamaQuestionResponse(model: String, allEntries: String, question: String) {
            let endpoint = URL(string: "http://localhost:11434/api/chat")!
            
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let systemPrompt = """
            below are my journal entries as well as my reflections on them. i will be asking a question and below is all the information you know about me. use this to answer the question.in your answer talk through it with me like a friend. don't therapize me and give me a whole breakdown, don't repeat my thoughts with headings. really take all of this, and answer the question as if you're an old homie.

            keep it casual, don't say yo, help me make new connections i don't see, comfort, validate, challenge, all of it. dont be afraid to say a lot. format with headings if needed. use new paragrahs to make what you say more readable.

            do not just go through every single thing i say, and say it back to me. you need to process everything said, making connections i don't see it, and then use the relevant bits to answer the question

            don't use markdown or any other formatting. just use text.
            
            my entries: 
            """

            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "system", "content": allEntries],
                ["role": "user", "content": question]
            ]
            
            let payload: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": true
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.error = "Failed to prepare request."
                }
                return
            }
            
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            streamingTask = session.dataTask(with: request)
            streamingTask?.resume()
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            DispatchQueue.main.async {
                self.isLoading = false
                if let error = error {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    // Computed property for toast overlay to avoid type-checking complexity
    private var toastOverlay: some View {
        Group {
            if showToast {
                ToastView(
                    message: toastMessage, 
                    type: toastType,
                    selectedFont: userSelectedFont,
                    fontSize: 18,
                    colorScheme: colorScheme
                )
                .transition(.move(edge: .top))
            }
        }
    }

    // Add this after the mainContent and sidebar view definitions

    @ViewBuilder
    private var reflectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if reflectionViewModel.isLoading && reflectionViewModel.reflectionResponse.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    OscillatingDotView(colorScheme: colorScheme)
                    Spacer()
                }
                .padding()
            } else if let error = reflectionViewModel.error {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .padding()
            } else {
                MarkdownTextView(
                    content: reflectionViewModel.reflectionResponse, // Already just the reflection
                    font: userSelectedFont, // Use the same font as the user editor
                    fontSize: userFontSize,
                    colorScheme: colorScheme,
                    lineHeight: aiLineHeight
                )
                .id(userFontSize)
                .id(userSelectedFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: userFontSize * 1.5 + 32)
            }
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private var centeredReflectionView: some View {
        ZStack {
            (colorScheme == .light ? Color.lightModeBackground : Color.black)
                .ignoresSafeArea()

            ScrollView {
                VStack {
                    reflectionContent
                        .frame(maxWidth: 650)
                        .padding(.horizontal, 16)
                        .padding(.top, 32)
                        
                    Spacer()
                }
                .frame(minHeight: (NSScreen.main?.visibleFrame.height ?? 800) - navHeight)
            }
            .scrollIndicators(.never)
            .padding(.bottom, navHeight)
            
            VStack {
                Spacer()
                bottomNavigationView
            }
            .animation(nil, value: showReflectionPanel)
            .ignoresSafeArea(.keyboard)
        }
    }
}

// Add these view structs before the main ContentView struct
struct SettingsModal: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var showingSettings: Bool
    @Binding var selectedSettingsTab: SettingsTab
    @Binding var openAIAPIKey: String
    @ObservedObject var settingsManager: SettingsManager
    let runDateRangeReflection: (Date, Date, String) -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedSettingsTab)
            SettingsContent(
                selectedTab: selectedSettingsTab,
                openAIAPIKey: $openAIAPIKey,
                settingsManager: settingsManager,
                runDateRangeReflection: runDateRangeReflection
            )
        }
        .frame(width: 600, height: 400)
        .background(colorScheme == .light ? Color.lightModeBackground : Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
    }
}

struct SettingsSidebar: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var selectedTab: SettingsTab
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            // Sidebar Items
            VStack(alignment: .leading, spacing: 2) {
                SettingsSidebarItem(
                    title: "Reflection",
                    icon: "calendar",
                    isSelected: selectedTab == .reflections,
                    action: { selectedTab = .reflections }
                )
                
                SettingsSidebarItem(
                    title: "LLM",
                    icon: "bolt.circle",
                    isSelected: selectedTab == .apiKeys,
                    action: { selectedTab = .apiKeys }
                )
                
                SettingsSidebarItem(
                    title: "Voice",
                    icon: "waveform",
                    isSelected: selectedTab == .transcription,
                    action: { selectedTab = .transcription }
                )
            }
            .padding(.horizontal, 8)
            
            Spacer()
        }
        .frame(width: 180)
        .background(colorScheme == .light ? Color.lightModeBackground : Color(NSColor.controlBackgroundColor))
    }
}

struct SettingsSidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 16, height: 16)
                    .foregroundColor(isSelected ? (colorScheme == .dark ? .white : .white) : .primary)
                
                Text(title)
                    .foregroundColor(isSelected ? (colorScheme == .dark ? .white : .white) : .primary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? (colorScheme == .dark ? Color.black : Color.primary) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SettingsContent: View {
    let selectedTab: SettingsTab
    @Binding var openAIAPIKey: String
    @ObservedObject var settingsManager: SettingsManager
    let runDateRangeReflection: (Date, Date, String) -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedTab {
            case .reflections:
                ReflectionsSettingsView(
                    settingsManager: settingsManager,
                    onRunWeek: { fromDate, toDate in runDateRangeReflection(fromDate, toDate, "This Week") },
                    onRunMonth: { fromDate, toDate in runDateRangeReflection(fromDate, toDate, "This Month") },
                    onRunYear: { fromDate, toDate in runDateRangeReflection(fromDate, toDate, "This Year") },
                    onRunCustom: { fromDate, toDate in runDateRangeReflection(fromDate, toDate, "Custom") }
                )
            case .apiKeys:
                APIKeysSettingsView(openAIAPIKey: $openAIAPIKey, settingsManager: settingsManager)
            case .transcription:
                TranscriptionSettingsView(settingsManager: settingsManager)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onChange(of: selectedTab) { newTab in
            if newTab == .apiKeys {
                // Refresh available models when switching to LLM tab
                if settingsManager.settings.llmMode == "local" {
                    // Use local model detection for local mode
                    OllamaManager.shared.fetchLocalModels { models in
                        // Check if the currently selected model is still available
                        if let selectedModel = settingsManager.settings.selectedOllamaModel,
                           !models.contains(selectedModel),
                           !models.isEmpty {
                            // Select the first available model if current selection is not available
                            settingsManager.settings.selectedOllamaModel = models.first
                            settingsManager.saveSettings()
                        }
                    }
                } else {
                    // For remote mode, just ensure clean state
                    OllamaManager.shared.resetState()
                }
            }
        }
    }
}

// Separate component for Local configuration UI
struct LocalConfigurationView: View {
    @ObservedObject var settingsManager: SettingsManager
    @StateObject private var ollamaManager = OllamaManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Powered by Ollama. 100% private.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 24)
                
                ModelSelectionMenu(settingsManager: settingsManager, ollamaManager: ollamaManager)
                
                OllamaStatusView(ollamaManager: ollamaManager)
            }
        }
        .frame(maxWidth: 400)
    }
}

// Model selection dropdown component
struct ModelSelectionMenu: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var ollamaManager: OllamaManager
    
    var body: some View {
        Menu {
            ForEach(ollamaManager.availableModels, id: \.self) { model in
                Button(action: {
                    settingsManager.settings.selectedOllamaModel = model
                    settingsManager.saveSettings()
                }) {
                    Label(model, systemImage: settingsManager.settings.selectedOllamaModel == model ? "checkmark" : "")
                }
            }
        } label: {
            HStack {
                Text(ollamaManager.isFetchingModels ? "..." : (ollamaManager.availableModels.isEmpty ? "No models detected" : (settingsManager.settings.selectedOllamaModel ?? "Select a model")))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.primary)
                    .allowsHitTesting(false)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .menuStyle(.button)
        .onHover { isHovering in
            DispatchQueue.main.async {
                if isHovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

// Ollama status and installation view
struct OllamaStatusView: View {
    @ObservedObject var ollamaManager: OllamaManager
    
    var body: some View {
        VStack {
            if !ollamaManager.isFetchingModels && (ollamaManager.isPulling || !ollamaManager.isOllamaInstalled || !ollamaManager.availableModels.contains("smollm2:latest")) {
                if !ollamaManager.isOllamaInstalled {
                    OllamaNotInstalledView(ollamaManager: ollamaManager)
                } else if !ollamaManager.availableModels.contains("smollm2:latest") {
                    ModelInstallView(ollamaManager: ollamaManager)
                }
            }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }
}

// Ollama not installed warning
struct OllamaNotInstalledView: View {
    @ObservedObject var ollamaManager: OllamaManager
    @State private var isRefreshing = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Expandable warning box
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 13))
                
                HStack(spacing: 0) {
                    Text("Install at ")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    
                    Link("ollama.com/download", destination: URL(string: "https://ollama.com/download")!)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                        .underline()
                }
                .lineLimit(1)
                
                Spacer() // This makes the warning box expand
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(warningBackground)
            
            // Fixed-width refresh button
            Button(action: {
                refreshOllamaStatus()
            }) {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .colorInvert()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 16)
                    } else {
                        Text("Verify")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                .frame(minWidth: 60)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isRefreshing)
        }
    }
    
    private func refreshOllamaStatus() {
        isRefreshing = true
        let startTime = Date()
        
        // Check if Ollama is installed and start server if needed
        let isInstalled = ollamaManager.checkOllamaInstalled()
        
        if isInstalled {
            // Check server status first
            ollamaManager.checkServerStatus { isRunning in
                if !isRunning {
                    // Server not running, try to start it with retries
                    self.ollamaManager.ensureServerRunning { success, errorMessage in
                        DispatchQueue.main.async {
                            // Ensure minimum 1s spinner duration
                            let elapsed = Date().timeIntervalSince(startTime)
                            let remainingTime = max(0, 1.0 - elapsed)
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) {
                                self.isRefreshing = false
                            }
                        }
                    }
                } else {
                    // Server already running
                    DispatchQueue.main.async {
                        // Ensure minimum 1s spinner duration
                        let elapsed = Date().timeIntervalSince(startTime)
                        let remainingTime = max(0, 1.0 - elapsed)
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) {
                            self.isRefreshing = false
                        }
                    }
                }
            }
        } else {
            // Not installed, just update the state
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.isRefreshing = false
            }
        }
    }
    
    private var warningBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.yellow.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow.opacity(0.8), lineWidth: 1)
            )
    }
}

// Model installation view with progress
struct ModelInstallView: View {
    @ObservedObject var ollamaManager: OllamaManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if !ollamaManager.isPulling {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 13))
                    }
                    
                    Text(ollamaManager.isPulling ? ollamaManager.pullProgress : "Recommended model: smollm2")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                    
                    if ollamaManager.isPulling {
                        ProgressView(value: ollamaManager.pullPercentage, total: 100)
                            .progressViewStyle(LinearProgressViewStyle(tint: .black))
                            .background(Color.clear)
                        
                        Text(String(format: "%.0f%%", ollamaManager.pullPercentage))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: 30, alignment: .trailing)
                    } else {
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(ollamaManager.isPulling ? Color.gray.opacity(0.1) : Color.yellow.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ollamaManager.isPulling ? Color.black : Color.yellow.opacity(0.8), lineWidth: 1)
                        )
                )
                
                if !ollamaManager.isPulling {
                    Text("Install")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black)
                        )
                        .onTapGesture {
                            Task {
                                // Ensure server is running before attempting to pull model
                                ollamaManager.ensureServerRunning { success, error in
                                    if success {
                                        Task {
                                            await ollamaManager.pullModel("smollm2:latest")
                                        }
                                    } else {
                                        DispatchQueue.main.async {
                                            ollamaManager.pullProgress = "Error: \(error ?? "Failed to start server")"
                                        }
                                    }
                                }
                            }
                        }
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            }
            
            if ollamaManager.isPulling {
                HStack(spacing: 2) {
                    Text("You can safely close the modal. Your download will continue.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, ollamaManager.isPulling ? -2 : -8)
    }
}

// Separate component for Remote configuration UI
struct RemoteConfigurationView: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var openAIAPIKey: String
    @Binding var tempOpenAIApiKey: String
    @Binding var hasUnsavedOpenAI: Bool
    @Binding var showOpenAISaveConfirmation: Bool
    @Binding var isEditingMode: Bool
    @Binding var keychainAccessDenied: Bool
    
    var enterEditMode: () -> Void
    var saveAndExitEditMode: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Powered by OpenAI. Connect to their latest model.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("OpenAI API Key")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 24)
                
                SecureField(isEditingMode ? "Enter your OpenAI API key" : "••••••••••••••••••••", text: $tempOpenAIApiKey)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.gray.opacity(isEditingMode ? 0.5 : 0.3), lineWidth: 1)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isEditingMode ? Color.clear : Color.gray.opacity(0.1))
                            )
                    )
                    .foregroundColor(isEditingMode ? .primary : .secondary)
                    .disabled(!isEditingMode)
                    .onChange(of: tempOpenAIApiKey) { newValue in
                        if isEditingMode {
                            hasUnsavedOpenAI = (newValue != openAIAPIKey)
                        }
                    }
                    .padding(.horizontal, 24)
                
                HStack(spacing: 2) {
                    Text("Used for reflections. Get your key at")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Link("platform.openai.com/api-keys", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 24)
                
                HStack(spacing: 12) {
                    Button(action: {
                        if isEditingMode {
                            saveAndExitEditMode()
                        } else {
                            enterEditMode()
                        }
                    }) {
                        Text(isEditingMode ? "Save" : "Edit")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark ? Color.black : .primary)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    if showOpenAISaveConfirmation {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                            Text("Saved")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showOpenAISaveConfirmation)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: 400)
    }
}

struct APIKeysSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    @Binding var openAIAPIKey: String
    @ObservedObject var settingsManager: SettingsManager
    
    @State private var tempOpenAIApiKey: String = ""
    @State private var hasUnsavedOpenAI: Bool = false
    @State private var showOpenAISaveConfirmation: Bool = false
    @State private var isEditingMode: Bool = false
    @State private var keychainAccessDenied: Bool = false
    @StateObject private var ollamaManager = OllamaManager.shared
    
    private func enterEditMode() {
        // Check if keychain access is denied first
        if KeychainHelper.shared.isKeychainAccessDenied(for: .openAI) {
            print("🔒 enterEditMode: keychain access denied - staying in non-edit mode")
            keychainAccessDenied = true
            return
        }
        
        // Load current saved API key from keychain when user clicks Edit
        let savedKey = KeychainHelper.shared.loadAPIKey(for: .openAI) ?? ""
        print("🔓 enterEditMode: loaded from keychain = '\(savedKey)'")
        tempOpenAIApiKey = savedKey
        openAIAPIKey = savedKey  // Update the main state as well
        print("🔓 Set tempOpenAIApiKey to: '\(tempOpenAIApiKey)'")
        print("🔓 Set openAIAPIKey to: '\(openAIAPIKey)'")
        isEditingMode = true
        hasUnsavedOpenAI = false
        keychainAccessDenied = false
    }
    
    private func saveAndExitEditMode() {
        // Save the API key to keychain
        print("🔐 saveAndExitEditMode: tempOpenAIApiKey = '\(tempOpenAIApiKey)'")
        if !tempOpenAIApiKey.isEmpty {
            print("🔐 Saving to keychain: '\(tempOpenAIApiKey)'")
            KeychainHelper.shared.saveAPIKey(tempOpenAIApiKey, for: .openAI)
            openAIAPIKey = tempOpenAIApiKey
            print("🔐 Updated openAIAPIKey to: '\(openAIAPIKey)'")
        } else {
            print("🔐 Deleting from keychain (empty key)")
            KeychainHelper.shared.deleteAPIKey(for: .openAI)
            openAIAPIKey = ""
        }
        
        // Exit edit mode and show confirmation
        isEditingMode = false
        hasUnsavedOpenAI = false
        showOpenAISaveConfirmation = true
        tempOpenAIApiKey = "" // Clear the temp field
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showOpenAISaveConfirmation = false
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Configuration Title and Dropdown
            ConfigurationHeaderView(settingsManager: settingsManager)
                .padding(.horizontal, 24)
            
            // Show content based on selected configuration
            if settingsManager.settings.llmMode == "local" {
                LocalConfigurationView(settingsManager: settingsManager)
            } else {
                RemoteConfigurationView(
                    openAIAPIKey: $openAIAPIKey,
                    tempOpenAIApiKey: $tempOpenAIApiKey,
                    hasUnsavedOpenAI: $hasUnsavedOpenAI,
                    showOpenAISaveConfirmation: $showOpenAISaveConfirmation,
                    isEditingMode: $isEditingMode,
                    keychainAccessDenied: $keychainAccessDenied,
                    enterEditMode: enterEditMode,
                    saveAndExitEditMode: saveAndExitEditMode
                )
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
        .onAppear {
            // Initialize state based on current mode
            if settingsManager.settings.llmMode == "local" {
                print("🔍 Configuration view appeared with Local mode active")
                // Fetch models immediately without waiting for server
                ollamaManager.fetchLocalModels { models in
                    print("✅ Local models loaded: \(models)")
                }
                // Start server in background if needed
                ollamaManager.checkServerStatus { isRunning in
                    if !isRunning {
                        ollamaManager.startServer { success, error in
                            if success {
                                print("✅ Server started in background")
                            } else {
                                print("⚠️ Server couldn't start, but models are available: \(error ?? "Unknown error")")
                            }
                        }
                    }
                }
            } else {
                print("🔍 Configuration view appeared with Remote mode active")
                // Ensure clean state when in remote mode
                ollamaManager.resetState()
            }
        }
        .onChange(of: settingsManager.settings.llmMode) { newMode in
            if newMode == "local" {
                // Switching TO local mode: fetch models first, then start server
                print("🔄 Switching to Local mode")
                
                // Fetch models immediately
                ollamaManager.fetchLocalModels { models in
                    print("✅ Local models loaded: \(models)")
                }
                
                // Start server in background (don't wait)
                DispatchQueue.global(qos: .background).async {
                    ollamaManager.ensureServerRunning { success, error in
                        if success {
                            print("✅ Server started in background")
                        } else {
                            print("⚠️ Server couldn't start, but models are available: \(error ?? "Unknown error")")
                        }
                    }
                }
            } else {
                // Switching FROM local mode (to remote): stop server and reset state
                print("🔄 Switching to Remote mode")
                ollamaManager.stopServer()
                ollamaManager.resetState()
            }
        }
    }
}

// Configuration header with dropdown menu
struct ConfigurationHeaderView: View {
    @ObservedObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Menu {
                Button(action: {
                    settingsManager.settings.llmMode = "local"
                    settingsManager.saveSettings()
                }) {
                    Label("Local", systemImage: settingsManager.settings.llmMode == "local" ? "checkmark" : "")
                }
                
                Button(action: {
                    settingsManager.settings.llmMode = "remote"
                    settingsManager.saveSettings()
                }) {
                    Label("Remote", systemImage: settingsManager.settings.llmMode == "remote" ? "checkmark" : "")
                }
            } label: {
                HStack {
                    Text(settingsManager.settings.llmMode == "local" ? "Local" : "Remote")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .allowsHitTesting(false)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 200)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .menuStyle(.button)
            .onHover { isHovering in
                DispatchQueue.main.async {
                    if isHovering {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
        }
    }
}

struct ReflectionsSettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var settingsManager: SettingsManager
    let onRunWeek: (Date, Date) -> Void
    let onRunMonth: (Date, Date) -> Void
    let onRunYear: (Date, Date) -> Void
    let onRunCustom: (Date, Date) -> Void
    
    // Week
    @State private var weekFromDate: Date = {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysToSubtract = weekday == 1 ? 7 : weekday - 1 // Sunday = 1, so if today is Sunday, go back 7 days
        return calendar.date(byAdding: .day, value: -daysToSubtract, to: today) ?? today
    }()
    @State private var weekToDate: Date = Date()
    
    // Month  
    @State private var monthFromDate: Date = {
        let calendar = Calendar.current
        let today = Date()
        let year = calendar.component(.year, from: today)
        let month = calendar.component(.month, from: today)
        return calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? today
    }()
    @State private var monthToDate: Date = Date()
    
    // Year
    @State private var yearFromDate: Date = {
        let calendar = Calendar.current
        let today = Date()
        let year = calendar.component(.year, from: today)
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
    }()
    @State private var yearToDate: Date = Date()
    
    // Custom
    @State private var customFromDate: Date = Date()
    @State private var customToDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            
            // Week Section
            VStack(alignment: .leading, spacing: 8) {
                Text("This Week")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $weekFromDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $weekToDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("")
                            .font(.caption)
                            .foregroundColor(.clear)
                        Button("Run") {
                            onRunWeek(weekFromDate, weekToDate)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black : .primary)
                        )
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            
            VStack(spacing: 4) {
                Spacer()
                Divider()
                Spacer()
            }
            
            // Month Section
            VStack(alignment: .leading, spacing: 8) {
                Text("This Month")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $monthFromDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $monthToDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("")
                            .font(.caption)
                            .foregroundColor(.clear)
                        Button("Run") {
                            onRunMonth(monthFromDate, monthToDate)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black : .primary)
                        )
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            
            VStack(spacing: 4) {
                Spacer()
                Divider()
                Spacer()
            }
            
            // Year Section
            VStack(alignment: .leading, spacing: 8) {
                Text("This Year")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $yearFromDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $yearToDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("")
                            .font(.caption)
                            .foregroundColor(.clear)
                        Button("Run") {
                            onRunYear(yearFromDate, yearToDate)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black : .primary)
                        )
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            
            VStack(spacing: 4) {
                Spacer()
                Divider()
                Spacer()
            }
            
            // Custom Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $customFromDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        DatePicker("", selection: $customToDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .padding(.leading, -8)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("")
                            .font(.caption)
                            .foregroundColor(.clear)
                        Button("Run") {
                            onRunCustom(customFromDate, customToDate)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black : .primary)
                        )
                        .buttonStyle(PlainButtonStyle())
                        .disabled(customFromDate > customToDate)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 20)
        .onAppear {
            // Set up default date ranges
            let today = Date()
            let calendar = Calendar.current
            
            // Week: From last Sunday to today
            let weekday = calendar.component(.weekday, from: today)
            let daysToSubtract = weekday == 1 ? 7 : weekday - 1 // Sunday = 1, so if today is Sunday, go back 7 days
            weekFromDate = calendar.date(byAdding: .day, value: -daysToSubtract, to: today) ?? today
            weekToDate = today
            
            // Month: From 1st of current month to today
            let year = calendar.component(.year, from: today)
            let month = calendar.component(.month, from: today)
            monthFromDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? today
            monthToDate = today
            
            // Year: From 1/1 of current year to today
            yearFromDate = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
            yearToDate = today
            
            // Custom: To = today, From = blank (will show today initially)
            customToDate = today
            // Leave customFromDate as is (will show today by default)
        }
    }
}

struct TranscriptionSettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Coming soon :)")
                .foregroundColor(.gray)
            Spacer()
        }
        .padding(.top, 8)
    }
}

// Helper function to calculate line height
func getLineHeight(font: NSFont) -> CGFloat {
    return font.ascender - font.descender + font.leading
}

// Add helper extension to find NSTextView
extension NSView {
    func findTextView() -> NSView? {
        if self is NSTextView {
            return self
        }
        for subview in subviews {
            if let textView = subview.findTextView() {
                return textView
            }
        }
        return nil
    }
}

// Add helper extension for finding subviews of a specific type
extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let typedSelf = self as? T {
            return typedSelf
        }
        for subview in subviews {
            if let found = subview.findSubview(ofType: type) {
                return found
            }
        }
        return nil
    }
}

// Add enum for toast types before ContentView struct
enum ToastType {
    case success, error, info
    
    var color: Color {
        switch self {
        case .success:
            return .green
        case .error:
            return .red
        case .info:
            return .blue
        }
    }
    
    var icon: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}



// Add ToastView component after the other view structs
struct ToastView: View {
    let message: String
    let type: ToastType
    let selectedFont: String
    let fontSize: CGFloat
    let colorScheme: ColorScheme
    
    private var iconColor: Color {
        colorScheme == .light ? .gray : .white.opacity(0.85)
    }
    
    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 14))
                
                Text(message)
                    .font(.custom(selectedFont, size: fontSize * 0.8)) // Slightly smaller than editor font
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(colorScheme == .light ? Color.lightModeBackground : Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
            )
            .frame(maxWidth: 400) // Max width constraint
            .padding(.top, 20) // Position from top
            
            Spacer()
        }
    }
}

// OscillatingDotView: Animated loading dot for reflection loading state
struct OscillatingDotView: View {
    @State private var scale: CGFloat = 1.0
    let colorScheme: ColorScheme
    
    var body: some View {
        Circle()
            .fill(colorScheme == .light ? Color(red: 0.20, green: 0.20, blue: 0.20) : Color(red: 0.9, green: 0.9, blue: 0.9))
            .frame(width: 16, height: 16)
            .scaleEffect(scale)
            .onAppear {
                let animation = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                withAnimation(animation) {
                    self.scale = 1.2
                }
            }
    }
}

// MarkdownTextView: Renders markdown content with proper styling
struct MarkdownTextView: View {
    let content: String
    let font: String
    let fontSize: CGFloat
    let colorScheme: ColorScheme
    let lineHeight: CGFloat
    
    @State private var attributedString: AttributedString = AttributedString()
    
    var body: some View {
        Text(attributedString)
            .textSelection(.enabled)
            .lineSpacing(lineHeight)
            .onAppear {
                updateAttributedString()
            }
            .onChange(of: content) { _ in
                updateAttributedString()
            }
            .onChange(of: font) { _ in
                updateAttributedString()
            }
            .onChange(of: fontSize) { _ in
                updateAttributedString()
            }
            .onChange(of: colorScheme) { _ in
                updateAttributedString()
            }
    }
    
    private func updateAttributedString() {
        do {
            // Parse markdown content
            var parsed = try AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            
            // Apply base font and color
            let baseFont = NSFont(name: font, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let textColor = colorScheme == .light ? 
                NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0) : 
                NSColor(calibratedWhite: 0.95, alpha: 1.0)
            
            // Apply base styling to entire string
            parsed.font = baseFont
            parsed.foregroundColor = textColor
            
            // Apply custom styling for markdown elements
            for run in parsed.runs {
                let range = run.range
                
                // Handle bold text
                if let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                    let boldFont = NSFont(name: font.replacingOccurrences(of: "Regular", with: "Bold"), size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
                    parsed[range].font = boldFont
                }
                
                // Handle italic text
                if let intent = run.inlinePresentationIntent, intent.contains(.emphasized) {
                    let italicFont = NSFont(name: font.replacingOccurrences(of: "Regular", with: "Italic"), size: fontSize) ?? {
                        // Fallback to system italic if custom font doesn't have italic variant
                        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
                        return NSFont(descriptor: descriptor, size: fontSize) ?? baseFont
                    }()
                    parsed[range].font = italicFont
                }
                
                // Handle code spans
                if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                    let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
                    parsed[range].font = codeFont
                    parsed[range].backgroundColor = colorScheme == .light ? 
                        NSColor.lightGray.withAlphaComponent(0.2) : 
                        NSColor.darkGray.withAlphaComponent(0.3)
                }
                
                // Handle headers by checking presentation intent
                if let intent = run.presentationIntent {
                    let intentString = "\(intent)"
                    if intentString.contains("header(level: 1)") {
                        let headerFont = NSFont(name: font.replacingOccurrences(of: "Regular", with: "Bold"), size: fontSize * 1.5) ?? NSFont.boldSystemFont(ofSize: fontSize * 1.5)
                        parsed[range].font = headerFont
                    } else if intentString.contains("header(level: 2)") {
                        let headerFont = NSFont(name: font.replacingOccurrences(of: "Regular", with: "Bold"), size: fontSize * 1.3) ?? NSFont.boldSystemFont(ofSize: fontSize * 1.3)
                        parsed[range].font = headerFont
                    } else if intentString.contains("header(level: 3)") {
                        let headerFont = NSFont(name: font.replacingOccurrences(of: "Regular", with: "Bold"), size: fontSize * 1.1) ?? NSFont.boldSystemFont(ofSize: fontSize * 1.1)
                        parsed[range].font = headerFont
                    }
                }
            }
            
            self.attributedString = parsed
            
        } catch {
            // If markdown parsing fails, fall back to plain text
            print("Markdown parsing failed: \(error)")
            var fallback = AttributedString(content)
            fallback.font = NSFont(name: font, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            fallback.foregroundColor = colorScheme == .light ? 
                NSColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0) : 
                NSColor(calibratedWhite: 0.90, alpha: 1.0)
            self.attributedString = fallback
        }
    }
}

#Preview {
    ContentView()
}

// Helper to remove reflection/follow-up separators from text
func removeReflectionSeparators(from text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    let filtered = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != "--- REFLECTION ---" && trimmed != "--- USER ---"
    }
    return filtered.joined(separator: "\n")
}

// Add this helper view at the end of the file:
import AppKit
struct TextEditorCursorColorView: NSViewRepresentable {
    let colorScheme: ColorScheme
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window, let textView = window.firstResponder as? NSTextView {
                textView.insertionPointColor = (colorScheme == .dark) ? .white : .black
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window, let textView = window.firstResponder as? NSTextView {
                textView.insertionPointColor = (colorScheme == .dark) ? .white : .black
            }
        }
    }
}
