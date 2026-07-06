//
//  S3ListParserTests.swift
//  TeenageEngVoiceSyncTests
//
//  Canned ListObjectsV2 XML fixtures, including a truncated page with a
//  continuation token and a final untruncated page.
//

import XCTest
@testable import TP_7_VoiceSync

final class S3ListParserTests: XCTestCase {
    private let truncatedPageXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Name>voicesync-test-bucket</Name>
        <Prefix>recordings/</Prefix>
        <KeyCount>2</KeyCount>
        <MaxKeys>2</MaxKeys>
        <IsTruncated>true</IsTruncated>
        <NextContinuationToken>abc123token==</NextContinuationToken>
        <Contents>
            <Key>recordings/session01.wav</Key>
            <LastModified>2024-01-15T10:30:00.000Z</LastModified>
            <Size>1048576</Size>
            <StorageClass>STANDARD</StorageClass>
        </Contents>
        <Contents>
            <Key>recordings/session02.wav</Key>
            <LastModified>2024-01-16T08:00:00.000Z</LastModified>
            <Size>2097152</Size>
            <StorageClass>STANDARD</StorageClass>
        </Contents>
    </ListBucketResult>
    """

    private let finalPageXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Name>voicesync-test-bucket</Name>
        <Prefix>recordings/</Prefix>
        <KeyCount>1</KeyCount>
        <MaxKeys>2</MaxKeys>
        <IsTruncated>false</IsTruncated>
        <Contents>
            <Key>recordings/session03.wav</Key>
            <LastModified>2024-01-17T12:00:00.000Z</LastModified>
            <Size>512000</Size>
            <StorageClass>STANDARD</StorageClass>
        </Contents>
    </ListBucketResult>
    """

    func testParsesTruncatedPageWithContinuationToken() throws {
        let result = try S3ListParser.parse(truncatedPageXML.data(using: .utf8)!)

        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.nextContinuationToken, "abc123token==")
        XCTAssertEqual(result.objects.count, 2)

        XCTAssertEqual(result.objects[0].key, "recordings/session01.wav")
        XCTAssertEqual(result.objects[0].size, 1_048_576)
        XCTAssertEqual(result.objects[0].filename, "session01.wav")

        XCTAssertEqual(result.objects[1].key, "recordings/session02.wav")
        XCTAssertEqual(result.objects[1].size, 2_097_152)
    }

    func testParsesLastModifiedWithFractionalSeconds() throws {
        let result = try S3ListParser.parse(truncatedPageXML.data(using: .utf8)!)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2024-01-15T10:30:00.000Z")!

        XCTAssertEqual(result.objects[0].lastModified.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testParsesFinalUntruncatedPage() throws {
        let result = try S3ListParser.parse(finalPageXML.data(using: .utf8)!)

        XCTAssertFalse(result.isTruncated)
        XCTAssertNil(result.nextContinuationToken)
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects[0].key, "recordings/session03.wav")
    }

    func testEmptyBucketProducesNoObjects() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Name>voicesync-test-bucket</Name>
            <KeyCount>0</KeyCount>
            <IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """
        let result = try S3ListParser.parse(xml.data(using: .utf8)!)

        XCTAssertFalse(result.isTruncated)
        XCTAssertTrue(result.objects.isEmpty)
        XCTAssertNil(result.nextContinuationToken)
    }

    func testContentsWithEmptyKeyIsSkipped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key></Key>
                <LastModified>2024-01-15T10:30:00.000Z</LastModified>
                <Size>0</Size>
            </Contents>
        </ListBucketResult>
        """
        let result = try S3ListParser.parse(xml.data(using: .utf8)!)

        XCTAssertTrue(result.objects.isEmpty)
    }
}
