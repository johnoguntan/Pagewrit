import Foundation
import AVFoundation

/// Wraps AVSpeechSynthesizer for the EPUB reader's read-aloud feature.
/// Reports the character range being spoken (in the full text that was
/// passed in) so the reader can highlight the current word, and supports
/// pause, resume and a speed multiplier.
@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var rate: Double = 1.0

    /// Called with (location, length) in UTF-16 units of the full text.
    var onProgress: ((Int, Int) -> Void)?
    /// Called when speech ends or is stopped.
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var fullText: NSString = ""
    private var baseOffset = 0
    private var lastAbsolute = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, from start: Int = 0) {
        stop()
        fullText = text as NSString
        let begin = min(max(start, 0), fullText.length)
        speakRemaining(from: begin)
    }

    private func speakRemaining(from begin: Int) {
        let remainder = fullText.substring(from: begin)
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: remainder)
        let scaled = Double(AVSpeechUtteranceDefaultSpeechRate) * rate
        utterance.rate = Float(min(max(scaled, Double(AVSpeechUtteranceMinimumSpeechRate)),
                                    Double(AVSpeechUtteranceMaximumSpeechRate)))
        baseOffset = begin
        lastAbsolute = begin
        current = utterance
        isSpeaking = true
        isPaused = false
        synthesizer.speak(utterance)
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        guard isSpeaking else { return }
        let resumeAt = lastAbsolute
        detach()
        speakRemaining(from: resumeAt)
    }

    func togglePause() {
        guard isSpeaking else { return }
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        let wasSpeaking = isSpeaking
        detach()
        isSpeaking = false
        isPaused = false
        if wasSpeaking { onFinish?() }
    }

    /// Cancels the utterance without reporting a finish.
    private func detach() {
        current = nil
        // Our own flags, not the synthesizer's: asking it whether it is
        // speaking waits on its lower priority audio thread, which froze the
        // main thread for a moment (Xcode's Hang Risk warning).
        if isSpeaking || isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current) == id else { return }
            let absolute = self.baseOffset + characterRange.location
            self.lastAbsolute = absolute
            self.onProgress?(absolute, characterRange.length)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current) == id else { return }
            self.current = nil
            self.isSpeaking = false
            self.isPaused = false
            self.onFinish?()
        }
    }
}
