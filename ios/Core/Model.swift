import Foundation

/**
 The domain model, in plain Swift.

 Separate from the `Record` types in `YuzicEngineModule.swift` on purpose. Those
 belong to the bridge — they carry `@Field`, they are decoded from JavaScript,
 and they drag `ExpoModulesCore` in with them. If the queue and the graph spoke
 that language, none of the logic worth testing could be built without the whole
 React Native toolchain standing up, which in practice means it never gets
 tested at all.

 So the bridge converts at the edge, and everything below here is ordinary
 Swift that `swift test` can reach.
 */

/// Stable identity for a track, chosen by the host. Opaque to the engine.
public typealias MediaId = String

public struct Track: Equatable {
  public let id: MediaId
  public let uri: String
  public let title: String
  public let artist: String?
  public let album: String?
  public let artworkUri: String?
  /// `nil` means the host does not know yet — which is not zero, and the
  /// crossfade clamp treats the two differently.
  public let durationSec: Double?
  public let headers: [String: String]
  /// Mastered to run straight out of the previous track: an album segue.
  public let followsPrevious: Bool
  public let replayGainDb: Double?
  public let replayGainPeak: Double?
  /// A stream with no end. Live radio.
  public let continuous: Bool

  public init(
    id: String,
    uri: String,
    title: String,
    artist: String? = nil,
    album: String? = nil,
    artworkUri: String? = nil,
    durationSec: Double? = nil,
    headers: [String: String] = [:],
    followsPrevious: Bool = false,
    replayGainDb: Double? = nil,
    replayGainPeak: Double? = nil,
    continuous: Bool = false
  ) {
    self.id = id
    self.uri = uri
    self.title = title
    self.artist = artist
    self.album = album
    self.artworkUri = artworkUri
    self.durationSec = durationSec
    self.headers = headers
    self.followsPrevious = followsPrevious
    self.replayGainDb = replayGainDb
    self.replayGainPeak = replayGainPeak
    self.continuous = continuous
  }
}

public enum CrossfadeMode: String {
  /// Fade between everything, segues included.
  case always
  /// Respect `followsPrevious` and hard-cut there.
  case gaplessAware = "gapless-aware"
}

public struct CrossfadeSettings: Equatable {
  public let durationSec: Double
  public let mode: CrossfadeMode
  public let skipIsImmediate: Bool

  public init(durationSec: Double, mode: CrossfadeMode, skipIsImmediate: Bool = true) {
    self.durationSec = durationSec
    self.mode = mode
    self.skipIsImmediate = skipIsImmediate
  }
}

public enum SampleRateMode: String {
  case fixed
  case matchSource = "match-source"
}

/// Matches `RepeatMode` in src/types.ts. Raw values are the wire strings, so a
/// rename on either side fails to decode rather than quietly meaning `off`.
public enum RepeatMode: String {
  case off
  case one
  case all
}
