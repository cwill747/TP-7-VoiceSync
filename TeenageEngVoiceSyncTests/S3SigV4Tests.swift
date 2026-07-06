//
//  S3SigV4Tests.swift
//  TeenageEngVoiceSyncTests
//
//  Golden-value tests for AWS Signature V4 signing. Expected values were
//  computed independently in Python (hashlib/hmac) against the same fixed
//  date/credentials, so these assertions catch regressions in the Swift
//  implementation rather than merely re-deriving its own output.
//

import XCTest
@testable import TP_7_VoiceSync

final class S3SigV4Tests: XCTestCase {
    // Fixed date: 2024-01-15T10:30:00Z
    private let fixedDate = Date(timeIntervalSince1970: 1_705_314_600)

    private func makeService() -> S3Service {
        S3Service(
            bucket: "voicesync-test-bucket",
            region: "us-east-1",
            prefix: "",
            accessKeyId: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            provider: .aws
        )
    }

    func testGeneratePresignedURLGoldenValue() throws {
        let s3 = makeService()
        let url = try s3.generatePresignedURL(
            s3Key: "recordings/2024-01-15/session01.wav",
            expiry: 3600,
            date: fixedDate
        )

        let expected = "https://voicesync-test-bucket.s3.us-east-1.amazonaws.com/recordings/2024-01-15/session01.wav?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDEXAMPLE%2F20240115%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20240115T103000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=aaa3d84c3abff64546b460308a83692ac931343bb9ed9031ecf0c92143584077"
        XCTAssertEqual(url.absoluteString, expected)
    }

    func testGenerateDownloadURLGoldenValue() throws {
        let s3 = makeService()
        let url = try s3.generateDownloadURL(
            s3Key: "recordings/2024-01-15/session01.wav",
            filename: "session01.wav",
            expiry: 3600,
            date: fixedDate
        )

        let expected = "https://voicesync-test-bucket.s3.us-east-1.amazonaws.com/recordings/2024-01-15/session01.wav?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDEXAMPLE%2F20240115%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20240115T103000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&response-content-disposition=attachment%3B%20filename%3D%22session01.wav%22&X-Amz-Signature=67febdb0061d9d54bebba0c5689558eedf6cd080cf552d3049551d2e280209a8"
        XCTAssertEqual(url.absoluteString, expected)
    }

    /// Exercises `signRequest`'s header-based canonicalization: query items
    /// containing `+`, `/`, `=` (as a continuation token would) must be
    /// percent-encoded and sorted independently of how the request URL was
    /// originally assembled.
    func testSignRequestGoldenValue() async throws {
        let s3 = makeService()

        var components = URLComponents(string: "https://voicesync-test-bucket.s3.us-east-1.amazonaws.com/")!
        components.queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: "recordings/2024/"),
            URLQueryItem(name: "continuation-token", value: "abc+def/ghi=")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let signed = try await s3.signRequest(request, body: Data(), date: fixedDate)

        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-Amz-Date"), "20240115T103000Z")
        XCTAssertEqual(
            signed.value(forHTTPHeaderField: "X-Amz-Content-Sha256"),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Host"), "voicesync-test-bucket.s3.us-east-1.amazonaws.com")

        let expectedAuthorization = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20240115/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=e09556a848bfd43aa97008c1362c0cbeb726c504a598b93ab0b253803f27aa31"
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
    }

    func testSignRequestUnsignedPayloadUsesLiteralMarker() async throws {
        let s3 = makeService()
        let url = URL(string: "https://voicesync-test-bucket.s3.us-east-1.amazonaws.com/recordings/audio.wav")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        let signed = try await s3.signRequest(request, body: nil, unsignedPayload: true, date: fixedDate)

        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-Amz-Content-Sha256"), "UNSIGNED-PAYLOAD")
    }
}
