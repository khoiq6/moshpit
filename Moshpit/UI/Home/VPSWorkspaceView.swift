import SwiftUI
import LocalAuthentication
import UIKit

enum WorkspaceWords {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "Workspace")
    }
}

struct VPSUsage {
    let cpu: Double
    let ram: Double
    let disk: Double
    static func parse(_ output: String) -> Self? {
        let tokens = output.split(whereSeparator: \.isWhitespace)
        let values = tokens.compactMap { Double($0) }
        guard tokens.count == 3, values.count == 3, values.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { return nil }
        return Self(cpu: values[0], ram: values[1], disk: values[2])
    }
}

enum VPSCommands {
    // POSIX exec channel: Linux only. No user text interpolated into a shell.
    static let usage = """
    LC_ALL=C; export LC_ALL
    read_cpu() { awk '/^cpu / {t=0; for(i=2;i<=9;i++) t+=$i; print t, $5+$6; exit}' /proc/stat; }
    set -- $(read_cpu); t1=$1; i1=$2
    sleep 0.25
    set -- $(read_cpu); t2=$1; i2=$2
    cpu=$(awk -v a="$t1" -v b="$t2" -v c="$i1" -v d="$i2" 'BEGIN {if(b<=a) exit 1; printf "%.1f",100*(1-(d-c)/(b-a))}') || exit 1
    mem=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if(t<=0||a<=0) exit 1; printf "%.1f",100*(1-a/t)}' /proc/meminfo) || exit 1
    disk=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5);print $5}')
    printf '%s %s %s\\n' "$cpu" "$mem" "$disk"
    """
    static let processes = "LC_ALL=C ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -n 51"
    static let ports = "LC_ALL=C ss -lntu"
    static let windowsUsage = "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory; Get-CimInstance Win32_Processor | Select-Object LoadPercentage; Get-PSDrive -PSProvider FileSystem"
    static let windowsProcesses = "Get-Process | Sort-Object CPU -Descending | Select-Object -First 30 Id,ProcessName,CPU,WorkingSet"
    static let windowsPorts = "Get-NetTCPConnection -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess"
}

