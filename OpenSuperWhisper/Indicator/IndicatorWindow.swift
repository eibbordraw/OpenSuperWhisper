import Cocoa
import SwiftUI

enum RecordingState {
    case idle
    case recording
    case decoding
    case busy
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false
    @Published var audioLevels: [Float] = Array(repeating: 0.0, count: 40)
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var audioLevelTimer: Timer?
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    
    init() {
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage() {
        state = .busy
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }
    
    func startRecording() {
        if isTranscriptionBusy {
            showBusyMessage()
            return
        }
        
        state = .recording
        startBlinking()
        startAudioLevelSampling()
        recorder.startRecording()
    }
    
    private func startAudioLevelSampling() {
        audioLevels = Array(repeating: 0.0, count: 40)
        audioLevelTimer?.invalidate()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.sampleAudioLevel()
            }
        }
    }
    
    private func stopAudioLevelSampling() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }
    
    private func sampleAudioLevel() {
        let level = recorder.audioLevel
        audioLevels.removeFirst()
        audioLevels.append(level)
    }
    
    func startDecoding() {
        stopBlinking()
        stopAudioLevelSampling()
        
        if isTranscriptionBusy {
            recorder.cancelRecording()
            showBusyMessage()
            return
        }
        
        state = .decoding
        
        if let tempURL = recorder.stopRecording() {
            Task { [weak self] in
                guard let self = self else { return }
                
                do {
                    print("start decoding...")
                    let text = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    
                    // Create a new Recording instance
                    let timestamp = Date()
                    let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                    let recordingId = UUID()
                    let finalURL = Recording(
                        id: recordingId,
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: text,
                        duration: 0,
                        status: .completed,
                        progress: 1.0,
                        sourceFileURL: nil
                    ).url
                    
                    // Move the temporary recording to final location
                    try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)
                    
                    // Save the recording to store
                    await MainActor.run {
                        self.recordingStore.addRecording(Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: 0,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        ))
                    }
                    
                    insertTextUsingPasteboard(text)
                    print("Transcription result: \(text)")
                } catch {
                    print("Error transcribing audio: \(error)")
                    try? FileManager.default.removeItem(at: tempURL)
                }
                
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        } else {
            
            print("!!! Not found record url !!!")
            
            Task {
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        }
    }
    
    func insertTextUsingPasteboard(_ text: String) {
        ClipboardUtil.insertTextUsingPasteboard(text)
    }
    
    private func startBlinking() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopAudioLevelSampling()
        recorder.cancelRecording()
    }

    @MainActor
    func hideWithAnimation() async {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            self.isVisible = false
        }
        // Wait for animation to complete
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

struct AudioWaveformView: View {
    let levels: [Float]
    let barCount: Int = 40
    let barSpacing: CGFloat = 4
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let level = index < levels.count ? CGFloat(levels[index]) : 0
                    // Minimum height so bars are always visible, max based on container
                    let minHeight: CGFloat = 4
                    let maxHeight = geometry.size.height
                    let barHeight = minHeight + (maxHeight - minHeight) * level
                    
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 3, height: barHeight)
                        .animation(.easeOut(duration: 0.05), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool
    let size: CGFloat
    
    init(isBlinking: Bool, size: CGFloat = 8) {
        self.isBlinking = isBlinking
        self.size = size
    }
    
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .shadow(color: .red.opacity(0.5), radius: size / 2)
            .opacity(isBlinking ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

private let funnyProcessingPhrases = [
    "Crunching words...",
    "Decoding vibes...",
    "Cooking up text...",
    "Doing the thing...",
    "Brain go brrr...",
    "Yapping to text...",
    "Translating mumbles...",
    "Working on it...",
    "Figuring it out...",
    "Spinning gears...",
    "Summoning words...",
    "Extracting wisdom...",
    "Processing noises...",
    "Making sense...",
    "Almost there...",
]

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var processingPhrase: String = funnyProcessingPhrases.randomElement() ?? "Processing..."
    
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }
    
    var body: some View {
        let rect = RoundedRectangle(cornerRadius: 32)
        
        VStack(spacing: 16) {
            switch viewModel.state {
            case .recording:
                AudioWaveformView(levels: viewModel.audioLevels)
                    .frame(height: 80)
                    .padding(.horizontal, 8)
                
            case .decoding:
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .frame(width: 32)
                    
                    Text(processingPhrase)
                        .font(.system(size: 24, weight: .semibold))
                }
                
            case .busy:
                HStack(spacing: 12) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                        .frame(width: 32)
                    
                    Text("Processing...")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.orange)
                }
                
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 380, height: viewModel.state == .recording ? 120 : 80)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.regularMaterial)
                }
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        }
        .clipShape(rect)
        .scaleEffect(viewModel.isVisible ? 1 : 0.5)
        .offset(y: viewModel.isVisible ? 0 : 30)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        .onAppear {
            viewModel.isVisible = true
        }
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.startDecoding()
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
