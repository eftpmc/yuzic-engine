import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 FLAC through libFLAC rather than Core Audio.

 The claims that matter are the two Core Audio fails, so they are tested
 directly rather than inferred from "it decodes":

 - a **forward-only** source decodes the whole stream, because that is the
   transcoded transport and the reason this reader exists;
 - a **seekable** source seeks without reading the file from the top.

 Fixtures are generated rather than committed, like `AudioFileReaderTests`.
 `afconvert` is asked for the FLAC because `AVAudioFile` will not write one.
 */
final class FLACFileReaderTests: XCTestCase {

  private static var fixture: Data?
  private static var fixture24: Data?

  /// A few seconds of broadband audio as FLAC. Noise rather than silence, so
  /// the decoder has real work and the file has real size.
  private func flacFixture(bitDepth: Int = 16) throws -> Data {
    if bitDepth == 16, let cached = Self.fixture { return cached }
    if bitDepth == 24, let cached = Self.fixture24 { return cached }

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-flac-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wav = dir.appendingPathComponent("fixture\(bitDepth).wav")
    let flac = dir.appendingPathComponent("fixture\(bitDepth).flac")
    try? FileManager.default.removeItem(at: wav)
    try? FileManager.default.removeItem(at: flac)

    let sampleRate = 44_100.0
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: bitDepth,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    var writer: AVAudioFile? = try AVAudioFile(forWriting: wav, settings: settings)
    let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    let chunk = AVAudioFrameCount(sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: chunk)!
    buffer.frameLength = chunk
    var phase = 0.0
    for _ in 0..<6 {
      for index in 0..<Int(chunk) {
        phase += 2.0 * Double.pi * 440.0 / sampleRate
        let sample = Float(0.3 * sin(phase) + Double.random(in: -0.1...0.1))
        buffer.floatChannelData![0][index] = sample
        buffer.floatChannelData![1][index] = sample
      }
      try writer!.write(from: buffer)
    }
    writer = nil

    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-d", "flac", "-f", "flac", wav.path, flac.path]
    convert.standardOutput = FileHandle.nullDevice
    convert.standardError = FileHandle.nullDevice
    try convert.run()
    convert.waitUntilExit()
    guard convert.terminationStatus == 0,
          let data = try? Data(contentsOf: flac) else {
      throw XCTSkip("afconvert could not produce a \(bitDepth)-bit FLAC fixture")
    }

    if bitDepth == 16 { Self.fixture = data } else { Self.fixture24 = data }
    return data
  }

  // MARK: - Sources

  private final class BlobFetcher: ByteFetcher, @unchecked Sendable {
    let blob: Data
    private(set) var requests: [Range<Int64>] = []
    init(_ blob: Data) { self.blob = blob }
    func contentLength() throws -> Int64 { Int64(blob.count) }
    func fetch(_ range: Range<Int64>) throws -> Data {
      requests.append(range)
      let end = min(Int(range.upperBound), blob.count)
      guard Int(range.lowerBound) < end else { return Data() }
      return blob.subdata(in: Int(range.lowerBound)..<end)
    }
  }

  /**
   Forward-only, and strict about it.

   Models `StreamingByteSource`: bytes arrive in order and an offset behind the
   cursor is gone. Anything that seeks backwards fails here by construction,
   which is the point — Core Audio does, and that is what #213 is.
   */
  private final class ForwardOnlySource: ByteSource {
    private let data: Data
    private var cursor: Int64 = 0
    private(set) var backwardSeeks = 0
    init(_ data: Data) { self.data = data }
    func totalBytes() throws -> Int64 { Int64(data.count) }
    func read(offset: Int64, count: Int) throws -> Data {
      if offset < cursor {
        backwardSeeks += 1
        throw ByteSourceError.fetchFailed("backward read to \(offset), cursor at \(cursor)")
      }
      if offset >= Int64(data.count) { return Data() }
      let end = min(Int(offset) + count, data.count)
      let out = data.subdata(in: Int(offset)..<end)
      cursor = offset + Int64(out.count)
      return out
    }
    func availableBytes(from offset: Int64) -> Int64 { max(0, Int64(data.count) - offset) }
    func cancel() {}
    func resume() {}
    var isSequential: Bool { true }
    var isFinished: Bool { true }
  }

  private func decodeAll(_ reader: FLACFileReader) throws -> Int64 {
    var frames: Int64 = 0
    var reads = 0
    while reads < 20_000 {
      reads += 1
      guard let buffer = try reader.read(frames: 8192) else { break }
      frames += Int64(buffer.frameLength)
    }
    return frames
  }

  // MARK: - The two claims

