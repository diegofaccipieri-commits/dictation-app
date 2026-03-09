import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: DictationViewModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                if viewModel.isModelLoading {
                    ProgressView().scaleEffect(0.6)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(statusColor)
            }
            .animation(.easeInOut, value: viewModel.state)

            ScrollView {
                Text(viewModel.transcribedText.isEmpty ? "Transcription will appear here..." : viewModel.transcribedText)
                    .font(.body)
                    .foregroundColor(viewModel.transcribedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 100)
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)

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

            Text("Global shortcut: ⌘⇧Space")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 360, height: 260)
    }

    private var statusText: String {
        if viewModel.isModelLoading { return "Loading model..." }
        if !viewModel.isModelLoaded { return "Model unavailable" }
        switch viewModel.state {
        case .idle: return "Ready"
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
