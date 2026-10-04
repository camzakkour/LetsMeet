//
// Deterministic tests for FriendAddressRules - the pure rules that decide
// whether typed friend-address text clearly corresponds to an autocomplete
// suggestion, whether a manual geocoder result is street-level, and how the
// manual confirmation text is formatted. No MapKit, no network: every input is
// a plain string, and the tests run against the real production source file
// (not a copy).
//
// This is a standalone script, NOT part of the LetsMeet Xcode target (see
// decision_logic_tests.swift for why: no XCTest target exists, and top-level
// statements would conflict with the app's entry point). It only needs
// Foundation, so it runs directly on macOS (staged as literally "main.swift"
// so top-level code is allowed):
//   cp Scripts/friend_address_rules_tests.swift /tmp/main.swift && \
//   swiftc -o /tmp/friend_address_rules_tests \
//     LetsMeet/Features/Home/FriendAddressRules.swift \
//     /tmp/main.swift \
//     && /tmp/friend_address_rules_tests

import Foundation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  PASS  \(label)")
    } else {
        print("  FAIL  \(label): expected \(expected), got \(actual)")
        failures += 1
    }
}

typealias Row = (title: String, subtitle: String)

/// How many of `rows` clearly correspond to `typed` (0 / 1 / many drives the
/// app's decision).
func matchCount(_ typed: String, _ rows: [Row]) -> Int {
    rows.filter { FriendAddressRules.suggestionMatches(typed: typed, title: $0.title, subtitle: $0.subtitle) }.count
}

let mainStreets: [Row] = [
    ("100 Main St", "San Francisco, CA"),
    ("100 Main St", "Los Altos, CA"),
    ("100 Main St", "Pleasanton, CA"),
]

// MARK: - 1. normalize()
do {
    print("1. normalize()")
    expect(FriendAddressRules.normalize("  100   Main  St  "), "100 main st", "trims, collapses whitespace, lowercases")
    expect(FriendAddressRules.normalize("100 Main St,"), "100 main st", "trailing comma dropped")
    expect(FriendAddressRules.normalize("100 Main St."), "100 main st", "trailing period dropped")
    expect(FriendAddressRules.normalize("100 Main St ,San Francisco"), "100 main st, san francisco", "comma spacing normalized")
    expect(FriendAddressRules.normalize("100 Main St,, San Francisco"), "100 main st, san francisco", "empty comma component dropped")
    expect(FriendAddressRules.normalize("São Paulo"), "sao paulo", "diacritics folded")
    expect(FriendAddressRules.normalize("   "), "", "whitespace only -> empty")
    expect(FriendAddressRules.normalize("St. Louis"), "st. louis", "inner periods are kept")
    expect(FriendAddressRules.normalize("Main St 100"), "main st 100", "word order is never changed")
}

// MARK: - 2. suggestionMatches(): zero / one / many
do {
    print("2. suggestionMatches() - zero / one / many")
    expect(matchCount("100 Main St", mainStreets), 3, "bare '100 Main St' matches every same-title row -> many")
    expect(matchCount("100 main st", mainStreets), 3, "case-insensitive")
    expect(matchCount("  100  Main   St, ", mainStreets), 3, "spacing and trailing comma variants")
    expect(matchCount("100 Main St, San Francisco", mainStreets), 1, "city-qualified text -> exactly one")
    expect(matchCount("100 Main St, San Francisco, CA", mainStreets), 1, "city and state -> exactly one")
    expect(matchCount("100 Main St, Los Altos, CA", mainStreets), 1, "another city -> exactly one")
    expect(matchCount("100 Main St, San", mainStreets), 0, "partial city word (not a comma boundary) -> zero")
    expect(matchCount("100 Main St, Oakland", mainStreets), 0, "city not among the rows -> zero")
    expect(matchCount("100 Main", mainStreets), 0, "shortened street -> zero (no fuzzy matching)")
    expect(matchCount("100 Main Street", mainStreets), 0, "'Street' vs 'St' -> zero (no abbreviation matching)")
    expect(matchCount("101 Main St", mainStreets), 0, "different number -> zero")
    expect(matchCount("Main St", mainStreets), 0, "missing number -> zero")
    expect(matchCount("100 Main St, San Francisco, CA, United States", [("100 Main St", "San Francisco, CA, United States")]), 1, "full title+subtitle text -> one")
    expect(matchCount("", mainStreets), 0, "empty text -> zero")
    expect(matchCount("100 Main St", []), 0, "no rows -> zero")
}

