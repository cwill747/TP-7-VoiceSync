//
//  S3SettingsView.swift
//  TeenageEngVoiceSync
//
//  AWS S3 bucket configuration settings.
//  Note: AWS credentials are managed in the API Keys tab.
//

import SwiftUI

struct S3SettingsView: View {
    @AppStorage("s3.bucket") private var bucket = ""
    @AppStorage("s3.region") private var region = "us-east-1"
    @AppStorage("s3.prefix") private var prefix = "recordings/"

    @State private var isTesting = false
    @State private var hasCredentials = false
    @State private var testStatus: TestStatus?

    enum TestStatus {
        case success
        case error(String)
    }

    var body: some View {
        Form {
            Section("S3 Bucket") {
                TextField("Bucket Name", text: $bucket)
                    .textFieldStyle(.roundedBorder)

                Picker("Region", selection: $region) {
                    ForEach(awsRegions, id: \.self) { region in
                        Text(region).tag(region)
                    }
                }

                TextField("Key Prefix", text: $prefix)
                    .textFieldStyle(.roundedBorder)

                Text("Files will be uploaded to: s3://\(bucket)/\(prefix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if !hasCredentials {
                    Label("Configure AWS credentials in the API Keys tab", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label("AWS credentials configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            if let status = testStatus {
                Section {
                    switch status {
                    case .success:
                        Label("Connection successful", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .error(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(bucket.isEmpty || !hasCredentials || isTesting)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await checkCredentials()
        }
    }

    private func checkCredentials() async {
        do {
            let accessKey = try await KeychainService.shared.retrieve(for: .awsAccessKeyId)
            let secretKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey)
            hasCredentials = (accessKey != nil && !accessKey!.isEmpty) &&
                           (secretKey != nil && !secretKey!.isEmpty)
        } catch {
            hasCredentials = false
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }

        do {
            let accessKeyId = try await KeychainService.shared.retrieve(for: .awsAccessKeyId) ?? ""
            let secretAccessKey = try await KeychainService.shared.retrieve(for: .awsSecretAccessKey) ?? ""

            let service = S3Service(
                bucket: bucket,
                region: region,
                prefix: prefix,
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey
            )

            try await service.validateBucket()
            testStatus = .success

            // Clear success message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    testStatus = nil
                }
            }
        } catch {
            testStatus = .error("Failed: \(error.localizedDescription)")
        }
    }

    private var awsRegions: [String] {
        [
            "us-east-1", "us-east-2", "us-west-1", "us-west-2",
            "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
            "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2",
            "ap-south-1", "sa-east-1", "ca-central-1"
        ]
    }
}

#Preview {
    S3SettingsView()
}
