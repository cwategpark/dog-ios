import Foundation
import XCTest
@testable import DogiosDataLayer

final class PetLifetimeDTOTests: DataLayerTestCase {
    private let decoder = DogiosJSON.makeDecoder()
    private let now = DogiosISO8601.date(from: "2026-11-05T00:00:00Z")!

    private func decode(_ json: String) throws -> PetSummary {
        let response = try decoder.decode(PetListResponse.self, from: Data(json.utf8))
        return response.pets[0]
    }

    func testLegacyPayloadStillDecodesAndKeepsOldFields() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"legacy","name":"Milo","species":"dog","breed":null,
          "age_months":24,"dog_size":"small","avatar_url":null}]}
        """)
        XCTAssertEqual(pet.name, "Milo")
        XCTAssertEqual(pet.ageMonths, 24)
        XCTAssertNil(pet.profileVersion)
        XCTAssertNil(pet.petInformation)
        XCTAssertNil(pet.birthYear)
        XCTAssertNil(pet.derivedAgeMonths(now: now))
        XCTAssertEqual(pet.ageDescription(now: now), "记录月龄 24 个月（历史值，未随时更新）")
    }

    func testUnknownAgeStaysUnknownAndNeverDefaultsToTwelve() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"unknown","name":null,"species":"dog","age_months":null,
          "profile_version":1,
          "pet_information":{"type":"dog","pet_name":null,"birth_precision":"unknown",
            "birth_is_estimated":false}}]}
        """)
        XCTAssertNil(pet.ageMonths)
        XCTAssertNil(pet.derivedAgeMonths(now: now))
        XCTAssertEqual(pet.ageDescription(now: now), "年龄未知")
    }

    func testCanonicalNestedFieldsTopLevelCompatAndMonthPrecisionAge() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"month","name":"Milo","species":"dog","breed":"Mixed",
          "age_months":null,"profile_version":3,
          "birth_year":2023,"birth_month":6,"birth_day":null,
          "birth_precision":"month","birth_is_estimated":false,
          "pet_information":{"type":"dog","pet_name":"Milo","breed":"Mixed breed",
            "birth_year":2023,"birth_month":6,"birth_day":null,
            "birth_precision":"month","birth_is_estimated":false,
            "goals":["play","walk"],"avoidance":"chicken"}}]}
        """)
        XCTAssertEqual(pet.profileVersion, 3)
        XCTAssertEqual(pet.petInformation?.petName, "Milo")
        XCTAssertEqual(pet.resolvedBreed, "Mixed breed")
        XCTAssertEqual(pet.resolvedSpecies, "dog")
        XCTAssertEqual(pet.resolvedBirthYear, 2023)
        XCTAssertEqual(pet.resolvedBirthMonth, 6)
        XCTAssertNil(pet.resolvedBirthDay)
        XCTAssertEqual(pet.birthPrecision, "month") // top-level compatibility
        XCTAssertEqual(pet.resolvedBirthPrecision, "month")
        XCTAssertEqual(pet.resolvedGoals, ["play", "walk"])
        XCTAssertEqual(pet.resolvedAvoidance?.status, "specified")
        XCTAssertEqual(pet.resolvedAvoidanceItems, ["chicken"])
        XCTAssertEqual(pet.derivedAgeMonths(now: now), 41)
        XCTAssertEqual(pet.ageDescription(now: now), "约 3 岁 5 个月")
    }

    func testDayPrecisionExactAndYearPrecisionApproximate() throws {
        let dayPet = try decode("""
        {"pets":[{"pet_id":"day","name":"Day","birth_year":2024,"birth_month":1,"birth_day":15,
          "birth_precision":"day","birth_is_estimated":false}]}
        """)
        XCTAssertEqual(dayPet.derivedAgeMonths(now: now), 33)
        XCTAssertEqual(dayPet.ageDescription(now: now), "2 岁 9 个月")

        let yearPet = try decode("""
        {"pets":[{"pet_id":"year","name":"Year","birth_year":2024,
          "birth_precision":"year","birth_is_estimated":false}]}
        """)
        XCTAssertEqual(yearPet.derivedAgeMonths(now: now), 24)
        XCTAssertEqual(yearPet.ageDescription(now: now), "约 2 岁")
    }

    func testObservedSnapshotIsPreservedAndGrowsOverTime() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"observed","name":"Observed",
          "pet_information":{"type":"cat","age_months_observed":24,
            "age_observed_at":1762200000.0}}]}
        """)
        XCTAssertEqual(pet.resolvedObservedAgeMonths, 24)
        XCTAssertEqual(pet.resolvedObservedAt?.timeIntervalSince1970 ?? 0, 1762200000.0, accuracy: 0.001)
        // 24 observed months at 2025-11-03 + 12 months to 2026-11-05 => 36.
        XCTAssertEqual(pet.derivedAgeMonths(now: now), 36)
        XCTAssertEqual(pet.ageDescription(now: now), "约 3 岁")
        // Decoding must not rewrite/reset the server observed_at snapshot.
        XCTAssertEqual(pet.petInformation?.ageObservedAt?.timeIntervalSince1970 ?? 0, 1762200000.0, accuracy: 0.001)
    }

    func testEstimatedBirthUsesApproximatePrefix() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"estimated","name":"Estimated","birth_year":2024,"birth_month":1,
          "birth_day":15,"birth_precision":"day","birth_is_estimated":true}]}
        """)
        XCTAssertEqual(pet.derivedAgeMonths(now: now), 33)
        XCTAssertTrue(pet.ageDescription(now: now).hasPrefix("约 "))
    }

    func testTopLevelBirthFieldsWorkWithoutNestedPetInformation() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"top","name":"Top","birth_year":2023,"birth_month":6,
          "birth_precision":"month","birth_is_estimated":false}]}
        """)
        XCTAssertNil(pet.petInformation)
        XCTAssertEqual(pet.resolvedBirthYear, 2023)
        XCTAssertEqual(pet.derivedAgeMonths(now: now), 41)
    }
}


