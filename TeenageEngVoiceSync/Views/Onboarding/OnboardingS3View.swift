//
//  OnboardingS3View.swift
//  TeenageEngVoiceSync
//
//  AWS S3 configuration for cloud storage (optional).
//

import SwiftUI

struct OnboardingS3View: View {
    @Binding var isConfigured: Bool

    @AppStorage("s3.enabled") private var s3Enabled = false
    @AppStorage("s3.bucket") private var bucket = ""
    @AppStorage("s3.region") private var region = "us-east-1"
    @AppStorage("s3.prefix") private var prefix = "recordings/"

    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var showSecret = false
    @State private var isTesting = false
    @State private var testStatus: TestStatus?
    @State private var isLoading = true

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

                    Text("AWS S3 Cloud Storage")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Optional: Upload recordings to S3 to enable playback links in Apple Notes. If you skip this, files will be stored locally.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Bucket configuration
                VStack(alignment: .leading, spacing: 8) {
                    Text("S3 Bucket")
                        .font(.headline)

                    TextField("Bucket name", text: $bucket)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Picker("Region", selection: $region) {
                            ForEach(awsRegions, id: \.self) { r in
                                Text(r).tag(r)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)

                        TextField("Key prefix", text: $prefix)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("Files will be uploaded to: s3://\(bucket)/\(prefix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // AWS Credentials
                VStack(alignment: .leading, spacing: 8) {
                    Text("AWS Credentials")
                        .font(.headline)

                    TextField("Access Key ID", text: $accessKeyId)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isLoading)

                    HStack {
                        if showSecret {
                            TextField("Secret Access Key", text: $secretAccessKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Secret Access Key", text: $secretAccessKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .disabled(isLoading)

                    Link("Open AWS Console", destination: URL(string: "https://console.aws.amazon.com/iam/home#/security_credentials")!)
                        .font(.caption)
                }

                // Test button
                VStack(spacing: 8) {
                    HStack {
                        Button("Test Connection & Save") {
                            Task { await testAndSave() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(bucket.isEmpty || accessKeyId.isEmpty || secretAccessKey.isEmpty || isTesting)

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
                Text("Your AWS credentials are stored securely in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadExistingCredentials()
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

    private func loadExistingCredentials() async {
        isLoading = true
        defer { isLoading = false }

        do {
            accessKeyId = try await KeychainService.shared.retrieve(for: .awsAccessKeyId) ?? ""
            secretAccessKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey) ?? ""

            if !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !bucket.isEmpty {
                isConfigured = true
            }
        } catch {
            // Credentials not found, that's fine
        }
    }

    private func testAndSave() async {
        isTesting = true
        defer { isTesting = false }

        let service = S3Service(
            bucket: bucket,
            region: region,
            prefix: prefix,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey
        )

        do {
            try await service.validateBucket()

            // Save credentials
            try await KeychainService.shared.save(accessKeyId, for: .awsAccessKeyId)
            try await KeychainService.shared.save(secretAccessKey, for: .awsSecretAccessKey)

            // Enable S3 storage
            s3Enabled = true

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
    OnboardingS3View(isConfigured: .constant(false))
        .frame(width: 600, height: 440)
}
