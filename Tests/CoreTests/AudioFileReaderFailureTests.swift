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

    init(data: Data, servableBytes: Int64, failure: Failure) {
      self.data = data
      self.servableBytes = servableBytes
      self.failure = failure
    }

    // The true length, always. The parser is told the file's real size even
    // when the source cannot currently serve all of it — that is the whole
    // design, and it is why "cannot serve" must not read as "finished".
    func totalBytes() throws -> Int64 { Int64(data.count) }

    func read(offset: Int64, count: Int) throws -> Data {
      if offset >= Int64(data.count) { return Data() }   // genuinely the end
      if offset + Int64(count) <= servableBytes {
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
  private static var flacFixture: Data?

  private func flacData() throws -> Data {
    if let cached = Self.flacFixture { return cached }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-engine-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("failure-fixture.flac")
    try? FileManager.default.removeItem(at: url)

    let sampleRate = 44_100.0
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatFLAC,
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
    Self.flacFixture = data
    return data
  }

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
}