extension PetLifetimeDTOTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// Decode the actual canonical `/mobile/v1/me` response captured over HTTP, not a
    /// hand-written approximation. It contains two pets: specified and unknown avoidance.
    func testActualCanonicalMeFixtureDecodesAvoidanceDogSizeAndObservedTimestamp() throws {
        let response = try decoder.decode(MobileMeResponse.self,
                                          from: fixtureData("canonical_me_lifetime.json"))
        XCTAssertEqual(response.pets.count, 2)

        let specified = try XCTUnwrap(response.pets.first { $0.resolvedName == "Fixture Golden" })
        XCTAssertEqual(specified.profileVersion, 1)
        XCTAssertEqual(specified.resolvedDogSize, "large")
        XCTAssertEqual(specified.resolvedBirthPrecision, "month")
        XCTAssertEqual(specified.resolvedBirthYear, 2023)
        XCTAssertEqual(specified.resolvedBirthMonth, 6)
        XCTAssertNil(specified.resolvedBirthDay)
        XCTAssertEqual(specified.resolvedGoals, ["play", "walk"])
        XCTAssertEqual(specified.resolvedAvoidance?.status, "specified")
        XCTAssertEqual(specified.resolvedAvoidanceItems, ["chicken", "beef"])
        XCTAssertNil(specified.resolvedObservedAt)

        let unknown = try XCTUnwrap(response.pets.first { $0.resolvedName == "Fixture Unknown Avoidance" })
        XCTAssertEqual(unknown.resolvedAvoidance?.status, "unknown")
        XCTAssertEqual(unknown.resolvedAvoidanceItems, [])
        XCTAssertEqual(unknown.resolvedAvoidance?.isUnknown, true)
        XCTAssertEqual(unknown.resolvedDogSize, "small")
        XCTAssertEqual(unknown.resolvedBirthPrecision, "unknown")
        XCTAssertEqual(unknown.resolvedObservedAgeMonths, 24)
        let observedAt = try XCTUnwrap(unknown.resolvedObservedAt)
        XCTAssertEqual(observedAt.timeIntervalSince1970, 1793874725.435116, accuracy: 0.001)
        XCTAssertEqual(unknown.ageDescription(now: now).hasPrefix("约 "), true)
    }

    func testLegacyAvoidanceStringAndArrayStillDecode() throws {
        let text = try decode("""
        {"pets":[{"pet_id":"legacy-text","name":"Text","avoidance":"chicken"}]}
        """)
        XCTAssertEqual(text.resolvedAvoidance?.status, "specified")
        XCTAssertEqual(text.resolvedAvoidanceItems, ["chicken"])

        let array = try decode("""
        {"pets":[{"pet_id":"legacy-array","name":"Array","avoidance":["beef","dairy"]}]}
        """)
        XCTAssertEqual(array.resolvedAvoidance?.status, "specified")
        XCTAssertEqual(array.resolvedAvoidanceItems, ["beef", "dairy"])

        let none = try decode("""
        {"pets":[{"pet_id":"legacy-none","name":"None","avoidance":"none"}]}
        """)
        XCTAssertEqual(none.resolvedAvoidance?.status, "none")
        XCTAssertEqual(none.resolvedAvoidanceItems, [])
    }
}

extension PetLifetimeDTOTests {
    func testYearPrecisionInCurrentYearIsUnderOneNotOne() throws {
        let pet = try decode("""
        {"pets":[{"pet_id":"newborn-year","name":"Newborn","birth_year":2026,
          "birth_precision":"year","birth_is_estimated":false}]}
        """)
        XCTAssertEqual(pet.derivedAgeMonths(now: now), 0)
        XCTAssertEqual(pet.ageDescription(now: now), "未满1岁（仅知出生年份）")
        XCTAssertNil(pet.resolvedBirthMonth)
        XCTAssertNil(pet.resolvedBirthDay)
    }

    func testObservedAgeJan31ToFeb28UsesClampedAnniversary() throws {
        let observedAt = DogiosISO8601.date(from: "2025-01-31T00:00:00Z")!
        let pet = try decode("""
        {"pets":[{"pet_id":"jan31","name":"Jan31",
          "pet_information":{"type":"cat","age_months_observed":24,
            "age_observed_at":\(observedAt.timeIntervalSince1970)}}]}
        """)
        let feb28 = DogiosISO8601.date(from: "2025-02-28T00:00:00Z")!
        XCTAssertEqual(pet.derivedAgeMonths(now: feb28), 25) // 24 + 1 completed month
        XCTAssertEqual(pet.resolvedObservedAt?.timeIntervalSince1970 ?? 0,
                       observedAt.timeIntervalSince1970, accuracy: 0.001)

        let feb27 = DogiosISO8601.date(from: "2025-02-27T00:00:00Z")!
        XCTAssertEqual(pet.derivedAgeMonths(now: feb27), 24) // anniversary not reached
    }
}
