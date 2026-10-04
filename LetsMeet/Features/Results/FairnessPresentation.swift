//
//  FairnessPresentation.swift
//  LetsMeet
//

import Foundation

/// Pure decision logic for how the results list should communicate fair vs.
/// fallback restaurants. Derived entirely from the current restaurant list's
/// `fairnessDisplayStatus` (already stamped on every progressive snapshot and
/// on the final list) and whether the search is still running - no stored
/// counts, so it recomputes naturally as progressive snapshots replace the
/// list. Foundation-only so `Scripts/decision_logic_tests.swift` can compile
/// and run it directly.
enum FairnessPresentation {

    enum Notice: Equatable {
        /// Nothing to say: all fair, empty, or a zero-fair list that may
        /// still gain fair restaurants because the search is running.
        case none
        /// Some fair and some fallback restaurants: a divider goes
        /// immediately before the fallback restaurant at `beforeIndex`.
        case otherOptionsDivider(beforeIndex: Int)
        /// The search finished with fallback restaurants only: a message
        /// goes at the top of the list.
        case noEvenlyMatchedOptions
    }

    static func notice(for restaurants: [Restaurant], isSearching: Bool) -> Notice {
        let fairCount = restaurants.filter { $0.fairnessDisplayStatus == .fair }.count
        let firstFallbackIndex = restaurants.firstIndex { $0.fairnessDisplayStatus == .verifiedAdditional }

        guard let firstFallbackIndex else { return .none }

        if fairCount > 0 {
            return .otherOptionsDivider(beforeIndex: firstFallbackIndex)
        }
        // Zero fair so far. While searching, fair restaurants may still
        // arrive, so don't claim there are none.
        return isSearching ? .none : .noEvenlyMatchedOptions
    }

    static let otherOptionsTitle = "Other options"
    static let otherOptionsDetail = "Travel times may be less balanced."
    static let noEvenlyMatchedTitle = "No evenly matched options found"
    static let noEvenlyMatchedDetail = "These are the closest alternatives we found. Compare each person's drive time below."
}
