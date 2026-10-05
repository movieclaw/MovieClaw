import Foundation
import Testing
@testable import MovieClaw

/// 服务端错误怎么说给用户听（2026-10-05：服务器还不认识 Mac 版设备类型，登录只报一句英文 request validation failed）
struct APIErrorMessageTests {
    private func body(_ json: String) throws -> APIErrorBody {
        try JSONDecoder().decode(APIErrorBody.self, from: Data(json.utf8))
    }

    @Test func unknownDeviceKindSaysTheServerIsTooOld() throws {
        // NAS 0.31.0 对 Mac 版登录的原样响应
        let error = try body("""
        {"success":false,"code":"VALIDATION_ERROR","message":"request validation failed","details":[{"type":"literal_error",\
        "location":["body","client","kind"],"message":"Input should be 'ios', 'tvos' or 'android'","input":"macos"}]}
        """)
        let message = error.userMessage(status: 422)
        #expect(message.contains("Mac 版 App"))
        #expect(message.contains("服务器版本太旧"))
        #expect(!message.contains("request validation failed"))
    }

    @Test func otherValidationErrorsNameTheFieldAndReason() throws {
        let error = try body("""
        {"success":false,"code":"VALIDATION_ERROR","message":"request validation failed",\
        "details":[{"location":["body","items",2,"name"],"message":"Field required"}]}
        """)
        let message = error.userMessage(status: 422)
        #expect(message.contains("items.2.name"))
        #expect(message.contains("Field required"))
        #expect(message.contains("版本"))
    }

    @Test func validationErrorWithoutDetailsStillExplains() throws {
        let message = try body(#"{"success":false,"code":"VALIDATION_ERROR","message":"request validation failed"}"#)
            .userMessage(status: 422)
        #expect(message.contains("版本可能不一致"))
    }

    @Test func businessErrorsAreShownAsTheServerWroteThem() throws {
        let message = try body(#"{"success":false,"code":"UNAUTHORIZED","message":"用户名或密码错误"}"#).userMessage(status: 401)
        #expect(message == "用户名或密码错误")
        #expect(APIErrorBody(message: nil, code: nil, details: nil).userMessage(status: 500) == "请求失败（HTTP 500）")
    }
}
