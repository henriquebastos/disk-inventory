import SwiftUI

/// What the outcome banner over the map shows. Plain values only, so the banner renders and
/// previews without a Rust session.
struct OutcomeBannerState: Equatable {
  /// A failed request: the red title, with the message in Details.
  let error: String?
  /// What an operation did, such as "Deleted. 2 items skipped."
  let outcome: String?
  /// The session issue log, all of it, also after a Dismiss of older issues.
  let issues: [String]
  /// The Details disclosure is open.
  var detailsShown = false
  var showsDetails: Bool { error != nil || !issues.isEmpty }
}

extension ExplorerModel {
  /// Nil while the banner is hidden: no error, no outcome and no issue after the last Dismiss.
  var outcomeBanner: OutcomeBannerState? {
    bannerVisible
      ? OutcomeBannerState(
        error: error, outcome: outcome, issues: issues, detailsShown: bannerDetailsShown) : nil
  }
}

/// Computes the banner state in its own body, so a new outcome redraws only the banner.
struct OutcomeBannerHost: View {
  let model: ExplorerModel
  var body: some View {
    if let banner = model.outcomeBanner {
      OutcomeBanner(
        state: banner, dismiss: { model.dismissBanner() },
        toggleDetails: { model.toggleBannerDetails() })
    }
  }
}

/// Errors, operation outcomes and issues, over the top of the map. It hit-tests only its own
/// frame and stays until Dismiss, a replacing outcome or a new folder.
struct OutcomeBanner: View {
  let state: OutcomeBannerState
  let dismiss: @MainActor () -> Void
  /// Opens or closes Details, from the chevron or the word.
  let toggleDetails: @MainActor () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if state.error != nil {
        Text("Could not complete the request.").font(.callout.weight(.semibold))
          .foregroundStyle(.red).accessibilityIdentifier("error")
      }
      if let outcome = state.outcome {
        Text(outcome).font(.callout).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("outcome")
      }
      if state.showsDetails {
        DisclosureGroup(
          isExpanded: Binding(
            get: { state.detailsShown },
            set: { if $0 != state.detailsShown { toggleDetails() } })
        ) {
          ScrollView {
            if let error = state.error {
              Text(error).textSelection(.enabled).accessibilityIdentifier("error-details")
            }
            Text(state.issues.joined(separator: "\n")).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 100)
        } label: {
          // The word is a larger target than the chevron alone, with the same action.
          Button("Details") { toggleDetails() }.buttonStyle(.plain)
        }.font(.caption).accessibilityIdentifier("issues")
      }
      HStack {
        Spacer()
        Button("Dismiss") { dismiss() }.accessibilityIdentifier("dismiss-banner")
      }.controlSize(.small)
    }
    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: 440, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    .padding(.top, 20).padding(.horizontal, 20)
    .accessibilityElement(children: .contain).accessibilityIdentifier("outcome-banner")
  }
}

#Preview("Outcome") {
  OutcomeBanner(
    state: OutcomeBannerState(error: nil, outcome: "Moved to Trash.", issues: []),
    dismiss: {}, toggleDetails: {}
  )
  .frame(width: 600, height: 300, alignment: .top)
}
#Preview("Outcome with skips, Details open") {
  OutcomeBanner(
    state: OutcomeBannerState(
      error: nil, outcome: "Deleted. 2 items skipped.",
      issues: ["Skipped locked: permission denied", "Skipped busy: resource busy"],
      detailsShown: true),
    dismiss: {}, toggleDetails: {}
  )
  .frame(width: 600, height: 300, alignment: .top)
}
#Preview("Error") {
  OutcomeBanner(
    state: OutcomeBannerState(
      error: "Refresh failed: the folder is no longer available.", outcome: nil, issues: []),
    dismiss: {}, toggleDetails: {}
  )
  .frame(width: 600, height: 300, alignment: .top)
}
