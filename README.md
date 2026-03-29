# GalaxySync

GalaxySync is an iOS app that bridges your **Samsung Galaxy Watch 4** fitness data to **Apple Health** using the **Google Fit REST API**.

## Features

- **Steps** — Daily step count synced from Google Fit aggregated datasets
- **Heart Rate** — Per-measurement BPM readings
- **Active Calories** — Energy expenditure from workouts and activity
- **Distance** — Walking and running distance in meters
- **Sleep Analysis** — Sleep stages mapped from Google Fit to HealthKit (Light, Deep, REM, Awake)
- **Oxygen Saturation** — SpO2 readings from the Galaxy Watch 4

## Project Structure

```
GalaxySync/
├── GalaxySync/
│   ├── GalaxySyncApp.swift       # @main entry point, injects SyncEngine
│   ├── ContentView.swift         # SwiftUI dashboard with auth buttons & sync controls
│   ├── GoogleFitService.swift    # OAuth 2.0 + Google Fit REST API client
│   ├── HealthKitService.swift    # HealthKit write operations for all data types
│   ├── SyncEngine.swift          # Orchestrates Google Fit → HealthKit sync
│   └── Info.plist                # App permissions and URL scheme for OAuth redirect
├── ExportOptions.plist           # Xcode archive export settings for App Store Connect
├── .github/
│   └── workflows/
│       └── build.yml             # CI: build+test on push, archive+export on main
└── README.md
```

## Requirements

- **iOS 17.0+**
- **Xcode 15.4+**
- **Swift 5.10+**
- A **Google Cloud Console** project with the Fitness API enabled
- An **Apple Developer** account with HealthKit entitlement

## Setup

### 1. Google Cloud / OAuth

1. Go to [Google Cloud Console](https://console.cloud.google.com/).
2. Create a project and enable the **Fitness API**.
3. Under **Credentials**, create an **OAuth 2.0 Client ID** for iOS.
4. Copy the client ID and paste it into `GoogleFitService.swift`:
   ```swift
   private let clientID = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
   ```
5. Add the reverse client ID as a URL scheme in **Info.plist** (already scaffolded — update `com.yourcompany.galaxysync` to match your bundle ID).

### 2. Apple Developer / HealthKit

1. In Xcode, open **Signing & Capabilities** for the GalaxySync target.
2. Click **+** and add the **HealthKit** capability.
3. The `NSHealthUpdateUsageDescription` and `NSHealthShareUsageDescription` keys are already set in `Info.plist`.

### 3. Bundle ID & Team

1. Update `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project settings.
2. Set `YOUR_TEAM_ID` in `ExportOptions.plist` to your Apple Developer Team ID.

## CI / CD (GitHub Actions)

The workflow in `.github/workflows/build.yml` performs two jobs:

| Job | Trigger | What it does |
|-----|---------|--------------|
| `build` | Every push/PR | Builds for testing, runs unit tests, uploads `TestResults.xcresult` |
| `archive` | Push to `main` only | Archives a Release build, exports an IPA, uploads the `.ipa` as an artifact |

### Required Secrets

Add these to your GitHub repository **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `CERTIFICATE_BASE64` | Base64-encoded `.p12` distribution certificate |
| `CERTIFICATE_PASSWORD` | Password for the `.p12` file |
| `KEYCHAIN_PASSWORD` | A temporary password for the CI keychain |
| `PROVISIONING_PROFILE_BASE64` | Base64-encoded `.mobileprovision` for App Store distribution |

Encode a file to base64:
```bash
base64 -i YourCertificate.p12 | pbcopy
```

## Architecture

```
ContentView (SwiftUI)
     │
     └─► SyncEngine (@MainActor ObservableObject)
              ├─► GoogleFitService   — OAuth 2.0 + REST API fetching
              └─► HealthKitService   — HKHealthStore write operations
```

`SyncEngine` fans out concurrent async fetch tasks (steps, heart rate, calories, distance, sleep, SpO2) using Swift concurrency (`async let`), then writes each result to HealthKit through `HealthKitService`.

Tokens are persisted in the device Keychain via `KeychainHelper`. The last sync date and data-point count are persisted in `UserDefaults`.

## License

MIT
