import SwiftUI
import AppKit

@available(macOS 15, *)
struct ReunioesView: View {
    @StateObject private var recorder = MeetingRecorder()
    @StateObject private var player = MeetingPlayer()
    @StateObject private var transcriber = MeetingTranscriber()
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !recorder.permissions.allGranted { permissionsSection; Divider() }
            meetingsSection
        }
        .frame(minWidth: 580, minHeight: 480)
        .onAppear {
            recorder.onAppear()
            transcriber.loadExisting(recorder.meetings)
        }
        .onChange(of: recorder.meetings) { _, items in
            transcriber.loadExisting(items)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reuniões").font(.title2.bold())
                    Text("Grava microfone + áudio do sistema e transcreve com Whisper")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                Button {
                    recorder.toggle()
                } label: {
                    HStack {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        Text(recorder.isRecording ? "Parar" : "Gravar reunião")
                    }
                    .frame(minWidth: 130).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
                .disabled(!recorder.permissions.allGranted && !recorder.isRecording)

                if recorder.isRecording {
                    Label(Self.elapsed(recorder.elapsed), systemImage: "clock")
                        .font(.system(.title3, design: .monospaced)).foregroundStyle(.red)
                    liveRecordingMeters
                }
                Spacer()
            }
            if let err = recorder.lastError {
                Text(err).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private var liveRecordingMeters: some View {
        HStack(spacing: 10) {
            MeetingLiveTrackMeter(label: "Você", systemImage: "mic.fill", color: .blue,
                                   levels: recorder.microphoneLevels)
            MeetingLiveTrackMeter(label: "Mac", systemImage: "speaker.wave.2.fill", color: .green,
                                   levels: recorder.systemLevels)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissões").font(.headline)
            permissionRow("Microfone", granted: recorder.permissions.microphone) { recorder.requestMicrophone() }
            Text("O macOS pedirá a permissão de Áudio do Sistema na primeira gravação — basta aceitar.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if granted { Text("Concedida").font(.caption).foregroundStyle(.secondary) }
            else { Button("Conceder", action: action).buttonStyle(.bordered) }
        }
    }

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

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gravações").font(.headline)
                    Spacer()
                    Button { NSWorkspace.shared.open(MeetingPaths.audioDir) } label: {
                        Image(systemName: MeetingPaths.isUsingDropbox ? "cloud" : "externaldrive")
                    }
                    .buttonStyle(.borderless)
                    .help("Abrir pasta das reuniões")
                    Button { recorder.loadMeetings() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Pesquisar nas transcrições", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal).padding(.top, 8)

            if recorder.meetings.isEmpty {
                Text("Nenhuma reunião ainda. Conceda as permissões e clique em Gravar reunião.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if visibleMeetings.isEmpty {
                Text("Nenhuma transcrição encontrada.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(visibleMeetings) { item in
                            MeetingCard(item: item, player: player, transcriber: transcriber, searchText: searchQuery) {
                                recorder.rename(item, title: $0)
                            } onDelete: {
                                player.stop()
                                transcriber.clear(id: item.id)
                                recorder.delete(item)
                            } onTrimSaved: {
                                recorder.loadMeetings()
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func elapsed(_ t: TimeInterval) -> String {
        MeetingTrimLogic.label(t)
    }
    static func timestamp(_ t: TimeInterval) -> String {
        MeetingTrimLogic.label(t)
    }
}

// MARK: - Meeting card

@available(macOS 15, *)
struct MeetingCard: View {
    let item: MeetingItem
    @ObservedObject var player: MeetingPlayer
    @ObservedObject var transcriber: MeetingTranscriber
    let searchText: String
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onTrimSaved: () -> Void
    @State private var language = TranscriptionLanguage.current.whisperCode
    @State private var isExpanded = true
    @State private var renameText = ""
    @State private var showingRenameAlert = false
    @State private var showingDeleteAlert = false
    @State private var isTrimming = false
    @State private var trimSelection: MeetingTrimLogic.Selection?
    @State private var trimDuration: Double = 0
    @State private var isExportingTrim = false
    @State private var trimError: String?

    private var isSearching: Bool { !searchText.isEmpty }
    private var effectiveExpanded: Bool { isExpanded || isSearching }
    private var pairURLs: [URL] { [item.micURL, item.systemURL].compactMap { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: effectiveExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(effectiveExpanded ? "Colapsar" : "Expandir")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.headline)
                    Text(item.id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let mic = item.micURL, let system = item.systemURL {
                    Button {
                        player.togglePair(id: item.id, urls: [mic, system])
                    } label: {
                        Label(player.isPlayingPair(id: item.id) ? "Pausar tudo" : "Ouvir tudo",
                              systemImage: player.isPlayingPair(id: item.id) ? "pause.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if isSearching {
                    let count = transcriber.matchCount(id: item.id, query: searchText)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.yellow.opacity(0.22)))
                }
                if !pairURLs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isTrimming.toggle()
                            trimSelection = nil
                            trimError = nil
                            if isTrimming { isExpanded = true }
                        }
                    } label: {
                        Image(systemName: "scissors")
                            .foregroundStyle(isTrimming ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.borderless)
                    .help(isTrimming ? "Sair do modo de recorte" : "Recortar um trecho desta reunião")
                }

                Button {
                    if let u = item.micURL ?? item.systemURL {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    }
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Mostrar no Finder")

                Button {
                    renameText = item.title ?? item.displayTitle
                    showingRenameAlert = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Renomear reunião")

                Button {
                    showingDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Apagar reunião")
            }

            if effectiveExpanded {
                MeetingWaveformLane(label: "Você (microfone)", systemImage: "mic.fill",
                                    url: item.micURL, color: .blue, player: player,
                                    isTrimming: isTrimming, trimSelection: $trimSelection) { progress in
                    player.playPair(id: item.id, urls: pairURLs, from: progress)
                }
                MeetingWaveformLane(label: "Outros (áudio do sistema)", systemImage: "speaker.wave.2.fill",
                                    url: item.systemURL, color: .green, player: player,
                                    isTrimming: isTrimming, trimSelection: $trimSelection) { progress in
                    player.playPair(id: item.id, urls: pairURLs, from: progress)
                }

                if isTrimming {
                    trimControls
                }

                Divider()
                transcriptSection
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .task(id: item.id) {
            let urls = pairURLs
            guard !urls.isEmpty else { return }
            trimDuration = await Task.detached(priority: .utility) {
                urls.map { MeetingWaveformLoader.duration(for: $0) }.max() ?? 0
            }.value
        }
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
    }

    @ViewBuilder
    private var transcriptSection: some View {
        let segments = transcriber.segments(for: item.id)
        let visibleSegments = searchText.isEmpty
            ? segments
            : segments.filter { MeetingSearch.matches($0, query: searchText) }
        let status = transcriber.status(for: item.id)
        let running: Bool = { if case .running = status { return true } else { return false } }()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Transcrição", systemImage: "text.bubble").font(.subheadline.bold())
                Spacer()
                if running, case let .running(msg) = status {
                    ProgressView().controlSize(.small)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                } else if !segments.isEmpty {
                    Button { transcriber.transcribe(item, language: language) } label: {
                        Label("Refazer", systemImage: "arrow.clockwise")
                    }.buttonStyle(.borderless).font(.caption)
                }
            }

            if !segments.isEmpty {
                ForEach(visibleSegments) { MeetingBubble(segment: $0, searchText: searchText) }
            } else if case let .failed(msg) = status {
                Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                transcribeControls
            } else if !running {
                transcribeControls
            }
        }
    }

    // MARK: Trim (recorte)

    @ViewBuilder
    private var trimControls: some View {
        let range = trimSelection.flatMap { MeetingTrimLogic.timeRange($0, duration: trimDuration) }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "scissors").foregroundStyle(.tint)
                if isExportingTrim {
                    ProgressView().controlSize(.small)
                    Text("Exportando recorte...").font(.caption).foregroundStyle(.secondary)
                } else if let range {
                    Text("\(ReunioesView.timestamp(range.start)) - \(ReunioesView.timestamp(range.end))")
                        .font(.caption.monospacedDigit())
                    Text("(\(ReunioesView.timestamp(range.end - range.start)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button {
                        if let sel = trimSelection {
                            player.playPair(id: item.id, urls: pairURLs,
                                            from: sel.startFraction, until: sel.endFraction)
                        }
                    } label: { Label("Ouvir seleção", systemImage: "play.circle") }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button {
                        saveTrim()
                    } label: { Label("Salvar recorte", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Text("Arraste sobre a waveform para selecionar o trecho a recortar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isTrimming = false
                        trimSelection = nil
                        trimError = nil
                    }
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(isExportingTrim)
            }
            if let trimError {
                Label(trimError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
    }

    @MainActor
    private func saveTrim() {
        guard let selection = trimSelection, !isExportingTrim else { return }
        isExportingTrim = true
        trimError = nil
        player.stop()
        Task {
            do {
                let newId = try await MeetingTrimmer.export(item: item, selection: selection)
                NSLog("DictationApp: [TRIM] recorte salvo: %@", newId)
                isExportingTrim = false
                withAnimation(.easeInOut(duration: 0.15)) {
                    isTrimming = false
                    trimSelection = nil
                }
                onTrimSaved()
            } catch {
                isExportingTrim = false
                trimError = error.localizedDescription
            }
        }
    }

    private var transcribeControls: some View {
        HStack(spacing: 10) {
            Button { transcriber.transcribe(item, language: language) } label: {
                Label("Transcrever", systemImage: "waveform.and.mic")
            }.buttonStyle(.borderedProminent)
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

// MARK: - Waveform lane

@available(macOS 15, *)
struct MeetingWaveformLane: View {
    let label: String
    let systemImage: String
    let url: URL?
    let color: Color
    @ObservedObject var player: MeetingPlayer
    var isTrimming = false
    @Binding var trimSelection: MeetingTrimLogic.Selection?
    let onSeek: (Double) -> Void
    @State private var peaks: [Float] = []
    @State private var loading = false
    @State private var duration: Double = 0

    private var isPlaying: Bool {
        guard let url else { return false }
        return player.isPlaying(url)
    }

    private var timeText: String? {
        if isPlaying, player.totalSeconds > 0 {
            return "\(ReunioesView.timestamp(player.currentSeconds)) / \(ReunioesView.timestamp(player.totalSeconds))"
        }
        guard duration > 0 else { return nil }
        return ReunioesView.timestamp(duration)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { if let url { player.toggle(url) } } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(url == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
            }
            .buttonStyle(.plain).disabled(url == nil)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(label, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let timeText {
                        Text(timeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isPlaying ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05))
                    if !peaks.isEmpty {
                        MeetingWaveformView(peaks: peaks, color: color, progress: url.map(player.progress(for:)) ?? 0)
                            .padding(.horizontal, 4)
                    } else {
                        Text(url == nil ? "sem áudio" : (loading ? "carregando..." : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if isTrimming, let sel = trimSelection {
                        GeometryReader { proxy in
                            let x0 = CGFloat(sel.startFraction) * proxy.size.width
                            let x1 = CGFloat(sel.endFraction) * proxy.size.width
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.22))
                                .frame(width: max(1, x1 - x0))
                                .offset(x: x0)
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: 1.5)
                                .offset(x: x0)
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: 1.5)
                                .offset(x: x1)
                        }
                        .allowsHitTesting(false)
                    }
                    if url != nil {
                        GeometryReader { proxy in
                            if isTrimming {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(trimGesture(width: proxy.size.width))
                            } else {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(seekGesture(width: proxy.size.width))
                            }
                        }
                    }
                }
                .frame(height: 44)
                .help(isTrimming
                      ? "Arraste para selecionar o trecho a recortar"
                      : "Clique na waveform para ouvir as duas faixas a partir deste ponto")
            }
        }
        .task(id: url) {
            guard let url else { return }
            loading = true
            let computed = await Task.detached(priority: .utility) {
                (peaks: MeetingWaveformLoader.peaks(for: url, buckets: 600),
                 duration: MeetingWaveformLoader.duration(for: url))
            }.value
            peaks = computed.peaks
            duration = computed.duration
            loading = false
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onEnded { value in
            guard width > 0 else { return }
            let progress = Double(min(1, max(0, value.location.x / width)))
            onSeek(progress)
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
}

@available(macOS 15, *)
private struct MeetingLiveTrackMeter: View {
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
                        .foregroundStyle(segment.isMe ? .blue : .green)
                    Text(ReunioesView.timestamp(segment.start)).font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text).font(.body)
                    .multilineTextAlignment(segment.isMe ? .leading : .trailing)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(searchText.isEmpty ? (segment.isMe ? Color.blue : Color.green).opacity(0.12) : Color.yellow.opacity(0.22)))
            }
            if segment.isMe { Spacer(minLength: 36) }
        }
    }
}
