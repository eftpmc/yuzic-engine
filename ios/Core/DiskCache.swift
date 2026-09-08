import Foundation

/**
 Audio kept on disk between tracks, and between launches.

 Everything cached before this was per-track and in memory: a `CachedByteSource`
 held the ranges it had fetched for as long as the track was playing, and they
 went when it did. Replaying a track re-downloaded it, and an "offline
 download" had nowhere to live. This is the store those become possible on.

 **Keyed by the host's `MediaId`, never by URL.** Subsonic and Jellyfin both
 hand out stream URLs carrying a token that rotates, so a URL key would miss on
 every session and fill the cache with duplicates of the same album. The
 Android side already keys its Media3 cache this way and says so; this is the
 same decision on the same reasoning.

 **Entries are sparse, and honest about it.** A track played halfway is
 half-fetched, and the ranges that arrived are worth keeping — but a file with
 holes cannot say which parts are real, so each entry carries a sidecar
 recording exactly what it holds. Without that, resuming would either
 re-download everything or serve silence out of a hole, and the second is worse
 because it sounds like a corrupt file.

 **Eviction takes whole entries.** Freeing space by dropping *ranges* would
 leave files that are technically valid and practically useless — a track with
 its middle removed still costs a request per gap. Least-recently-used, whole
 entries, until the budget is met.

 Not thread-safe by itself; `CachedByteSource` serialises access to a given
 entry, and the lock here covers the index the two share.
 */
public final class DiskCache {

  public struct Stats: Equatable {
    public let usedBytes: Int64
    public let maxBytes: Int64
    public let entryCount: Int
  }

  /// What one cached track knows about itself.
  struct Entry: Codable {
    var totalBytes: Int64
    /// Present ranges, as flat pairs — `ByteRangeSet` is not `Codable` and
    /// giving it a persistence format would tie an in-memory type to a file on
    /// disk that has to survive a version of the app it has never met.
    var ranges: [Int64]
    var lastUsed: Double

    var byteCount: Int64 { present.totalBytes }

    /// The flat pairs, back as the set the rest of the engine speaks in.
    var present: ByteRangeSet {
      var set = ByteRangeSet()
      for pair in stride(from: 0, to: ranges.count - 1, by: 2) {
        set.insert(ranges[pair]..<ranges[pair + 1])
      }
      return set
    }

    mutating func setPresent(_ set: ByteRangeSet) {
      ranges = set.ranges.flatMap { [$0.lowerBound, $0.upperBound] }
    }
  }

  public static let defaultMaxBytes: Int64 = 1_024 * 1_024 * 1_024

  private let directory: URL
  private let lock = NSLock()
  private var index: [MediaId: Entry] = [:]
  public private(set) var maxBytes: Int64

  public init(directory: URL, maxBytes: Int64 = DiskCache.defaultMaxBytes) throws {
    self.directory = directory
    self.maxBytes = maxBytes
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    loadIndex()
  }

  // MARK: - The contract src/AudioEngine.ts describes

  public func configure(maxBytes: Int64) {
    lock.lock()
    self.maxBytes = max(0, maxBytes)
    lock.unlock()
    evictIfNeeded()
  }

  public func stats() -> Stats {
    lock.lock(); defer { lock.unlock() }
    return Stats(
      usedBytes: index.values.reduce(0) { $0 + $1.byteCount },
      maxBytes: maxBytes,
      entryCount: index.count
    )
  }

  /// Drop one track. Used when a download is deleted, where leaving the audio
  /// behind would mean the app says it freed space and did not.
  public func evict(_ id: MediaId) {
    lock.lock()
    index[id] = nil
    lock.unlock()
    try? FileManager.default.removeItem(at: dataURL(id))
    try? FileManager.default.removeItem(at: metaURL(id))
  }

  public func clear() {
    lock.lock()
    let ids = Array(index.keys)
    index.removeAll()
    lock.unlock()
    for id in ids {
      try? FileManager.default.removeItem(at: dataURL(id))
      try? FileManager.default.removeItem(at: metaURL(id))
    }
  }

  // MARK: - Reading and writing ranges

  /// What this entry holds, or nil if it holds nothing.
  public func ranges(for id: MediaId) -> (total: Int64, present: ByteRangeSet)? {
    lock.lock(); defer { lock.unlock() }
    guard let entry = index[id] else { return nil }
    return (entry.totalBytes, entry.present)
  }

