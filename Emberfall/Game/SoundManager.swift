import AVFoundation

/// Tiny synthesized SFX (no audio assets): build clink, march horn,
/// victory chime, coin tick. Silent by default-safe: respects the mute
/// switch via the ambient audio session category.
final class SoundManager {
    static let shared = SoundManager()
    private var engine: AVAudioEngine?
    private init() {}

    enum SFX { case build, march, victory, defeat, coin, summon }

    func play(_ sfx: SFX) {
        guard UserDefaults.standard.bool(forKey: "emberfall.sound") != false else { return }
        let freqs: [Double]
        let dur: Double
        switch sfx {
        case .build: freqs = [660, 880]; dur = 0.09
        case .march: freqs = [392, 523, 659]; dur = 0.12
        case .victory: freqs = [523, 659, 784, 1047]; dur = 0.14
        case .defeat: freqs = [330, 262, 196]; dur = 0.16
        case .coin: freqs = [1319, 1760]; dur = 0.06
        case .summon: freqs = [440, 554, 659, 880]; dur = 0.12
        }
        playTones(freqs, dur: dur)
    }

    private func playTones(_ freqs: [Double], dur: Double) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        } catch { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        let sampleRate = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * dur * Double(freqs.count))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: player.outputFormat(forBus: 0), frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        var frame = 0
        for f in freqs {
            let n = Int(sampleRate * dur)
            for i in 0..<n where frame + i < Int(frameCount) {
                let t = Double(i) / sampleRate
                let env = 1.0 - Double(i) / Double(n)
                channels[0][frame + i] = Float(sin(2 * .pi * f * t) * env * 0.25)
            }
            frame += n
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer) {
                engine.stop()
            }
            player.play()
            self.engine = engine
        } catch { /* silent failure: never break the game for a blip */ }
    }
}
