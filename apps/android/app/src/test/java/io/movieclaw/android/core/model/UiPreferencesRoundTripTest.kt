package io.movieclaw.android.core.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

class UiPreferencesRoundTripTest {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        namingStrategy = JsonNamingStrategy.SnakeCase
    }

    @Test fun `type row source survives decoding and encoding`() {
        val source = """{"id":"row:tv","media_kind":"tv","sort":"random","name":"今晚追哪部","hidden":true}"""
        val row = json.decodeFromString<HomeRowPref>(source)
        assertEquals(json.parseToJsonElement(source).jsonObject,
            json.parseToJsonElement(json.encodeToString(row)).jsonObject)
    }
}
