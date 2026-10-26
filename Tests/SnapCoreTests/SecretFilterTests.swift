import Testing
@testable import SnapCore

@Suite struct SecretFilterTests {
    @Test(arguments: [
        ("key sk_live_51HxQe2LkS8vA0bC9dEfGh12", "key [hidden]"),
        ("sk_test_4eC39HqLyjWDarjtT1zdp7dc", "[hidden]"),
        ("rk_live_abcDEF1234567890xyz", "[hidden]"),
        ("pk_live_abcDEF1234567890xyz", "[hidden]"),
        ("token ghp_16C7e42F292c6912E7710c838347Ae178B4a", "token [hidden]"),
        ("gho_16C7e42F292c6912E7710c838347Ae178B4a", "[hidden]"),
        ("github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "[hidden]"),
        ("xoxb-123456789012-1234567890123-AbCdEfGhIjKlMnOp", "[hidden]"),
        ("xoxp-123456789012-1234567890123-AbCdEfGhIjKlMnOp", "[hidden]"),
        ("AKIAIOSFODNN7EXAMPLE", "[hidden]"),
        ("ASIAIOSFODNN7EXAMPLE", "[hidden]"),
        ("AIzaSyA1234567890abcdefghijklmnopqrstu", "[hidden]"),
        ("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345", "[hidden]"),
        ("export KEY=sk-proj-abcdefghij0123456789ABCD", "export KEY=sk-proj-abcdefghij0123456789ABCD".replacingOccurrences(of: "sk-proj-abcdefghij0123456789ABCD", with: "[hidden]")),
        ("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "Bearer [hidden]"),
        ("Q2FzZSBjbG9zZWQgd2l0aCBubyBhY3Rpb24gbmVlZGVkIGJ5IHVz", "[hidden]"),
        ("secret: aB3dE5fG7hJ9kL1mN2pQ4r", "secret: [hidden]"),
    ])
    func hidesSecret(input: String, expected: String) {
        #expect(SecretFilter.redact([input]) == [expected])
    }

    @Test(arguments: [
        "commit 9fceb02d0ae598e95dc970b74767f19372d61af8",
        "id 123e4567-e89b-12d3-a456-426614174000",
        "internationalization",
        "HistoryWindowController",
        "Stripe error 4402: card declined",
        "截图里的错误信息",
        "https://sdusteric.github.io/app-updates/snap/appcast.xml",
        "ask-me-anything",
    ])
    func keepsOrdinaryText(input: String) {
        #expect(SecretFilter.redact([input]) == [input])
    }

    @Test func hidesEveryLineOfPrivateKeyBlock() {
        let lines = [
            "Here is the key:", "-----BEGIN OPENSSH PRIVATE KEY-----", "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ",
            "AAAAMwAAAAtzc2gtZWQyNTUxOQAAACD", "-----END OPENSSH PRIVATE KEY-----", "done",
        ]
        #expect(SecretFilter.redact(lines) == ["Here is the key:", "[hidden]", "[hidden]", "[hidden]", "[hidden]", "done"])
    }

    @Test func keepsTheRestOfTheLine() {
        #expect(SecretFilter.redact(["use (sk_live_51HxQe2LkS8vA0bC9dEfGh12) here"]) == ["use ([hidden]) here"])
    }
}