// MARK: - 3. suggestionMatches(): single-row cases
do {
    print("3. suggestionMatches() - single rows")
    let one: [Row] = [("1 Infinite Loop", "Cupertino, CA")]
    expect(matchCount("1 Infinite Loop", one), 1, "title only -> one")
    expect(matchCount("1 Infinite Loop, Cupertino", one), 1, "title + city -> one")
    expect(matchCount("1 Infinite Loop, Cupertino, CA", one), 1, "title + city + state -> one")
    expect(matchCount("1 Infinite Loop, Cupertino, CA, USA", one), 0, "text longer than the row -> zero")
    expect(matchCount("1 Infinite Loo", one), 0, "truncated title -> zero")
    expect(matchCount("São Paulo", [("Sao Paulo", "Brazil")]), 1, "diacritic-insensitive match")
    expect(matchCount("Sao Paulo", [("São Paulo", "Brazil")]), 1, "diacritic-insensitive match (reverse)")
    expect(matchCount("Starbucks", [("Starbucks", "Search Nearby")]), 1, "title match works for any row kind")
    expect(matchCount("Main St", [("100 Main St", "San Francisco, CA")]), 0, "typed text that is only a suffix of the title -> zero")
    expect(matchCount("Main St 100", [("100 Main St", "San Francisco, CA")]), 0, "reordered words -> zero")
    expect(matchCount("100 Main St, San Francisco", [("100 Main St", "")]), 0, "empty subtitle: city text does not match a bare title row")
    expect(matchCount("100 Main St", [("100 Main St", "")]), 1, "empty subtitle: title still matches")
}

// MARK: - 4. isStreetLevel()
do {
    print("4. isStreetLevel()")
    expect(FriendAddressRules.isStreetLevel(thoroughfare: "Main St"), true, "thoroughfare present -> street level")
    expect(FriendAddressRules.isStreetLevel(thoroughfare: nil), false, "nil thoroughfare (ZIP/city result) -> not street level")
    expect(FriendAddressRules.isStreetLevel(thoroughfare: ""), false, "empty thoroughfare -> not street level")
    expect(FriendAddressRules.isStreetLevel(thoroughfare: "   "), false, "whitespace thoroughfare -> not street level")
}

// MARK: - 5. Address text and confirmation formatting
do {
    print("5. streetLine() / cityState() / confirmationRegion()")
    expect(FriendAddressRules.streetLine(subThoroughfare: "123", thoroughfare: "Main St"), "123 Main St", "street line with number")
    expect(FriendAddressRules.streetLine(subThoroughfare: nil, thoroughfare: "Main St"), "Main St", "street line without number")
    expect(FriendAddressRules.streetLine(subThoroughfare: "", thoroughfare: "Main St"), "Main St", "empty number ignored")
    expect(FriendAddressRules.cityState(locality: "San Francisco", administrativeArea: "CA"), "San Francisco, CA", "city and state")
    expect(FriendAddressRules.cityState(locality: nil, administrativeArea: "CA"), "CA", "missing city")
    expect(FriendAddressRules.cityState(locality: nil, administrativeArea: nil), "", "nothing -> empty")

    func region(_ iso: String?, device: String?, country: String? = "United Kingdom") -> String {
        FriendAddressRules.confirmationRegion(
            locality: "London", administrativeArea: "England", postalCode: "SW1A 2AA",
            countryName: country, isoCountryCode: iso, deviceRegionCode: device
        )
    }
    expect(region("GB", device: "US"), "London, England SW1A 2AA, United Kingdom", "country shown when it differs from the device region")
    expect(region("GB", device: "GB"), "London, England SW1A 2AA", "country hidden when it matches the device region")
    expect(region("gb", device: "GB"), "London, England SW1A 2AA", "region comparison is case-insensitive")
    expect(region("GB", device: nil), "London, England SW1A 2AA, United Kingdom", "unknown device region -> country shown")
    expect(region(nil, device: "US"), "London, England SW1A 2AA", "no country code -> no country")
    expect(region("GB", device: "US", country: nil), "London, England SW1A 2AA", "no country name -> no country")

    let us = FriendAddressRules.confirmationRegion(
        locality: "San Francisco", administrativeArea: "CA", postalCode: "94110",
        countryName: "United States", isoCountryCode: "US", deviceRegionCode: "US"
    )
    expect(us, "San Francisco, CA 94110", "US address on a US device: city, state ZIP")
    let sparse = FriendAddressRules.confirmationRegion(
        locality: nil, administrativeArea: "CA", postalCode: nil,
        countryName: "United States", isoCountryCode: "US", deviceRegionCode: "US"
    )
    expect(sparse, "CA", "missing parts are omitted without stray separators")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
