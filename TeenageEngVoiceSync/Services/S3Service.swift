//
//  S3Service.swift
//  TeenageEngVoiceSync
//
//  AWS S3 upload and presigned URL service.
//  Uses URLSession with AWS Signature V4 signing.
//

import Foundation
import CryptoKit

actor S3Service {
    private let bucket: String
    private let region: String
    private let prefix: String
    private let accessKeyId: String
    private let secretAccessKey: String
    private let session: URLSession

    // Character set for AWS query parameter encoding (excludes / and + which must be encoded)
    private static let awsQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/+")
        return allowed
    }()

    init(
        bucket: String,
        region: String,
        prefix: String,
        accessKeyId: String,
        secretAccessKey: String
    ) {
        self.bucket = bucket
        self.region = region
        self.prefix = prefix
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    /// Upload a file to S3
    func upload(fileURL: URL) async throws -> S3UploadResult {
        let filename = fileURL.lastPathComponent
        let s3Key = prefix + filename
        let contentType = "audio/wav"

        // Read file data
        let data = try Data(contentsOf: fileURL)

        // Get file attributes
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? Int64 ?? Int64(data.count)

        // Create request
        let url = URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(s3Key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        // Sign request
        let signedRequest = try signRequest(request, body: data)

        // Execute
        let (_, response) = try await session.data(for: signedRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw S3Error.uploadFailed(statusCode: httpResponse.statusCode)
        }

        return S3UploadResult(
            filename: filename,
            s3Key: s3Key,
            size: fileSize,
            uploadedAt: Date()
        )
    }

    /// Generate a presigned URL for downloading/playing a file
    nonisolated func generatePresignedURL(s3Key: String, expiry: TimeInterval = 3600) throws -> URL {
        let expires = Int(expiry)
        let date = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        let dateStamp = dateFormatter.string(from: date).replacingOccurrences(of: "-", with: "")

        let amzDate = amzDateString(from: date)

        let host = "\(bucket).s3.\(region).amazonaws.com"
        let canonicalURI = "/" + s3Key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!

        // Canonical query string
        let credential = "\(accessKeyId)/\(dateStamp)/\(region)/s3/aws4_request"
        let queryParams = [
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
            "X-Amz-Credential": credential,
            "X-Amz-Date": amzDate,
            "X-Amz-Expires": "\(expires)",
            "X-Amz-SignedHeaders": "host"
        ]

        let canonicalQueryString = queryParams
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: Self.awsQueryAllowed)!
                return "\(key)=\(encodedValue)"
            }
            .joined(separator: "&")

        // Canonical headers
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"

        // Canonical request
        let canonicalRequest = [
            "GET",
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        // String to sign
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let hashedRequest = SHA256.hash(data: canonicalRequest.data(using: .utf8)!)
            .compactMap { String(format: "%02x", $0) }
            .joined()

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hashedRequest
        ].joined(separator: "\n")

        // Calculate signature
        let signature = calculateSignature(
            stringToSign: stringToSign,
            dateStamp: dateStamp,
            region: region,
            service: "s3"
        )

        // Build final URL
        let urlString = "https://\(host)\(canonicalURI)?\(canonicalQueryString)&X-Amz-Signature=\(signature)"
        guard let url = URL(string: urlString) else {
            throw S3Error.invalidURL
        }

        return url
    }

    /// Generate a presigned URL with Content-Disposition for download
    nonisolated func generateDownloadURL(s3Key: String, filename: String, expiry: TimeInterval = 3600) throws -> URL {
        // For simplicity, using the same presigned URL
        // In production, would add response-content-disposition parameter
        try generatePresignedURL(s3Key: s3Key, expiry: expiry)
    }

    /// Delete an object from S3
    func deleteObject(s3Key: String) async throws {
        let url = URL(string: "https://\(bucket).s3.\(region).amazonaws.com/\(s3Key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let signedRequest = try signRequest(request, body: Data())
        let (_, response) = try await session.data(for: signedRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw S3Error.deleteFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Validate bucket access
    func validateBucket() async throws {
        let url = URL(string: "https://\(bucket).s3.\(region).amazonaws.com/")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let signedRequest = try signRequest(request, body: Data())

        let (_, response) = try await session.data(for: signedRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw S3Error.bucketNotAccessible
        }
    }

    // MARK: - AWS Signature V4

    private func signRequest(_ request: URLRequest, body: Data) throws -> URLRequest {
        var signedRequest = request
        let date = Date()
        let amzDate = amzDateString(from: date)
        let dateStamp = dateStampString(from: date)

        let host = request.url!.host!
        signedRequest.setValue(host, forHTTPHeaderField: "Host")
        signedRequest.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")

        // Content hash
        let payloadHash = SHA256.hash(data: body)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        signedRequest.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        // Canonical request
        let method = request.httpMethod ?? "GET"
        let canonicalURI = request.url!.path.isEmpty ? "/" : request.url!.path
        let canonicalQueryString = request.url!.query ?? ""

        let headers = signedRequest.allHTTPHeaderFields ?? [:]
        let sortedHeaders = headers.keys.sorted { $0.lowercased() < $1.lowercased() }
        let canonicalHeaders = sortedHeaders
            .map { "\($0.lowercased()):\(headers[$0]!.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n") + "\n"
        let signedHeaders = sortedHeaders.map { $0.lowercased() }.joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let hashedRequest = SHA256.hash(data: canonicalRequest.data(using: .utf8)!)
            .compactMap { String(format: "%02x", $0) }
            .joined()

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hashedRequest
        ].joined(separator: "\n")

        // Calculate signature
        let signature = calculateSignature(
            stringToSign: stringToSign,
            dateStamp: dateStamp,
            region: region,
            service: "s3"
        )

        // Authorization header
        let credential = "\(accessKeyId)/\(scope)"
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        signedRequest.setValue(authorization, forHTTPHeaderField: "Authorization")

        return signedRequest
    }

    private nonisolated func calculateSignature(stringToSign: String, dateStamp: String, region: String, service: String) -> String {
        let kSecret = "AWS4\(secretAccessKey)".data(using: .utf8)!
        let kDate = hmacSHA256(key: kSecret, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmacSHA256(key: kDate, data: region.data(using: .utf8)!)
        let kService = hmacSHA256(key: kRegion, data: service.data(using: .utf8)!)
        let kSigning = hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)
        let signature = hmacSHA256(key: kSigning, data: stringToSign.data(using: .utf8)!)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature)
    }

    private nonisolated func amzDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private nonisolated func dateStampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

struct S3UploadResult {
    let filename: String
    let s3Key: String
    let size: Int64
    let uploadedAt: Date
}

enum S3Error: LocalizedError {
    case invalidResponse
    case uploadFailed(statusCode: Int)
    case deleteFailed(statusCode: Int)
    case bucketNotAccessible
    case invalidURL
    case credentialsNotConfigured

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from S3"
        case .uploadFailed(let statusCode):
            return "S3 upload failed with status \(statusCode)"
        case .deleteFailed(let statusCode):
            return "S3 delete failed with status \(statusCode)"
        case .bucketNotAccessible:
            return "S3 bucket is not accessible"
        case .invalidURL:
            return "Invalid S3 URL"
        case .credentialsNotConfigured:
            return "AWS credentials not configured"
        }
    }
}
