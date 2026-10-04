//
// Deterministic tests for LocationAvailability / LocationAvailabilityLogic -
// the pure availability-resolution and fix-usability rules behind
// LocationProvider. No CLLocationManager, no UI, no network: every input is a
// plain status, flag, or hand-built CLLocation with a fixed timestamp, so the
// states that are hard to provoke in the simulator (granted but no fix,
// stale/invalid/inaccurate fixes, CoreLocation failure) are exercised
// directly against the real production source file (not a copy).
//
// This is a standalone script, NOT part of the LetsMeet Xcode target (see
// decision_logic_tests.swift for why: no XCTest target exists, and top-level
// statements would conflict with the app's entry point).
//
// CLAuthorizationStatus.authorizedWhenInUse is unavailable on macOS, so this
// is compiled for the iOS Simulator SDK and run inside a booted simulator
// (staged as literally "main.swift" so top-level code is allowed):
//   cp Scripts/location_logic_tests.swift /tmp/main.swift && \
//   xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
//     -o /tmp/location_logic_tests \
//     LetsMeet/LocationManager/LocationAvailability.swift \
//     /tmp/main.swift \
//     && xcrun simctl spawn booted /tmp/location_logic_tests

import Foundation
import CoreLocation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        print("  PASS  \(label)")
    } else {
        print("  FAIL  \(label): expected \(expected), got \(actual)")
        failures += 1
    }
}

let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

func fix(accuracy: CLLocationAccuracy, ageSeconds: TimeInterval, lat: Double = 37.77) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: -122.41),
        altitude: 0,
        horizontalAccuracy: accuracy,
        verticalAccuracy: 0,
        timestamp: now.addingTimeInterval(-ageSeconds)
    )
}

func resolve(_ status: CLAuthorizationStatus, services: Bool = true, fix hasFix: Bool = false, failure: Bool = false) -> LocationAvailability {
    LocationAvailabilityLogic.resolve(status: status, servicesEnabled: services, hasUsableFix: hasFix, hasFailure: failure)
}

// MARK: - 1. resolve(): authorization states
do {
    print("1. resolve() - authorization states")
    expect(resolve(.notDetermined), .notDetermined, "notDetermined -> notDetermined")
    expect(resolve(.notDetermined, fix: true), .notDetermined, "notDetermined ignores any fix")
    expect(resolve(.restricted), .restricted, "restricted -> restricted")
    expect(resolve(.restricted, services: false), .restricted, "restricted wins regardless of services flag")
    expect(resolve(.denied, services: true), .denied, "denied + services on -> denied")
    expect(resolve(.denied, services: false), .servicesDisabled, "denied + services off -> servicesDisabled")
    expect(resolve(.denied, fix: true), .denied, "denied is never 'available', even with a leftover fix")
}

// MARK: - 2. resolve(): authorized states
do {
    print("2. resolve() - authorized, fix/failure combinations")
    for status in [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways] {
        let name = status == .authorizedAlways ? "authorizedAlways" : "authorizedWhenInUse"
        expect(resolve(status), .acquiring, "\(name), no fix, no failure -> acquiring (granted but no fix yet)")
        expect(resolve(status, failure: true), .failed, "\(name), no fix, failure -> failed")
        expect(resolve(status, fix: true), .available, "\(name), usable fix -> available")
        expect(resolve(status, fix: true, failure: true), .available, "\(name), usable fix beats a failure flag")
    }
}

// MARK: - 3. isUsable(): validity, accuracy, age
do {
    print("3. isUsable() - accuracy and age rules")
    let maxAccuracy = LocationAvailabilityLogic.maximumHorizontalAccuracyMeters
    let maxAge = LocationAvailabilityLogic.maximumFixAge
    expect(maxAccuracy, 1000, "accuracy threshold constant is 1000 m")
    expect(maxAge, 60, "age threshold constant is 60 s")

    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 10, ageSeconds: 2), now: now), true, "fresh 10 m fix is usable")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: -1, ageSeconds: 2), now: now), false, "negative accuracy (invalid) is rejected")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 0, ageSeconds: 2), now: now), true, "zero accuracy is not negative -> usable")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: maxAccuracy, ageSeconds: 2), now: now), true, "accuracy exactly at the cap is usable")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: maxAccuracy + 0.1, ageSeconds: 2), now: now), false, "accuracy just over the cap is rejected")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 3000, ageSeconds: 2), now: now), false, "3 km accuracy is rejected")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 10, ageSeconds: maxAge), now: now), true, "age exactly at the limit is usable")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 10, ageSeconds: maxAge + 1), now: now), false, "age just over the limit is rejected")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 10, ageSeconds: 3600), now: now), false, "hour-old cached fix is rejected")
    expect(LocationAvailabilityLogic.isUsable(fix(accuracy: 10, ageSeconds: -5), now: now), true, "slightly-future timestamp (clock skew) is not treated as stale")
}

// MARK: - 4. usableFix(): batch handling uses the newest entry
do {
    print("4. usableFix() - newest-in-batch semantics")
    expect(LocationAvailabilityLogic.usableFix(from: [], now: now) == nil, true, "empty batch -> nil")

    let oldGood = fix(accuracy: 10, ageSeconds: 20, lat: 10)
    let newGood = fix(accuracy: 10, ageSeconds: 1, lat: 20)
    expect(LocationAvailabilityLogic.usableFix(from: [oldGood, newGood], now: now)?.coordinate.latitude, 20, "returns the LAST (newest) location, not the first")

    let staleCached = fix(accuracy: 10, ageSeconds: 900, lat: 10)
    let freshNow = fix(accuracy: 10, ageSeconds: 1, lat: 20)
    expect(LocationAvailabilityLogic.usableFix(from: [staleCached, freshNow], now: now)?.coordinate.latitude, 20, "stale cached fix first, fresh last -> fresh one")
    expect(LocationAvailabilityLogic.usableFix(from: [freshNow, staleCached], now: now) == nil, true, "newest entry stale -> rejected (older entries are not substituted)")
    expect(LocationAvailabilityLogic.usableFix(from: [fix(accuracy: -1, ageSeconds: 1)], now: now) == nil, true, "single invalid fix -> nil")
}

// MARK: - 5. Granted-but-no-fix lifecycle (state sequence)
do {
    print("5. Lifecycle - notDetermined -> acquiring -> available -> revoked")
    var hasFix = false
    expect(resolve(.notDetermined, fix: hasFix), .notDetermined, "launch, prompt unanswered")
    expect(resolve(.authorizedWhenInUse, fix: hasFix), .acquiring, "granted, nothing delivered yet")
    if LocationAvailabilityLogic.usableFix(from: [fix(accuracy: 5000, ageSeconds: 1)], now: now) != nil { hasFix = true }
    expect(resolve(.authorizedWhenInUse, fix: hasFix), .acquiring, "only a 5 km fix delivered -> still acquiring")
    if LocationAvailabilityLogic.usableFix(from: [fix(accuracy: 20, ageSeconds: 1)], now: now) != nil { hasFix = true }
    expect(resolve(.authorizedWhenInUse, fix: hasFix), .available, "good fix delivered -> available")
    hasFix = false // LocationProvider.clearFix() on revoke
    expect(resolve(.denied, fix: hasFix), .denied, "revoked -> denied")
    expect(resolve(.denied, services: false, fix: hasFix), .servicesDisabled, "Services switched off -> servicesDisabled")
    expect(resolve(.authorizedWhenInUse, fix: hasFix), .acquiring, "re-granted -> acquiring again (updates restart)")
}

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
