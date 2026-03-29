import Foundation
import HealthKit

// MARK: - HealthKit Data Models

struct HealthSample {
    let type: HKQuantityType
    let quantity: HKQuantity
    let startDate: Date
    let endDate: Date
    let metadata: [String: Any]?
}

struct HealthCategorySample {
    let type: HKCategoryType
    let value: Int
    let startDate: Date
    let endDate: Date
    let metadata: [String: Any]?
}

enum HealthKitError: LocalizedError {
    case notAvailable
    case notAuthorized
    case writeFailed(Error)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:          return "HealthKit is not available on this device."
        case .notAuthorized:         return "Not authorized to write to Apple Health."
        case .writeFailed(let e):    return "Failed to write to HealthKit: \(e.localizedDescription)"
        case .invalidData(let msg):  return "Invalid health data: \(msg)"
        }
    }
}

// MARK: - HealthKitService

final class HealthKitService {

    private let healthStore = HKHealthStore()

    private let writeTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = []
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .heartRate,
            .activeEnergyBurned,
            .distanceWalkingRunning,
            .oxygenSaturation,
            .bodyMass,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
            .appleExerciseTime
        ]
        for id in quantityIdentifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(type)
            }
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleepType)
        }
        return types
    }()

    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = []
        let identifiers: [HKQuantityTypeIdentifier] = [.stepCount, .heartRate]
        for id in identifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(type)
            }
        }
        return types
    }()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var isAuthorized: Bool {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return false }
        return healthStore.authorizationStatus(for: stepType) == .sharingAuthorized
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.notAvailable }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: writeTypes, read: readTypes) { success, error in
                if let error = error {
                    continuation.resume(throwing: HealthKitError.writeFailed(error))
                } else if !success {
                    continuation.resume(throwing: HealthKitError.notAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Writing Samples

    func saveStepCount(steps: Int, startDate: Date, endDate: Date) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw HealthKitError.invalidData("Step count type unavailable")
        }
        let quantity = HKQuantity(unit: .count(), doubleValue: Double(steps))
        let sample = HKQuantitySample(type: type, quantity: quantity, start: startDate, end: endDate,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await save(sample: sample)
    }

    func saveHeartRate(bpm: Double, date: Date) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            throw HealthKitError.invalidData("Heart rate type unavailable")
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let quantity = HKQuantity(unit: unit, doubleValue: bpm)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await save(sample: sample)
    }

    func saveActiveCalories(kcal: Double, startDate: Date, endDate: Date) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            throw HealthKitError.invalidData("Active energy type unavailable")
        }
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: startDate, end: endDate,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await save(sample: sample)
    }

    func saveDistance(meters: Double, startDate: Date, endDate: Date) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else {
            throw HealthKitError.invalidData("Distance type unavailable")
        }
        let quantity = HKQuantity(unit: .meter(), doubleValue: meters)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: startDate, end: endDate,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await save(sample: sample)
    }

    func saveOxygenSaturation(percentage: Double, date: Date) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else {
            throw HealthKitError.invalidData("Oxygen saturation type unavailable")
        }
        let quantity = HKQuantity(unit: .percent(), doubleValue: percentage / 100.0)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await save(sample: sample)
    }

    func saveBodyWeight(kg: Double, date: Date) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            throw HealthKitError.invalidData("Body mass type unavailable")
        }
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await save(sample: sample)
    }

    func saveBloodPressure(systolicMmHg: Double, diastolicMmHg: Double, date: Date) async throws {
        guard
            let systolicType  = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            let diastolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
            let bpType        = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)
        else {
            throw HealthKitError.invalidData("Blood pressure types unavailable")
        }

        let mmHg = HKUnit.millimeterOfMercury()
        let systolicSample  = HKQuantitySample(type: systolicType,  quantity: HKQuantity(unit: mmHg, doubleValue: systolicMmHg),  start: date, end: date)
        let diastolicSample = HKQuantitySample(type: diastolicType, quantity: HKQuantity(unit: mmHg, doubleValue: diastolicMmHg), start: date, end: date)

        let correlation = HKCorrelation(
            type: bpType,
            start: date,
            end: date,
            objects: [systolicSample, diastolicSample],
            metadata: [HKMetadataKeyWasUserEntered: false]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(correlation) { success, error in
                if let error = error {
                    continuation.resume(throwing: HealthKitError.writeFailed(error))
                } else if !success {
                    continuation.resume(throwing: HealthKitError.notAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func saveSleepAnalysis(startDate: Date, endDate: Date, sleepStage: HKCategoryValueSleepAnalysis) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitError.invalidData("Sleep analysis type unavailable")
        }
        let sample = HKCategorySample(type: type, value: sleepStage.rawValue, start: startDate, end: endDate,
                                      metadata: [HKMetadataKeyWasUserEntered: false])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(sample) { success, error in
                if let error = error {
                    continuation.resume(throwing: HealthKitError.writeFailed(error))
                } else if !success {
                    continuation.resume(throwing: HealthKitError.notAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func saveBatchSamples(_ samples: [HKObject]) async throws {
        guard !samples.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(samples) { success, error in
                if let error = error {
                    continuation.resume(throwing: HealthKitError.writeFailed(error))
                } else if !success {
                    continuation.resume(throwing: HealthKitError.notAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Private

    private func save(sample: HKObject) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(sample) { success, error in
                if let error = error {
                    continuation.resume(throwing: HealthKitError.writeFailed(error))
                } else if !success {
                    continuation.resume(throwing: HealthKitError.notAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