  /**
   Read what is on disk for `range`, or nil when any of it is missing.

   All-or-nothing on purpose: a partial answer would have to describe which
   part, and every caller would then have to handle a case that the fetcher
   above already handles better by simply asking for what it lacks.
   */
  public func read(_ id: MediaId, range: Range<Int64>) -> Data? {
    lock.lock()
    guard var entry = index[id] else { lock.unlock(); return nil }
    guard entry.present.firstGap(from: range.lowerBound, limit: range.upperBound) == nil else {
      lock.unlock(); return nil
    }
    entry.lastUsed = Date().timeIntervalSince1970
    index[id] = entry
    lock.unlock()

    guard let handle = try? FileHandle(forReadingFrom: dataURL(id)) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(range.lowerBound))
    let wanted = Int(range.upperBound - range.lowerBound)
    let data = try? handle.read(upToCount: wanted)
    // A short read means the file and the index disagree, which is a corrupt
    // entry rather than a miss — drop it so the next attempt refetches.
    guard let data, data.count == wanted else { evict(id); return nil }
    return data
  }

  /// Store bytes at `offset`, growing the file as needed.
  public func write(_ id: MediaId, offset: Int64, data: Data, totalBytes: Int64) {
    guard !data.isEmpty else { return }
    let url = dataURL(id)
    let manager = FileManager.default

    if !manager.fileExists(atPath: url.path) {
      manager.createFile(atPath: url.path, contents: nil)
      // Sparse: the file is declared full-size up front and the holes cost
      // nothing until written. Growing it per range instead would rewrite the
      // tail every time a gap earlier on was filled.
      if let handle = try? FileHandle(forWritingTo: url) {
        try? handle.truncate(atOffset: UInt64(max(0, totalBytes)))
        try? handle.close()
      }
    }

    /*
     Every step checked, because the index is a claim about the file.

     These were four `try?`s in a row, and the last of them mattered: the file
     is truncated to full size up front, so a write that fails — a full disk,
     which is the ordinary way this fails on a phone — leaves a correctly-sized
     region of *zeros* where the index then records bytes as present. `read`
     only rejects a short read, not a zeroed one, so the parser is later handed
     silence and the entry survives an app restart. The track is broken until
     something evicts it, and it looks like a corrupt library rather than a
     disk that filled up.

     A cache is allowed to fail to store something. It is not allowed to
     remember storing something it did not.
    */
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    do {
      try handle.seek(toOffset: UInt64(offset))
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      return
    }

    lock.lock()
    var entry = index[id] ?? Entry(totalBytes: totalBytes, ranges: [], lastUsed: 0)
    entry.totalBytes = totalBytes
    var present = entry.present
    present.insert(offset..<(offset + Int64(data.count)))
    entry.setPresent(present)
    entry.lastUsed = Date().timeIntervalSince1970
    index[id] = entry
    lock.unlock()

    persist(id)
    evictIfNeeded()
  }

  // MARK: - Eviction

  private func evictIfNeeded() {
    lock.lock()
    var used = index.values.reduce(Int64(0)) { $0 + $1.byteCount }
    guard used > maxBytes else { lock.unlock(); return }
    // Oldest first. Ties broken by id so eviction is deterministic, which
    // matters only for the tests but costs nothing here.
    let victims = index.sorted {
      $0.value.lastUsed == $1.value.lastUsed ? $0.key < $1.key : $0.value.lastUsed < $1.value.lastUsed
    }
    var dropped: [MediaId] = []
    for (id, entry) in victims {
      guard used > maxBytes else { break }
      used -= entry.byteCount
      index[id] = nil
      dropped.append(id)
    }
    lock.unlock()

    for id in dropped {
      try? FileManager.default.removeItem(at: dataURL(id))
      try? FileManager.default.removeItem(at: metaURL(id))
    }
  }

  // MARK: - On-disk layout

  // Ids come from a server and can contain anything; a percent-encoded name
  // keeps one from escaping the directory or colliding with a sidecar.
  private func safeName(_ id: MediaId) -> String {
    id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(id.hashValue)
  }

  private func dataURL(_ id: MediaId) -> URL { directory.appendingPathComponent(safeName(id) + ".audio") }
  private func metaURL(_ id: MediaId) -> URL { directory.appendingPathComponent(safeName(id) + ".json") }

  private func persist(_ id: MediaId) {
    lock.lock(); let entry = index[id]; lock.unlock()
    guard let entry, let data = try? JSONEncoder().encode(entry) else { return }
    try? data.write(to: metaURL(id))
  }

  private func loadIndex() {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names where name.hasSuffix(".json") {
      let url = directory.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url),
            let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
      let encoded = String(name.dropLast(".json".count))
      guard let id = encoded.removingPercentEncoding else { continue }
      // Only trust a sidecar whose audio is still there. A half-deleted pair
      // would otherwise report bytes that cannot be read.
      guard manager.fileExists(atPath: dataURL(id).path) else {
        try? manager.removeItem(at: url)
        continue
      }
      index[id] = entry
    }
  }
}
