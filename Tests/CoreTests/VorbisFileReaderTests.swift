import XCTest
import AVFoundation
import COgg
import CVorbis
@testable import YuzicEngineCore

/**
 The Vorbis decoder, against a real Ogg Vorbis bitstream.

 The fixture is encoded in-process by libvorbisenc rather than checked in or
 shelled out to. That is not a weaker test than using `oggenc`: `oggenc` *is*
 libvorbisenc, so the bitstream is the same one a real encoder produces — and
 it runs on any machine, where an external tool made four of these tests skip
 silently on this one.
 */
final class VorbisFileReaderTests: XCTestCase {

  /**
   A 440Hz tone, encoded to Ogg Vorbis in memory.

   The encoder is driven the way the reference example does: VBR at quality
   0.4, feed float planes, pull packets, page them into an Ogg stream.
   */
  private func encodeTone(seconds: Double = 2, rate: Int = 44_100) -> Data {
    var info = vorbis_info()
    vorbis_info_init(&info)
    defer { vorbis_info_clear(&info) }
    guard vorbis_encode_init_vbr(&info, 2, Int(rate), 0.4) == 0 else { return Data() }

    var comment = vorbis_comment()
    vorbis_comment_init(&comment)
    defer { vorbis_comment_clear(&comment) }

    var dsp = vorbis_dsp_state()
    vorbis_analysis_init(&dsp, &info)
    defer { vorbis_dsp_clear(&dsp) }

    var block = vorbis_block()
    vorbis_block_init(&dsp, &block)
    defer { vorbis_block_clear(&block) }

    var stream = ogg_stream_state()
    ogg_stream_init(&stream, 1)
    defer { ogg_stream_clear(&stream) }

    var output = Data()

    func drainPages(flush: Bool) {
      var page = ogg_page()
      while true {
        let got = flush ? ogg_stream_flush(&stream, &page) : ogg_stream_pageout(&stream, &page)
        if got == 0 { break }
        output.append(page.header, count: page.header_len)
        output.append(page.body, count: page.body_len)
      }
    }

    var headerId = ogg_packet(), headerComment = ogg_packet(), headerCode = ogg_packet()
    vorbis_analysis_headerout(&dsp, &comment, &headerId, &headerComment, &headerCode)
    ogg_stream_packetin(&stream, &headerId)
    ogg_stream_packetin(&stream, &headerComment)
    ogg_stream_packetin(&stream, &headerCode)
    drainPages(flush: true)

    let totalFrames = Int(Double(rate) * seconds)
    let chunk = 1024
    var written = 0
    var phase = 0.0

    while written < totalFrames {
      let count = min(chunk, totalFrames - written)
      if let planes = vorbis_analysis_buffer(&dsp, Int32(count)) {
        for index in 0..<count {
          phase += 2.0 * Double.pi * 440.0 / Double(rate)
          let sample = Float(0.5 * sin(phase))
          planes[0]?[index] = sample
          planes[1]?[index] = sample
        }
      }
      vorbis_analysis_wrote(&dsp, Int32(count))
      written += count

      var packet = ogg_packet()
      while vorbis_analysis_blockout(&dsp, &block) == 1 {
        vorbis_analysis(&block, nil)
        vorbis_bitrate_addblock(&block)
        while vorbis_bitrate_flushpacket(&dsp, &packet) == 1 {
          ogg_stream_packetin(&stream, &packet)
          drainPages(flush: false)
        }
      }
    }

    // Zero frames marks the end of the stream, which is what makes the final
    // page carry the real total rather than an estimate.
    vorbis_analysis_wrote(&dsp, 0)
    var packet = ogg_packet()
    while vorbis_analysis_blockout(&dsp, &block) == 1 {
      vorbis_analysis(&block, nil)
      vorbis_bitrate_addblock(&block)
      while vorbis_bitrate_flushpacket(&dsp, &packet) == 1 {
        ogg_stream_packetin(&stream, &packet)
      }
    }
    drainPages(flush: true)

    return output
  }

  /// The whole file in memory, behind the same interface the network uses.
  private final class MemorySource: ByteSource {
    private let blob: Data
    init(_ blob: Data) { self.blob = blob }
    func totalBytes() throws -> Int64 { Int64(blob.count) }
    func read(offset: Int64, count: Int) throws -> Data {
      let start = min(Int(offset), blob.count)
      let end = min(start + count, blob.count)
      return blob.subdata(in: start..<end)
    }
    func availableBytes(from offset: Int64) -> Int64 {
      max(0, Int64(blob.count) - offset)
    }
    func cancel() {}
    func resume() {}
  }

