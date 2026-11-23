import SwiftUI
import AppKit

struct Device: Codable, Identifiable, Hashable {
    let device: String
    let name: String
    let size: Int64
    let parent: String
    var id: String { device }
    var label: String { "\(name)  •  \(device)  •  \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))" }
}
struct Recording: Codable, Identifiable {
    let name: String
    let first: Int
    let size: Int64
    let dir: Bool
    let timestamp: String?
    let path: String
    var id: String { path }
}
struct DeviceResponse: Codable { let devices: [Device] }
struct ScanResponse: Codable { let files: [Recording] }

@MainActor final class ImportModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedDevice = ""
    @Published var recordings: [Recording] = []
    @Published var checked: Set<String> = []
    @Published var localFiles: [URL] = []
    @Published var output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Cooyeye DVR Recordings")
    @Published var busy = false
    @Published var status = "Connect a Cooyeye SD card and click Refresh."
    @Published var log = ""
    @Published var convertToMP4 = true
    @Published var openWhenDone = true
    @Published var fileProgress = 0.0
    @Published var overallProgress = 0.0
    @Published var stage = "Ready"
    @Published var currentFile = ""
    @Published var completedCount = 0
    @Published var failedCount = 0
    @Published var mode = 0
    @Published var showQuitConfirmation = false
    @Published var showSetup = false

    private var runningProcess: Process?
    private var cancelled = false
    private var progressWeight = 1.0

    private var script: String {
        Bundle.module.url(forResource: "cooyeye_client", withExtension: "py")!.path
    }
    private func command(_ args: [String]) throws -> Process {
        let process = Process()
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "Cooyeye", code: 1, userInfo: [NSLocalizedDescriptionKey: "Python 3 is missing. Open Setup & Help to install dependencies."])
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script] + args
        return process
    }
    private func runJSON(_ args: [String]) throws -> Data {
        let process = try command(args)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "Cooyeye", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error.isEmpty ? output : error, as: UTF8.self)])
        }
        return output
    }
    private func begin(_ task: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        cancelled = false
        DispatchQueue.global(qos: .userInitiated).async {
            do { try task() }
            catch { DispatchQueue.main.async { self.status = "Error: \(error.localizedDescription)" } }
            DispatchQueue.main.async { self.busy = false }
        }
    }
    func refresh() {
        begin {
            let devices = try JSONDecoder().decode(DeviceResponse.self, from: self.runJSON(["devices"])) .devices
            let preferred = devices.first(where: { $0.name.lowercased().contains("linux") })?.device
            let selection = devices.contains(where: { $0.device == self.selectedDevice }) ? self.selectedDevice : (preferred ?? devices.first?.device ?? "")
            // Scan in the same background task; no timer or busy-state race.
            let files: [Recording]
            if let preferred = preferred {
                files = try JSONDecoder().decode(ScanResponse.self, from: self.runJSON(["scan", "--device", preferred])).files
            } else { files = [] }
            DispatchQueue.main.async {
                self.devices = devices
                self.selectedDevice = preferred ?? selection
                self.recordings = files
                self.checked = Set(files.map(\.path))
                self.status = preferred != nil ? "Found \(files.count) recording(s)." : "No SD card detected. Connect the card and click Refresh."
            }
        }
    }
    func scan() {
        guard !selectedDevice.isEmpty else { return }
        let device = selectedDevice
        begin {
            let files = try JSONDecoder().decode(ScanResponse.self, from: self.runJSON(["scan", "--device", device])).files
            DispatchQueue.main.async {
                self.recordings = files
                self.checked = Set(files.map(\.path))
                self.status = "Found \(files.count) recording(s). Dates are shown only when valid FAT32 metadata exists."
            }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { output = url }
    }
    func chooseLocalFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Accept all files here; the converter validates supported video extensions.
        if panel.runModal() == .OK { localFiles = panel.urls }
    }
    func cancel() {
        guard busy else { return }
        cancelled = true
        runningProcess?.terminate()
        status = "Cancelling…"
    }
    func start() {
        guard !busy else { return }
        let selected = recordings.filter { checked.contains($0.path) }.map(\.path)
        let isLocal = mode == 1
        let count = isLocal ? localFiles.count : selected.count
        guard count > 0 else { return }
        let destination = output.path
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        catch { status = "Cannot create output folder: \(error.localizedDescription)"; return }
        var args = isLocal ? ["convert", "--output", destination, "--files"] + localFiles.map(\.path) : ["import", "--device", selectedDevice, "--output", destination, "--files"] + selected
        if !isLocal && convertToMP4 { args.append("--convert") }
        completedCount = 0
        failedCount = 0
        fileProgress = 0
        overallProgress = 0
        currentFile = ""
        stage = "Preparing"
        log = ""
        progressWeight = (isLocal || convertToMP4) ? 0.5 : 1.0
        begin {
            let process = try self.command(args)
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            DispatchQueue.main.sync { self.runningProcess = process }
            defer { DispatchQueue.main.async { self.runningProcess = nil } }
            try process.run()
            // Consume stdout as it arrives so the UI can update during long transfers.
            let handle = outputPipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { self.consume(event) }
                    }
                }
            }
            let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            DispatchQueue.main.async {
                if self.cancelled {
                    self.status = "Cancelled. Completed recordings are preserved."
                    self.stage = "Cancelled"
                } else if process.terminationStatus != 0 {
                    if !self.status.hasPrefix("Error:") { self.status = "Error: \(stderr.isEmpty ? "Operation failed" : stderr)" }
                    self.stage = "Failed"
                } else {
                    self.status = self.failedCount > 0 ? "Finished with \(self.failedCount) failure(s). \(self.completedCount) saved. See Completed files." : "Finished: \(self.completedCount) recording(s) saved to \(destination)"
                    self.stage = self.failedCount > 0 ? "Completed with errors" : "Complete"
                    self.overallProgress = 1
                    self.fileProgress = 1
                    if self.openWhenDone { NSWorkspace.shared.open(self.output) }
                }
            }
        }
    }
    private func consume(_ event: [String: Any]) {
        let kind = event["event"] as? String ?? ""
        let name = event["file"] as? String ?? ""
        let index = event["index"] as? Int ?? (completedCount + 1)
        let total = max(1, event["total"] as? Int ?? 1)
        switch kind {
        case "start":
            currentFile = (name as NSString).lastPathComponent
            stage = "Starting"
            fileProgress = 0
        case "stage", "progress":
            let phase = event["stage"] as? String ?? "extract"
            stage = phase == "convert" ? "Converting to MP4" : "Extracting AVI"
            let value = max(0, min(1, event["progress"] as? Double ?? 0))
            fileProgress = value
            let phaseFraction = phase == "convert" ? (convertToMP4 || mode == 1 ? 0.5 + value * 0.5 : value) : value * progressWeight
            overallProgress = min(1, (Double(index - 1) + phaseFraction) / Double(total))
        case "done":
            completedCount += 1
            overallProgress = Double(completedCount) / Double(total)
            log += "Saved: \(event["output"] as? String ?? name)\n"
        case "file_error":
            failedCount += 1
            let detail = event["error"] as? String ?? "Unknown conversion error"
            log += "FAILED: \(name) — \(detail)\n"
            status = "Failed: \(name) — \(detail)"
            stage = "File failed"
            overallProgress = Double(completedCount + failedCount) / Double(total)
        case "error":
            let detail = event["error"] as? String ?? "Unknown error"
            status = "Error: \(detail)"
            log += "ERROR: \(detail)\n"
            stage = "Failed"
        default: break
        }
    }
}


