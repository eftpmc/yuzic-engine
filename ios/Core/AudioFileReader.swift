import Foundation
import AVFoundation
import AudioToolbox

/**
 Decodes audio out of a `CachedByteSource` into PCM buffers a player node can
 schedule.

 `AVAudioFile` is deliberately not used, and the reason is the whole argument
 for this class existing. Its `length` is computed once when the file is opened
 and never re-derived, so a partial file reports a partial duration; and a read
 past the current end returns success with zero frames, indistinguishable from
 a real end-of-file, with no way to say "would block". Both were confirmed
 rather than assumed — see `spikes/ios-reader`.

 `AudioFileOpenWithCallbacks` has neither problem, because we answer the size
 question ourselves. The parser is told the resource's true length, the read
 proc is handed offsets rather than a cursor, and the source blocks until the
 bytes arrive.

 Takes any `ByteSource`, because there are two transports: a ranged direct
 stream, and a transcoded one that can only serve what has arrived. The reader
 does not care which — it asks for bytes and either gets them or waits.

 Not thread-safe: one reader per producer thread, which is the shape the design
 wants anyway.
 */
public final class AudioFileReader {

  public enum ReaderError: Error {
    case openFailed(OSStatus)
    case wrapFailed(OSStatus)
    case formatFailed(OSStatus)
    case readFailed(OSStatus)
  }

  private let source: ByteSource
  private var audioFile: AudioFileID?
  private var extFile: ExtAudioFileRef?

  /// Playable frames — the music, with the encoder's padding already taken off
  /// both ends. Seeking is expressed against this, not against the file.
  public private(set) var totalFrames: Int64 = 0

  /// Silence the encoder put at the front, which playback skips. Zero for
  /// formats that are sample-exact.
  public private(set) var primingFrames: Int64 = 0
  /// Silence at the end, which playback stops before.
  public private(set) var remainderFrames: Int64 = 0

  /// Playable frames handed out so far. Tracked rather than asked for, because
  /// `ExtAudioFile` counts in file frames and this has to count in music.
  private var framesRead: Int64 = 0
  public private(set) var sampleRate: Double = 0
  public private(set) var channelCount: UInt32 = 0

  /// The format handed out — float32 non-interleaved, which is what an
  /// `AVAudioPlayerNode` wants and what the graph is wired for.
  public private(set) var outputFormat: AVAudioFormat?

  public init(source: ByteSource) {
    self.source = source
  }

  deinit {
    if let extFile { ExtAudioFileDispose(extFile) }
    if let audioFile { AudioFileClose(audioFile) }
  }

  /**
   Open the stream.

   `hint` is the file-type hint Core Audio gets. Worth passing when the
   container is known from the URL or the server's content type: without it the
   parser sniffs, which costs extra reads at the head — and reads are network
   requests here, not memcpy.
   */
  public func open(hint: AudioFileTypeID = 0) throws {
    let context = Unmanaged.passUnretained(self).toOpaque()

    var file: AudioFileID?
    let status = AudioFileOpenWithCallbacks(
      context,
      AudioFileReader.readProc,
      nil,
      AudioFileReader.sizeProc,
      nil,
      hint,
      &file
    )
    guard status == noErr, let file else { throw ReaderError.openFailed(status) }
    audioFile = file

    var ext: ExtAudioFileRef?
    let wrapped = ExtAudioFileWrapAudioFileID(file, false, &ext)
    guard wrapped == noErr, let ext else { throw ReaderError.wrapFailed(wrapped) }
    extFile = ext

    var native = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let gotFormat = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &native)
    guard gotFormat == noErr else { throw ReaderError.formatFailed(gotFormat) }

    sampleRate = native.mSampleRate
    // Everything downstream is stereo; a mono source is widened by the
    // converter rather than special-cased in the graph.
    channelCount = max(1, min(2, native.mChannelsPerFrame))

