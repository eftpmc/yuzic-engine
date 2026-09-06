import AVFoundation
import AudioToolbox

/**
 Spike item 2, and the question item 1 raised.

 Item 2 asks: does `AudioFileOpenWithCallbacks` + `ExtAudioFileWrapAudioFileID`
 decode a file whose bytes are only partly present, if `GetSizeProc` reports the
 full length and `ReadProc` serves what it has?

 The sharper question, after finding FLAC seeks by decoding from zero: **which
 byte ranges does the decoder actually ask for when seeking?** If it requests
 everything from offset 0, then random access buys nothing for FLAC — a seek to
 90% would force fetching 90% of the file over the network first, which defeats
 the whole fetch-to-cache design rather than merely being slow.

 So the read proc here records every request instead of just serving it.
 */

final class ByteSource {
  let data: Data
  /// How much of the file has "arrived". Everything past this is treated as
  /// not yet fetched — the state a streaming cache is in for most of a track.
  let availableBytes: Int
  var requests: [(offset: Int64, count: UInt32)] = []
  var missedRanges: [(offset: Int64, count: UInt32)] = []

  init(path: String, availableFraction: Double = 1.0) throws {
    data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    availableBytes = Int(Double(data.count) * availableFraction)
  }

  /// Always the *full* size, even when most of the file is absent. This is the
  /// trick the whole design rests on: the parser believes the file is whole.
  var totalBytes: Int64 { Int64(data.count) }

  func read(offset: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer) -> UInt32 {
    requests.append((offset, count))
    let start = Int(offset)
    guard start < data.count else { return 0 }
    if start >= availableBytes {
      // A real implementation blocks here and issues a ranged GET. The spike
      // records the miss and refuses, so we can see whether the decoder can
      // even get started on a partial file.
      missedRanges.append((offset, count))
      return 0
    }
    let end = min(start + Int(count), min(data.count, availableBytes))
    data.withUnsafeBytes { raw in
      buffer.copyMemory(from: raw.baseAddress!.advanced(by: start), byteCount: end - start)
    }
    return UInt32(end - start)
  }

  /// Total distinct bytes touched, as a fraction of the file.
  func coverage() -> (bytes: Int64, fraction: Double) {
    var touched: Int64 = 0
    for request in requests { touched += Int64(request.count) }
    return (touched, Double(touched) / Double(max(1, totalBytes)))
  }
}

let readProc: AudioFile_ReadProc = { inClientData, inPosition, requestCount, buffer, actualCount in
  let source = Unmanaged<ByteSource>.fromOpaque(inClientData).takeUnretainedValue()
  let got = source.read(offset: inPosition, count: requestCount, into: buffer)
  actualCount.pointee = got
  return got == 0 ? kAudioFileEndOfFileError : noErr
}

let sizeProc: AudioFile_GetSizeProc = { inClientData in
  let source = Unmanaged<ByteSource>.fromOpaque(inClientData).takeUnretainedValue()
  return source.totalBytes
}

