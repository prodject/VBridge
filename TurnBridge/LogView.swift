import SwiftUI
import Combine
import NetworkExtension

struct LogView: View {
    @State private var entries: [LogEntry] = []
    @State private var searchText = ""
    @State private var selectedSource: LogSource? = nil
    @State private var minimumLevel: LogLevel = .debug
    @State private var autoScroll = true
    @State private var showFilters = false
    @State private var monitoringTask: Task<Void, Never>? = nil
    @State private var lastRawLines: [String] = []
    @State private var exportedTunnelLogURL: URL?
    @State private var isExportingTunnelLog = false
    @State private var exportTunnelLogError: String?
    @ObservedObject private var tunnelManagerStore = VBridgeTunnelManagerStore.shared

    var filteredEntries: [LogEntry] {
        entries.filter { entry in
            guard entry.level >= minimumLevel else { return false }
            if let source = selectedSource, entry.source != source { return false }
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                return entry.message.lowercased().contains(query)
                    || entry.source.rawValue.lowercased().contains(query)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                logListView
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: copyLogs) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(Color(red: 0.53, green: 0.37, blue: 0.98))
                }
                Button(action: exportTunnelLog) {
                    if isExportingTunnelLog {
                        ProgressView()
                            .tint(Color(red: 0.53, green: 0.37, blue: 0.98))
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(Color(red: 0.53, green: 0.37, blue: 0.98))
                    }
                }
                .disabled(isExportingTunnelLog)
                if let logURL = SharedLogger.logFileURL {
                    ShareLink(item: logURL) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(Color(red: 0.53, green: 0.37, blue: 0.98))
                    }
                }
                Button(action: { SharedLogger.clearLogs(); entries = [] }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .onAppear {
            startMonitoring()
        }
        .onDisappear {
            stopMonitoring()
        }
        .sheet(
            isPresented: Binding(
                get: { exportedTunnelLogURL != nil },
                set: { newValue in
                    if !newValue {
                        exportedTunnelLogURL = nil
                    }
                }
            )
        ) {
            if let url = exportedTunnelLogURL {
                LogShareActivityView(items: [url])
            }
        }
        .alert(
            "Tunnel Log Unavailable",
            isPresented: Binding(
                get: { exportTunnelLogError != nil },
                set: { newValue in
                    if !newValue {
                        exportTunnelLogError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportTunnelLogError ?? "")
        }
    }

    private func startMonitoring() {
        stopMonitoring()
        monitoringTask = Task {
            await loadLogs()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    await loadLogs()
                } catch {
                    break
                }
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    @MainActor
    private func loadLogs() async {
        // File I/O and parsing must not run on the UI actor. In particular,
        // parsing the whole 500 KB rolling log every 300 ms made scrolling
        // noticeably stall on devices.
        let rawLines = await Task.detached(priority: .utility) {
            SharedLogger.readLogs()
        }.value
        guard !Task.isCancelled, rawLines != lastRawLines else { return }

        if rawLines.count >= lastRawLines.count,
           Array(rawLines.prefix(lastRawLines.count)) == lastRawLines {
            let appendedLines = Array(rawLines.dropFirst(lastRawLines.count))
            let appendedEntries = await Task.detached(priority: .utility) {
                Array(appendedLines.compactMap(LogEntry.parse).reversed())
            }.value
            entries.insert(contentsOf: appendedEntries, at: 0)
        } else {
            // The file was cleared or rotated; rebuild only in that case.
            entries = await Task.detached(priority: .utility) {
                Array(rawLines.compactMap(LogEntry.parse).reversed())
            }.value
        }
        lastRawLines = rawLines
    }

    private var newestEntryID: Int? {
        filteredEntries.isEmpty ? nil : 0
    }

    private var autoScrollIcon: String {
        autoScroll ? "arrow.up.to.line.compact" : "arrow.up.to.line"
    }

    private var autoScrollAnchor: UnitPoint {
        .top
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard autoScroll, let newestEntryID else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(newestEntryID, anchor: autoScrollAnchor)
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    TextField("Search logs...", text: $searchText)
                        .font(.system(size: 14))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(10)

                Button(action: { withAnimation { showFilters.toggle() } }) {
                    Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundColor(hasActiveFilters ? Color(red: 0.53, green: 0.37, blue: 0.98) : .secondary)
                }

                Button(action: { autoScroll.toggle() }) {
                    Image(systemName: autoScrollIcon)
                        .foregroundColor(autoScroll ? Color(red: 0.53, green: 0.37, blue: 0.98) : .secondary)
                }
            }

            if showFilters {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Source:").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        filterChip("All", isActive: selectedSource == nil) { selectedSource = nil }
                        ForEach(LogSource.allCases, id: \.self) { source in
                            filterChip(source.displayName, isActive: selectedSource == source) { selectedSource = source }
                        }
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        Text("Level:").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            filterChip("\(level.icon)", isActive: minimumLevel == level) { minimumLevel = level }
                        }
                        Spacer()
                    }
                }
                .transition(.opacity)
            }

            HStack {
                Text("\(filteredEntries.count) of \(entries.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if hasActiveFilters {
                    Button("Clear") {
                        selectedSource = nil
                        minimumLevel = .debug
                        searchText = ""
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    private var logListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filteredEntries.enumerated()), id: \.offset) { index, entry in
                        logRow(entry)
                            .id(index)
                            .contextMenu {
                                Button(action: { UIPasteboard.general.string = entry.rawLine }) {
                                    Label("Copy Line", systemImage: "doc.on.doc")
                                }
                                Button(action: { UIPasteboard.general.string = entry.message }) {
                                    Label("Copy Message", systemImage: "text.quote")
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color(UIColor.secondarySystemBackground))
            .onChange(of: filteredEntries.count) { _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: autoScroll) { isEnabled in
                if isEnabled {
                    scrollToLatest(using: proxy)
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(timeString(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)

            Text(entry.level.icon)
                .font(.system(size: 10))
                .frame(width: 16)

            Text(entry.source.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(sourceColor(entry.source))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(sourceColor(entry.source).opacity(0.15))
                .cornerRadius(3)
                .frame(width: 30)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(levelColor(entry.level))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(entry.level == .error ? Color.red.opacity(0.06) : Color.clear)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            if !SharedLogger.isAvailable {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.orange.opacity(0.7))
                Text("Logging unavailable")
                    .font(.system(size: 16, weight: .medium))
                Text(SharedLogger.appGroupDiagnostics)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Image(systemName: entries.isEmpty ? (SharedLogger.hasAppGroupContainer ? "doc.text" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") : "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(entries.isEmpty ? (SharedLogger.hasAppGroupContainer ? "No logs yet" : "Degraded logging mode") : "No matches")
                    .font(.system(size: 16, weight: .medium))
                Text(entries.isEmpty ? SharedLogger.logAvailabilityDescription() : "Try adjusting filters.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func filterChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isActive ? Color(red: 0.53, green: 0.37, blue: 0.98).opacity(0.2) : Color(UIColor.tertiarySystemBackground))
                    .foregroundColor(isActive ? Color(red: 0.53, green: 0.37, blue: 0.98) : .secondary)
                    .cornerRadius(6)
        }
    }

    private var hasActiveFilters: Bool {
        selectedSource != nil || minimumLevel != .debug || !searchText.isEmpty
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func sourceColor(_ source: LogSource) -> Color {
        switch source {
        case .app: return Color(red: 0.53, green: 0.37, blue: 0.98)
        case .tunnel: return .purple
        case .wireguard: return .green
        }
    }

    private func copyLogs() {
        let text = filteredEntries.map { $0.rawLine }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    private func exportTunnelLog() {
        guard !isExportingTunnelLog else { return }
        isExportingTunnelLog = true
        exportTunnelLogError = nil

        Task { @MainActor in
            defer { isExportingTunnelLog = false }

            guard let manager = tunnelManagerStore.manager,
                  let session = manager.connection as? NETunnelProviderSession else {
                exportTunnelLogError = "The tunnel extension is not available in the current session."
                return
            }

            let message = Data("vbridge_export_tunnel_log".utf8)
            let response = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                do {
                    try session.sendProviderMessage(message) { data in
                        continuation.resume(returning: data)
                    }
                } catch {
                    SharedLogger.warning("Tunnel log export request failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }

            guard let response, !response.isEmpty else {
                exportTunnelLogError = "The app could not retrieve the tunnel log from the extension. Start the VPN once and try again while the extension is still running."
                return
            }

            do {
                let exportURL = try saveExportedTunnelLog(response)
                exportedTunnelLogURL = exportURL
                SharedLogger.info("Tunnel log exported to \(exportURL.lastPathComponent)")
            } catch {
                exportTunnelLogError = "Failed to save the exported tunnel log: \(error.localizedDescription)"
            }
        }
    }

    private func saveExportedTunnelLog(_ data: Data) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let url = documents.appendingPathComponent("vbridge-tunnel-log-\(formatter.string(from: Date())).log")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct LogShareActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
