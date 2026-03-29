import Foundation
import HealthKit
import Combine

// MARK: - Sync Result

struct SyncResult {
    let dataPointsWritten: Int
    let errors: [Error]
    let syncDate: Date
}

// MARK: - SyncEngine

@MainActor
final class SyncEngine: ObservableObject {

    // MARK: Published State
    @Published var isGoogleFitConnected: Bool = false
    @Published var isHealthKitAuthorized: Bool = false
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncCount: Int?

    // MARK: Services
    private let googleFit: GoogleFitService
    private let healthKit: HealthKitService

    // MARK: Configuration
    private let syncWindowDays: Int = 7
    private let defaults = UserDefaults.standard
    private let lastSyncKey = "galaxysync_last_sync_date"
    private let lastCountKey = "galaxysync_last_sync_count"

    init(
        googleFit: GoogleFitService = GoogleFitService(),
        healthKit: HealthKitService = HealthKitService()
    ) {
        self.googleFit = googleFit
        self.healthKit = healthKit
        loadPersistedState()
        checkInitialAuthState()
    }

    // MARK: - Public Interface

    func connectGoogleFit() async throws {
        try await googleFit.authenticate()
        isGoogleFitConnected = googleFit.isAuthenticated
    }

    func requestHealthKitPermission() async throws {
        try await healthKit.requestAuthorization()
        isHealthKitAuthorized = healthKit.isAuthorized
    }

    func syncNow() async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let endDate = Date()
        let startDate: Date
        if let last = lastSyncDate {
            startDate = last
        } else {
            startDate = Calendar.current.date(byAdding: .day, value: -syncWindowDays, to: endDate)!
        }

        let result = try await performSync(from: startDate, to: endDate)

