import AlloyCore
import Foundation
import MetalUI

/// The pane after a replace: the summary, Keep All / Revert All and one row per file with its diff count and outcome.
struct SearchReviewList: Component {
    let workspace: Workspace
    let review: ReplaceReview

    static func outcome(_ row: ReviewRow) -> String {
        switch row.state {
        case .applied: return row.diffCount == 1 ? "1 change" : "\(row.diffCount) changes"
        case .skipped(let reason): return "skipped: \(reason)"
        case .kept: return "kept"
        case .reverted: return "reverted"
        case .conflict(let reason): return "kept: \(reason)"
        }
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("SearchReviewList")
        let model = workspace.search
        let review = review
        VStack(alignment: .leading, spacing: Pixels(4)) {
            Text(verbatim: review.summary).font(size: searchFontSize).foregroundColor(.mutedInk)
                .accessibilityIdentifier("search-summary")
            HStack(spacing: Pixels(6)) {
                Button("Keep All") { model.keepAll() }
                    .disabled(!review.isOpen || model.isReplacing)
                    .accessibilityIdentifier("search-review-keep-all")
                Button("Revert All") { model.revertAll() }
                    .disabled(!review.isOpen || model.isReplacing)
                    .accessibilityIdentifier("search-review-revert-all")
                Button("Done") { model.dismissReview() }
                    .accessibilityIdentifier("search-review-done")
            }
            ProposalScrollView {
                List {
                    ForEach(Array(review.rows.enumerated()), id: \.element.path) { position, row in
                        HStack(spacing: searchRowGap) {
                            Text(verbatim: row.name).font(size: searchFontSize).lineLimit(1)
                            Text(verbatim: row.folder).font(size: searchFontSize).foregroundColor(.mutedInk).lineLimit(1)
                            Spacer()
                            Text(verbatim: Self.outcome(row)).font(size: searchFontSize).foregroundColor(.mutedInk).lineLimit(1)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("search-review-file-\(position)")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-review")
    }
}
