//
//  FriendAddressRules.swift
//  LetsMeet
//

import Foundation

/// Deterministic rules for turning what the user typed into a trusted friend
/// location. Plain strings only (no MapKit/CoreLocation types), so they can be
/// compiled and exercised directly by `Scripts/friend_address_rules_tests.swift`.
///
/// The matching here is deliberately conservative and exact: no fuzzy
/// matching, no typo tolerance. A false negative just falls through to the
/// manual confirmation; a false positive would silently pick the wrong
/// address, which is the one outcome these rules must not produce.
enum FriendAddressRules {

    // MARK: - Matching typed text against autocomplete rows

    /// Lowercased, diacritic-folded, whitespace-collapsed, with comma-separated
    /// components trimmed and empty ones dropped, and no trailing periods or
    /// spaces. Nothing else - words are never reordered, dropped or corrected.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let components = folded
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var joined = components.joined(separator: ", ")
        while let last = joined.last, last == "." || last == " " {
            joined.removeLast()
        }
        return joined
    }

    /// True when the typed text clearly refers to this suggestion: it equals
    /// the suggestion's title, or it equals the full "title, subtitle" text,
    /// or it is a prefix of that full text ending on a comma boundary (so
    /// "100 Main St, San Francisco" matches "100 Main St, San Francisco, CA"
    /// but "100 Main St, San" matches nothing).
    static func suggestionMatches(typed: String, title: String, subtitle: String) -> Bool {
        let typed = normalize(typed)
        guard !typed.isEmpty else { return false }

        if typed == normalize(title) { return true }

        let full = normalize(subtitle.isEmpty ? title : "\(title), \(subtitle)")
        return full == typed || full.hasPrefix(typed + ", ")
    }

    // MARK: - Manual geocoder results

    /// A result only counts as a friend's starting location if the geocoder
    /// resolved it to a street. City-, ZIP- and region-level results (like the
    /// bare "99999" ZIP that arbitrary text can resolve to) have no
    /// thoroughfare.
    static func isStreetLevel(thoroughfare: String?) -> Bool {
        nonEmpty(thoroughfare) != nil
    }

    // MARK: - Address text

    /// "123 Main St"
    static func streetLine(subThoroughfare: String?, thoroughfare: String?) -> String {
        [subThoroughfare, thoroughfare].compactMap(nonEmpty).joined(separator: " ")
    }

    /// "San Francisco, CA"
    static func cityState(locality: String?, administrativeArea: String?) -> String {
        [locality, administrativeArea].compactMap(nonEmpty).joined(separator: ", ")
    }

    /// "San Francisco, CA 94110", with the country appended only when it
    /// differs from the device's region (an unknown device region counts as
    /// different, so the country is shown rather than hidden).
    static func confirmationRegion(
        locality: String?,
        administrativeArea: String?,
        postalCode: String?,
        countryName: String?,
        isoCountryCode: String?,
        deviceRegionCode: String?
    ) -> String {
        let stateAndPostal = [administrativeArea, postalCode].compactMap(nonEmpty).joined(separator: " ")
        var parts = [nonEmpty(locality), nonEmpty(stateAndPostal)].compactMap { $0 }

        if let country = nonEmpty(countryName), let iso = nonEmpty(isoCountryCode) {
            let isDeviceRegion = deviceRegionCode.map { $0.caseInsensitiveCompare(iso) == .orderedSame } ?? false
            if !isDeviceRegion { parts.append(country) }
        }
        return parts.joined(separator: ", ")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
