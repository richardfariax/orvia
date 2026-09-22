import Foundation

/// Agente/daemon de inicialização (plist em LaunchAgents/LaunchDaemons).
struct StartupItem: Identifiable, Hashable {
    enum Domain: String, CaseIterable {
        case userAgent
        case globalAgent
        case globalDaemon
    }

    let url: URL
    let label: String
    let programPath: String?
    let domain: Domain

    var id: URL { url }
    /// Apenas itens do usuário podem ser removidos sem privilégios de admin.
    var isRemovable: Bool { domain == .userAgent }
}

/// Processo pesado (CPU/RAM) para o módulo de aceleração.
struct HeavyProcess: Identifiable, Hashable {
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memoryPercent: Double

    var id: Int32 { pid }
}

@MainActor
final class StartupItemsService: ObservableObject {
    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var processes: [HeavyProcess] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            async let loadedItems = Task.detached(priority: .utility) { Self.loadStartupItems() }.value
            async let loadedProcesses = Task.detached(priority: .utility) { Self.loadHeavyProcesses() }.value
            items = await loadedItems
            processes = await loadedProcesses
            isLoading = false
        }
    }

    /// Move o plist do agente para a Lixeira (efeito após logout/reboot).
    func remove(_ item: StartupItem) {
        guard item.isRemovable else { return }
        let outcome = FileSweeper.trash(urls: [item.url])
        if !outcome.failures.isEmpty {
            errorMessage = outcome.failures.joined(separator: "\n")
        }
        refresh()
    }

    // MARK: - Carregamento

    nonisolated static func loadStartupItems() -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [(URL, StartupItem.Domain)] = [
            (home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .globalDaemon)
        ]

        var found: [StartupItem] = []
        for (root, domain) in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for url in urls where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dict = plist as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                let program = dict["Program"] as? String
                    ?? (dict["ProgramArguments"] as? [String])?.first
                found.append(StartupItem(url: url, label: label, programPath: program, domain: domain))
            }
        }
        return found.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    nonisolated static func loadHeavyProcesses(limit: Int = 12) -> [HeavyProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,pmem=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var result: [HeavyProcess] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]) else { continue }
            result.append(HeavyProcess(pid: pid, name: String(parts[3]), cpuPercent: cpu, memoryPercent: mem))
            if result.count >= limit { break }
        }
        return result
    }
}