struct VPSWorkspaceView: View {
    let store: ConnectionStore
    let hub: SessionHub
    let openTerminal: (UUID) -> Void
    let openDesktop: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @AppStorage("workspace.deviceAuth") private var deviceAuth = false
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var authError = false
    @State private var authGeneration = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if deviceAuth && !unlocked {
                    VStack(spacing: 18) {
                        Image(systemName: "lock.shield").font(.system(size: 48))
                        Text(WorkspaceWords.text("Workspace locked"))
                        Button(WorkspaceWords.text("Unlock")) { unlock() }
                            .buttonStyle(.borderedProminent).disabled(authenticating)
                        if authError { Text(WorkspaceWords.text("Authentication failed")).foregroundStyle(.secondary) }
                    }
                } else {
                    List {
                        Section(WorkspaceWords.text("Servers")) {
                            ForEach(store.connections) { server in
                                NavigationLink {
                                    VPSHostTools(server: server, hub: hub, openTerminal: openTerminal)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.displayName).font(.headline)
                                        Text(server.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        if let active = hub.session(for: server), case .connected = active.viewModel.status {
                                            Label(WorkspaceWords.text("Connected"), systemImage: "checkmark.circle").foregroundStyle(.green)
                                        } else {
                                            Text(WorkspaceWords.text("Not connected")).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if store.connections.isEmpty {
                                Text(WorkspaceWords.text("Add a server first"))
                            }
                        }
                        Section(WorkspaceWords.text("Tools")) {
                            Button { openDesktop() } label: { Label(WorkspaceWords.text("Windows desktop"), systemImage: "display") }
                            NavigationLink { WorkspaceGitHubView() } label: { Label("GitHub Actions", systemImage: "hammer") }
                        }
                        Section(WorkspaceWords.text("Security")) {
                            Toggle(WorkspaceWords.text("Protect workspace"), isOn: $deviceAuth)
                            Text(WorkspaceWords.text("Workspace security explanation")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(WorkspaceWords.text("VPS workspace"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(WorkspaceWords.text("Close")) { dismiss() }
            } }
        }
        // Reset the entire navigation stack when relocking, including a
        // previously pushed host detail or editor.
        .id(deviceAuth && !unlocked)
        .onChange(of: phase) { _, value in
            if value == .background {
                authGeneration = UUID()
                unlocked = false
                authenticating = false
            }
        }
        .onChange(of: deviceAuth) { _, enabled in
            if enabled { unlocked = false; unlock() }
        }
        .task { if deviceAuth && !unlocked { unlock() } }
    }

    private func unlock() {
        guard !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = true
            return
        }
        authenticating = true
        let generation = UUID()
        authGeneration = generation
        Task { @MainActor in
            let passed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: WorkspaceWords.text("Unlock"))) == true
            guard generation == authGeneration else { return }
            authenticating = false
            unlocked = passed
            authError = !unlocked
        }
    }
}

private struct VPSHostTools: View {
    let server: ServerConnection
    let hub: SessionHub
    let openTerminal: (UUID) -> Void
    @State private var usage: VPSUsage?
    @State private var output = ""
    @State private var busy = false
    @State private var folder: RemoteFileEntry?
    @State private var showFiles = false
    @State private var live = false
    @State private var windows = false
    @State private var confirmRestart = false
    @AppStorage("workspace.quickCommand") private var quickCommand = ""
    private var active: SessionHub.ActiveSession? {
        guard let session = hub.session(for: server), case .connected = session.viewModel.status else { return nil }
        return session
    }
    var body: some View {
        List {
            Section {
                Button(WorkspaceWords.text("Open terminal")) { openTerminal(server.id) }
                if active == nil { Text(WorkspaceWords.text("Connect in terminal first")).foregroundStyle(.secondary) }
                Toggle(WorkspaceWords.text("Windows server"), isOn: $windows)
                    .onChange(of: windows) { _, _ in live = false; usage = nil; output = "" }
            }
            Section(WorkspaceWords.text("Resource usage")) {
                if windows {
                    Text(WorkspaceWords.text("Windows metrics explanation")).font(.caption)
                    Button(WorkspaceWords.text("Copy PowerShell metrics")) { copy(VPSCommands.windowsUsage) }
                } else {
                    if let usage {
                        gauge("CPU", usage.cpu)
                        gauge("RAM", usage.ram)
                        gauge(WorkspaceWords.text("Disk"), usage.disk)
                    } else {
                        Text(WorkspaceWords.text("No measurements")).foregroundStyle(.secondary)
                    }
                    Button(WorkspaceWords.text("Refresh")) { Task { await refresh() } }.disabled(active == nil || busy)
                    Toggle(WorkspaceWords.text("Auto refresh (10s)"), isOn: $live).disabled(active == nil)
                }
            }
            Section(WorkspaceWords.text("Management")) {
                Button(WorkspaceWords.text("Processes")) {
                    if windows { copy(VPSCommands.windowsProcesses) } else { Task { await run(VPSCommands.processes) } }
                }.disabled(!windows && (active == nil || busy))
                Button(WorkspaceWords.text("Listening ports")) {
                    if windows { copy(VPSCommands.windowsPorts) } else { Task { await run(VPSCommands.ports) } }
                }.disabled(!windows && (active == nil || busy))
                Button(WorkspaceWords.text("File manager")) { Task { await browse() } }.disabled(active == nil || busy)
                if let active {
                    NavigationLink(WorkspaceWords.text("Text / code editor")) { WorkspaceCodeEditor(session: active) }
                }
                Button(WorkspaceWords.text("Restart server"), role: .destructive) { confirmRestart = true }
                    .disabled(!windows && (active == nil || busy))
                if busy { ProgressView() }
                if !output.isEmpty {
                    Text(verbatim: output).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section(WorkspaceWords.text("AI and shortcuts")) {
                Button("Codex CLI") { copy("codex") }
                Button("Claude Code") { copy("claude") }
                TextField(WorkspaceWords.text("Quick command"), text: $quickCommand)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(WorkspaceWords.text("Copy command")) { copy(quickCommand) }.disabled(quickCommand.isEmpty)
                Button(WorkspaceWords.text("Paste clipboard into command")) {
                    quickCommand = UIPasteboard.general.string ?? ""
                }
                Text(WorkspaceWords.text("Commands are copied only")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(server.displayName)
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .appSheet(isPresented: $showFiles) {
            if let folder, let active { RemoteFolderNSHSheet(folder: folder, files: active.remoteFileAccess) }
        }
        .confirmationDialog(WorkspaceWords.text("Restart server?"), isPresented: $confirmRestart, titleVisibility: .visible) {
            Button(WorkspaceWords.text("Confirm restart"), role: .destructive) {
                if windows { copy("Restart-Computer") }
                else { Task { await run("sudo -n shutdown -r +1") } }
            }
            Button(WorkspaceWords.text("Cancel"), role: .cancel) {}
        } message: { Text(WorkspaceWords.text("Restart explanation")) }
    }
    private func gauge(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(label); Spacer(); Text(value.formatted(.number.precision(.fractionLength(1))) + "%").monospacedDigit() }
            ProgressView(value: value, total: 100)
        }
    }
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        output = WorkspaceWords.text("Copied to clipboard")
    }
    private func refresh() async {
        guard !busy, !windows, let active else { return }
        busy = true
        defer { busy = false }
        let result = await active.runOnHost(VPSCommands.usage)
        guard !windows else { return }
        usage = result.flatMap(VPSUsage.parse)
        if usage == nil { output = WorkspaceWords.text("Read failed") }
    }
    private func run(_ command: String) async {
        guard !busy, let active else { return }
        busy = true
        defer { busy = false }
        if let result = await active.runOnHost(command) {
            output = result.isEmpty ? WorkspaceWords.text("Command accepted") : String(result.prefix(32_000))
        } else { output = WorkspaceWords.text("Read failed") }
    }
    private func browse() async {
        guard !busy, let active else { return }
        busy = true
        defer { busy = false }
        do {
            let host = try await active.acquireFileTransferSSH()
            let path = try await host.remoteHomeDirectory()
            folder = try await host.remoteStat(path)
            showFiles = folder?.isDirectory == true
        } catch { output = error.localizedDescription }
    }
}

private struct WorkspaceCodeEditor: View {
    let session: SessionHub.ActiveSession
    @State private var path = ""
    @State private var destination = ""
    @State private var content = ""
    @State private var status = ""
    @State private var busy = false
    @State private var loaded = false
    private let limit: UInt64 = 1_048_576

    var body: some View {
        Form {
            Section(WorkspaceWords.text("Open text file")) {
                TextField(WorkspaceWords.text("Remote file path"), text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(WorkspaceWords.text("Read")) { Task { await read() } }.disabled(path.isEmpty || busy)
            }
            if loaded {
                Section(WorkspaceWords.text("Content")) {
                    TextEditor(text: $content).font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never).frame(minHeight: 220)
                        .disabled(busy)
                }
                Section(WorkspaceWords.text("Save as new file")) {
                    TextField(WorkspaceWords.text("Destination path"), text: $destination)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(WorkspaceWords.text("Upload copy")) { Task { await save() } }
                        .disabled(destination.isEmpty || busy || UInt64(content.utf8.count) > limit)
                    Text(WorkspaceWords.text("Editor safety explanation")).font(.caption)
                }
            }
            if busy { ProgressView() }
            if !status.isEmpty { Text(status).textSelection(.enabled) }
        }
        .navigationTitle(WorkspaceWords.text("Text / code editor"))
    }
    private func read() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        loaded = false
        content = ""
        let source = path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let host = try await session.acquireFileTransferSSH()
            let entry = try await host.remoteStat(source)
            guard !entry.isDirectory, let size = entry.size, size <= limit else {
                status = WorkspaceWords.text("Text file limit")
                return
            }
            try await host.downloadRemoteFile(source, to: tmp, progress: nil)
            let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
            guard let bytes = attrs[.size] as? NSNumber, bytes.uint64Value <= limit,
                  let text = String(data: try Data(contentsOf: tmp), encoding: .utf8),
                  !text.contains("\0") else {
                status = WorkspaceWords.text("Text file limit")
                return
            }
            content = text
            destination = source + ".edited"
            loaded = true
            status = ""
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard !busy, loaded, !destination.isEmpty, UInt64(content.utf8.count) <= limit else { return }
        busy = true
        defer { busy = false }
        let target = destination
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try Data(content.utf8).write(to: tmp, options: .completeFileProtection)
            let host = try await session.acquireFileTransferSSH()
            try await host.uploadRemoteFile(from: tmp, to: target, progress: nil)
            status = WorkspaceWords.text("Copy uploaded")
        } catch { status = error.localizedDescription }
    }
}

private struct WorkspaceGitHubView: View {
    struct Runs: Decodable { let workflow_runs: [Run] }
    struct Run: Decodable, Identifiable {
        let id: Int64
        let name: String
        let status: String
        let conclusion: String?
        let head_branch: String?
        let html_url: URL
    }
    @AppStorage("workspace.githubRepo") private var repository = "khoiq6/moshpit"
    @State private var runs: [Run] = []
    @State private var busy = false
    @State private var failure = ""
    private var validRepo: Bool {
        repository.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil &&
        !repository.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    var body: some View {
        List {
            Section {
                TextField("owner/repository", text: $repository).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(WorkspaceWords.text("Refresh builds")) { Task { await refresh() } }.disabled(!validRepo || busy)
                if let url = validRepo ? URL(string: "https://github.com/" + repository) : nil {
                    Link(WorkspaceWords.text("Open repository"), destination: url)
                    Link(WorkspaceWords.text("Commits"), destination: url.appendingPathComponent("commits"))
                }
                Text(WorkspaceWords.text("Public repos only")).font(.caption)
            }
            Section("GitHub Actions") {
                if busy { ProgressView() }
                if !failure.isEmpty { Text(failure).foregroundStyle(.secondary) }
                ForEach(runs) { run in
                    if run.html_url.scheme == "https", run.html_url.host == "github.com" {
                        Link(destination: run.html_url) {
                            VStack(alignment: .leading) {
                                Text(run.name)
                                Text((run.head_branch ?? "") + " · " + state(run)).font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("GitHub Actions")
    }
    private func state(_ run: Run) -> String {
        switch run.conclusion ?? run.status {
        case "success": return WorkspaceWords.text("Succeeded")
        case "failure": return WorkspaceWords.text("Failed")
        case "in_progress": return WorkspaceWords.text("Running")
        case "queued": return WorkspaceWords.text("Queued")
        case "cancelled": return WorkspaceWords.text("Cancelled")
        default: return run.conclusion ?? run.status
        }
    }
    private func refresh() async {
        guard validRepo, !busy, let url = URL(string: "https://api.github.com/repos/" + repository + "/actions/runs?per_page=20") else { return }
        busy = true
        failure = ""
        runs = []
        defer { busy = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                failure = WorkspaceWords.text("GitHub unavailable")
                return
            }
            runs = try JSONDecoder().decode(Runs.self, from: data).workflow_runs
        } catch { failure = WorkspaceWords.text("GitHub unavailable") }
    }
}
