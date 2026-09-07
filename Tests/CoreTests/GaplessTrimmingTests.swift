import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 Gapless playback, and who is responsible for it.

 Lossy encoders pad both ends — priming at the start so the decoder can warm
 up, remainder at the end to fill the last block. Untrimmed, every track gains
 tens of milliseconds of silence at each join, which is the thing that makes a
 live album or a DJ set sound broken.

 **Core Audio does the trimming.** That is the finding these tests exist to
 pin, and it was not obvious: the first implementation subtracted the padding
 from the reported length and seeked past the priming, which reported every
 lossy track about 3000 frames short and skipped 2112 frames of real audio at
 the head of each one. It passed four of its own five tests, because four of
 them were written against the same wrong assumption as the code.

 So what is checked here is the platform's behaviour, not ours. If a future
 macOS or iOS stops applying the packet table, this fails and the engine needs
 the trimming it does not currently do.

 AAC because macOS ships an AAC encoder and no MP3 one — the same limitation
 `spikes/ios-reader` hit.
 */
final class GaplessTrimmingTests: XCTestCase {

  private let sourceFrames: Int64 = 44_100 * 2
  private let sampleRate = 44_100.0

  private func makeAAC() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-gapless-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tone-\(sourceFrames).m4a")
    if FileManager.default.fileExists(atPath: url.path) { return url }

    // Scoped: an AVAudioFile finalises the container when it deallocates, and
    // an unfinalised m4a will not open.
    try {
      let writer = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
      ])
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: 2, interleaved: false)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                    frameCapacity: AVAudioFrameCount(sourceFrames))!
      buffer.frameLength = AVAudioFrameCount(sourceFrames)
      var phase = 0.0
      for index in 0..<Int(sourceFrames) {
        phase += 2.0 * Double.pi * 440.0 / sampleRate
        let sample = Float(0.5 * sin(phase))
        buffer.floatChannelData![0][index] = sample
        buffer.floatChannelData![1][index] = sample
      }
      try writer.write(from: buffer)
    }()
    return url
  }

  private func makeReader() throws -> AudioFileReader {
    let data = try Data(contentsOf: try makeAAC())
    let reader = AudioFileReader(source: CachedByteSource(fetcher: BlobFetcher(data)))
    try reader.open(hint: kAudioFileM4AType)
    return reader
  }

  private func peak(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    var highest: Float = 0
    for index in 0..<Int(buffer.frameLength) { highest = max(highest, abs(data[0][index])) }
    return highest
  }

  func testTheFileDeclaresPaddingToTrim() throws {
    let reader = try makeReader()
    // If this is zero the encoder changed and everything below passes
    // vacuously — there would be no padding to get right or wrong.
    XCTAssertGreaterThan(reader.primingFrames, 0)
    XCTAssertGreaterThan(reader.remainderFrames, 0)
  }

  func testTheReportedLengthIsTheMusicNotTheEncodedFrames() throws {
    let reader = try makeReader()
    // Measured: 88200 in, 88200 reported, with 2112 priming and 824 remainder
    // alongside. The padding is already off — subtracting it here again is the
    // bug this test was written after finding.
    XCTAssertEqual(Double(reader.totalFrames), Double(sourceFrames), accuracy: 64)
  }

  func testTheFirstBufferIsAudioRatherThanPrimingSilence() throws {
    let reader = try makeReader()
    guard let buffer = try reader.read(frames: 2048) else { return XCTFail("no audio") }
    XCTAssertGreaterThan(peak(buffer), 0.1, "first read is silence — the priming was not trimmed")
  }

  func testReadingEndsWithTheMusic() throws {
    let reader = try makeReader()
    var total: Int64 = 0
    while let buffer = try reader.read(frames: 4096) {
      total += Int64(buffer.frameLength)
      if total > reader.totalFrames + 8192 { break }
    }
    XCTAssertEqual(Double(total), Double(reader.totalFrames), accuracy: 64)
  }

  func testSeekingToZeroLandsOnTheMusic() throws {
    let reader = try makeReader()
    _ = try reader.read(frames: 4096)
    try reader.seek(toFrame: 0)
    guard let buffer = try reader.read(frames: 1024) else { return XCTFail("no audio") }
    // Silence here would mean a priming offset had been added on top of one
    // Core Audio already applied.
    XCTAssertGreaterThan(peak(buffer), 0.1)
  }

  private final class BlobFetcher: ByteFetcher, @unchecked Sendable {
    let blob: Data
    init(_ blob: Data) { self.blob = blob }
    func contentLength() throws -> Int64 { Int64(blob.count) }
    func fetch(_ range: Range<Int64>) throws -> Data {
      let end = min(Int(range.upperBound), blob.count)
      guard Int(range.lowerBound) < end else { return Data() }
      return blob.subdata(in: Int(range.lowerBound)..<end)
    }
  }
}
