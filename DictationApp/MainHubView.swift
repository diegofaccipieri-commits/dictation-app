import AppKit
import SwiftUI

enum HubDestination: String, CaseIterable, Identifiable {
    case home
    case dictation
    case translation
    case meetings
    case transcriptions
    case voiceMemos
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Início"
        case .dictation: return "Ditado"
        case .translation: return "Tradução"
        case .meetings: return "Reuniões"
        case .transcriptions: return "Transcrições"
        case .voiceMemos: return "Voice Memos"
        case .settings: return "Ajustes"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .dictation: return "mic"
        case .translation: return "character.book.closed"
        case .meetings: return "person.2.wave.2"
        case .transcriptions: return "doc.text"
        case .voiceMemos: return "waveform"
        case .settings: return "gearshape"
        }
    }

    static let primary: [HubDestination] = [
        .home, .dictation, .translation, .meetings, .transcriptions, .voiceMemos,
    ]
}

@MainActor
final class MainHubRouter: ObservableObject {
    @Published var selection: HubDestination = .home
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct MainHubView: View {
    @ObservedObject var router: MainHubRouter
    // Plain references: the hub only forwards these models to the pages, which observe
    // them themselves. Observing here re-rendered every page (all kept alive in the
    // ZStack) on each keystroke in the translation editor.
    let viewModel: DictationViewModel
    let translationModel: TranslationWorkspaceViewModel
    let voiceMemosStore: VoiceMemosStore
    let fnMonitor: FnKeyMonitor
    let onSelectFile: () -> Void
    let onSelectFolder: () -> Void
    let onTranscribeMemos: (Set<String>, Bool) -> Void
    let onCheckForUpdates: () -> Void

    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 0) {
            HubSidebar(router: router)
                .frame(width: 206)

            Divider().overlay(AppColors.borderSoft)

            ZStack {
                page(.home) {
                    HomeDashboardView(router: router, viewModel: viewModel)
                }
                page(.dictation) {
                    DictationWorkspaceView(viewModel: viewModel, fnMonitor: fnMonitor)
                }
                page(.translation) {
                    TranslationWorkspaceView(viewModel: translationModel)
                }
                page(.meetings) {
                    meetingsPage
                }
                page(.transcriptions) {
                    TranscriptionsWorkspaceView(
                        viewModel: viewModel,
                        onSelectFile: onSelectFile,
                        onSelectFolder: onSelectFolder,
                        onOpenVoiceMemos: { router.selection = .voiceMemos }
                    )
                }
                page(.voiceMemos) {
                    VoiceMemosView(store: voiceMemosStore, onTranscribe: onTranscribeMemos)
                }
                page(.settings) {
                    HubSettingsView(
                        viewModel: viewModel,
                        fnMonitor: fnMonitor,
                        onCheckForUpdates: onCheckForUpdates
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(AppColors.windowBG)
        .tint(AppColors.voice)
        .preferredColorScheme(appearance.colorScheme)
    }

    @ViewBuilder
    private var meetingsPage: some View {
        if #available(macOS 15, *) {
            ReunioesView(embedded: true)
        } else {
            ContentUnavailableView {
                Label("Reuniões indisponíveis", systemImage: "person.2.wave.2")
            } description: {
                Text("A captura de reuniões requer macOS 15 ou superior.")
            }
            .background(AppColors.windowBG)
        }
    }

    // Only the selected page is mounted. Keeping every page alive (hidden via opacity)
    // made SwiftUI lay out all seven pages on every hosting-view layout pass, which
    // showed up as keystroke lag in the translation editor.
    @ViewBuilder
    private func page<Content: View>(
        _ destination: HubDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if router.selection == destination {
            content()
        }
    }
}

private struct HubSidebar: View {
    @ObservedObject var router: MainHubRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AppColors.voice).frame(width: 42, height: 42)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Dictation")
                    .font(.system(size: 18, weight: .bold))
            }
            .padding(.horizontal, 18)
            .padding(.top, 50)
            .padding(.bottom, 24)

            VStack(spacing: 5) {
                ForEach(HubDestination.primary) { destination in
                    sidebarButton(destination)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Divider().overlay(AppColors.borderSoft).padding(.horizontal, 16)

            sidebarButton(.settings)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        .background(AppColors.sidebarBG)
    }

    private func sidebarButton(_ destination: HubDestination) -> some View {
        let selected = router.selection == destination
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                router.selection = destination
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Text(destination.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? AppColors.voice : Color.clear))
    }
}

