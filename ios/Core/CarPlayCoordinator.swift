import Foundation

/**
 The handover point between the engine and the car.

 A singleton, which is not a choice so much as an admission: CarPlay hands the
 app a scene delegate it constructs itself, at a moment the app does not choose,
 and there is nowhere to inject anything. The delegate has to find the tree and
 the play callback from somewhere global.

 Everything the car needs lives here so it is available even when the app's
 JavaScript is suspended — which it usually is. Someone starts driving, the
 phone connects, the car asks for a root list, and there is no JS runtime awake
 to build one. A tree pushed down in advance is a tree that is there.
 */
public final class CarPlayCoordinator {

  public static let shared = CarPlayCoordinator()

  private let lock = NSLock()
  private var rootValue: BrowseNode?
  private var onPlayValue: (([Track], Int) -> Void)?
  private var onRootChangeValue: (() -> Void)?

  private init() {}

  public var root: BrowseNode? {
    lock.lock(); defer { lock.unlock() }
    return rootValue
  }

  /// Replace the tree. Notifies the scene, if one is connected, so a library
  /// that finishes loading after the car connects still shows up rather than
  /// leaving an empty list until the driver backs out and re-enters.
  public func setRoot(_ node: BrowseNode?) {
    lock.lock()
    rootValue = node
    let notify = onRootChangeValue
    lock.unlock()
    DispatchQueue.main.async { notify?() }
  }

  public func setPlayHandler(_ handler: (([Track], Int) -> Void)?) {
    lock.lock(); onPlayValue = handler; lock.unlock()
  }

  public func setRootChangeHandler(_ handler: (() -> Void)?) {
    lock.lock(); onRootChangeValue = handler; lock.unlock()
  }

  /// What a selection in the car means: play everything under the chosen node,
  /// starting at the chosen one.
  public func select(_ id: String) {
    lock.lock()
    let root = rootValue
    let play = onPlayValue
    lock.unlock()

    guard let root, let node = BrowseTree.find(id, in: root) else { return }

    if node.playable != nil, let path = BrowseTree.path(to: id, in: root), path.count >= 2 {
      // A track chosen inside an album should queue the album and start there,
      // not play one track and stop. The parent is the context the driver
      // thinks they are in.
      let parent = path[path.count - 2]
      let tracks = BrowseTree.tracks(under: parent)
      let index = tracks.firstIndex { $0.id == node.playable?.id } ?? 0
      play?(tracks, index)
      return
    }

    let tracks = BrowseTree.tracks(under: node)
    if !tracks.isEmpty { play?(tracks, 0) }
  }
}
