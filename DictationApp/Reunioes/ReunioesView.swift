import SwiftUI
import AppKit

@available(macOS 15, *)
struct ReunioesView: View {
    @StateObject private var recorder = MeetingRecorder()
    @StateObject private var player = MeetingPlayer()
    @StateObject private var transcriber = MeetingTranscriber()

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
                }
                Spacer()
            }
            if let err = recorder.lastError {
                Text(err).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissões").font(.headline)
            permissionRow("Microfone", granted: recorder.permissions.microphone) { recorder.requestMicrophone() }
            permissionRow("Gravação de tela / áudio do sistema", granted: recorder.permissions.screenRecording) { recorder.requestScreenRecording() }
            Text("A permissão de gravação de tela costuma exigir reabrir o app depois de concedida.")
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

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gravações").font(.headline)
                Spacer()
                Button { recorder.loadMeetings() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal).padding(.top, 8)

            if recorder.meetings.isEmpty {
                Text("Nenhuma reunião ainda. Conceda as permissões e clique em Gravar reunião.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(recorder.meetings) { item in
                            MeetingCard(item: item, player: player, transcriber: transcriber)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%02d:%02d", s / 60, s % 60)
    }
    static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t.rounded()); return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Meeting card

@available(macOS 15, *)
struct MeetingCard: View {
    let item: MeetingItem
    @ObservedObject var player: MeetingPlayer
    @ObservedObject var transcriber: MeetingTranscriber
    @State private var language = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.headline)
                    Text(item.id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let u = item.micURL ?? item.systemURL {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    }
                } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Mostrar no Finder")
            }

            MeetingWaveformLane(label: "Você (microfone)", systemImage: "mic.fill",
                                url: item.micURL, color: .blue, player: player)
            MeetingWaveformLane(label: "Outros (áudio do sistema)", systemImage: "speaker.wave.2.fill",
                                url: item.systemURL, color: .green, player: player)

            Divider()
            transcriptSection
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private var transcriptSection: some View {
        let segments = transcriber.segments(for: item.id)
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
                ForEach(segments) { MeetingBubble(segment: $0) }
            } else if case let .failed(msg) = status {
                Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                transcribeControls
            } else if !running {
                transcribeControls
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
            }
            .pickerStyle(.segmented).frame(width: 170)
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
    @State private var peaks: [Float] = []
    @State private var loading = false

    private var isPlaying: Bool { url != nil && player.playingURL == url }

    var body: some View {
        HStack(spacing: 10) {
            Button { if let url { player.toggle(url) } } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(url == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
            }
            .buttonStyle(.plain).disabled(url == nil)

            VStack(alignment: .leading, spacing: 3) {
                Label(label, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05))
                    if !peaks.isEmpty {
                        MeetingWaveformView(peaks: peaks, color: color, progress: isPlaying ? player.progress : 0)
                            .padding(.horizontal, 4)
                    } else {
                        Text(url == nil ? "sem áudio" : (loading ? "carregando..." : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 44)
            }
        }
        .task(id: url) {
            guard let url else { return }
            loading = true
            let computed = await Task.detached(priority: .utility) {
                MeetingWaveformLoader.peaks(for: url, buckets: 600)
            }.value
            peaks = computed
            loading = false
        }
    }
}

// MARK: - Transcript bubble

@available(macOS 15, *)
struct MeetingBubble: View {
    let segment: MeetingSegment

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
                        .fill((segment.isMe ? Color.blue : Color.green).opacity(0.12)))
            }
            if segment.isMe { Spacer(minLength: 36) }
        }
    }
}