struct ContentView: View {
    @StateObject private var model = ImportModel()
    private let blue = Color(red: 0.04, green: 0.55, blue: 1.0)
    private let panel = Color(red: 0.155, green: 0.155, blue: 0.165)
    private let canvas = Color(red: 0.115, green: 0.115, blue: 0.12)

    private var recordingsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle("RECORDINGS")
                Text("\(model.checked.count) of \(model.recordings.count) selected")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                ForEach(model.recordings) { rec in
                    let selected = model.checked.contains(rec.path)
                    Button {
                        if selected { model.checked.remove(rec.path) }
                        else { model.checked.insert(rec.path) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(selected ? blue : Color.gray)
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 13))
                                .foregroundColor(blue)
                            Text((rec.path as NSString).lastPathComponent + " (" + ByteCountFormatter.string(fromByteCount: rec.size, countStyle: .file) + ")")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .accessibilityLabel((rec.path as NSString).lastPathComponent)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
            if model.recordings.isEmpty {
                Text("No recordings scanned yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ value: String) -> some View {
        Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(blue)
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("SOURCE")
                Spacer()
            }
            Picker("SD card", selection: $model.selectedDevice) {
                if model.devices.isEmpty { Text("No SD card connected").tag("") }
                ForEach(model.devices) { d in Text(d.label).tag(d.device) }
            }
            .labelsHidden()
            HStack(spacing: 8) {
                Text(model.selectedDevice.isEmpty ? "Connect a card and refresh" : "Read-only SD card access")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(blue)
                }
                .help("Refresh SD cards")
                .accessibilityLabel("Refresh SD cards")
                .disabled(model.busy)
                Button("Scan") { model.scan() }
                    .disabled(model.busy || model.selectedDevice.isEmpty)
            }
        }
        .padding(14)
        .background(panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var localPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("LOCAL VIDEOS")
                Spacer()
                Button("Add videos…") { model.chooseLocalFiles() }.disabled(model.busy)
                Button("Clear") { model.localFiles = [] }.disabled(model.busy || model.localFiles.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.localFiles, id: \.path) { file in
                        Label(file.lastPathComponent, systemImage: "film")
                            .font(.system(size: 12)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 110)
            Text("Converts local videos without modifying the originals.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14).background(panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("OUTPUT")
                Spacer()
                Button("Choose…") { model.chooseFolder() }.disabled(model.busy)
            }
            HStack(spacing: 7) {
                Image(systemName: "folder").foregroundStyle(blue)
                Text(model.output.path).font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
            }
            Toggle("Open folder when finished", isOn: $model.openWhenDone)
                .disabled(model.busy)
        }
        .font(.system(size: 12))
        .padding(14).background(panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("PROGRESS")
                Spacer()
                Text(model.stage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(model.currentFile.isEmpty ? "Current file" : model.currentFile)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("\(Int(model.fileProgress * 100))%")
                            .monospacedDigit()
                    }
                    ProgressView(value: model.fileProgress)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Overall")
                        Spacer(minLength: 6)
                        Text("\(Int(model.overallProgress * 100))%")
                            .monospacedDigit()
                    }
                    ProgressView(value: model.overallProgress)
                }
            }
            .font(.system(size: 11))
        }
        .padding(14).background(panel, in: RoundedRectangle(cornerRadius: 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 25)).foregroundStyle(blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cooyeye DVR Importer").font(.system(size: 17, weight: .semibold))
                    Text("Read-only extraction · AVI archive · MP4 conversion")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 7) {
                    Button("Setup & Help") { model.showSetup = true }
                    Button("SD card") { model.mode = 0 }
                        .buttonStyle(.bordered)
                        .tint(model.mode == 0 ? blue : .gray)
                        .disabled(model.busy)
                    Button("Local converter") { model.mode = 1 }
                        .buttonStyle(.bordered)
                        .tint(model.mode == 1 ? blue : .gray)
                        .disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(panel)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.mode == 0 {
                        sourcePanel
                        VStack(alignment: .leading, spacing: 9) {
                            recordingsGrid
                            HStack(spacing: 10) {
                                Toggle("Automatically convert to MP4", isOn: $model.convertToMP4)
                                    .font(.system(size: 12)).tint(blue).disabled(model.busy)
                                Spacer(minLength: 8)
                                Button("Select all") { model.checked = Set(model.recordings.map(\.path)) }
                                    .disabled(model.busy || model.recordings.isEmpty)
                                Button("Clear") { model.checked.removeAll() }
                                    .disabled(model.busy || model.checked.isEmpty)
                            }
                        }
                        .padding(14)
                        .background(panel, in: RoundedRectangle(cornerRadius: 10))
                    } else { localPanel }
                    outputPanel
                    progressPanel
                    if !model.log.isEmpty {
                        DisclosureGroup("Import log") {
                            ScrollView {
                                Text(model.log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 90)
                        }
                    }
                }
                .padding(16)
            }
            HStack(spacing: 12) {
                Text(model.status).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 12)
                if model.busy {
                    Button("Cancel", role: .destructive) { model.cancel() }
                } else {
                    Button(model.mode == 0 ? "Import" : "Convert") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.mode == 0 ? model.checked.isEmpty || model.selectedDevice.isEmpty : model.localFiles.isEmpty)
                }
                Button("Close") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(panel)
        }
        .background(canvas)
        .tint(blue)
        .preferredColorScheme(.dark)
        .frame(minWidth: 790, minHeight: 610)
        .onAppear { model.refresh() }
        .sheet(isPresented: $model.showSetup) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Setup & permissions").font(.title2)
                Text("Install Python 3 and FFmpeg using the dependency setup below. SD extraction also needs the native reader installed by the macOS installer package. Local conversion does not need the reader.")
                Text("If scanning reports Operation not permitted, add /Library/Application Support/Cooyeye DVR Importer/cooyeye-reader to System Settings → Privacy & Security → Full Disk Access. Restart your Mac after changing this permission.")
                Text("When macOS offers to initialize the SD card, choose Ignore. Never erase or repair it to make it mount.")
                HStack {
                    Button("Set up dependencies") {
                        if let url = Bundle.main.resourceURL?.appendingPathComponent("Setup Dependencies.command") { NSWorkspace.shared.open(url) }
                    }
                    Button("Full Disk Access") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                    Button("Show reader") { NSWorkspace.shared.selectFile("/Library/Application Support/Cooyeye DVR Importer/cooyeye-reader", inFileViewerRootedAtPath: "") }
                }
                Button("Done") { model.showSetup = false }
            }.padding(24).frame(width: 630)
        }
        .alert("Close Cooyeye DVR Importer?", isPresented: $model.showQuitConfirmation) {
            Button("Keep Working", role: .cancel) { }
            Button("Cancel Import and Quit", role: .destructive) {
                model.cancel()
                NSApplication.shared.terminate(nil)
            }
        } message: {
            Text("An import or conversion is running. Quitting will interrupt it. Completed recordings will be kept.")
        }
    }
}

@main struct CooyeyeImporterApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
