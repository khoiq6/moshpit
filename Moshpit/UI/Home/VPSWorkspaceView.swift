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
    static let services = "LC_ALL=C systemctl list-units --type=service --state=running --no-pager --plain | head -n 101"
    static let windowsUsage = #"""
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    if ($null -eq $cpu -or $os.TotalVisibleMemorySize -le 0 -or $drive.Size -le 0) { exit 1 }
    $ram = 100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize)
    $disk = 100 * (1 - $drive.FreeSpace / $drive.Size)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    Write-Output (($cpu.ToString('F1',$culture)) + ' ' + ($ram.ToString('F1',$culture)) + ' ' + ($disk.ToString('F1',$culture)))
    """#
    static let windowsProcesses = "Get-Process | Sort-Object CPU -Descending | Select-Object -First 50 Id,ProcessName,CPU,WorkingSet | Format-Table -AutoSize | Out-String -Width 200"
    static let windowsPorts = "Get-NetTCPConnection -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize | Out-String -Width 200; Get-NetUDPEndpoint | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize | Out-String -Width 200"
    static let windowsServices = "Get-Service | Where-Object Status -eq Running | Select-Object Name,DisplayName,Status | Format-Table -AutoSize | Out-String -Width 200"
    static let windowsRestart = #"shutdown.exe /r /t 60 /c "Moshpit"; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"#
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
    @State private var measuredAt: Date?
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
                    .disabled(busy || server.connectionProtocol != .ssh || server.multiplexer != .none)
                    .onChange(of: windows) { _, value in
                        WindowsHostPreferences.setWindows(value, id: server.id)
                        live = false; usage = nil; measuredAt = nil; output = ""
                    }
            }
            Section(WorkspaceWords.text("Resource usage")) {
                if let usage {
                    gauge("CPU", usage.cpu)
                    gauge("RAM", usage.ram)
                    gauge(WorkspaceWords.text("Disk"), usage.disk)
                    if let measuredAt { Text(measuredAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(WorkspaceWords.text("No measurements")).foregroundStyle(.secondary)
                }
                Button(WorkspaceWords.text("Refresh")) { Task { await refresh() } }.disabled(active == nil || busy)
                Toggle(WorkspaceWords.text("Auto refresh (10s)"), isOn: $live).disabled(active == nil)
            }
            Section(WorkspaceWords.text("Management")) {
                Button(WorkspaceWords.text("Processes")) {
                    Task { await run(windows ? VPSCommands.windowsProcesses : VPSCommands.processes) }
                }.disabled(active == nil || busy)
                Button(WorkspaceWords.text("Listening ports")) {
                    Task { await run(windows ? VPSCommands.windowsPorts : VPSCommands.ports) }
                }.disabled(active == nil || busy)
                Button(WorkspaceWords.text("Running services")) {
                    Task { await run(windows ? VPSCommands.windowsServices : VPSCommands.services) }
                }.disabled(active == nil || busy)
                Button(WorkspaceWords.text("File manager")) { Task { await browse() } }.disabled(active == nil || busy)
                if let active {
                    NavigationLink(WorkspaceWords.text("Text / code editor")) { WorkspaceCodeEditor(session: active) }
                }
                Button(WorkspaceWords.text("Restart server"), role: .destructive) { confirmRestart = true }
                    .disabled(active == nil || busy)
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
        .onAppear { windows = WindowsHostPreferences.isWindows(server.id) }
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
                Task { await run(windows ? VPSCommands.windowsRestart : "sudo -n shutdown -r +1", mutating: true) }
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
        guard !busy, let active else { return }
        busy = true
        defer { busy = false }
        let isWindows = windows
        let command = isWindows ? WindowsSSHCommand.encode(VPSCommands.windowsUsage) : VPSCommands.usage
        let result = try? await active.runWorkspaceCommand(command)
        guard windows == isWindows, !Task.isCancelled else { return }
        usage = result.flatMap(VPSUsage.parse)
        measuredAt = usage == nil ? nil : Date()
        if usage == nil { output = WorkspaceWords.text("Read failed") }
    }
    private func run(_ command: String, mutating: Bool = false) async {
        guard !busy, let active else { return }
        busy = true
        defer { busy = false }
        let encoded = windows ? WindowsSSHCommand.encode(command) : command
        do {
            let result = try await active.runWorkspaceCommand(encoded, mutating: mutating)
            output = result.isEmpty ? WorkspaceWords.text("Command accepted") : String(result.prefix(32_000))
        } catch {
            output = mutating ? WorkspaceWords.text("Restart result unknown") : WorkspaceWords.text("Read failed")
        }
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
