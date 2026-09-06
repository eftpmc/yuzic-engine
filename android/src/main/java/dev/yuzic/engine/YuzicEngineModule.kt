package dev.yuzic.engine

import android.content.ComponentName
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record

/**
 * The Expo module surface — the thin part. Everything of substance lives in
 * [AudioGraph], [PlaybackQueue] and [PlaybackService]; this file only translates.
 *
 * Expo Modules rather than Nitro because nothing high-frequency crosses this
 * bridge: audio never does, commands are rare, and progress is emitted about
 * once a second. What is large is the *integration* surface — background audio
 * mode, the CarPlay entitlement and scene, the Android foreground service and
 * notification channel — and that is config-plugin work, which is where the
 * Expo Modules API is markedly better. See docs/architecture.md.
 *
 * Function names, argument shapes and event names are the same strings as
 * `ios/YuzicEngineModule.swift`. They are the contract `src/AudioEngine.ts`
 * describes, and a divergence here is a platform-specific bug in the host, which
 * is the worst kind to find.
 */
@UnstableApi
class YuzicEngineModule : Module() {

  private val queue get() = PlaybackService.queue
  private var controllerFuture: ListenableFuture<MediaController>? = null

  override fun definition() = ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { options: SetupOptions? ->
      configureAudioSession(options?.pauseOnBecomingNoisy ?: true)
      PlaybackService.eventSink = { name, body -> sendEvent(name, body) }
    }

    AsyncFunction("teardown") {
      // The sink goes first. Between here and the service actually stopping,
      // the session may still fire — and sending an event into a JS context
      // that is being torn down is a crash rather than a no-op.
      PlaybackService.eventSink = null
      controllerFuture?.let { MediaController.releaseFuture(it) }
      controllerFuture = null
      TrackHeaders.clear()
    }

    // MARK: queue
    //
    // The queue lives here, natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the notification still
    // has to update, and the car still has to answer its buttons.

