//
//  S3Service.swift
//  TeenageEngVoiceSync
//
//  S3-compatible upload and presigned URL service (AWS S3, Backblaze B2, etc).
//  Uses URLSession with AWS Signature V4 signing.
//

import Foundation
import CryptoKit

/// S3-compatible storage providers supported by the app.
enum S3Provider: String, CaseIterable, Identifiable, Codable {
    case aws
    case backblazeB2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aws: return "AWS S3"
        case .backblazeB2: return "Backblaze B2"
        }
    }

    var defaultRegion: String {
        switch self {
        case .aws: return "us-east-1"
        case .backblazeB2: return "us-west-004"
        }
    }

    /// Virtual-hosted-style endpoint host, e.g. "s3.us-east-1.amazonaws.com".
    /// The bucket name is prepended by the caller: "\(bucket).\(endpointHost)".
    func endpointHost(region: String) -> String {
        switch self {
        case .aws: return "s3.\(region).amazonaws.com"
        case .backblazeB2: return "s3.\(region).backblazeb2.com"
        }
    }
}

actor S3Service {
    private let bucket: String
    private let region: String
    private let endpointHost: String
    private let prefix: String
    private let accessKeyId: String
    private let secretAccessKey: String
    private let session: URLSession

    // SigV4 canonical query encoding: percent-encode every character except the
    // RFC 3986 unreserved set. `.urlQueryAllowed` leaves reserved characters like
    // `=`, `&`, `+`, and `/` unescaped, which breaks signing for opaque values such
    // as S3 continuation tokens (which routinely contain `=` and `/`).
    private static let awsQueryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    )

    init(
        bucket: String,
        region: String,
        prefix: String,
        accessKeyId: String,
        secretAccessKey: String,
        provider: S3Provider = .aws
    ) {
        self.bucket = bucket
        self.region = region
        self.endpointHost = provider.endpointHost(region: region)
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
        let url = URL(string: "https://\(bucket).\(endpointHost)/\(s3Key)")!
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

        let host = "\(bucket).\(endpointHost)"
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
        let expires = Int(expiry)
        let date = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        let dateStamp = dateFormatter.string(from: date).replacingOccurrences(of: "-", with: "")

        let amzDate = amzDateString(from: date)

        let host = "\(bucket).\(endpointHost)"
        let canonicalURI = "/" + s3Key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!

        let disposition = "attachment; filename=\"\(filename)\""

        // Canonical query string
        let credential = "\(accessKeyId)/\(dateStamp)/\(region)/s3/aws4_request"
        let queryParams = [
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
            "X-Amz-Credential": credential,
            "X-Amz-Date": amzDate,
            "X-Amz-Expires": "\(expires)",
            "X-Amz-SignedHeaders": "host",
            "response-content-disposition": disposition
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

    /// Delete an object from S3
    func deleteObject(s3Key: String) async throws {
        let url = URL(string: "https://\(bucket).\(endpointHost)/\(s3Key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let signedRequest = try signRequest(request, body: Data())
        let (_, response) = try await session.data(for: signedRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 else {
            throw S3Error.deleteFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// List objects under the configured prefix. Returns keys and metadata
    /// for all objects (paginates automatically).
    func listObjects() async throws -> [S3ObjectInfo] {
        var results: [S3ObjectInfo] = []
        var continuationToken: String?

        repeat {
            var components = URLComponents(string: "https://\(bucket).\(endpointHost)/")!
            var pairs = [("list-type", "2"), ("prefix", prefix)]
            if let token = continuationToken {
                pairs.append(("continuation-token", token))
            }
            // Percent-encode values ourselves (a continuation token can contain
            // `+`, `/`, or `=`) so the transmitted query matches what we sign.
            components.percentEncodedQuery = pairs
                .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: Self.awsQueryAllowed) ?? $0.1)" }
                .joined(separator: "&")

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            let signedRequest = try signRequest(request, body: Data())

            let (data, response) = try await session.data(for: signedRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw S3Error.invalidResponse
            }

            let parsed = try S3ListParser.parse(data)
            results.append(contentsOf: parsed.objects)
            continuationToken = parsed.isTruncated ? parsed.nextContinuationToken : nil
        } while continuationToken != nil

        return results
    }

    /// Download an object's bytes by key. Used to re-transcribe recordings that
    /// were restored by startup recovery and have no local audio copy.
    func download(s3Key: String) async throws -> Data {
        let presignedURL = try generatePresignedURL(s3Key: s3Key, expiry: 3600)
        let (data, response) = try await session.data(from: presignedURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw S3Error.invalidResponse
        }
        return data
    }

    /// Validate bucket access
    func validateBucket() async throws {
        let url = URL(string: "https://\(bucket).\(endpointHost)/")!
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

        // Canonicalize the query per SigV4: percent-encode each name/value
        // (so `/` in a prefix becomes %2F), then sort by encoded name. Signing
        // `url.query` verbatim would leave it unsorted and unencoded, which the
        // server rejects with a 403.
        let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var encodedPairs: [(name: String, value: String)] = []
        for item in queryItems {
            let rawValue = item.value ?? ""
            let name = item.name.addingPercentEncoding(withAllowedCharacters: Self.awsQueryAllowed) ?? item.name
            let value = rawValue.addingPercentEncoding(withAllowedCharacters: Self.awsQueryAllowed) ?? rawValue
            encodedPairs.append((name: name, value: value))
        }
        encodedPairs.sort { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        let canonicalQueryString = encodedPairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")

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
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.string(from: date)
    }

    private nonisolated func dateStampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.string(from: date)
    }
}

struct S3UploadResult {
    let filename: String
    let s3Key: String
    let size: Int64
    let uploadedAt: Date
}

struct S3ObjectInfo {
    let key: String
    let size: Int64
    let lastModified: Date

    var filename: String { URL(fileURLWithPath: key).lastPathComponent }
}

private class S3ListParser: NSObject, XMLParserDelegate {
    struct Result {
        var objects: [S3ObjectInfo] = []
        var isTruncated = false
        var nextContinuationToken: String?
    }

    private var result = Result()
    private var currentElement = ""
    private var currentText = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentLastModified = Date()
    private var inContents = false

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ data: Data) throws -> Result {
        let parser = S3ListParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.result
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = element
        currentText = ""
        if element == "Contents" { inContents = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "Key" where inContents:
            currentKey = text
        case "Size" where inContents:
            currentSize = Int64(text) ?? 0
        case "LastModified" where inContents:
            currentLastModified = Self.dateFormatter.date(from: text) ?? Date()
        case "Contents":
            if !currentKey.isEmpty && currentKey != "" {
                result.objects.append(S3ObjectInfo(key: currentKey, size: currentSize, lastModified: currentLastModified))
            }
            inContents = false
            currentKey = ""
            currentSize = 0
        case "IsTruncated":
            result.isTruncated = text.lowercased() == "true"
        case "NextContinuationToken":
            result.nextContinuationToken = text
        default:
            break
        }
    }
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
