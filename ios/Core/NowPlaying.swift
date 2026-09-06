import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/**
 What the lock screen, the Control Centre and the car are told.

 Split in two on purpose: `NowPlayingInfo` builds the dictionary and is pure, so
 the interesting decisions can be tested; `NowPlayingCenter` is the thin part
 that hands it to a system singleton and cannot be tested without an app.

 The single most important line in this file is `playbackState`. yuzic's current
 player leaves it implicit, and CarPlay shows "paused" over playing audio on the
 first track of a session — a bug patched downstream in a fork of that library
 rather than fixed. An engine that owns the session should never make anyone do
 that, so the state is stated outright on every change. See docs/architecture.md
 §4.
 */
public struct NowPlayingInfo {

  public struct Snapshot {
    public let title: String
    public let artist: String?
    public let album: String?
    public let durationSec: Double
    public let positionSec: Double
    public let isPlaying: Bool
    public let rate: Double
    /// Live radio: no finish line, so no duration and no scrubber.
    public let isLive: Bool

    public init(
      title: String, artist: String? = nil, album: String? = nil,
      durationSec: Double = 0, positionSec: Double = 0,
      isPlaying: Bool = false, rate: Double = 1.0, isLive: Bool = false
    ) {
      self.title = title
      self.artist = artist
      self.album = album
      self.durationSec = durationSec
      self.positionSec = positionSec
      self.isPlaying = isPlaying
      self.rate = rate
      self.isLive = isLive
    }
  }

  /**
   The dictionary iOS reads.

   Three things here are easy to get subtly wrong and unpleasant to debug:

   - **`elapsedPlaybackTime` is a fix point, not a clock.** iOS extrapolates
     from it using the rate, so this only needs updating on seeks and state
     changes — pushing it every tick makes the lock-screen timer stutter as it
     is repeatedly yanked back to a value that is already stale.
   - **The rate must be zero when paused.** Left at 1.0, iOS keeps advancing the
     displayed time over audio that is not playing.
   - **A live stream gets no duration.** Supplying one draws a scrubber that
     lies about a stream with no end, and lets the user drag it.
   */
  public static func build(from snapshot: Snapshot) -> [String: Any] {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: snapshot.title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.positionSec,
      MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.rate : 0.0,
    ]

    if let artist = snapshot.artist, !artist.isEmpty {
      info[MPMediaItemPropertyArtist] = artist
    }
    if let album = snapshot.album, !album.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = album
    }

    if snapshot.isLive {
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
    } else if snapshot.durationSec > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = snapshot.durationSec
    }

    return info
  }
}

/// The commands to advertise. A control that is offered but does nothing is
/// worse than one that is absent, so this list is what the engine can actually
/// honour rather than everything the framework has.
public struct RemoteCommandHandlers {
  public var play: (() -> Void)?
  public var pause: (() -> Void)?
  public var next: (() -> Void)?
  public var previous: (() -> Void)?
  public var seek: ((Double) -> Void)?
  public var stop: (() -> Void)?

  public init() {}
}

public final class NowPlayingCenter {

  private let center = MPNowPlayingInfoCenter.default()
  private let commands = MPRemoteCommandCenter.shared()
  private var artworkURL: String?
  private var handlers = RemoteCommandHandlers()

  public init() {}

  public func update(_ snapshot: NowPlayingInfo.Snapshot, artworkUri: String? = nil) {
    var info = NowPlayingInfo.build(from: snapshot)

    // Keep whatever artwork is already loaded rather than blanking it while a
    // new image is fetched — the lock screen flickering to grey between tracks
    // is worse than a stale cover for a moment.
    if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
      info[MPMediaItemPropertyArtwork] = existing
    }
    center.nowPlayingInfo = info

    // Stated, never inferred. This is the CarPlay bug.
    center.playbackState = snapshot.isPlaying ? .playing : .paused

    if let artworkUri, artworkUri != artworkURL {
      artworkURL = artworkUri
      loadArtwork(artworkUri)
    }
  }

  public func clear() {
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    artworkURL = nil
  }

  private func loadArtwork(_ uri: String) {
    // UIKit-only. The package also builds for macOS so the logic above can be
    // tested by `swift test` without an app, and cover art is the one part of
    // this that genuinely cannot come along.
    #if canImport(UIKit)
    guard let url = URL(string: uri) else { return }
    URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data,
            self.artworkURL == uri,             // a later track already won
            let image = UIImage(data: data) else { return }
      let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      DispatchQueue.main.async {
        var info = self.center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        self.center.nowPlayingInfo = info
      }
    }.resume()
    #endif
  }

  // MARK: - Remote commands

  public func setCommands(_ enabled: [RemoteCommand], handlers: RemoteCommandHandlers) {
    self.handlers = handlers
    // Targets accumulate: reconfiguring without removing the old ones means a
    // single press firing every handler ever registered.
    removeAllTargets()

    let wanted = Set(enabled)

    commands.playCommand.isEnabled = wanted.contains(.playPause)
    commands.pauseCommand.isEnabled = wanted.contains(.playPause)
    commands.togglePlayPauseCommand.isEnabled = wanted.contains(.playPause)
    commands.nextTrackCommand.isEnabled = wanted.contains(.next)
    commands.previousTrackCommand.isEnabled = wanted.contains(.previous)
    commands.changePlaybackPositionCommand.isEnabled = wanted.contains(.seek)
    commands.stopCommand.isEnabled = wanted.contains(.stop)

    commands.playCommand.addTarget { [weak self] _ in
      self?.handlers.play?(); return .success
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      self?.handlers.pause?(); return .success
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      // The car and the headphone button send this one rather than a specific
      // play or pause, so the engine's own state decides which it means.
      if self?.center.playbackState == .playing { self?.handlers.pause?() }
      else { self?.handlers.play?() }
      return .success
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in
      self?.handlers.next?(); return .success
    }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      self?.handlers.previous?(); return .success
    }
    commands.stopCommand.addTarget { [weak self] _ in
      self?.handlers.stop?(); return .success
    }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.handlers.seek?(event.positionTime)
      return .success
    }
  }

  private func removeAllTargets() {
    commands.playCommand.removeTarget(nil)
    commands.pauseCommand.removeTarget(nil)
    commands.togglePlayPauseCommand.removeTarget(nil)
    commands.nextTrackCommand.removeTarget(nil)
    commands.previousTrackCommand.removeTarget(nil)
    commands.stopCommand.removeTarget(nil)
    commands.changePlaybackPositionCommand.removeTarget(nil)
  }
}

/// Which remote controls to advertise.
public enum RemoteCommand: String, Hashable {
  case playPause
  case next
  case previous
  case seek
  case stop
}
