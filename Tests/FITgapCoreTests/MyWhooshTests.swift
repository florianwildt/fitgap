import Foundation
import Testing
@testable import FITgapCore

@Test func myWhooshParsesNestedResults() throws {
    let page = try MyWhooshProbe.parse(Data(#"""
    {"data":{"currentPage":1,"totalPages":3,"results":[
      {"id":"a1","title":"MyWhoosh - Synthetic","date":1771171823,"rideDuration":"1:02:03","activityFileId":"f-1"},
      {"id":"a2","title":"Fallback","date":0,"startDatetime":"2026-01-01T10:00:00Z","rideDuration":"95"},
      {"name":"No id"}
    ]}}
    """#.utf8))
    #expect(page.itemCount == 3)
    #expect(page.totalPages == 3)
    let activities = try #require(page.activities)
    #expect(activities.map(\.id) == ["a1", "a2"])
    #expect(activities[0].start == Date(timeIntervalSince1970: 1_771_171_823))
    #expect(activities[0].duration == 3723 && activities[0].fileID == "f-1")
    #expect(activities[1].start == ActivityRecord.parseDate("2026-01-01T10:00:00Z"))
    #expect(activities[1].duration == 95 && activities[1].fileID == nil)
    #expect(activities[0].key == ActivityKey(source: "mywhoosh", id: "a1"))

    let records = activities.map(ActivityRecord.init)
    #expect(records[0].source == .mywhoosh && records[0].status == .pending && records[0].name == "MyWhoosh - Synthetic")
    #expect(records[1].status == .unavailable)
    #expect(records[0].key == activities[0].key)
}

@Test func myWhooshDurationFormats() {
    #expect(MyWhooshActivity.seconds("12:30") == 750)
    #expect(MyWhooshActivity.seconds("x:30") == nil)
    #expect(MyWhooshActivity.seconds("1:2:3:4") == nil)
    #expect(MyWhooshActivity.seconds("-5") == nil)
}

@Test func myWhooshSessionKeepsAccountAndJWTExpiry() throws {
    func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let jwt = base64URL(#"{"alg":"none"}"#) + "." + base64URL(#"{"exp":1800000000}"#) + ".sig"
    let credentials = MyWhooshSession(token: jwt, whooshID: "w-1").credentials
    #expect(credentials.accountID == "w-1" && credentials.refreshToken == nil)
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(try MyWhooshSession(credentials).whooshID == "w-1")
    #expect(MyWhooshSession(token: "opaque", whooshID: "w").credentials.expiresAt == nil)
    #expect(throws: AccountError.self) {
        try MyWhooshSession(Credentials(accessToken: "t", refreshToken: nil, expiresAt: nil))
    }
}

@Test func myWhooshShapeHidesValues() throws {
    let page = try MyWhooshProbe.parse(Data(#"{"data":[{"id":"7","name":"Secret ride","private":false}]}"#.utf8))
    #expect(page.shape == "{data: [1 × {id: string, name: string, private: bool}]}")
    #expect(!page.shape.contains("Secret"))
}

@Test func myWhooshMissingListIsReported() throws {
    let page = try MyWhooshProbe.parse(Data(#"{"Success":false,"Message":"x"}"#.utf8))
    #expect(page.activities == nil && page.itemCount == 0 && page.totalPages == nil)
}

@Test func myWhooshSignedLinksArePlainHTTPS() {
    #expect(MyWhooshActivity.allowed(URL(string: "https://bucket.s3.amazonaws.com/x.fit?X-Amz-Signature=1")!) != nil)
    #expect(MyWhooshActivity.allowed(URL(string: "http://files.mywhoosh.com/x.fit")!) == nil)
    #expect(MyWhooshActivity.allowed(URL(string: "https://user@files.mywhoosh.com/x.fit")!) == nil)
    #expect(MyWhooshActivity.allowed(URL(string: "https://files.mywhoosh.com:8443/x.fit")!) == nil)
    #expect(MyWhooshActivity.allowed(URL(string: "file:///etc/passwd")!) == nil)
}

@Test func myWhooshDownloadDiagnosticsNameTheFormatOnly() {
    #expect(MyWhooshProbe.describe(Data([0x50, 0x4B, 3, 4, 0, 0])).contains("zip"))
    #expect(MyWhooshProbe.describe(Data("{\"error\":true}".utf8)).contains("json"))
    let fit = Data([14, 0x20, 0, 0, 10, 0, 0, 0] + Array(".FIT".utf8) + [0, 0, 1, 2])
    #expect(MyWhooshProbe.describe(fit) == "16 bytes, fit, signature 0e200000, header 14, declared 26 bytes")
}
