import Foundation
import ServiceManagement

/// App-side access to the root helper. Thread-safe; calls are synchronous and meant for background tasks.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    var service: SMAppService { SMAppService.daemon(plistName: HelperConfig.plistName) }

    enum State: Equatable {
        case notInstalled, needsApproval, notFound, running(pid: Int32), unreachable(String)
        var label: String {
            switch self {
            case .notInstalled: "Helper not installed"
            case .needsApproval: "Helper needs approval in Login Items"
            case .notFound: "Helper plist missing from bundle"
            case .running(let pid): "Helper running as root (pid \(pid))"
            case .unreachable(let e): "Helper unreachable: \(e)"
            }
        }
        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    func register() throws { try service.register() }
    func unregister() throws {
        invalidate()
        try service.unregister()
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Checks registration, then pings the helper (which launchd starts on demand).
    func probe() -> State {
        switch service.status {
        case .notRegistered: return .notInstalled
        case .requiresApproval: return .needsApproval
        case .notFound:
            // SMAppService also reports .notFound for a daemon that was simply never registered.
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConfig.plistName)")
            return FileManager.default.fileExists(atPath: plist.path) ? .notInstalled : .notFound
        case .enabled: break
        @unknown default: return .unreachable("unknown SMAppService status")
        }
        var result: State = .unreachable("no reply")
        let sem = DispatchSemaphore(value: 0)
        let proxy = proxy { err in result = .unreachable(err.localizedDescription); sem.signal() }
        proxy?.version { v, pid in
            result = v == HelperConfig.protocolVersion ? .running(pid: pid) : .unreachable("helper protocol v\(v), app v\(HelperConfig.protocolVersion)")
            sem.signal()
        }
        if proxy == nil { return .unreachable("no connection") }
        if sem.wait(timeout: .now() + 3) == .timedOut { return .unreachable("timed out") }
        return result
    }

    func allMetrics(timeout: Double = 15) -> [Int32: PrivMetrics]? {
        guard let data = call({ p, done in p.allMetrics { done($0) } }, timeout: timeout) as Data?,
              let list = try? JSONDecoder().decode([PrivMetrics].self, from: data) else { return nil }
        return Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func argsEnv(_ pid: Int32) -> PrivArgsEnv? {
        guard let data = call({ p, done in p.argsEnv(pid: pid) { done($0) } }) ?? nil else { return nil }
        return try? JSONDecoder().decode(PrivArgsEnv.self, from: data)
    }

    func run(_ tool: HelperTool, pid: Int32 = 0, timeout: Double = 60) -> String? {
        call({ p, done in p.runTool(tool.rawValue, pid: pid) { done($0) } }, timeout: timeout)
    }

    // MARK: plumbing

    private func call<T>(_ body: (HelperProtocol, @escaping (T) -> Void) -> Void, timeout: Double = 15) -> T? {
        // The reply can arrive after we stopped waiting; the lock keeps that late write from racing the read.
        let lock = NSLock()
        var out: T?
        let sem = DispatchSemaphore(value: 0)
        guard let p = proxy({ _ in sem.signal() }) else { return nil }
        body(p) { v in lock.lock(); out = v; lock.unlock(); sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return out
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> HelperProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConfig.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            // Only talk to a helper that is our own signed binary.
            c.setCodeSigningRequirement(HelperConfig.peerRequirement)
            c.invalidationHandler = { [weak self] in self?.dropConnection() }
            c.interruptionHandler = { [weak self] in self?.dropConnection() }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? HelperProtocol
    }

    private func dropConnection() {
        lock.lock(); connection = nil; lock.unlock()
    }

    private func invalidate() {
        lock.lock(); let c = connection; connection = nil; lock.unlock()
        c?.invalidate()
    }
}
