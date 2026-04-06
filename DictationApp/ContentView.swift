import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: DictationViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Status
            HStack(spacing: 6) {
                if viewModel.isModelLoading {
                    ProgressView().scaleEffect(0.6)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(statusColor)
            }
            .animation(.easeInOut, value: viewModel.state)

            // Current transcription
            ScrollView {
                Text(viewModel.transcribedText.isEmpty ? "Transcription will appear here..." : viewModel.transcribedText)
                    .font(.body)
                    .foregroundColor(viewModel.transcribedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 80)
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)

            // Record button
            Button(action: viewModel.toggle) {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonColor)
            .disabled(viewModel.state == .transcribing || !viewModel.isModelLoaded)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // History
            if !viewModel.history.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(viewModel.history, id: \.self) { item in
                        HistoryRow(text: item) {
                            viewModel.reuseHistoryItem(item)
                        }
                    }
                }
            }

            // Wake word toggle
            Toggle(isOn: Binding(
                get: { viewModel.isWakeWordEnabled },
                set: { viewModel.setWakeWord(enabled: $0) }
            )) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                    Text("\"Sileide\" wake word")
                }
                .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Translation mode
            HStack {
                Text("Tradução:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { viewModel.translationMode },
                    set: { viewModel.setTranslationMode($0) }
                )) {
                    ForEach(TranslationMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            // Model selectors
            VStack(spacing: 4) {
                HStack {
                    Text("Ditado ao vivo:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { viewModel.liveModel },
                        set: { viewModel.setLiveModel($0) }
                    )) {
                        ForEach(WhisperModel.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                HStack {
                    Text("Documentos:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { viewModel.batchModel },
                        set: { viewModel.setBatchModel($0) }
                    )) {
                        ForEach(WhisperModel.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
            }

            if let status = viewModel.batchStatus {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text(status)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Cancelar") {
                        BatchTranscriber.shared.cancel()
                        viewModel.batchStatus = nil
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
                .font(.caption2)
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            HStack {
                Text("Shortcut: fn fn  •  ESC to cancel")
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 360, height: viewModel.history.isEmpty ? 360 : 360 + CGFloat(viewModel.history.count) * 46)
    }

    private var statusText: String {
        if viewModel.isModelLoading { return "Loading model..." }
        if !viewModel.isModelLoaded { return "Model unavailable" }
        if viewModel.isTranslating { return "Translating..." }
        switch viewModel.state {
        case .idle:
            let base = viewModel.isFinalModelReady ? "Ready" : "Ready (loading Turbo...)"
            if viewModel.translationMode != .off {
                return base + " · \(viewModel.translationMode.displayName)"
            }
            return base
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        }
    }

    private var statusColor: Color {
        if viewModel.isModelLoading { return .orange }
        if !viewModel.isModelLoaded { return .red }
        switch viewModel.state {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing: return .orange
        }
    }

    private var buttonIcon: String {
        switch viewModel.state {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "ellipsis"
        }
    }

    private var buttonLabel: String {
        switch viewModel.state {
        case .idle: return "Start Dictation"
        case .recording: return "Stop"
        case .transcribing: return "Transcribing..."
        }
    }

    private var buttonColor: Color {
        viewModel.state == .recording ? .red : .accentColor
    }
}

private struct HistoryRow: View {
    let text: String
    let onReuse: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onReuse) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy and paste")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.15) : Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .onHover { hovered = $0 }
    }
}