  private func makeReader() -> VorbisFileReader {
    VorbisFileReader(source: MemorySource(encodeTone()))
  }

  func testReadsTheStreamShapeFromTheHeaders() throws {
    let reader = makeReader()
    try reader.open()

    XCTAssertEqual(reader.sampleRate, 44_100)
    XCTAssertEqual(reader.channelCount, 2)
    // Two seconds, give or take the encoder's own padding.
    XCTAssertEqual(Double(reader.totalFrames), 88_200, accuracy: 4_000)
  }

  /**
   Audio comes out, and it is the tone that went in.

   RMS rather than sample equality: Vorbis is lossy, so the samples are not the
   ones encoded and asserting they were would be asserting the wrong thing. A
   0.5-amplitude sine has an RMS of about 0.354, and anything near it means the
   decode produced the signal rather than noise or silence.
   */
  func testDecodesAudioRatherThanSilence() throws {
    let reader = makeReader()
    try reader.open()

    let buffer = try reader.read(frames: 8192)
    let decoded = try XCTUnwrap(buffer)
    XCTAssertGreaterThan(decoded.frameLength, 0)

    var sum: Float = 0
    let data = decoded.floatChannelData![0]
    for index in 0..<Int(decoded.frameLength) { sum += data[index] * data[index] }
    let rms = sqrt(sum / Float(decoded.frameLength))
    XCTAssertEqual(rms, 0.354, accuracy: 0.08, "decoded signal was not the tone that was encoded")
  }

  /// Reading to the end returns nil rather than looping or throwing.
  func testEndOfStreamIsNilAndNotAnError() throws {
    let reader = makeReader()
    try reader.open()

    var total: AVAudioFrameCount = 0
    while let buffer = try reader.read(frames: 16_384), buffer.frameLength > 0 {
      total += buffer.frameLength
      if total > 400_000 { XCTFail("read past the end of a two-second file"); return }
    }
    XCTAssertEqual(Double(total), 88_200, accuracy: 4_000)
  }

  /// Seeking moves the decode position, which is what makes a scrubber work.
  func testSeekingMovesThePlayhead() throws {
    let reader = makeReader()
    try reader.open()

    try reader.seek(toFrame: 44_100)
    let buffer = try XCTUnwrap(try reader.read(frames: 4096))
    XCTAssertGreaterThan(buffer.frameLength, 0)

    // A second seek back to the start must also work: vorbisfile keeps its own
    // cursor, and a stream that only seeks forward would strand the scrubber.
    try reader.seek(toFrame: 0)
    XCTAssertGreaterThan(try XCTUnwrap(try reader.read(frames: 4096)).frameLength, 0)
  }

  // MARK: - Picking the decoder

  /**
   The container is not enough to choose a decoder by.

   Ogg carries Opus and FLAC as well as Vorbis, all behind the same `OggS`
   capture pattern. Matching the container alone would route an Opus file to
   this reader, which fails with a header error — where today it is
   transcoded by the server and plays.
   */
  func testAnOggVorbisStreamIsRecognised() {
    XCTAssertTrue(HTTPTrackReaderFactory.oggCodec(MemorySource(encodeTone(seconds: 0.2))) == .vorbis)
  }

  func testAnOggOpusStreamIsRecognisedAsOpus() {
    // An Ogg page header followed by Opus's identification packet.
    var opus = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0, 0, 0, 0, 0, 0])
    opus.append(contentsOf: Array("OpusHead".utf8))
    opus.append(Data(repeating: 0, count: 64))
    XCTAssertEqual(HTTPTrackReaderFactory.oggCodec(MemorySource(opus)), .opus)
  }

  func testSomethingThatIsNotOggIsNotClaimed() {
    XCTAssertNil(HTTPTrackReaderFactory.oggCodec(MemorySource(Data(repeating: 0x41, count: 512))))
  }

  /// Too short to judge: answer no and let the Core Audio path try.
  func testATruncatedStreamIsNotClaimed() {
    XCTAssertNil(HTTPTrackReaderFactory.oggCodec(MemorySource(Data([0x4F, 0x67, 0x67]))))
  }

  func testOpeningSomethingThatIsNotVorbisFails() throws {
    let reader = VorbisFileReader(source: MemorySource(Data(repeating: 0x41, count: 8192)))
    XCTAssertThrowsError(try reader.open())
  }
}