private struct HomeDashboardView: View {
    @ObservedObject var router: MainHubRouter
    @ObservedObject var viewModel: DictationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("O que você quer fazer?")
                        .font(.system(size: 28, weight: .bold))
                    Text("Escolha uma ferramenta para começar.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Button {
                    router.selection = .dictation
                    viewModel.toggle()
                } label: {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(AppColors.voice.opacity(0.11)).frame(width: 66, height: 66)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(AppColors.voice)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(viewModel.state == .recording ? "Parar ditado" : "Iniciar ditado")
                                .font(.system(size: 21, weight: .bold))
                            HStack(spacing: 6) {
                                Circle().fill(statusColor).frame(width: 8, height: 8)
                                Text(statusLabel)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: viewModel.state == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(viewModel.state == .recording ? AppColors.recording : AppColors.voice))
                    }
                    .padding(20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(cardBackground)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    actionCard(.translation, title: "Traduzir texto", subtitle: "LAWYER, Argentina ou dia a dia")
                    actionCard(.meetings, title: "Gravar reunião", subtitle: "Sua voz + áudio do Mac")
                    actionCard(.transcriptions, title: "Transcrever arquivo", subtitle: "Áudio, vídeo ou pasta")
                    actionCard(.voiceMemos, title: "Abrir Voice Memos", subtitle: "Gravações do iPhone")
                }

                if !viewModel.history.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Recentes").font(.system(size: 15, weight: .bold))
                            Spacer()
                            Button("Ver no Ditado") { router.selection = .dictation }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(AppColors.voice)
                        }
                        .padding(14)

                        Divider().overlay(AppColors.borderSoft)

                        ForEach(Array(viewModel.history.prefix(3).enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(item).lineLimit(1).font(.system(size: 13))
                                Spacer()
                                Button {
                                    viewModel.reuseHistoryItem(item)
                                } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                    .background(cardBackground)
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppColors.windowBG)
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle, .correcting: return .green
        case .recording: return AppColors.recording
        case .transcribing: return .orange
        }
    }

    private var statusLabel: String {
        if viewModel.isModelLoading { return "Carregando modelo…" }
        switch viewModel.state {
        case .idle: return "Pronto · toque duas vezes em fn"
        case .recording: return "Gravando · pressione fn para parar"
        case .transcribing: return "Transcrevendo…"
        case .correcting: return "Texto copiado"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(AppColors.panel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderSoft, lineWidth: 1))
    }

    private func actionCard(_ destination: HubDestination, title: String, subtitle: String) -> some View {
        Button { router.selection = destination } label: {
            HStack(spacing: 13) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppColors.voice)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(AppColors.voice.opacity(0.10)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(cardBackground)
    }
}

private struct DictationWorkspaceView: View {
    @ObservedObject var viewModel: DictationViewModel
    let fnMonitor: FnKeyMonitor
    @State private var selectedKey = DoubleTapKey(
        rawValue: UserDefaults.standard.string(forKey: "doubleTapKey") ?? ""
    ) ?? .fn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader("Ditado", subtitle: "Transcrição local, rápida e pronta para colar.")

                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(statusText).font(.system(size: 13, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("TEXTO TRANSCRITO")
                        .font(.system(size: 10, weight: .bold)).kerning(0.7).foregroundStyle(.secondary)
                    ScrollView {
                        Text(viewModel.transcribedText.isEmpty
                             ? "A transcrição aparece aqui e é colada no app em foco…"
                             : viewModel.transcribedText)
                            .font(.system(size: 14))
                            .foregroundStyle(viewModel.transcribedText.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 130)
                }
                .padding(18)
                .background(cardBackground)

                Button(action: viewModel.toggle) {
                    HStack(spacing: 16) {
                        Image(systemName: viewModel.state == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 62)
                            .background(Circle().fill(viewModel.state == .recording ? AppColors.recording : AppColors.voice))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(viewModel.state == .recording ? "Parar e transcrever" : "Iniciar ditado")
                                .font(.system(size: 18, weight: .bold))
                            Text("Toque duas vezes em \(selectedKey.displayName) de qualquer app · ESC cancela")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.state == .transcribing || !viewModel.isModelLoaded)
                .background(cardBackground)

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }

                if !viewModel.history.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RECENTES")
                            .font(.system(size: 10, weight: .bold)).kerning(0.7).foregroundStyle(.secondary)
                            .padding(14)
                        Divider().overlay(AppColors.borderSoft)
                        ForEach(Array(viewModel.history.prefix(4).enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Button { viewModel.reuseHistoryItem(item) } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                    }
                    .background(cardBackground)
                }

                HStack(spacing: 18) {
                    compactPicker("Idioma", selection: Binding(
                        get: { viewModel.transcriptionLanguage },
                        set: { viewModel.setTranscriptionLanguage($0) }
                    ), values: TranscriptionLanguage.allCases, label: { $0.label })

                    compactPicker("Tradução", selection: Binding(
                        get: { viewModel.translationMode },
                        set: { viewModel.setTranslationMode($0) }
                    ), values: [.off] + TranslationMode.directModes, label: { $0.displayName })

                    compactPicker("Tecla dupla", selection: $selectedKey,
                                  values: DoubleTapKey.allCases, label: { $0.displayName })
                        .onChange(of: selectedKey) { _, value in fnMonitor.doubleTapKey = value }
                }
                .padding(14)
                .background(cardBackground)
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppColors.windowBG)
    }

