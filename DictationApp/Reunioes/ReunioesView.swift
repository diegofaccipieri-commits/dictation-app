import SwiftUI
import AppKit

@available(macOS 15, *)
struct ReunioesView: View {
    @StateObject private var recorder = MeetingRecorder()
    @StateObject private var player = MeetingPlayer()
    @StateObject private var transcriber = MeetingTranscriber()
    @State private var searchText = ""
    @State private var selectedId: String?
    @State private var durations: [String: Double] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppColors.borderSoft)
            if !recorder.permissions.allGranted { permissionsBanner }
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 264)
                    .background(AppColors.sidebarBG)
                Divider().overlay(AppColors.borderSoft)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppColors.windowBG)
        .frame(minWidth: 880, minHeight: 560)
        .tint(AppColors.voice)
        .onAppear {
            recorder.onAppear()
            transcriber.loadExisting(recorder.meetings)
            if selectedId == nil { selectedId = recorder.meetings.first?.id }
        }
        .onChange(of: recorder.meetings) { _, items in
            transcriber.loadExisting(items)
            if let selectedId, items.contains(where: { $0.id == selectedId }) == false {
                self.selectedId = items.first?.id
            } else if selectedId == nil {
                selectedId = items.first?.id
            }
        }
    }

    // MARK: Header (merged with the titlebar; leading inset clears the traffic lights)

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reuniões").font(.system(size: 15, weight: .bold))
                    Text("Sua voz e o áudio do Mac, gravados e transcritos no aparelho")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if recorder.isRecording { recordingStatus }
                Button {
                    recorder.toggle()
                } label: {
                    Label(recorder.isRecording ? "Parar" : "Gravar reunião",
                          systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 116)
                }
                .buttonStyle(PillButtonStyle(kind: recorder.isRecording ? .rec : .primary))
                .disabled(!recorder.permissions.allGranted && !recorder.isRecording)
            }
            if let err = recorder.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(AppColors.windowBG)
    }

    private var recordingStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(AppColors.recording)
                .symbolEffect(.pulse, options: .repeating)
            Text(Self.elapsed(recorder.elapsed))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(AppColors.recording)
            MeetingLiveTrackMeter(label: "Você", systemImage: "mic.fill", color: AppColors.voice,
                                  levels: recorder.microphoneLevels)
            MeetingLiveTrackMeter(label: "Mac", systemImage: "speaker.wave.2.fill", color: AppColors.others,
                                  levels: recorder.systemLevels)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppColors.recording.opacity(0.09)))
    }

    private var permissionsBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissão de microfone necessária").font(.subheadline.weight(.medium))
                Text("O macOS pedirá a permissão de Áudio do Sistema na primeira gravação; basta aceitar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Conceder microfone") { recorder.requestMicrophone() }
                .buttonStyle(PillButtonStyle())
        }
        .padding(10)
        .background(Rectangle().fill(Color.orange.opacity(0.09)))
    }

    // MARK: Sidebar (custom, orange selection like the prototype)

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleMeetings: [MeetingItem] {
        searchQuery.isEmpty
            ? recorder.meetings
            : recorder.meetings.filter { meetingMatches($0, query: searchQuery) }
    }

    private func meetingMatches(_ item: MeetingItem, query: String) -> Bool {
        item.displayTitle.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || item.id.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || transcriber.contains(id: item.id, query: query)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Pesquisar gravações", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(AppColors.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppColors.border, lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Text("GRAVAÇÕES")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)

            if visibleMeetings.isEmpty {
                Spacer()
                Text(recorder.meetings.isEmpty ? "Nenhuma reunião ainda." : "Nada encontrado.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visibleMeetings) { item in
                            sidebarRow(item)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }

            Divider().overlay(AppColors.borderSoft)
            HStack {
                Button { NSWorkspace.shared.open(MeetingPaths.audioDir) } label: {
                    Image(systemName: MeetingPaths.isUsingDropbox ? "cloud" : "externaldrive")
                }
                .buttonStyle(.accessoryBar)
                .help("Abrir pasta das reuniões")
                Button { recorder.loadMeetings() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.accessoryBar)
                    .help("Recarregar lista")
                Spacer()
                Text("\(visibleMeetings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func sidebarRow(_ item: MeetingItem) -> some View {
        let selected = item.id == selectedId
        return Button {
            selectedId = item.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                HStack(spacing: 8) {
                    Text(Self.shortDate(item.date))
                    if let d = durations[item.id], d > 0 {
                        Text(Self.timestamp(d)).monospacedDigit()
                    }
                    if !searchQuery.isEmpty {
                        let count = transcriber.matchCount(id: item.id, query: searchQuery)
                        if count > 0 {
                            Text("\(count) trecho\(count == 1 ? "" : "s")")
                                .foregroundStyle(selected ? Color.white.opacity(0.9) : AppColors.voice)
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? AppColors.voice : Color.clear))
        .task(id: item.id) {
            guard durations[item.id] == nil else { return }
            let urls = [item.micURL, item.systemURL].compactMap { $0 }
            guard !urls.isEmpty else { return }
            let d = await Task.detached(priority: .utility) {
                urls.map { MeetingWaveformLoader.duration(for: $0) }.max() ?? 0
            }.value
            durations[item.id] = d
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let item = visibleMeetings.first(where: { $0.id == selectedId }) ?? recorder.meetings.first(where: { $0.id == selectedId }) {
            MeetingDetailView(item: item, player: player, transcriber: transcriber, searchText: searchQuery) {
                recorder.rename(item, title: $0)
            } onDelete: {
                player.stop()
                transcriber.clear(id: item.id)
                recorder.delete(item)
            } onLibraryChanged: {
                durations.removeValue(forKey: item.id)
                recorder.loadMeetings()
            }
            .id(item.id)
        } else {
            ContentUnavailableView {
                Label("Nenhuma reunião ainda", systemImage: "person.2.wave.2")
            } description: {
                Text("Clique em Gravar reunião para capturar sua voz e o áudio do Mac.")
            }
        }
    }

    // MARK: Formatting

    static func elapsed(_ t: TimeInterval) -> String { MeetingTrimLogic.label(t) }
    static func timestamp(_ t: TimeInterval) -> String { MeetingTrimLogic.label(t) }
    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Detail view

@available(macOS 15, *)
struct MeetingDetailView: View {
    let item: MeetingItem
    @ObservedObject var player: MeetingPlayer
    @ObservedObject var transcriber: MeetingTranscriber
    let searchText: String
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onLibraryChanged: () -> Void

    @State private var language = TranscriptionLanguage.current.whisperCode
    @State private var renameText = ""
    @State private var showingRenameAlert = false
    @State private var showingDeleteAlert = false
    @State private var isTrimming = false
    @State private var trimSelection: MeetingTrimLogic.Selection?
    @State private var isExportingTrim = false
    @State private var trimError: String?
    @State private var showingRemoveAlert = false
    @State private var waveformGeneration = 0
    @State private var micPeaks: [Float] = []
    @State private var sysPeaks: [Float] = []
    @State private var duration: Double = 0
    /// Pending start position (fraction) used when playback is stopped.
    @State private var startFraction: Double = 0

    private var pairURLs: [URL] { [item.micURL, item.systemURL].compactMap { $0 } }
    private var isPlayingThis: Bool { player.isPlayingPair(id: item.id) }
    private var progressFraction: Double { isPlayingThis ? player.progress : startFraction }
    private var currentSeconds: Double { isPlayingThis ? player.currentSeconds : startFraction * duration }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                waveCard
                transcriptCard
            }
            .padding(18)
        }
        .background(AppColors.windowBG)
        .task(id: "\(waveformGeneration)|\(item.id)") { await loadWave() }
        .alert("Renomear reunião", isPresented: $showingRenameAlert) {
            TextField("Nome da reunião", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { onRename(renameText) }
        } message: {
            Text("Use nomes de pessoas, cliente ou assunto para achar esta reunião depois.")
        }
        .alert("Apagar reunião?", isPresented: $showingDeleteAlert) {
            Button("Cancelar", role: .cancel) {}
            Button("Apagar", role: .destructive, action: onDelete)
        } message: {
            Text("Isso remove os áudios e a transcrição salva desta reunião.")
        }
        .alert("Remover trecho?", isPresented: $showingRemoveAlert) {
            Button("Cancelar", role: .cancel) {}
            Button("Remover", role: .destructive) { removeTrim() }
        } message: {
            if let sel = trimSelection, let range = MeetingTrimLogic.timeRange(sel, duration: duration) {
                Text("O trecho \(ReunioesView.timestamp(range.start)) - \(ReunioesView.timestamp(range.end)) será apagado permanentemente dos áudios desta reunião, e a transcrição atual será descartada.")
            } else {
                Text("O trecho selecionado será apagado permanentemente dos áudios desta reunião.")
            }
        }
    }

    private func loadWave() async {
        let mic = item.micURL, sys = item.systemURL
        let result = await Task.detached(priority: .utility) { () -> ([Float], [Float], Double) in
            let m = mic.map { MeetingWaveformLoader.peaks(for: $0, buckets: 700) } ?? []
            let s = sys.map { MeetingWaveformLoader.peaks(for: $0, buckets: 700) } ?? []
            let dm = mic.map { MeetingWaveformLoader.duration(for: $0) } ?? 0
            let ds = sys.map { MeetingWaveformLoader.duration(for: $0) } ?? 0
            return (m, s, max(dm, ds))
        }.value
        micPeaks = result.0
        sysPeaks = result.1
        duration = result.2
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.system(size: 19, weight: .bold)).lineLimit(2)
                HStack(spacing: 10) {
                    Text(ReunioesView.shortDate(item.date))
                        .font(.caption).foregroundStyle(.secondary)
                    if duration > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                            Text(ReunioesView.timestamp(duration)).monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.voice)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(AppColors.voice.opacity(0.11)))
                    }
                }
            }
            Spacer()
            if !pairURLs.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isTrimming.toggle()
                        trimSelection = nil
                        trimError = nil
                    }
                } label: {
                    Label("Recortar", systemImage: "scissors")
                        .foregroundStyle(isTrimming ? AnyShapeStyle(AppColors.voice) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.accessoryBar)
                .help(isTrimming ? "Sair do modo de recorte" : "Recortar um trecho desta reunião")
            }
            Button {
                if let u = item.micURL ?? item.systemURL {
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            } label: { Image(systemName: "folder") }
            .buttonStyle(.accessoryBar).help("Mostrar no Finder")
            Button {
                renameText = item.title ?? item.displayTitle
                showingRenameAlert = true
            } label: { Image(systemName: "pencil") }
            .buttonStyle(.accessoryBar).help("Renomear reunião")
            Button {
                showingDeleteAlert = true
            } label: { Image(systemName: "trash").foregroundStyle(.red) }
            .buttonStyle(.accessoryBar).help("Apagar reunião")
        }
    }

    // MARK: Wave card

    private var waveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                legendItem(color: AppColors.voice, label: "Você (microfone)")
                legendItem(color: AppColors.others, label: "Outros (áudio do Mac)")
                Spacer()
                if duration > 0 {
                    (Text(ReunioesView.timestamp(currentSeconds)).bold()
                        + Text(" / \(ReunioesView.timestamp(duration))").foregroundStyle(.secondary))
                        .font(.system(size: 12.5)).monospacedDigit()
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045))
                if micPeaks.isEmpty && sysPeaks.isEmpty {
                    Text(pairURLs.isEmpty ? "sem áudio" : "carregando...")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    MeetingMirrorWaveform(top: micPeaks, bottom: sysPeaks,
                                          progress: progressFraction,
                                          topColor: AppColors.voice, bottomColor: AppColors.others)
                        .padding(.horizontal, 4)
                }
                if isTrimming, let sel = trimSelection {
                    GeometryReader { proxy in
                        let x0 = CGFloat(sel.startFraction) * proxy.size.width
                        let x1 = CGFloat(sel.endFraction) * proxy.size.width
                        Rectangle().fill(AppColors.voice.opacity(0.18))
                            .frame(width: max(1, x1 - x0)).offset(x: x0)
                        Rectangle().fill(AppColors.voice).frame(width: 1.5).offset(x: x0)
                        Rectangle().fill(AppColors.voice).frame(width: 1.5).offset(x: x1)
                    }
                    .allowsHitTesting(false)
                }
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 2)
                        .offset(x: CGFloat(progressFraction) * proxy.size.width - 1)
                        .allowsHitTesting(false)
                }
                if !pairURLs.isEmpty {
                    GeometryReader { proxy in
                        if isTrimming {
                            Color.clear.contentShape(Rectangle())
                                .gesture(trimGesture(width: proxy.size.width))
                        } else {
                            Color.clear.contentShape(Rectangle())
                                .gesture(seekGesture(width: proxy.size.width))
                        }
                    }
                }
            }
            .frame(height: 132)
            .help(isTrimming ? "Arraste para selecionar o trecho a recortar"
                             : "Clique para posicionar; play reproduz as duas faixas juntas")

            HStack {
                ForEach(0..<6) { i in
                    if i > 0 { Spacer() }
                    Text(ReunioesView.timestamp(duration * Double(i) / 5))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            transport

            if isTrimming { trimControls }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderSoft, lineWidth: 1))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { skip(-15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(TransportButtonStyle())
                .help("Voltar 15 segundos")
            Button {
                if isPlayingThis {
                    player.stop()
                } else {
                    player.playPair(id: item.id, urls: pairURLs, from: startFraction)
                }
            } label: {
                Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
            }
            .buttonStyle(TransportButtonStyle(prominent: true))
            .disabled(pairURLs.isEmpty)
            .help(isPlayingThis ? "Pausar" : "Reproduzir as duas faixas")
            Button { skip(15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(TransportButtonStyle())
                .help("Avançar 15 segundos")
            Spacer()
        }
        .padding(.top, 2)
    }

    private func skip(_ delta: Double) {
        guard duration > 0 else { return }
        let newSeconds = min(max(0, currentSeconds + delta), duration)
        let frac = newSeconds / duration
        if isPlayingThis {
            player.playPair(id: item.id, urls: pairURLs, from: frac)
        } else {
            startFraction = frac
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onEnded { value in
            guard width > 0 else { return }
            let frac = Double(min(1, max(0, value.location.x / width)))
            startFraction = frac
            if isPlayingThis {
                player.playPair(id: item.id, urls: pairURLs, from: frac)
            }
        }
    }

    private func trimGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard width > 0 else { return }
            trimSelection = MeetingTrimLogic.Selection(
                Double(value.startLocation.x / width),
                Double(value.location.x / width))
        }
    }

    // MARK: Trim

    @ViewBuilder
    private var trimControls: some View {
        let range = trimSelection.flatMap { MeetingTrimLogic.timeRange($0, duration: duration) }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").foregroundStyle(AppColors.voice)
                if isExportingTrim {
                    ProgressView().controlSize(.small)
                    Text("Processando áudio...").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else if let range {
                    Text("\(ReunioesView.timestamp(range.start)) - \(ReunioesView.timestamp(range.end))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Text("(\(ReunioesView.timestamp(range.end - range.start)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if let sel = trimSelection {
                            player.playPair(id: item.id, urls: pairURLs,
                                            from: sel.startFraction, until: sel.endFraction)
                        }
                    } label: { Label("Ouvir", systemImage: "play.circle") }
                    .buttonStyle(PillButtonStyle())
                    .help("Reproduzir apenas o trecho selecionado")
                    Button {
                        separateTrim()
                    } label: { Label("Separar", systemImage: "plus.square.on.square") }
                    .buttonStyle(PillButtonStyle())
                    .help("Salvar o trecho selecionado como uma nova gravação")
                    Button {
                        showingRemoveAlert = true
                    } label: { Label("Remover", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(kind: .danger))
                    .help("Apagar o trecho selecionado desta gravação")
                    Button("Cancelar") { exitTrimMode() }
                        .buttonStyle(.borderless).controlSize(.small)
                } else {
                    Text("Arraste sobre a waveform para selecionar um trecho.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancelar") { exitTrimMode() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            if let trimError {
                Label(trimError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.voice.opacity(0.08)))
    }

    private func exitTrimMode() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isTrimming = false
            trimSelection = nil
            trimError = nil
        }
    }

    @MainActor
    private func separateTrim() {
        guard let selection = trimSelection, !isExportingTrim else { return }
        isExportingTrim = true
        trimError = nil
        player.stop()
        Task {
            do {
                let newId = try await MeetingTrimmer.export(item: item, selection: selection)
                NSLog("DictationApp: [TRIM] trecho separado: %@", newId)
                isExportingTrim = false
                exitTrimMode()
                onLibraryChanged()
            } catch {
                isExportingTrim = false
                trimError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func removeTrim() {
        guard let selection = trimSelection, !isExportingTrim else { return }
        isExportingTrim = true
        trimError = nil
        player.stop()
        Task {
            do {
                try await MeetingTrimmer.removeSection(item: item, selection: selection)
                transcriber.clear(id: item.id)
                isExportingTrim = false
                exitTrimMode()
                startFraction = 0
                waveformGeneration += 1
                onLibraryChanged()
            } catch {
                isExportingTrim = false
                trimError = error.localizedDescription
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptCard: some View {
        let segments = transcriber.segments(for: item.id)
        let visibleSegments = searchText.isEmpty
            ? segments
            : segments.filter { MeetingSearch.matches($0, query: searchText) }
        let status = transcriber.status(for: item.id)
        let running: Bool = { if case .running = status { return true } else { return false } }()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Transcrição", systemImage: "text.bubble").font(.subheadline.bold())
                Spacer()
                if running, case let .running(msg) = status {
                    ProgressView().controlSize(.small)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                } else if !segments.isEmpty {
                    Button { transcriber.transcribe(item, language: language) } label: {
                        Label("Refazer", systemImage: "arrow.clockwise")
                    }.buttonStyle(.accessoryBar).font(.caption)
                }
            }

            if !segments.isEmpty {
                VStack(spacing: 10) {
                    ForEach(visibleSegments) { MeetingBubble(segment: $0, searchText: searchText) }
                }
            } else if case let .failed(msg) = status {
                Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                transcribeControls
            } else if !running {
                transcribeControls
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.borderSoft, lineWidth: 1))
    }

    private var transcribeControls: some View {
        HStack(spacing: 10) {
            Button { transcriber.transcribe(item, language: language) } label: {
                Label("Transcrever", systemImage: "waveform.and.mic")
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            Picker("", selection: $language) {
                Text("Auto").tag("auto")
                Text("PT").tag("pt")
                Text("EN").tag("en")
                Text("ES").tag("es")
            }
            .pickerStyle(.segmented).frame(width: 210)
            Spacer()
        }
    }
}

// MARK: - Mirror waveform (assinatura do módulo)

/// The conversation as one mirrored waveform: the user's mic grows upward in orange,
/// the Mac's system audio grows downward in teal, from a shared centerline.
@available(macOS 15, *)
struct MeetingMirrorWaveform: View {
    let top: [Float]
    let bottom: [Float]
    var progress: Double = 0
    var topColor: Color = AppColors.voice
    var bottomColor: Color = AppColors.others

    var body: some View {
        Canvas { ctx, size in
            let count = max(top.count, bottom.count)
            guard count > 0 else { return }
            let mid = size.height / 2
            let barWidth = size.width / CGFloat(count)
            let maxH = mid - 4

            for i in 0..<count {
                let x = CGFloat(i) * barWidth
                let played = Double(i) / Double(count) <= progress
                let w = max(0.8, barWidth - 0.8)

                if i < top.count {
                    let h = max(1, CGFloat(top[i]) * maxH)
                    let rect = CGRect(x: x, y: mid - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                             with: .color(played ? topColor : topColor.opacity(0.30)))
                }
                if i < bottom.count {
                    let h = max(1, CGFloat(bottom[i]) * maxH)
                    let rect = CGRect(x: x, y: mid + 1, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                             with: .color(played ? bottomColor : bottomColor.opacity(0.30)))
                }
            }
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                     with: .color(.secondary.opacity(0.35)))
        }
    }
}

// MARK: - Live meters

@available(macOS 15, *)
struct MeetingLiveTrackMeter: View {
    let label: String
    let systemImage: String
    let color: Color
    let levels: [Float]

    var body: some View {
        HStack(spacing: 5) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            MeetingLiveWaveform(levels: levels, color: color)
                .frame(width: 66, height: 20)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nível de áudio de \(label)")
    }
}

@available(macOS 15, *)
private struct MeetingLiveWaveform: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let barWidth = size.width / CGFloat(levels.count)
            let middle = size.height / 2
            for (index, level) in levels.enumerated() {
                let height = max(2, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * barWidth,
                                  y: middle - height / 2,
                                  width: max(1, barWidth - 1),
                                  height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.7), with: .color(color))
            }
        }
    }
}

// MARK: - Transcript bubble

@available(macOS 15, *)
struct MeetingBubble: View {
    let segment: MeetingSegment
    var searchText = ""

    var body: some View {
        HStack(alignment: .top) {
            if !segment.isMe { Spacer(minLength: 36) }
            VStack(alignment: segment.isMe ? .leading : .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text(segment.speaker).font(.caption2.bold())
                        .foregroundStyle(segment.isMe ? AppColors.voice : AppColors.others)
                    Text(ReunioesView.timestamp(segment.start)).font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text).font(.body)
                    .multilineTextAlignment(segment.isMe ? .leading : .trailing)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(searchText.isEmpty
                              ? (segment.isMe ? AppColors.voice : AppColors.others).opacity(0.12)
                              : Color.yellow.opacity(0.22)))
            }
            if segment.isMe { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity)
    }
}