    AsyncFunction("setQueue") { tracks: List<TrackRecord>, startIndex: Int? ->
      queue.set(tracks, startIndex ?: 0)
      tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
      pushQueueToPlayer()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    AsyncFunction("append") { tracks: List<TrackRecord> ->
      queue.append(tracks)
      tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
      pushQueueToPlayer()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    AsyncFunction("getActiveIndex") {
      queue.activeIndex
    }

    // MARK: transport

    AsyncFunction("play") { PlaybackService.graph?.activeVoice?.player?.play() }
    AsyncFunction("pause") { PlaybackService.graph?.activeVoice?.player?.pause() }

    // MARK: the reasons this exists

    AsyncFunction("setEqualizer") { bands: List<EqBandRecord> ->
      PlaybackService.graph?.setEqualizer(
        bands.map {
          AudioGraph.Band(
            frequencyHz = it.frequencyHz.toFloat(),
            gainDb = it.gainDb.toFloat(),
            q = (it.q ?: 1.0).toFloat(),
          )
        }
      )
    }

    AsyncFunction("setCrossfade") { options: CrossfadeRecord? ->
      queue.crossfade = options
    }

    AsyncFunction("setSampleRateMode") { mode: String ->
      // Enforced rather than merely recorded: overlapping sources have to share
      // a rate, so matching the source and crossfading are mutually exclusive.
      // The engine resolves the contradiction instead of leaving two settings
      // to fight, and tells the host it did.
      //
      // Android reaches the same conclusion by a different route than iOS. There
      // is no `setPreferredSampleRate` here, so nothing stops the engine
      // mechanically — but honouring the source rate means letting one
      // AudioTrack dictate the output configuration, and the second voice would
      // be resampled into it silently, which is exactly the thing the mode is
      // asked for to avoid. Refusing is more honest than pretending.
      if (mode == "match-source" && queue.crossfade != null) {
        queue.crossfade = null
        sendEvent(
          "onError",
          mapOf(
            "code" to "CROSSFADE_DISABLED",
            "message" to "Crossfade turned off: matching the source sample rate cannot overlap two tracks.",
          ),
        )
      }
      queue.sampleRateMode = mode
    }

    // MARK: platform surfaces
    //
    // These two have no counterpart in ios/YuzicEngineModule.swift yet — it is a
    // partial file and stops before them. They are declared here anyway because
    // [PlaybackService] has no other way to be handed a browse tree, and a
    // MediaLibraryService with no root is invisible in the car. Names and
    // argument shapes are taken from `src/AudioEngine.ts` so that the iOS
    // implementations, when they land, have nothing to negotiate.

    AsyncFunction("setBrowseTree") { root: BrowseNodeRecord ->
      PlaybackService.browseRoot = root
    }

    AsyncFunction("setCommands") { commands: List<String> ->
      PlaybackService.enabledCommands = commands.toSet()
      // Deliberately not re-issued to already-connected controllers. Media3 asks
      // for the command set once, at connect; a car that is already connected
      // keeps the set it was given until it reconnects. Forcing a reconnect to
      // apply a new set would drop the notification mid-track, which is a worse
      // trade than a stale button.
    }
  }

  /**
   * The Android counterpart to claiming the audio session.
   *
   * There is no session to claim — focus is requested per playback by the
   * `AudioAttributes` the service sets — so what this actually does is start
   * the service. Connecting a `MediaController` is the sanctioned way: it binds
   * the service, which is what makes it survivable, and Media3 promotes it to
   * the foreground itself once something is playing. Calling
   * `startForegroundService` directly instead is the usual route to an
   * `ForegroundServiceDidNotStartInTimeException`.
   *
   * `pauseOnBecomingNoisy` is honoured on the players rather than here; it is
   * passed down so the two platforms take the same argument even though Android
   * spends it in a different place.
   */
  private fun configureAudioSession(pauseOnBecomingNoisy: Boolean) {
    val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()
    PlaybackService.graph?.let { graph ->
      graph.voiceA.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
      graph.voiceB.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
    }

    // Idempotent, as the contract in src/AudioEngine.ts requires: a second call
    // reconfigures rather than restarting, because tearing the session down
    // mid-playback is audible.
    if (controllerFuture != null) return

    val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
    controllerFuture = MediaController.Builder(context, token).buildAsync()
  }

  /**
   * Hand the queue to the foreground voice.
   *
   * Only the foreground one. The idle voice is loaded with a single item during
   * the preload window and exists to overlap, so giving it the whole timeline
   * would have it advancing through the queue in parallel — two playheads on the
   * same list, which is not what the pair is for.
   */
  private fun pushQueueToPlayer() {
    val graph = PlaybackService.graph ?: return
    val player = graph.activeVoice.player
    player.setMediaItems(queue.tracks.map { it.toMediaItem() }, queue.activeIndex, 0L)
    player.prepare()
  }
}

// MARK: - Records
//
// Shapes crossing the bridge. Kept flat and optional-tolerant: a host that
// omits a field means "no information", which is not the same as a zero — the
// replay-gain pair is exactly that distinction.
//
// These mirror the `Record` structs at the bottom of ios/YuzicEngineModule.swift
// field for field. Where Swift can say `Double?` and mean absent, Kotlin says
// `Double?` too, and neither is allowed to quietly default to 0.

class SetupOptions : Record {
  @Field var progressIntervalMs: Int = 1000
  @Field var pauseOnBecomingNoisy: Boolean = true
}

class TrackRecord : Record {
  @Field var id: String = ""
  @Field var uri: String = ""
  @Field var title: String = ""
  @Field var artist: String? = null
  @Field var album: String? = null
  @Field var artworkUri: String? = null
  @Field var durationSec: Double? = null
  @Field var headers: Map<String, String>? = null
  @Field var followsPrevious: Boolean = false
  @Field var replayGainDb: Double? = null
  @Field var replayGainPeak: Double? = null
  @Field var continuous: Boolean = false
}

class EqBandRecord : Record {
  @Field var frequencyHz: Double = 0.0
  @Field var gainDb: Double = 0.0
  @Field var q: Double? = null
}

class CrossfadeRecord : Record {
  @Field var durationSec: Double = 0.0
  @Field var mode: String = "gapless-aware"
  @Field var skipIsImmediate: Boolean = true
}

/**
 * A node of the browse tree. Recursive, which Expo's record converter handles,
 * and which the iOS side does not yet declare — the tree arrives whole either
 * way, so the shape is dictated by `BrowseNode` in src/types.ts rather than by
 * either platform.
 */
class BrowseNodeRecord : Record {
  @Field var id: String = ""
  @Field var title: String = ""
  @Field var subtitle: String? = null
  @Field var artworkUri: String? = null
  @Field var children: List<BrowseNodeRecord>? = null
  @Field var playable: TrackRecord? = null
}

/**
 * A track as Media3 sees it.
 *
 * The cache key is the host's `MediaId`, not the URI. Subsonic and Jellyfin both
 * hand out URLs carrying a token that rotates, so keying the cache on the URI
 * would re-download the same audio every session and the LRU would fill with
 * duplicates of one album.
 */
@UnstableApi
fun TrackRecord.toMediaItem(): MediaItem = MediaItem.Builder()
  .setMediaId(id)
  .setUri(Uri.parse(uri))
  .setCustomCacheKey(id)
  .setMediaMetadata(
    MediaMetadata.Builder()
      .setTitle(title)
      .setArtist(artist)
      .setAlbumTitle(album)
      .setArtworkUri(artworkUri?.let { Uri.parse(it) })
      .setIsBrowsable(false)
      .setIsPlayable(true)
      .build()
  )
  .build()