        lastSyncDate  = result.syncDate
        lastSyncCount = result.dataPointsWritten
        persistSyncState()
    }

    // MARK: - Core Sync Logic

    private func performSync(from startDate: Date, to endDate: Date) async throws -> SyncResult {
        var written = 0
        var errors: [Error] = []

        async let stepsResult    = syncSteps(from: startDate, to: endDate)
        async let heartRateResult = syncHeartRate(from: startDate, to: endDate)
        async let caloriesResult  = syncCalories(from: startDate, to: endDate)
        async let distanceResult  = syncDistance(from: startDate, to: endDate)
        async let sleepResult     = syncSleep(from: startDate, to: endDate)
        async let spo2Result      = syncOxygenSaturation(from: startDate, to: endDate)

        let results = await [
            (try? stepsResult)    ?? 0,
            (try? heartRateResult) ?? 0,
            (try? caloriesResult)  ?? 0,
            (try? distanceResult)  ?? 0,
            (try? sleepResult)     ?? 0,
            (try? spo2Result)      ?? 0
        ]

        written = results.reduce(0, +)

        return SyncResult(
            dataPointsWritten: written,
            errors: errors,
            syncDate: Date()
        )
    }

    // MARK: - Per-metric Sync

    private func syncSteps(from startDate: Date, to endDate: Date) async throws -> Int {
        let points = try await googleFit.fetchAggregatedData(
            dataType: .stepCount,
            startDate: startDate,
            endDate: endDate
        )

        var count = 0
        for point in points {
            guard let steps = point.values.first?.intVal, steps > 0 else { continue }
            let start = Date(timeIntervalSince1970: Double(point.startTimeNanos) / 1_000_000_000)
            let end   = Date(timeIntervalSince1970: Double(point.endTimeNanos)   / 1_000_000_000)
            try await healthKit.saveStepCount(steps: steps, startDate: start, endDate: end)
            count += 1
        }
        return count
    }

    private func syncHeartRate(from startDate: Date, to endDate: Date) async throws -> Int {
        let points = try await googleFit.fetchDataPoints(
            dataType: .heartRate,
            startDate: startDate,
            endDate: endDate
        )

        var count = 0
        for point in points {
            guard let bpm = point.values.first?.fpVal, bpm > 0 else { continue }
            let date = Date(timeIntervalSince1970: Double(point.startTimeNanos) / 1_000_000_000)
            try await healthKit.saveHeartRate(bpm: bpm, date: date)
            count += 1
        }
        return count
    }

    private func syncCalories(from startDate: Date, to endDate: Date) async throws -> Int {
        let points = try await googleFit.fetchAggregatedData(
            dataType: .calories,
            startDate: startDate,
            endDate: endDate
        )

        var count = 0
        for point in points {
            guard let kcal = point.values.first?.fpVal, kcal > 0 else { continue }
            let start = Date(timeIntervalSince1970: Double(point.startTimeNanos) / 1_000_000_000)
            let end   = Date(timeIntervalSince1970: Double(point.endTimeNanos)   / 1_000_000_000)
            try await healthKit.saveActiveCalories(kcal: kcal, startDate: start, endDate: end)
            count += 1
        }
        return count
    }

    private func syncDistance(from startDate: Date, to endDate: Date) async throws -> Int {
        let points = try await googleFit.fetchAggregatedData(
            dataType: .distance,
            startDate: startDate,
            endDate: endDate
        )

        var count = 0
        for point in points {
            guard let meters = point.values.first?.fpVal, meters > 0 else { continue }
            let start = Date(timeIntervalSince1970: Double(point.startTimeNanos) / 1_000_000_000)
            let end   = Date(timeIntervalSince1970: Double(point.endTimeNanos)   / 1_000_000_000)
            try await healthKit.saveDistance(meters: meters, startDate: start, endDate: end)
            count += 1
        }
        return count
    }

    private func syncSleep(from startDate: Date, to endDate: Date) async throws -> Int {
        let points = try await googleFit.fetchDataPoints(
            dataType: .sleepSegment,
            startDate: startDate,
            endDate: endDate
        )

        var count = 0
        for point in points {
            let start = Date(timeIntervalSince1970: Double(point.startTimeNanos) / 1_000_000_000)
            let end   = Date(timeIntervalSince1970: Double(point.endTimeNanos)   / 1_000_000_000)
            guard end > start else { continue }

            let stage = mapGoogleFitSleepToHKSleep(googleFitValue: point.values.first?.intVal ?? 1)
            try await healthKit.saveSleepAnalysis(startDate: start, endDate: end, sleepStage: stage)
            count += 1
        }
        return count
    }

    private func syncOxygenSaturation(from startDate: Date, to endDate: Date) async throws -> Int {
        let points = try await googleFit.fetchDataPoints(
            dataType: .oxygenSaturation,
            startDate: startDate,
            endDate: endDate
        )

        var count = 0
        for point in points {
            guard let spo2 = point.values.first?.fpVal, spo2 > 0 else { continue }
            let date = Date(timeIntervalSince1970: Double(point.startTimeNanos) / 1_000_000_000)
            try await healthKit.saveOxygenSaturation(percentage: spo2, date: date)
            count += 1
        }
        return count
    }

    // MARK: - Mapping Helpers

    private func mapGoogleFitSleepToHKSleep(googleFitValue: Int) -> HKCategoryValueSleepAnalysis {
        // Google Fit sleep segment values:
        // 1 = Awake, 2 = Sleep, 3 = Out-of-bed, 4 = Light sleep, 5 = Deep sleep, 6 = REM
        switch googleFitValue {
        case 4:  return .asleepCore
        case 5:  return .asleepDeep
        case 6:  return .asleepREM
        case 1, 3: return .awake
        default: return .asleepUnspecified
        }
    }

    // MARK: - State Management

    private func checkInitialAuthState() {
        isGoogleFitConnected  = googleFit.isAuthenticated
        isHealthKitAuthorized = healthKit.isAuthorized
    }

    private func loadPersistedState() {
        if let ts = defaults.object(forKey: lastSyncKey) as? Double {
            lastSyncDate = Date(timeIntervalSince1970: ts)
        }
        lastSyncCount = defaults.integer(forKey: lastCountKey)
        if lastSyncCount == 0 { lastSyncCount = nil }
    }

    private func persistSyncState() {
        if let date = lastSyncDate {
            defaults.set(date.timeIntervalSince1970, forKey: lastSyncKey)
        }
        if let count = lastSyncCount {
            defaults.set(count, forKey: lastCountKey)
        }
    }
}
