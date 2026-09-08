import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 A source that cannot serve bytes is not a file that has ended.

 `AudioFileReader` talks to Core Audio through `AudioFile_ReadProc`, and that
 callback answers with an `OSStatus`. It used to answer *every* failure of the
 underlying source with `kAudioFileEndOfFileError`:

     } catch {
       actualCount.pointee = 0
       // A cancelled read is not a corrupt file...
       return kAudioFileEndOfFileError
     }

 The reasoning holds for a cancelled read — a seek abandons the read in flight
 on purpose, and unwinding as end-of-file is cleaner than raising a decode
 error nobody can distinguish from a broken track. It does not hold for a
 network that stalled, and the two arrived through the same `catch`.

 The consequence reached a listener as songs cutting off part-way through, at a
 different point every time, over the network and never on downloaded files.
 Nothing threw, nothing failed, no error was reported anywhere: the engine was
 told the file had ended, believed it, and advanced to the next track. Fixes
 above this layer could not see it, because the failure had already been
 relabelled as success before it left this callback.
 */
final class AudioFileReaderFailureTests: XCTestCase {

  /// Serves a real file up to `servableBytes`, then behaves as told.
  private final class FlakySource: ByteSource {
    enum Failure { case throwsFetchFailed, throwsCancelled, returnsEmpty }

    private let data: Data
    private let servableBytes: Int64
    private let failure: Failure

    /**
     Bytes at the end that are served regardless of the stall.

     Models `CachedByteSource.prefetchTail`, which the factory calls for
     MP4-family files: `moov` lives at the tail unless the file was written
     faststart, and the parser reads it before anything else. Without this an
     ALAC or AAC fixture cannot be opened at all when the source is only
     serving its first quarter — which is a fact about the test, not about the
     reader, and it hid the rest of the matrix behind an open failure.
     */
    private let servableTail: Int64

    init(data: Data, servableBytes: Int64, failure: Failure, servableTail: Int64 = 0) {
      self.data = data
      self.servableBytes = servableBytes
      self.failure = failure
      self.servableTail = servableTail
    }

    // The true length, always. The parser is told the file's real size even
    // when the source cannot currently serve all of it — that is the whole
    // design, and it is why "cannot serve" must not read as "finished".
    func totalBytes() throws -> Int64 { Int64(data.count) }

    /**
     Whether the stall has started yet.

     Off while a reader is being opened, because opening is not where the
     fault lives and refusing reads there tests the wrong thing: an MP4-family
     file cannot be opened at all from a quarter-served source — `moov` is at
     the tail and the sample tables are spread through the file — so every
     assertion about ALAC and AAC was hidden behind an open failure that said
     nothing about stalls. A real stall arrives *during* playback, on a
     connection that was working when the track started.
     */
    var stalled = true

    func read(offset: Int64, count: Int) throws -> Data {
      if offset >= Int64(data.count) { return Data() }   // genuinely the end
      let intoTheTail = offset >= Int64(data.count) - servableTail
      if !stalled || offset + Int64(count) <= servableBytes
          || (servableTail > 0 && intoTheTail) {
        let end = min(Int(offset) + count, data.count)
        return data.subdata(in: Int(offset)..<end)
      }
      switch failure {
      case .throwsFetchFailed: throw ByteSourceError.fetchFailed("stalled")
      case .throwsCancelled: throw ByteSourceError.cancelled
      case .returnsEmpty: return Data()
      }
    }

    func availableBytes(from offset: Int64) -> Int64 {
      max(0, servableBytes - offset)
    }
    func cancel() {}
    func resume() {}
  }

  /**
   A source that stalls for a while and then comes back.

   The shape of a real network drop: reads fail for a few seconds and then
   succeed again, which is the case `TrackPlayback`'s retry ladder exists for.
   Everything above it is built on the assumption that a reader survives a
   stall — the ladder retries the *same* reader, so if the reader cannot
   recover, thirty-three seconds of retrying can only end in the track dying.
   */
  private final class RecoveringSource: ByteSource {
    private let data: Data
    private let stallAfter: Int64
    private let failuresBeforeRecovery: Int
    /// See `FlakySource.servableTail` — the prefetched `moov`, without which
    /// an MP4-family file cannot be opened at all.
    private let servableTail: Int64
    private(set) var failuresServed = 0

