import AVFoundation
import Metal
import Testing
@testable import Spellcrest

/// A folder whose Assets hold a.wav and b.m4a, a tenth of a second of silence each, made the current directory.
@MainActor func silentTracks() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID())")
    try FileManager.default.createDirectory(at: folder.appending(path: "Assets"), withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(folder.path) // games load Assets/ relative to here
    for (file, format) in [("a.wav", kAudioFormatLinearPCM), ("b.m4a", kAudioFormatMPEG4AAC)] {
        let audio = try AVAudioFile(forWriting: folder.appending(path: "Assets/\(file)"),
                                    settings: [AVFormatIDKey: format, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4410))
        silence.frameLength = 4410
        try audio.write(from: silence)
    }
    return folder
}

/// The music's player, once the players have done what they were asked so far, on their queue.
@MainActor func musicPlayer() -> AVAudioPlayer? {
    Music.queue.sync {}
    return Music.player
}

@MainActor @Test func musicKeepsItsTrackSwitchesStopsPausesWithTheGameAndStartsOverWhenTheFileChanges() throws {
    _ = try silentTracks()
    Music.volume = 0
    defer { Music.stop(); Music.volume = 1 }

    Music.play("a")
    let a = try #require(musicPlayer())
    Music.play("a")
    #expect(musicPlayer() === a && a.isPlaying)
    Music.play("b")
    let b = try #require(musicPlayer())
    #expect(b !== a && !a.isPlaying && b.url?.lastPathComponent == "b.m4a")

    Music.restartIfChanged()
    #expect(musicPlayer() === b) // the file didn't change
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: "Assets/b.m4a")
    Music.restartIfChanged()
    #expect(musicPlayer() !== b && Music.track?.name == "b" && Music.player?.isPlaying == true)

    // Pausing the game holds the track's place, and one that starts or restarts meanwhile waits for the resume.
    let loop = Loop(resolution: Size(8, 8), gpu: try #require(systemGPU()))
    let playing = try #require(musicPlayer())
    loop.paused = true
    #expect(musicPlayer() === playing && !playing.isPlaying)
    loop.paused = false
    #expect(musicPlayer() === playing && playing.isPlaying) // resumed, not started over
    loop.paused = true
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 20)], ofItemAtPath: "Assets/b.m4a")
    Music.restartIfChanged()
    #expect(musicPlayer() !== playing && Music.player?.isPlaying == false)
    Music.play("a")
    #expect(Music.track?.name == "a" && musicPlayer()?.isPlaying == false)
    loop.paused = false
    #expect(musicPlayer()?.isPlaying == true)

    Music.stop()
    #expect(musicPlayer() == nil && Music.track == nil)

}

@MainActor @Test func musicFadesFromOneTrackIntoTheNext() async throws {
    _ = try silentTracks()
    Music.volume = 0
    defer { Music.stop(); Music.volume = 1 }
    Music.play("a")
    let a = try #require(musicPlayer())
    Music.play("b", fade: 0.2)
    #expect(Music.track?.name == "b" && musicPlayer() !== a && a.isPlaying) // still on while it fades out
    // Then it stops, on the players' queue once the fade is over. (When the main actor stopped it, the tests beside
    // this one held it up to a second, so a fixed half second's sleep ended first about one run in five.)
    let start = ContinuousClock.now
    while a.isPlaying, ContinuousClock.now - start < .seconds(10) { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!a.isPlaying)
}

@MainActor @Test func aGamesOwnPauseHoldsTheMusicApartFromTheEditorsAndStopsFadeIt() async throws {
    let folder = try silentTracks()
    Music.volume = 0
    defer { Music.resume(); Music.stop(); Music.volume = 1 }
    let loop = Loop(resolution: Size(8, 8), gpu: try #require(systemGPU()))
    Music.play("a")
    let a = try #require(musicPlayer())
    Music.pause()
    #expect(musicPlayer() === a && !a.isPlaying)
    loop.paused = true
    loop.paused = false // the editor's resume leaves the game's pause holding it
    #expect(!a.isPlaying)
    Music.resume()
    #expect(musicPlayer() === a && a.isPlaying) // on from where it was, not started over
    Music.volume = 2
    #expect(Music.volume == 1)
    Music.volume = -1
    #expect(Music.volume == 0)

    // Stopped with a fade, it plays on until it's silent, then stops.
    Music.stop(fade: 0.2)
    #expect(Music.track == nil && musicPlayer() == nil && a.isPlaying)
    let start = ContinuousClock.now
    while a.isPlaying, ContinuousClock.now - start < .seconds(10) { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!a.isPlaying)

    // A track that isn't there stops the music, and plays once its file is.
    FileManager.default.changeCurrentDirectoryPath(folder.path) // which tests beside this one changed while it waited
    Music.play("b")
    Music.play("c")
    #expect(Music.track?.name == "c" && musicPlayer() == nil)
    try FileManager.default.copyItem(atPath: "Assets/a.wav", toPath: "Assets/c.wav")
    Music.restartIfChanged()
    #expect(musicPlayer()?.url?.lastPathComponent == "c.wav")
}
