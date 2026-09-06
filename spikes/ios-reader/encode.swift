import AVFoundation

// Re-encode the reference WAV into the formats under test, using AVAudioFile
// directly — afconvert's post-pass rewrites the file and fails on FLAC here.

let src = URL(fileURLWithPath: "tone.wav")
let input = try AVAudioFile(forReading: src)
let sampleRate = input.fileFormat.sampleRate

struct Target {
  let path: String
  let settings: [String: Any]
}

let targets: [Target] = [
  Target(path: "tone.flac", settings: [
    AVFormatIDKey: kAudioFormatFLAC,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16,
  ]),
  Target(path: "tone.m4a", settings: [
    AVFormatIDKey: kAudioFormatAppleLossless,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitDepthHintKey: 16,
  ]),
]

let readFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!

for target in targets {
  let url = URL(fileURLWithPath: target.path)
  try? FileManager.default.removeItem(at: url)
  var out: AVAudioFile? = try AVAudioFile(forWriting: url, settings: target.settings)

  input.framePosition = 0
  let chunk = AVAudioFrameCount(sampleRate)
  let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunk)!
  while input.framePosition < input.length {
    try input.read(into: buffer, frameCount: chunk)
    if buffer.frameLength == 0 { break }
    try out!.write(from: buffer)
  }
  out = nil // finalise the header before measuring
  let size = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? Int) ?? 0
  print("\(target.path): \(size / 1_048_576) MB")
}