    init(data: Data, stallAfter: Int64, failuresBeforeRecovery: Int, servableTail: Int64 = 0) {
      self.data = data
      self.stallAfter = stallAfter
      self.failuresBeforeRecovery = failuresBeforeRecovery
      self.servableTail = servableTail
    }

    func totalBytes() throws -> Int64 { Int64(data.count) }

    /// See `FlakySource.stalled` — open on a working connection, stall during
    /// playback, because that is both the real shape and the only one an
    /// MP4-family file can be opened under.
    var stalled = true

    func read(offset: Int64, count: Int) throws -> Data {
      if offset >= Int64(data.count) { return Data() }
      if !stalled || (servableTail > 0 && offset >= Int64(data.count) - servableTail) {
        let end = min(Int(offset) + count, data.count)
        return data.subdata(in: Int(offset)..<end)
      }
      let beyondTheStall = offset + Int64(count) > stallAfter
      if beyondTheStall && failuresServed < failuresBeforeRecovery {
        failuresServed += 1
        throw ByteSourceError.fetchFailed("stalled")
      }
      let end = min(Int(offset) + count, data.count)
      return data.subdata(in: Int(offset)..<end)
    }

    func availableBytes(from offset: Int64) -> Int64 { max(0, Int64(data.count) - offset) }
    func cancel() {}
    func resume() {}
  }

  /// Reads until it throws, returns nil, or runs out of patience.
  private enum Outcome { case threw, endedCleanly, keptGoing }

  private func drain(_ reader: AudioFileReader) -> Outcome {
    for _ in 0..<4_000 {
      do {
        guard let buffer = try reader.read(frames: 4096), buffer.frameLength > 0 else {
          return .endedCleanly
        }
      } catch {
        return .threw
      }
    }
    return .keptGoing
  }

  private func fixtureData() throws -> Data {
    try EncodedFixture.wav(seconds: 5).data
  }

  /**
   The same tone as FLAC.

   WAV is the wrong format to prove this with on its own. Its parser is a
   header and a block of samples, so a read that fails has nowhere to go but
   up. FLAC is a real decoder with its own framing, and the reported fault is
   lossless over cellular — so the format the listener actually hit needs its
   own test rather than the assumption that one parser behaves like another.
   */
  private static var encodedFixtures: [String: Data] = [:]

  private func flacData() throws -> Data {
    try encoded(format: kAudioFormatFLAC, ext: "flac")
  }

  /**
   The same tone in whichever container is asked for.

   Parameterised because the lesson of this file is that one decoder's
   behaviour predicts nothing about another's: WAV propagated a failed read
   where FLAC swallowed it, and WAV carried on after a stall where FLAC
   latched. Anything asserted about one format here is asserted about all of
   them, or it is not really known.
   */
  private func encoded(format: AudioFormatID, ext: String) throws -> Data {
    // Keyed on the format as well as the extension: ALAC and AAC are both
    // `.m4a`, and caching on the container alone would hand one the other.
    let key = "\(format)-\(ext)"
    if let cached = Self.encodedFixtures[key] { return cached }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-engine-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("failure-fixture-\(format).\(ext)")
    try? FileManager.default.removeItem(at: url)

    let sampleRate = 44_100.0
    let settings: [String: Any] = [
      AVFormatIDKey: format,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16,
      AVEncoderBitDepthHintKey: 16,
    ]

    var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: sampleRate, channels: 2, interleaved: false)!
    let chunk = AVAudioFrameCount(sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: chunk)!
    buffer.frameLength = chunk

    // Noise rather than a tone: FLAC compresses a sine to almost nothing, and
    // a fixture that is mostly silence has too few frames to stall inside.
    var phase = 0.0
    for frame in 0..<Int(chunk) {
      phase += 0.05
      let sample = Float(0.4 * sin(phase) + 0.2 * sin(phase * 7.3))
      buffer.floatChannelData![0][frame] = sample
      buffer.floatChannelData![1][frame] = sample
    }

    for _ in 0..<5 { try writer?.write(from: buffer) }
    writer = nil

