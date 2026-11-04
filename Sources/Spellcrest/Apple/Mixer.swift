#if canImport(AVFoundation)
import AVFoundation

/// A sound, read in full.
typealias SoundData = AVAudioPCMBuffer

/// The music's player.
typealias MusicPlayer = AVAudioPlayer

extension AVAudioPlayer: MusicPlaying {}

/// A player for the track in the file at `url`.
func musicPlayer(_ url: URL) throws -> MusicPlayer {
    #if os(iOS)
    _ = audioSession
    #endif
    return try AVAudioPlayer(contentsOf: url)
}

/// Where sound effects play: an `AVAudioEngine`, its main mixer adding up voices, each a player kept for a format of
/// sound and started once, the usual format's as the game starts and others' as they're first needed. A sound is a
/// buffer scheduled on one, with no file read and no audio queue started, which an `AVAudioPlayer` for each sound took
/// about 10 ms of the main thread to do.
@MainActor final class Mixer: SoundOutput {
    let engine: AVAudioEngine
    /// The voices for each format of sound.
    var voices: [(format: AVAudioFormat, voices: [Strip])] = []
    static let most = 8 // of a format at once
    /// `Sound.volume`: the main mixer's, which adds up the voices, so it reaches those playing.
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    /// A voice: a player, a varispeed for a sound's pitch, and a mixer of its own on the main mixer for its volume and
    /// pan, which a player's own `volume` and `pan` don't reach through an effect.
    struct Strip {
        let player: AVAudioPlayerNode
        let speed: AVAudioUnitVarispeed
        let fader: AVAudioMixerNode
        var until = 0.0 // when it's free, in `CACurrentMediaTime()`'s seconds
        var sound = "" // the name of the sound on it, for `Sound.stop(_:)`
    }

    /// The game's, playing to the output; a test's, rendering offline.
    init(engine: AVAudioEngine = AVAudioEngine()) { self.engine = engine }

    /// Plays `buffer`, the sound `name`, at `volume`, `pitch` times as fast and high, and panned by `pan`, on a voice for
    /// its format: a free one, a new one, or the one nearest its end.
    func play(_ buffer: AVAudioPCMBuffer, name: String = "", volume: Float, pitch: Float = 1, pan: Float = 0) {
        guard running() else { return } // with no output to play to, as in a test without audio, it's skipped
        let now = CACurrentMediaTime()
        let group = voices.firstIndex { $0.format == buffer.format } ?? {
            voices.append((buffer.format, []))
            return voices.count - 1
        }()
        let i: Int
        switch voice(voices[group].voices.map(\.until), now: now, most: Mixer.most) {
        case let .free(free): i = free
        case let .cut(cut): i = cut
        case .new:
            voices[group].voices.append(strip(for: buffer.format))
            i = voices[group].voices.count - 1
        }
        let strip = voices[group].voices[i]
        (strip.fader.volume, strip.fader.pan, strip.speed.rate) = (volume, pan, pitch)
        strip.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        voices[group].voices[i].until = now + Double(buffer.frameLength) / buffer.format.sampleRate / Double(pitch)
        voices[group].voices[i].sound = name
    }

    /// Stops every voice still playing the sound `name`, leaving each ready for the next sound.
    func stop(_ name: String) {
        let now = CACurrentMediaTime()
        for group in voices.indices {
            for i in voices[group].voices.indices where voices[group].voices[i].sound == name && voices[group].voices[i].until > now {
                let player = voices[group].voices[i].player
                player.stop() // which forgets what it had to play, and stops it
                if engine.isRunning { player.play() }
                voices[group].voices[i].until = 0
            }
        }
    }

    /// Starts the engine with voices for the usual format of sound, two channels at 44.1 kHz, which a mono one is read
    /// into, so the first sounds needn't wait for them: starting took about 110 ms on a Mac and 25 on an iPhone
    /// simulator, and each voice a few more. The loop does it as the game starts, while its first frames take their
    /// time anyway; other formats get theirs as they first play.
    func prepare() {
        guard let usual = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2), !voices.contains(where: { $0.format == usual }) else { return }
        // Made before it starts, so they're in its graph from the first sound: the engine takes one made while it runs
        // in its own time, a few milliseconds. Eight strips of three nodes started in 45 to 48 ms on the M6 Mac, where
        // eight players alone took 100 to 140.
        voices.append((usual, (0..<Mixer.most).map { _ in strip(for: usual) }))
        _ = running()
    }

    /// A voice for sounds of `format`, on the main mixer, which takes any rate and channels, playing if the engine is.
    func strip(for format: AVAudioFormat) -> Strip {
        let strip = Strip(player: AVAudioPlayerNode(), speed: AVAudioUnitVarispeed(), fader: AVAudioMixerNode())
        for node in [strip.player, strip.speed, strip.fader] { engine.attach(node) }
        engine.connect(strip.player, to: strip.speed, format: format)
        engine.connect(strip.speed, to: strip.fader, format: format)
        engine.connect(strip.fader, to: engine.mainMixerNode, format: format)
        if engine.isRunning { strip.player.play() } // which a stopped engine refuses; `running` plays them once it's started
        return strip
    }

    /// Whether the engine runs, starting it and its voices again if it doesn't: at the first sound, and after an
    /// interruption on iOS or a change of output stopped it.
    func running() -> Bool {
        if engine.isRunning { return true }
        #if os(iOS)
        _ = audioSession
        #endif
        _ = engine.mainMixerNode // connects the mixer to the output, which starting wants
        do { try engine.start() } catch { return false }
        for group in voices { for voice in group.voices { voice.player.play() } }
        return true
    }
}

/// The sound in the file at `url`, read in full and in two channels (`stereo`); nil when it's longer than `longest`
/// seconds, or too long to hold.
func readSound(_ url: URL, longest: Double = .infinity) throws -> AVAudioPCMBuffer? {
    let file = try AVAudioFile(forReading: url)
    guard Double(file.length) <= longest * file.processingFormat.sampleRate,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, file.length))) else { return nil }
    try file.read(into: buffer)
    return stereo(buffer)
}

/// `buffer` in two channels, a mono one's in both, as an `AVAudioPlayer` plays it: the mixer would pan one channel to
/// the middle, 3 dB down.
func stereo(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard buffer.format.channelCount == 1, let mono = buffer.floatChannelData,
          let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2),
          let both = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, buffer.frameLength)), let into = both.floatChannelData else { return buffer }
    both.frameLength = buffer.frameLength
    for channel in 0..<2 { into[channel].update(from: mono[0], count: Int(buffer.frameLength)) }
    return both
}

#if os(iOS)
/// Sounds mix with other apps' audio, and the silent switch mutes them. Set before the first sound or track plays.
let audioSession: Void = { try? AVAudioSession.sharedInstance().setCategory(.ambient) }()
#endif
#endif