    private var statusColor: Color {
        if !viewModel.isModelLoaded { return .red }
        switch viewModel.state {
        case .idle, .correcting: return .green
        case .recording: return AppColors.recording
        case .transcribing: return .orange
        }
    }

    private var statusText: String {
        if viewModel.isModelLoading { return "Carregando modelo…" }
        if viewModel.isTranslating { return "Traduzindo…" }
        switch viewModel.state {
        case .idle: return "Pronto"
        case .recording: return "Gravando…"
        case .transcribing: return "Transcrevendo…"
        case .correcting: return "Colado no app em foco ✓"
        }
    }
}

private struct TranscriptionsWorkspaceView: View {
    @ObservedObject var viewModel: DictationViewModel
    let onSelectFile: () -> Void
    let onSelectFolder: () -> Void
    let onOpenVoiceMemos: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader("Transcrições", subtitle: "Transforme arquivos de áudio e vídeo em texto.")

            HStack(spacing: 14) {
                importCard("Selecionar arquivo", subtitle: "Áudio ou vídeo", symbol: "doc.text", action: onSelectFile)
                importCard("Selecionar pasta", subtitle: "Processar vários arquivos", symbol: "folder", action: onSelectFolder)
                importCard("Importar do Voice Memos", subtitle: "Gravações do iPhone", symbol: "waveform", action: onOpenVoiceMemos)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PROCESSAMENTO").font(.system(size: 10, weight: .bold)).kerning(0.7).foregroundStyle(.secondary)
                        Text(viewModel.batchStatus ?? "Nenhuma transcrição em andamento.")
                            .font(.system(size: 14, weight: .medium))
                    }
                    Spacer()
                    if viewModel.batchStatus != nil {
                        ProgressView().controlSize(.small)
                        Button("Cancelar") {
                            BatchTranscriber.shared.cancel()
                            viewModel.batchStatus = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider().overlay(AppColors.borderSoft)

                HStack {
                    Text("Modelo para documentos").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { viewModel.batchModel },
                        set: { viewModel.setBatchModel($0) }
                    )) {
                        ForEach(WhisperModel.allCases) { model in Text(model.displayName).tag(model) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                Text("O processamento é feito localmente no Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(cardBackground)

            Spacer()
        }
        .padding(30)
        .background(AppColors.windowBG)
    }

    private func importCard(_ title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(AppColors.voice)
                Spacer()
                Text(title).font(.system(size: 14, weight: .bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(cardBackground)
    }
}

private struct HubSettingsView: View {
    @ObservedObject var viewModel: DictationViewModel
    let fnMonitor: FnKeyMonitor
    let onCheckForUpdates: () -> Void
    @State private var selectedKey = DoubleTapKey(
        rawValue: UserDefaults.standard.string(forKey: "doubleTapKey") ?? ""
    ) ?? .fn
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader("Ajustes", subtitle: "Personalize o ditado e o processamento local.")

                settingsGroup("APARÊNCIA") {
                    settingsRow("Tema") {
                        Picker("", selection: $appearanceRaw) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance.rawValue)
                            }
                        }
                        .pickerStyle(.segmented).frame(width: 310)
                    }
                }

                settingsGroup("DITADO") {
                    settingsRow("Motor do ditado") {
                        Picker("", selection: Binding(
                            get: { viewModel.dictationEngine },
                            set: { viewModel.setDictationEngine($0) }
                        )) {
                            ForEach(DictationEngine.allCases) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.segmented).frame(width: 260)
                    }
                    Text(voxtralStatus)
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    if viewModel.dictationEngine == .voxtral {
                        settingsDivider
                        settingsRow("Digitar direto no cursor") {
                            Toggle("", isOn: Binding(
                                get: { viewModel.typesLive },
                                set: { viewModel.setTypesLive($0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        Text("Desligado: o texto aparece num balão e é colado ao terminar. Comandos como “vírgula” só funcionam desligado.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    settingsDivider
                    settingsRow("Idioma de transcrição") {
                        Picker("", selection: Binding(
                            get: { viewModel.transcriptionLanguage },
                            set: { viewModel.setTranscriptionLanguage($0) }
                        )) {
                            ForEach(TranscriptionLanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .pickerStyle(.segmented).frame(width: 430)
                    }
                    settingsDivider
                    settingsRow("Tecla dupla") {
                        Picker("", selection: $selectedKey) {
                            ForEach(DoubleTapKey.allCases) { key in Text(key.displayName).tag(key) }
                        }
                        .frame(width: 210)
                        .onChange(of: selectedKey) { _, value in fnMonitor.doubleTapKey = value }
                    }
                    settingsDivider
                    settingsRow("Wake word") {
                        Toggle("“Sileide”", isOn: Binding(
                            get: { viewModel.isWakeWordEnabled },
                            set: { viewModel.setWakeWord(enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                    }
                }

                settingsGroup("MODELOS") {
                    settingsRow("Ditado ao vivo") {
                        modelPicker(selection: Binding(
                            get: { viewModel.liveModel }, set: { viewModel.setLiveModel($0) }
                        ))
                    }
                    settingsDivider
                    settingsRow("Documentos") {
                        modelPicker(selection: Binding(
                            get: { viewModel.batchModel }, set: { viewModel.setBatchModel($0) }
                        ))
                    }
                    Text("Modelos processados localmente no Mac.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }

                settingsGroup("TRADUÇÃO NO DITADO") {
                    settingsRow("Direção") {
                        Picker("", selection: Binding(
                            get: { viewModel.translationMode },
                            set: { viewModel.setTranslationMode($0) }
                        )) {
                            Text(TranslationMode.off.displayName).tag(TranslationMode.off)
                            ForEach(TranslationMode.directModes) { mode in Text(mode.displayName).tag(mode) }
                        }
                        .frame(width: 220)
                    }
                    Text("Somente direções diretas; os modos especiais ficam na tela Tradução.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }

                settingsGroup("APLICATIVO") {
                    settingsRow("Versão") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                            .foregroundStyle(.secondary)
                        Button("Buscar atualização", action: onCheckForUpdates)
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AppColors.windowBG)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 10, weight: .bold)).kerning(0.7).foregroundStyle(.secondary)
            content()
        }
        .padding(18)
        .background(cardBackground)
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 13.5, weight: .medium))
            Spacer()
            content()
        }
    }

    private var settingsDivider: some View { Divider().overlay(AppColors.borderSoft) }

    private var voxtralStatus: String {
        guard viewModel.dictationEngine == .voxtral else {
            return "Texto aparece ao terminar de falar."
        }
        if !viewModel.isVoxtralInstalled { return "Modelo Voxtral não encontrado; usando Whisper." }
        if viewModel.isVoxtralLoading { return "Carregando Voxtral… enquanto isso, usa Whisper." }
        if viewModel.isVoxtralReady { return "Texto aparece enquanto você fala. Whisper fica de reserva." }
        return "Voxtral não iniciou; usando Whisper."
    }

    private func modelPicker(selection: Binding<WhisperModel>) -> some View {
        Picker("", selection: selection) {
            ForEach(WhisperModel.allCases) { model in Text(model.displayName).tag(model) }
        }
        .pickerStyle(.segmented).frame(width: 310)
    }
}

private func pageHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 27, weight: .bold))
        Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
    }
}

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 11)
        .fill(AppColors.panel)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColors.borderSoft, lineWidth: 1))
}

private func compactPicker<Value: Hashable>(
    _ title: String,
    selection: Binding<Value>,
    values: [Value],
    label: @escaping (Value) -> String
) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Picker("", selection: selection) {
            ForEach(values, id: \.self) { value in Text(label(value)).tag(value) }
        }
        .labelsHidden().frame(minWidth: 150)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