func probe(path: String, seekFraction: Double) {
  guard let source = try? ByteSource(path: path) else {
    print("  \(path): could not load")
    return
  }
  let opaque = Unmanaged.passUnretained(source).toOpaque()

  var audioFile: AudioFileID?
  let openStatus = AudioFileOpenWithCallbacks(opaque, readProc, nil, sizeProc, nil, 0, &audioFile)
  guard openStatus == noErr, let audioFile else {
    print("  \(path): AudioFileOpenWithCallbacks failed (\(openStatus))")
    return
  }

  var extFile: ExtAudioFileRef?
  guard ExtAudioFileWrapAudioFileID(audioFile, false, &extFile) == noErr, let extFile else {
    print("  \(path): ExtAudioFileWrapAudioFileID failed")
    return
  }

  // Ask for float32 non-interleaved, which is what a player node wants.
  var client = AudioStreamBasicDescription(
    mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
  ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                          UInt32(MemoryLayout.size(ofValue: client)), &client)

  var frames: Int64 = 0
  var size = UInt32(MemoryLayout<Int64>.size)
  ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &size, &frames)

  let openRequests = source.requests.count
  let openBytes = source.coverage().bytes
  source.requests.removeAll()

  // Now the part that matters: seek, read one buffer, and see what was fetched.
  let target = Int64(Double(frames) * seekFraction)
  ExtAudioFileSeek(extFile, target)

  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
  // The buffer list advertises frameLength, not capacity, and ExtAudioFileRead
  // reads mDataByteSize to decide how much it may write. Left at zero it
  // returns paramErr — which looks exactly like an unsupported format.
  pcm.frameLength = pcm.frameCapacity
  var readFrames: UInt32 = 4096
  let started = DispatchTime.now().uptimeNanoseconds
  let readStatus = ExtAudioFileRead(extFile, &readFrames, pcm.mutableAudioBufferList)
  let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

  let seekCoverage = source.coverage()
  let lowest = source.requests.map(\.offset).min() ?? -1
  let highest = source.requests.map { $0.offset + Int64($0.count) }.max() ?? -1

  let ext = (path as NSString).pathExtension.uppercased()
  print("  \(ext) seek to \(Int(seekFraction * 100))%")
  print("      open: \(openRequests) reads, \(openBytes / 1024) KB")
  print("      seek+read: status \(readStatus), \(readFrames) frames in \(String(format: "%.4f", elapsed))s")
  print("      bytes fetched for the seek: \(seekCoverage.bytes / 1024) KB "
        + "(\(String(format: "%.1f", seekCoverage.fraction * 100))% of file)")
  print("      byte range touched: \(lowest / 1024) KB .. \(highest / 1024) KB")

  ExtAudioFileDispose(extFile)
  AudioFileClose(audioFile)
}

print("")
print("Which bytes does the decoder ask for, to play from the middle?")
print("")
for path in ["tone.wav", "tone.flac", "tone.m4a"] {
  probe(path: path, seekFraction: 0.9)
  print("")
}

// ── item 2 proper: can it start at all with only the head present? ──────────

print("Opening and playing from the start with only 30% of the file fetched")
print("")
for path in ["tone.wav", "tone.flac", "tone.m4a"] {
  guard let source = try? ByteSource(path: path, availableFraction: 0.3) else { continue }
  let opaque = Unmanaged.passUnretained(source).toOpaque()
  var audioFile: AudioFileID?
  let ext = (path as NSString).pathExtension.uppercased()
  let status = AudioFileOpenWithCallbacks(opaque, readProc, nil, sizeProc, nil, 0, &audioFile)
  guard status == noErr, let audioFile else {
    print("  \(ext): open FAILED (\(status)) after \(source.requests.count) reads, "
          + "\(source.missedRanges.count) of them past the fetched region")
    continue
  }
  var extFile: ExtAudioFileRef?
  guard ExtAudioFileWrapAudioFileID(audioFile, false, &extFile) == noErr, let extFile else {
    print("  \(ext): wrap FAILED"); continue
  }
  var client = AudioStreamBasicDescription(
    mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
  ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                          UInt32(MemoryLayout.size(ofValue: client)), &client)
  var frames: Int64 = 0
  var size = UInt32(MemoryLayout<Int64>.size)
  ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &size, &frames)

  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
  pcm.frameLength = pcm.frameCapacity
  var readFrames: UInt32 = 4096
  let readStatus = ExtAudioFileRead(extFile, &readFrames, pcm.mutableAudioBufferList)

  let reportedMinutes = Double(frames) / 44100.0 / 60.0
  print("  \(ext): open OK, reports \(String(format: "%.1f", reportedMinutes)) min "
        + "(true 20.0), first read \(readFrames) frames status \(readStatus), "
        + "\(source.missedRanges.count) reads past the fetched region")
  ExtAudioFileDispose(extFile)
  AudioFileClose(audioFile)
}
print("")