    var client = AudioStreamBasicDescription(
      mSampleRate: native.mSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let setClient = ExtAudioFileSetProperty(
      ext, kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout.size(ofValue: client)), &client)
    guard setClient == noErr else { throw ReaderError.formatFailed(setClient) }

    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: native.mSampleRate,
      channels: 2, interleaved: false)

    var frames: Int64 = 0
    var frameSize = UInt32(MemoryLayout<Int64>.size)
    ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &frameSize, &frames)

    readEncoderPadding(from: file)
    // Used as reported. `ExtAudioFile` has already applied the packet table:
    // measured on a 2s AAC file, it returns 88200 for 88200 frames of input
    // with priming=2112 and remainder=824 sitting alongside — so this length
    // is the music, and subtracting the padding again would report every lossy
    // track ~3000 frames short.
    totalFrames = frames
  }

  /**
   Encoder delay and padding, read for the record rather than to act on.

   Lossy encoders cannot represent an arbitrary number of samples: MP3 and AAC
   work in fixed blocks, so they pad the start (priming, for the decoder to
   warm up) and the end (remainder, to fill the last block). Untrimmed, every
   track gains a few tens of milliseconds of silence at each end — inaudible
   alone, and exactly the seam that makes a live album or a DJ set sound
   broken. This is what "gapless" is about.

   **Core Audio already trims it, and this was measured rather than assumed.**
   `ExtAudioFile` applies the packet table itself: `FileLengthFrames` comes
   back as the playable length and the first read is music, not silence. The
   first version of this code subtracted the padding from the length and
   seeked past the priming — which reported every lossy track ~3000 frames
   short and skipped 2112 frames of real audio at the head of each one. The
   test alongside pins the platform behaviour so that stays visible.

   Kept exposed because "how much padding does this file declare" is worth
   being able to see, and because a future format handled by a decoder that
   does *not* trim would need it.
   */
  private func readEncoderPadding(from file: AudioFileID) {
    var info = AudioFilePacketTableInfo()
    var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
    let status = AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &info)
    guard status == noErr else { return }
    primingFrames = Int64(max(0, info.mPrimingFrames))
    remainderFrames = Int64(max(0, info.mRemainderFrames))
  }

  /**
   How many frames beyond `frame` are already fetched.

   An estimate, and deliberately a crude one: it maps frames to bytes by
   assuming a constant rate across the file. That is exact for PCM, close for
   CBR, and wrong in the middle of a VBR file — a quiet passage occupies fewer
   bytes than a loud one, so the figure drifts either way.

   Good enough because of what it is for. This drives a buffering indicator, a
   thing whose only job is to distinguish "stalled" from "fine". Being ten
   percent out on how much is buffered changes nothing anyone can see; being
   unable to say whether anything is buffered at all is the failure worth
   avoiding, and the alternative on offer was reporting zero forever.

   Never used for a decision — not for scheduling, not for the crossfade
   trigger, not for end-of-track. Only for display.
   */
  public func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 {
    guard totalFrames > 0, let totalBytes = try? source.totalBytes(), totalBytes > 0 else {
      return 0
    }
    let bytesPerFrame = Double(totalBytes) / Double(totalFrames)
    guard bytesPerFrame > 0 else { return 0 }

    let byteOffset = Int64(Double(frame) * bytesPerFrame)
    let available = source.availableBytes(from: byteOffset)
    return Int64(Double(available) / bytesPerFrame)
  }

  /// Seek, in playable frames — which is what `ExtAudioFile` already counts
  /// in, padding excluded. No priming correction here: adding one skips real
  /// audio, which is what the first version of this did.
  public func seek(toFrame frame: Int64) throws {
    guard let extFile else { return }
    let clamped = max(0, min(frame, totalFrames))
    let status = ExtAudioFileSeek(extFile, clamped)
    guard status == noErr else { throw ReaderError.readFailed(status) }
    framesRead = clamped
  }

  /**
   Unblock a read parked on the network, so the producer thread unwinds.

   Forwarded to the byte source, which is the only thing that can be waiting.
   The read proc turns the resulting `cancelled` into end-of-file, so the
   parser unwinds cleanly and `read` returns nil — see `readProc`.

   Exposed here rather than reaching for the source directly because this class
   owns it, and because "stop waiting" is a reader-level idea: the caller
   holding a reader has no business knowing whether the bytes come from a
   socket or a file.
   */
  public func cancelPendingReads() { source.cancel() }

  /// Undo `cancelPendingReads`. Required before the reader is used again — a
  /// cancelled source refuses every read until it is put back to work.
  public func resumePendingReads() { source.resume() }

  /**
   Decode up to `frames` frames.

   Returns nil at end of stream. A short buffer is normal near the end and is
   not an error.
   */
  public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    guard let extFile, let outputFormat else { return nil }

    // Stop at the last frame of music rather than the last frame of file. The
    // remainder is the encoder's block padding; decoding it would append
    // silence to every lossy track, which is the other half of the seam.
    let remaining = totalFrames > 0 ? totalFrames - framesRead : Int64(frames)
    guard remaining > 0 else { return nil }
    let wanted = AVAudioFrameCount(min(Int64(frames), remaining))

    guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: wanted) else {
      return nil
    }

    // The buffer list advertises frameLength, not capacity, and
    // ExtAudioFileRead reads mDataByteSize to decide how much it may write.
    // Left at zero it returns paramErr — which looks exactly like an
    // unsupported format, and cost an hour during the spike.
    buffer.frameLength = wanted

    var count = wanted
    let status = ExtAudioFileRead(extFile, &count, buffer.mutableAudioBufferList)
    guard status == noErr else { throw ReaderError.readFailed(status) }
    guard count > 0 else { return nil }

    framesRead += Int64(count)
    buffer.frameLength = count
    return buffer
  }

  // MARK: - Core Audio callbacks

  private static let readProc: AudioFile_ReadProc = { context, position, requestCount, buffer, actualCount in
    let reader = Unmanaged<AudioFileReader>.fromOpaque(context).takeUnretainedValue()
    do {
      let data = try reader.source.read(offset: position, count: Int(requestCount))
      if data.isEmpty {
        actualCount.pointee = 0
        return kAudioFileEndOfFileError
      }
      data.withUnsafeBytes { raw in
        buffer.copyMemory(from: raw.baseAddress!, byteCount: data.count)
      }
      actualCount.pointee = UInt32(data.count)
      return noErr
    } catch {
      actualCount.pointee = 0
      // A cancelled read is not a corrupt file. Reporting end-of-file lets the
      // parser unwind cleanly instead of surfacing a decode error the caller
      // would have to distinguish from a genuinely broken track.
      return kAudioFileEndOfFileError
    }
  }

  private static let sizeProc: AudioFile_GetSizeProc = { context in
    let reader = Unmanaged<AudioFileReader>.fromOpaque(context).takeUnretainedValue()
    return (try? reader.source.totalBytes()) ?? 0
  }
}
