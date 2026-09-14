import AVFoundation
import Foundation

enum VoiceRecorderError: Error {
    case conversionFailed
}

/// Records a short WAV sample to a temp file for voice cloning
/// (`PocketTtsManager.cloneVoice(from:)` expects a WAV file, any sample
/// rate — it resamples internally), and plays it back for preview before
/// the user commits to cloning it. Also accepts an imported audio file
/// (any format `AVAudioFile` can read) and transcodes it to the same temp
/// WAV location, so the rest of the app treats a recording and an import
/// identically. One temp file, overwritten by either path — nothing here
/// persists past the current session.
final class VoiceRecorderService {
    private var recorder: AVAudioRecorder?
    private var previewPlayer: AVAudioPlayer?
    private var previewDelegate: AudioPlaybackDelegate?

    private lazy var recordingURL: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-clone-sample.wav")

    var currentRecordingURL: URL? {
        FileManager.default.fileExists(atPath: recordingURL.path) ? recordingURL : nil
    }

    func startRecording() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        recorder.record()
        self.recorder = recorder
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
    }

    func discardRecording() {
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: recordingURL)
    }

    /// Reads an arbitrary picked audio file (`.fileImporter` hands back a
    /// security-scoped URL) and transcodes it in one shot — these clips
    /// are short (≤30s), so loading the whole thing into memory rather
    /// than a chunked streaming conversion keeps this simple.
    func importAudioFile(from sourceURL: URL) throws {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let sourceFile = try AVAudioFile(forReading: sourceURL)
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat, frameCapacity: AVAudioFrameCount(sourceFile.length))
        else { throw VoiceRecorderError.conversionFailed }
        try sourceFile.read(into: inputBuffer)

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true)!
        let outputFrameCapacity =
            AVAudioFrameCount(
                Double(inputBuffer.frameLength) * outputFormat.sampleRate
                    / sourceFile.processingFormat.sampleRate) + 1024
        guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: outputFormat),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity)
        else { throw VoiceRecorderError.conversionFailed }

        var conversionError: NSError?
        var didProvideInput = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }

        let outputFile = try AVAudioFile(
            forWriting: recordingURL, settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        try outputFile.write(from: outputBuffer)
    }

    func playPreview(onFinish: @escaping () -> Void) {
        guard let url = currentRecordingURL else {
            onFinish()
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AudioPlaybackDelegate(onFinish: onFinish)
            player.delegate = delegate
            previewDelegate = delegate
            previewPlayer = player
            player.play()
        } catch {
            onFinish()
        }
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewDelegate = nil
    }
}
