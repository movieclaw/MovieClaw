package io.movieclaw.android.core.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * 会话轨迹解码回归：`toolCalls[].arguments` 在服务端是**对象**（解析后的参数，见
 * `movieclaw_llm.models.ToolCall.arguments: dict`），iOS 也按对象解。安卓曾把它声明成
 * `String?`，带工具调用的历史会话一加载就整条失败——
 * 「Unexpected JSON token at offset 934: Expected beginning of the string, but got {」
 * （真机截图 2026-10-09，`mclaw discover --help` 那条）。这里锁死两种形态都能解。
 */
class AgentToolCallDecodeTest {

    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        namingStrategy = JsonNamingStrategy.SnakeCase
    }

    @Test fun toolCallArgumentsDecodeAsObject() {
        val payload = """
        {
          "message_id": "m2",
          "timestamp": "2026-10-09T20:07:00Z",
          "message": {
            "role": "assistant",
            "content": "我来查一下。",
            "tool_calls": [
              {
                "id": "call_1",
                "name": "mclaw",
                "arguments": {"args": "discover --help"},
                "raw_arguments": "{\"args\": \"discover --help\"}",
                "parse_error": null
              }
            ]
          }
        }
        """.trimIndent()

        val entry = json.decodeFromString<TranscriptEntry>(payload)
        val call = entry.message?.toolCalls?.firstOrNull()
        assertNotNull("工具调用必须解出来（此前对象参数会让整条会话加载失败）", call)
        assertEquals("mclaw", call!!.name)
        val args = call.arguments?.jsonObject
        assertNotNull("arguments 应为已解析的对象", args)
        assertEquals("discover --help", args!!["args"]?.jsonPrimitive?.content)
        assertEquals("{\"args\": \"discover --help\"}", call.rawArguments)
    }

    @Test fun stringifiedArgumentsStillDecode() {
        // 老数据 / 某些供应商可能给字符串化参数：JsonElement 一并收下（比 iOS 的对象声明更宽容）
        val payload = """
        {"message":{"role":"assistant","tool_calls":[{"id":"c","name":"mclaw","arguments":"{\"args\":\"x\"}"}]}}
        """.trimIndent()
        val entry = json.decodeFromString<TranscriptEntry>(payload)
        assertEquals("{\"args\":\"x\"}", entry.message?.toolCalls?.firstOrNull()?.arguments?.jsonPrimitive?.content)
    }

    @Test fun sessionMessageWithoutToolCallsStillDecodes() {
        val payload = """{"message":{"role":"user","content":"你好"}}"""
        val entry = json.decodeFromString<TranscriptEntry>(payload)
        assertEquals("user", entry.message?.role)
    }
}
