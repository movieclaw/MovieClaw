import Testing
@testable import MovieClaw

struct ProfileSettingsTests {
    @Test func nicknameTrimsWhitespaceAndEnforcesServerLength() {
        #expect(ProfileSettingsValidation.nickname(" \n ") != nil)
        #expect(ProfileSettingsValidation.nickname("  影迷  ") == nil)
        #expect(ProfileSettingsValidation.nickname(String(repeating: "影", count: 32)) == nil)
        #expect(ProfileSettingsValidation.nickname(String(repeating: "影", count: 33)) != nil)
        // 一个组合表情包含多个 Unicode 字符，必须遵守服务端长度限制。
        #expect(ProfileSettingsValidation.nickname(String(repeating: "👨‍👩‍👧‍👦", count: 8)) != nil)
    }

    @Test func passwordRequiresAllFieldsAndMatchingConfirmation() {
        var value = ProfilePasswordDraft()
        #expect(!value.valid && !value.changed && !value.signOutPaired)
        value.current = "current"
        value.new = "12345678"
        #expect(!value.valid)
        value.confirmation = "different"
        #expect(!value.valid && value.validation != nil)
        value.confirmation = value.new
        #expect(value.valid && value.changed)
    }

    @Test func passwordLengthMatchesServerAndPreservesSpaces() {
        var value = ProfilePasswordDraft(current: " old ", new: "1234567", confirmation: "1234567")
        #expect(!value.valid)
        value.new = " 123456 "
        value.confirmation = value.new
        #expect(value.valid && value.current == " old " && value.new == " 123456 ")
        value.new = String(repeating: "a", count: 128)
        value.confirmation = value.new
        #expect(value.valid)
        value.new += "a"
        value.confirmation = value.new
        #expect(!value.valid)
    }
}
