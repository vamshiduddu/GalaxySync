import SwiftUI

struct ContentView: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @State private var isAuthenticating = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                headerSection
                statusSection
                syncControlSection
                lastSyncSection
                Spacer()
            }
            .padding()
            .navigationTitle("GalaxySync")
            .navigationBarTitleDisplayMode(.large)
        }
        .alert("GalaxySync", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundColor(.blue)
            Text("Samsung Galaxy Watch 4")
                .font(.headline)
            Text("→ Apple Health via Google Fit")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 16)
    }

    private var statusSection: some View {
        GroupBox(label: Label("Connection Status", systemImage: "wifi")) {
            VStack(alignment: .leading, spacing: 12) {
                StatusRow(
                    label: "Google Fit",
                    isConnected: syncEngine.isGoogleFitConnected,
                    icon: "g.circle.fill"
                )
                StatusRow(
                    label: "Apple Health",
                    isConnected: syncEngine.isHealthKitAuthorized,
                    icon: "heart.fill"
                )
            }
            .padding(.vertical, 4)
        }
    }

    private var syncControlSection: some View {
        VStack(spacing: 12) {
            if !syncEngine.isGoogleFitConnected {
                Button {
                    isAuthenticating = true
                    Task {
                        do {
                            try await syncEngine.connectGoogleFit()
                        } catch {
                            alertMessage = "Failed to connect Google Fit: \(error.localizedDescription)"
                            showAlert = true
                        }
                        isAuthenticating = false
                    }
                } label: {
                    Label("Connect Google Fit", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAuthenticating)
            }

            if !syncEngine.isHealthKitAuthorized {
                Button {
                    Task {
                        do {
                            try await syncEngine.requestHealthKitPermission()
                        } catch {
                            alertMessage = "Failed to authorize HealthKit: \(error.localizedDescription)"
                            showAlert = true
                        }
                    }
                } label: {
                    Label("Authorize Apple Health", systemImage: "heart.text.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            if syncEngine.isGoogleFitConnected && syncEngine.isHealthKitAuthorized {
                Button {
                    Task {
                        do {
                            try await syncEngine.syncNow()
                        } catch {
                            alertMessage = "Sync failed: \(error.localizedDescription)"
                            showAlert = true
                        }
                    }
                } label: {
                    if syncEngine.isSyncing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(syncEngine.isSyncing)
            }
        }
    }

    private var lastSyncSection: some View {
        GroupBox(label: Label("Last Sync", systemImage: "clock")) {
            HStack {
                if let lastSync = syncEngine.lastSyncDate {
                    Text(lastSync, style: .relative)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("Never synced")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let count = syncEngine.lastSyncCount {
                    Text("\(count) data points")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct StatusRow: View {
    let label: String
    let isConnected: Bool
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(isConnected ? .green : .gray)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(isConnected ? "Connected" : "Not Connected")
                .font(.caption)
                .foregroundColor(isConnected ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isConnected ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(SyncEngine())
}
