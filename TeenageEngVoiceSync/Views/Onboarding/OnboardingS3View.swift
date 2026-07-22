//
//  OnboardingS3View.swift
//  TeenageEngVoiceSync
//
//  S3-compatible configuration for cloud storage (optional): AWS S3 or Backblaze B2.
//

import SwiftUI

struct OnboardingS3View: View {
    @Bindable var draft: OnboardingDraft
    @Binding var isConfigured: Bool

    @State private var showSecret = false
    @State private var isTesting = false
    @State private var testStatus: TestStatus?

    enum TestStatus {
        case success
        case error(String)
    }

    private let awsRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
        "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2",
        "ap-south-1", "sa-east-1", "ca-central-1"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "cloud")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)

                    Text("S3 Cloud Storage")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Optional: Upload recordings to AWS S3 or Backblaze B2 to enable playback links in Apple Notes. If you skip this, files will be stored locally.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Provider
                VStack(alignment: .leading, spacing: 8) {
                    Text("Provider")
                        .font(.headline)

                    Picker("Provider", selection: Binding(
                        get: { draft.s3Provider },
                        set: { newValue in
                            draft.s3Provider = newValue
                            draft.s3Region = newValue.defaultRegion
                        }
                    )) {
                        ForEach(S3Provider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Bucket configuration
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bucket")
                        .font(.headline)

                    TextField("Bucket name", text: $draft.s3Bucket)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        if draft.s3Provider == .aws {
                            Picker("Region", selection: $draft.s3Region) {
                                ForEach(awsRegions, id: \.self) { r in
                                    Text(r).tag(r)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        } else {
                            TextField("Region (e.g. us-west-004)", text: $draft.s3Region)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                        }

                        TextField("Key prefix", text: $draft.s3Prefix)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("Files will be uploaded to: s3://\(draft.s3Bucket)/\(draft.s3Prefix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Credentials
                VStack(alignment: .leading, spacing: 8) {
                    Text("Credentials")
                        .font(.headline)

                    TextField("Access Key ID", text: $draft.awsAccessKeyId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(draft.isSeeding)

                    HStack {
                        if showSecret {
                            TextField("Secret Access Key", text: $draft.awsSecretAccessKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Secret Access Key", text: $draft.awsSecretAccessKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .disabled(draft.isSeeding)

                    if draft.s3Provider == .aws {
                        Link("Open AWS Console", destination: URL(string: "https://console.aws.amazon.com/iam/home#/security_credentials")!)
                            .font(.caption)
                    } else {
                        Link("Open Backblaze B2 Application Keys", destination: URL(string: "https://secure.backblaze.com/app_keys.htm")!)
                            .font(.caption)
                    }
                }

                // Test button
                VStack(spacing: 8) {
                    HStack {
                        Button("Test Connection & Save") {
                            Task { await testAndSave() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(draft.s3Bucket.isEmpty || draft.awsAccessKeyId.isEmpty || draft.awsSecretAccessKey.isEmpty || isTesting)

                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    if let status = testStatus {
                        statusLabel(for: status)
                    }
                }

                // Info
                Text("Your credentials are saved securely to your Mac's Keychain when you finish setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Reflect existing, already-configured credentials seeded into the draft.
            if !draft.awsAccessKeyId.isEmpty && !draft.awsSecretAccessKey.isEmpty && !draft.s3Bucket.isEmpty {
                isConfigured = true
            }
        }
    }

    @ViewBuilder
    private func statusLabel(for status: TestStatus) -> some View {
        switch status {
        case .success:
            Label("Connection successful! Configuration saved.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func testAndSave() async {
        isTesting = true
        defer { isTesting = false }

        let service = S3Service(
            bucket: draft.s3Bucket,
            region: draft.s3Region,
            prefix: draft.s3Prefix,
            accessKeyId: draft.awsAccessKeyId,
            secretAccessKey: draft.awsSecretAccessKey,
            provider: draft.s3Provider
        )

        do {
            try await service.validateBucket()

            // Stage S3 as enabled; credentials and flags are persisted only when
            // onboarding completes.
            draft.s3Enabled = true

            testStatus = .success
            isConfigured = true

            // Clear success message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    testStatus = nil
                }
            }
        } catch {
            testStatus = .error("Connection failed: \(error.localizedDescription)")
            isConfigured = false
        }
    }
}

#Preview {
    OnboardingS3View(draft: OnboardingDraft(), isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
