import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 The end-to-end claim: real encoded audio, delivered a window at a time through
 the cache, decodes into PCM.

 Fixtures are generated rather than committed — a few seconds of broadband
 audio, because silence compresses to nearly nothing and would let a decoder
 skip work a real track makes it do.
 */
final class AudioFileReaderTests: XCTestCase {

  private static var fixtures: [String: Data] = [:]

  /// Encode once for the whole suite; each test gets its own source over the
  /// same bytes.
  private func fixture(format: AudioFormatID, ext: String) throws -> Data {
    let key = ext
    if let cached = Self.fixtures[key] { return cached }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-engine-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("fixture.\(ext)")
    try? FileManager.default.removeItem(at: url)

    let sampleRate = 44_100.0
    var settings: [String: Any] = [
      AVFormatIDKey: format,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 2,
    ]
    if format == kAudioFormatLinearPCM {
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVLinearPCMIsFloatKey] = false
      settings[AVLinearPCMIsBigEndianKey] = false
    } else {
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVEncoderBitDepthHintKey] = 16
    }

    var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    let seconds = 8
    let chunk = AVAudioFrameCount(sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: chunk)!
    buffer.frameLength = chunk
    var phase = 0.0
    for _ in 0..<seconds {
      let left = buffer.floatChannelData![0]
      let right = buffer.floatChannelData![1]
      for index in 0..<Int(chunk) {
        phase += 2.0 * Double.pi * 440.0 / sampleRate
        let sample = Float(0.3 * sin(phase) + Double.random(in: -0.1...0.1))
        left[index] = sample
        right[index] = sample
      }
      try writer!.write(from: buffer)
    }
    // The header is finalised on deallocation. Without this the file reads as
    // empty despite being the right size on disk.
    writer = nil

    let data = try Data(contentsOf: url)
    Self.fixtures[key] = data
    return data
  }

  /// Serves a fixture, so a "download" is deterministic.
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

  private func read(_ data: Data, window: Int64 = 32 * 1024, prefetchTail: Bool = false)
    throws -> (reader: AudioFileReader, fetcher: BlobFetcher) {
    let fetcher = BlobFetcher(data)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: window)
    if prefetchTail { try source.prefetchTail() }
    let reader = AudioFileReader(source: source)
    try reader.open()
    return (reader, fetcher)
  }

  // MARK: - WAV

  func testDecodesWavThroughTheCache() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatLinearPCM, ext: "wav"))
    XCTAssertEqual(reader.sampleRate, 44_100)
    XCTAssertEqual(reader.totalFrames, 8 * 44_100, accuracy: 4096)

    let buffer = try XCTUnwrap(try reader.read(frames: 4096))
    XCTAssertEqual(buffer.frameLength, 4096)
    XCTAssertEqual(buffer.format.channelCount, 2)
  }

  func testReportsFullDurationWithAlmostNothingFetched() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, fetcher) = try read(data, window: 16 * 1024)

    // This is the property AVAudioFile does not have: its length is computed
    // once at open, so a partial file reports a partial duration. Here the
    // parser is told the true size and answers correctly having seen a
    // fraction of the bytes.
    XCTAssertEqual(reader.totalFrames, 8 * 44_100, accuracy: 4096)
    let fetched = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    XCTAssertLessThan(fetched, Int64(data.count) / 2)
  }

  func testSeekingNearTheEndDoesNotPullTheWholeFile() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, fetcher) = try read(data, window: 32 * 1024)

    try reader.seek(toFrame: Int64(Double(reader.totalFrames) * 0.9))
    _ = try reader.read(frames: 4096)

    let fetched = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    // Uncompressed audio seeks by arithmetic, so this should be a couple of
    // windows, nowhere near the 90% of the file being skipped over.
    XCTAssertLessThan(fetched, Int64(data.count) / 2)
  }

  // MARK: - FLAC

  func testDecodesFlacThroughTheCache() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatFLAC, ext: "flac"))
    XCTAssertEqual(reader.sampleRate, 44_100)

    let buffer = try XCTUnwrap(try reader.read(frames: 4096))
    XCTAssertGreaterThan(buffer.frameLength, 0)
  }

  /**
   The measured defect, as a test rather than a note.

   Apple's FLAC decoder ignores the SEEKTABLE and decodes from byte zero, so
   seeking to the end pulls the whole file through the cache. This asserts the
   behaviour we actually get today, so that if a future iOS fixes it — or if
   libFLAC is wired in, which is the plan — this test fails and tells us the
   world changed rather than silently passing.
   */
  func testFlacSeekPullsFarMoreThanItShould() throws {
    let data = try fixture(format: kAudioFormatFLAC, ext: "flac")
    let (reader, fetcher) = try read(data, window: 32 * 1024)

    try reader.seek(toFrame: Int64(Double(reader.totalFrames) * 0.9))
    _ = try reader.read(frames: 4096)

    let fetched = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    print("FLAC 90% seek: fetched \(fetched) of \(data.count) bytes "
          + "(\(Int(Double(fetched) / Double(data.count) * 100))%)")
    XCTAssertGreaterThan(
      fetched, Int64(Double(data.count) * 0.5),
      "FLAC seek fetched \(fetched) of \(data.count) bytes. If this dropped, Core Audio "
      + "started honouring the SEEKTABLE, or libFLAC is in the path — either way the "
      + "architecture note in docs/architecture.md §9 needs revisiting.")
  }

  // MARK: - ALAC, the opposite failure

  func testAlacNeedsItsTailBeforeItWillOpen() throws {
    let data = try fixture(format: kAudioFormatAppleLossless, ext: "m4a")

    // moov sits at the end of a file AVAudioFile wrote, so a reader that has
    // only the head cannot open it. Confirmed in the spike; asserted here so
    // the tail-prefetch cannot be quietly removed.
    let fetcher = BlobFetcher(data.prefix(data.count / 4))
    let truncated = CachedByteSource(fetcher: fetcher, windowBytes: 32 * 1024)
    let blind = AudioFileReader(source: truncated)
    XCTAssertThrowsError(try blind.open())

    // With the tail fetched first it opens.
    let (reader, _) = try read(data, window: 32 * 1024, prefetchTail: true)
    XCTAssertGreaterThan(reader.totalFrames, 0)
    XCTAssertNotNil(try reader.read(frames: 4096))
  }

  func testReadReturnsNilAtEndOfStream() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatLinearPCM, ext: "wav"))
    try reader.seek(toFrame: reader.totalFrames)
    XCTAssertNil(try reader.read(frames: 4096))
  }
}

private func XCTAssertEqual(
  _ lhs: Int64, _ rhs: Int, accuracy: Int64, file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertLessThanOrEqual(abs(lhs - Int64(rhs)), accuracy, file: file, line: line)
}
