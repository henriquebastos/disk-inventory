import AppKit
import Observation

struct RemovalMotionPlan {
  enum Style: String { case poof, travel, fade }
  let style: Style
  let source: Rectangle
  let destination: Rectangle?

  static func make(
    mutation: MutationOutcome, scope: TrashScope?, source: Rectangle?,
    rootPath: Data, visibleTargets: [DiagramSelection], reduceMotion: Bool
  ) -> RemovalMotionPlan? {
    guard let source else { return nil }
    switch mutation {
    case .removed:
      return RemovalMotionPlan(
        style: reduceMotion ? .fade : .poof, source: source, destination: nil)
    case .trashed(let destination):
      var visible: Rectangle?
      if case .inside(let relativePath) = scope {
        var absolute = rootPath
        if absolute.last != 47 { absolute.append(47) }
        absolute.append(relativePath)
        if absolute == destination {
          visible = visibleTargets.first { $0.actionable && $0.relativePath == relativePath }?.rect
        }
      }
      return RemovalMotionPlan(
        style: reduceMotion ? .fade : (visible == nil ? .poof : .travel),
        source: source, destination: visible)
    case .failed, .partial, .indeterminate: return nil
    }
  }
}

// One previous bounded bitmap, one affected rectangle and a 200 ms clock; no tile animation graph.
@MainActor @Observable final class ResultMotion {
  private(set) var previous: DiagramPicture?
  private(set) var plan: RemovalMotionPlan?
  private(set) var fraction = 0.0
  /// Style and clock ticks of the most recent motion that started; fixture UI tests read them.
  private(set) var lastStyle: RemovalMotionPlan.Style?
  private(set) var lastTicks = 0
  private var version = 0
  var active: Bool { previous != nil }
  func cancel() {
    version += 1
    previous = nil
    plan = nil
    fraction = 0
  }
  func hold(_ picture: DiagramPicture) {
    cancel()
    previous = picture
  }
  func play(previous: DiagramPicture, plan: RemovalMotionPlan) async {
    cancel()
    let generation = version
    self.previous = previous
    self.plan = plan
    lastStyle = plan.style
    lastTicks = 0
    let start = ContinuousClock.now
    while generation == version {
      lastTicks += 1
      let elapsed = start.duration(to: .now)
      fraction = min(
        1, Double(elapsed.components.seconds) * 5 + Double(elapsed.components.attoseconds) / 2e17)
      if fraction >= 1 { break }
      try? await Task.sleep(for: .milliseconds(16))
      if Task.isCancelled { break }
    }
    if generation == version { cancel() }
  }
}
