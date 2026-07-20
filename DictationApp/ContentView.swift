import KeyboardShortcuts
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: DictationViewModel
    var fnMonitor: FnKeyMonitor?
    @State private var selectedKey: DoubleTapKey = DoubleTapKey(rawValue: UserDefaults.standard.string(forKey: "doubleTapKey") ?? "") ?? .fn
    @State private var recordingStart: Date?

    var body: some View {
        VStack(spacing: 12) {
            statusRow
            transcriptBox
            dictationMain

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !viewModel.history.isEmpty { historySection }

            settingsSection

            if let status = viewModel.batchStatus { batchBanner(status) }

            footerHints
        }
        .padding(14)
        .tint(AppColors.voice)
        .background(AppColors.windowBG)
        .frame(width: 360, height: baseHeight + CGFloat(viewModel.history.count) * 40)
        .onChange(of: viewModel.state) { newState in
            recordingStart = newState == .recording ? Date() : nil
        }
    }

    private var baseHeight: CGFloat { viewModel.history.isEmpty ? 460 : 486 }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 8) {
            if viewModel.isModelLoading {
                ProgressView().scaleEffect(0.5)
            } else {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(statusTextColor)
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
        .animation(.easeInOut, value: viewModel.state)
    }

    private var transcriptBox: some View {
        ScrollView {
            Text(viewModel.transcribedText.isEmpty ? "A transcrição aparece aqui e é colada no app em foco..." : viewModel.transcribedText)
                .font(.system(size: 13))
                .foregroundColor(viewModel.transcribedText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 68)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(AppColors.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColors.borderSoft, lineWidth: 1))
    }

    // MARK: Main action

    private var dictationMain: some View {
        HStack(spacing: 14) {
            Button(action: viewModel.toggle) {
                ZStack {
                    Circle()
                        .fill(viewModel.state == .recording ? AppColors.recording : AppColors.voice)
                        .frame(width: 54, height: 54)
                        .shadow(color: (viewModel.state == .recording ? AppColors.recording : AppColors.voice).opacity(0.35),
                                radius: 9, y: 3)
                    Image(systemName: mainIcon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.state == .transcribing || !viewModel.isModelLoaded)
            .opacity(viewModel.state == .transcribing || !viewModel.isModelLoaded ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                switch viewModel.state {
                case .recording:
                    if let start = recordingStart {
                        TimelineView(.animation(minimumInterval: 1)) { context in
                            Text(elapsedString(from: start, to: context.date))
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(AppColors.recording)
                        }
                    } else {
                        Text("Gravando...")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(AppColors.recording)
                    }
                    Text("clique para parar e transcrever")
                        .font(.caption).foregroundColor(.secondary)
                case .transcribing:
                    Text(viewModel.isTranslating ? "Traduzindo..." : "Transcrevendo...")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.orange)
                    Text("whisper.cpp local")
                        .font(.caption).foregroundColor(.secondary)
                case .correcting:
                    Text("Colado ✓")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                    Text("copiado para a área de transferência")
                        .font(.caption).foregroundColor(.secondary)
                case .idle:
                    Text("Iniciar ditado")
                        .font(.system(size: 14, weight: .bold))
                    Text("\(selectedKey.displayName) \(selectedKey.displayName) de qualquer app · ESC cancela")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private var mainIcon: String {
        switch viewModel.state {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "ellipsis"
        case .correcting: return "checkmark"
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("RECENTES")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.7)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(viewModel.history, id: \.self) { item in
                HistoryRow(text: item) {
                    viewModel.reuseHistoryItem(item)
                }
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("AJUSTES")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.7)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))

            settingRow("Idioma") {
                Picker("", selection: Binding(
                    get: { viewModel.transcriptionLanguage },
                    set: { viewModel.setTranscriptionLanguage($0) }
                )) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.shortLabel).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
            }

            settingRow("Tradução") {
                Picker("", selection: Binding(
                    get: { viewModel.translationMode },
                    set: { viewModel.setTranslationMode($0) }
                )) {
                    ForEach(TranslationMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
            }

            settingRow("Ditado ao vivo") {
                Picker("", selection: Binding(
                    get: { viewModel.liveModel },
                    set: { viewModel.setLiveModel($0) }
                )) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
            }

            settingRow("Documentos") {
                Picker("", selection: Binding(
                    get: { viewModel.batchModel },
                    set: { viewModel.setBatchModel($0) }
                )) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
            }

            settingRow("Tecla dupla") {
                Picker("", selection: $selectedKey) {
                    ForEach(DoubleTapKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
                .onChange(of: selectedKey) { newKey in
                    fnMonitor?.doubleTapKey = newKey
                }
            }

            settingRow("Wake word") {
                Toggle(isOn: Binding(
                    get: { viewModel.isWakeWordEnabled },
                    set: { viewModel.setWakeWord(enabled: $0) }
                )) {
                    Text("\u{201C}Sileide\u{201D}").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(AppColors.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColors.borderSoft, lineWidth: 1))
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 88, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func batchBanner(_ status: String) -> some View {
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

    private var footerHints: some View {
        HStack {
            Text("\(selectedKey.displayName) \(selectedKey.displayName) grava  ·  ESC cancela")
            Spacer()
            Text("local · offline")
        }
        .font(.caption2)
        .foregroundColor(Color(NSColor.tertiaryLabelColor))
    }

    // MARK: State helpers

    private func elapsedString(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var statusText: String {
        if viewModel.isModelLoading { return "Carregando modelo..." }
        if !viewModel.isModelLoaded { return "Modelo indisponível" }
        if viewModel.isTranslating { return "Traduzindo..." }
        switch viewModel.state {
        case .idle:
            let base = viewModel.isFinalModelReady ? "Pronto" : "Pronto (carregando Turbo...)"
            if viewModel.translationMode != .off {
                return base + " · \(viewModel.translationMode.displayName)"
            }
            return base
        case .recording: return "Gravando..."
        case .transcribing: return "Transcrevendo..."
        case .correcting: return "Colado no app em foco ✓"
        }
    }

    private var statusDotColor: Color {
        if !viewModel.isModelLoaded { return .red }
        switch viewModel.state {
        case .idle: return .green
        case .recording: return AppColors.recording
        case .transcribing: return .orange
        case .correcting: return .green
        }
    }

    private var statusTextColor: Color {
        if viewModel.isModelLoading { return .orange }
        if !viewModel.isModelLoaded { return .red }
        switch viewModel.state {
        case .idle: return .primary
        case .recording: return AppColors.recording
        case .transcribing: return .orange
        case .correcting: return .green
        }
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
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onReuse) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.caption)
                    .foregroundColor(AppColors.voice)
            }
            .buttonStyle(.borderless)
            .help("Copiar e colar")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(AppColors.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(hovered ? AppColors.voice.opacity(0.6) : AppColors.borderSoft, lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }
}