    let data = try Data(contentsOf: url)
    Self.encodedFixtures[key] = data
    return data
  }

  /**
   Every container the engine hands to Core Audio and can also encode here.

   Ogg Vorbis and Opus are absent because they do not go through this reader
   at all — they have their own, and their own copy of these tests. MP3 is
   absent for a duller reason: Core Audio decodes it and will not encode it,
   so there is no way to build the fixture in process. That is a real gap,
   because MP3 is what every transcoded stream is, and it is written down in
   `docs/architecture.md` §12 rather than left to be rediscovered.
   */
  private static let formats: [(name: String, id: AudioFormatID, ext: String, hint: AudioFileTypeID)] = [
    ("WAV", kAudioFormatLinearPCM, "wav", kAudioFileWAVEType),
    ("FLAC", kAudioFormatFLAC, "flac", kAudioFileFLACType),
    ("ALAC", kAudioFormatAppleLossless, "m4a", kAudioFileM4AType),
    ("AAC", kAudioFormatMPEG4AAC, "m4a", kAudioFileM4AType),
  ]

  /**
   The reported case, in the format it was reported in.

   Lossless over cellular, leaving the house — a stall a quarter of the way in
   must reach the engine as a failure it can retry or report, not as the track
   having finished. The engine takes an ending at face value and advances,
   which is what a listener hears as the song skipping itself.
   */
  func testAStalledFLACSourceIsAFailureNotTheEndOfTheFile() throws {
    let data = try flacData()
    let source = FlakySource(
      data: data, servableBytes: Int64(data.count) / 4, failure: .throwsFetchFailed
    )
    let reader = AudioFileReader(source: source)
    try reader.open()

    XCTAssertEqual(drain(reader), .threw,
                   "a stalled FLAC stream was reported as a track that ended")
  }

  func testAnEmptyReadBeforeTheEndOfAFLACIsAlsoAFailure() throws {
    let data = try flacData()
    let source = FlakySource(
      data: data, servableBytes: Int64(data.count) / 4, failure: .returnsEmpty
    )
    let reader = AudioFileReader(source: source)
    try reader.open()

    XCTAssertEqual(drain(reader), .threw,
                   "an empty read mid-FLAC was reported as a track that ended")
  }

  /**
   The reported case: the source stalls a fraction of the way in.

   The reader must report that as a failure, so the engine can retry or say so,
   rather than as the end of the track, which the engine takes at face value.
   */
  func testAStalledSourceIsAFailureNotTheEndOfTheFile() throws {
    let data = try fixtureData()
    let source = FlakySource(
      data: data, servableBytes: Int64(data.count) / 4, failure: .throwsFetchFailed
    )
    let reader = AudioFileReader(source: source)
    try reader.open()

    XCTAssertEqual(drain(reader), .threw,
                   "a source that stalled must not look like a track that ended")
  }

  /// An empty read before the end is the same fault wearing different clothes.
  func testAnEmptyReadBeforeTheEndIsAlsoAFailure() throws {
    let data = try fixtureData()
    let source = FlakySource(
      data: data, servableBytes: Int64(data.count) / 4, failure: .returnsEmpty
    )
    let reader = AudioFileReader(source: source)
    try reader.open()

    XCTAssertEqual(drain(reader), .threw,
                   "empty before the end is a source that could not serve, not an ending")
  }

  /**
   A cancelled read still unwinds as the end of the file.

   This is the case the original code was written for, and it must keep
   working: a seek deliberately abandons the read in flight, and surfacing that
   as a decode error would make a normal seek look like a corrupt track.
   */
  func testACancelledReadStillUnwindsCleanly() throws {
    let data = try fixtureData()
    let source = FlakySource(
      data: data, servableBytes: Int64(data.count) / 4, failure: .throwsCancelled
    )
    let reader = AudioFileReader(source: source)
    try reader.open()

    XCTAssertEqual(drain(reader), .endedCleanly,
                   "a cancelled read is deliberate and should unwind as an ending")
  }

  /// And a source that can serve everything reaches a real end, still cleanly.
  func testAWholeFileEndsCleanly() throws {
    let data = try fixtureData()
    let source = FlakySource(
      data: data, servableBytes: Int64(data.count), failure: .throwsFetchFailed
    )
    let reader = AudioFileReader(source: source)
    try reader.open()

    XCTAssertEqual(drain(reader), .endedCleanly,
                   "running out of file is the one thing that is genuinely the end")
  }

  // MARK: - Surviving the stall, which is what the retry ladder assumes

  /**
   A stall the connection recovers from must not cost the track.

   `TrackPlayback` retries a failed read for about thirty-three seconds, and it
   retries *the same reader*. That only helps if a reader that has thrown can
   go on to decode the rest of the file. If Core Audio latches after a failed
   read — returning zero frames from then on — the ladder cannot win: the
   retries either keep throwing until the budget runs out, or come back with a
   clean end and the engine advances. Both reach a listener as the song
   stopping part-way through, which is the fault this whole area exists to fix.

   Counted in frames rather than asserted as "did not throw", because the
   failure mode to catch is a reader that recovers into *silence* or into an
   early end — both of which look fine to a test that only watches for errors.
   */
  private func framesAfterRecovering(
    from data: Data, hint: AudioFileTypeID = 0
  ) throws -> (recovered: Int64, whole: Int64) {
    let whole = AudioFileReader(source: FlakySource(
      data: data, servableBytes: Int64(data.count), failure: .throwsFetchFailed
    ))
    try whole.open(hint: hint)
    var wholeFrames: Int64 = 0
    while let buffer = try whole.read(frames: 4096), buffer.frameLength > 0 {
      wholeFrames += Int64(buffer.frameLength)
    }

    let source = RecoveringSource(
      data: data, stallAfter: Int64(data.count) / 4,
      failuresBeforeRecovery: 3, servableTail: 16 * 1024
    )
    source.stalled = false
    let reader = AudioFileReader(source: source)
    try reader.open(hint: hint)
    source.stalled = true

    var recoveredFrames: Int64 = 0
    var thrown = 0
    for _ in 0..<4_000 {
      do {
        guard let buffer = try reader.read(frames: 4096), buffer.frameLength > 0 else { break }
        recoveredFrames += Int64(buffer.frameLength)
      } catch {
        // What the retry ladder does: try the same reader again.
        thrown += 1
        if thrown > 10 { break }
      }
    }

    XCTAssertGreaterThan(thrown, 0, "the stall was never reported at all")
    return (recoveredFrames, wholeFrames)
  }

  /**
   Both properties, against every container this reader is given.

   One test rather than eight because the point is the comparison: each of the
   two faults found here was invisible until the *same* stall was run through a
   second format and behaved differently. Failures name the format, so a new
   decoder that misbehaves says which one it is.

   A lossy format decodes to a slightly different frame count than it was
   handed — priming and padding — so recovery is measured against that format's
   own whole-file read rather than against the source material.
   */
  func testEveryFormatReportsAndSurvivesAStall() throws {
    for format in Self.formats {
      let data = try encoded(format: format.id, ext: format.ext)
      XCTAssertGreaterThan(data.count, 1000, "\(format.name): the fixture did not encode")

      // Opened on a working connection with the hint production passes, from
      // `typeHint(for:)`, and only then stalled.
      func openedThenStalling(_ mode: FlakySource.Failure) throws -> AudioFileReader {
        let source = FlakySource(
          data: data, servableBytes: Int64(data.count) / 4, failure: mode
        )
        source.stalled = false
        let reader = AudioFileReader(source: source)
        try reader.open(hint: format.hint)
        source.stalled = true
        return reader
      }

      // 1. A stall is a failure, not the end of the track.
      XCTAssertEqual(try drain(openedThenStalling(.throwsFetchFailed)), .threw,
                     "\(format.name): a stalled source was reported as a track that ended")

      // 2. An empty read before the end is the same fault in other clothes.
      XCTAssertEqual(try drain(openedThenStalling(.returnsEmpty)), .threw,
                     "\(format.name): an empty read mid-file was reported as an ending")

      // 3. A cancelled read is still deliberate, and still an ending.
      XCTAssertEqual(try drain(openedThenStalling(.throwsCancelled)), .endedCleanly,
                     "\(format.name): a deliberate cancellation was raised as a failure")

      // 4. A stall the connection recovers from does not cost the track.
      let (recovered, whole) = try framesAfterRecovering(from: data, hint: format.hint)
      XCTAssertEqual(Double(recovered), Double(whole), accuracy: Double(whole) * 0.02,
                     "\(format.name): the reader did not decode the rest after the stall passed")
    }
  }
}