  /**
   The whole reason this reader exists.

   Core Audio cannot do this: it reads from the start of the file to the seek
   point and seeks backwards at will, so on a forward-only transport it fails
   outright. libFLAC is given no seek, tell or length callbacks at all when the
   source is sequential, and decodes straight through.
   */
  func testDecodesEverythingOverAForwardOnlySource() throws {
    let data = try flacFixture()
    let source = ForwardOnlySource(data)
    let reader = FLACFileReader(source: source)
    try reader.open()

    XCTAssertEqual(reader.sampleRate, 44_100)
    XCTAssertGreaterThan(reader.totalFrames, 0)

    let frames = try decodeAll(reader)
    XCTAssertEqual(frames, reader.totalFrames, "the stream was truncated on a forward-only source")
    XCTAssertEqual(source.backwardSeeks, 0, "something asked to read backwards, which a transcode cannot serve")
  }

  /// 24-bit is the case that prompted this: the failing track is 24-bit, where
  /// a conversion scaled for 16-bit would overflow by 256x.
  func testDecodes24BitWithoutClipping() throws {
    let data = try flacFixture(bitDepth: 24)
    let reader = FLACFileReader(source: ForwardOnlySource(data))
    try reader.open()
    XCTAssertEqual(reader.bitsPerSample, 24, "fixture is not actually 24-bit")

    var peak: Float = 0
    var frames: Int64 = 0
    while let buffer = try reader.read(frames: 8192) {
      frames += Int64(buffer.frameLength)
      let channel = buffer.floatChannelData![0]
      for index in 0..<Int(buffer.frameLength) {
        peak = max(peak, abs(channel[index]))
      }
    }
    XCTAssertEqual(frames, reader.totalFrames)
    // The fixture peaks around 0.4. A wrongly scaled conversion lands orders of
    // magnitude out, which this catches without pinning the exact value.
    XCTAssertGreaterThan(peak, 0.05, "signal is far too quiet — scaled as if it were deeper than it is")
    XCTAssertLessThanOrEqual(peak, 1.0, "samples exceed full scale — scaled as if it were shallower than it is")
  }

  /**
   Seeking reads the seek point, not the whole file.

   `docs/architecture.md` §10 measured Core Audio touching 177% of a file to
   play from 90% in. That is what defeats the ranged-fetch design for FLAC, so
   the replacement has to be asserted on, not assumed.
   */
  func testSeekingDoesNotReadTheWholeFile() throws {
    let data = try flacFixture()
    let fetcher = BlobFetcher(data)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: 32 * 1024)
    let reader = FLACFileReader(source: source)
    try reader.open()

    let target = Int64(Double(reader.totalFrames) * 0.9)
    let before = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    try reader.seek(toFrame: target)
    _ = try reader.read(frames: 8192)
    let after = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }

    let fetchedForSeek = after - before
    XCTAssertLessThan(
      fetchedForSeek, Int64(data.count) / 2,
      "seeking fetched \(fetchedForSeek) of \(data.count) bytes — that is the Core Audio behaviour this reader replaces"
    )
  }

  /// A seek on the transcoded transport has nothing to seek within; the engine
  /// answers that by reconnecting with `timeOffset`, so the reader declines
  /// rather than pretending.
  func testSeekIsRefusedOnASequentialSource() throws {
    let data = try flacFixture()
    let reader = FLACFileReader(source: ForwardOnlySource(data))
    try reader.open()
    XCTAssertThrowsError(try reader.seek(toFrame: 1000))
  }

  // MARK: - A stall is not an ending

  /// The fault this engine has fixed twice in other readers: a source that
  /// cannot serve must not arrive as a finished track.
  func testAStalledReadThrowsRatherThanEndingTheTrack() throws {
    final class StallingSource: ByteSource {
      private let data: Data
      private let stallAfter: Int64
      init(_ data: Data, stallAfter: Int64) { self.data = data; self.stallAfter = stallAfter }
      func totalBytes() throws -> Int64 { Int64(data.count) }
      var stalled = false
      func read(offset: Int64, count: Int) throws -> Data {
        if stalled && offset >= stallAfter { throw ByteSourceError.fetchFailed("stalled") }
        if offset >= Int64(data.count) { return Data() }
        let end = min(Int(offset) + count, data.count)
        return data.subdata(in: Int(offset)..<end)
      }
      func availableBytes(from offset: Int64) -> Int64 { max(0, Int64(data.count) - offset) }
      func cancel() {}
      func resume() {}
      var isSequential: Bool { true }
      var isFinished: Bool { false }
    }

    let data = try flacFixture()
    let source = StallingSource(data, stallAfter: Int64(data.count) / 4)
    let reader = FLACFileReader(source: source)
    try reader.open()
    source.stalled = true

    var threw = false
    var frames: Int64 = 0
    for _ in 0..<2000 {
      do {
        guard let buffer = try reader.read(frames: 8192) else { break }
        frames += Int64(buffer.frameLength)
      } catch {
        threw = true
        break
      }
    }
    XCTAssertTrue(threw, "a stalled source ended the track cleanly instead of failing — the \(frames)-frame read looked like a finished file")
    XCTAssertLessThan(frames, reader.totalFrames)
  }
}
