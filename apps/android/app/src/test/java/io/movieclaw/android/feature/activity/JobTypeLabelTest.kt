package io.movieclaw.android.feature.activity

import io.movieclaw.android.core.model.JobView
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import org.junit.Assert.assertEquals
import org.junit.Test

/** 任务类型显示名：内置类型用本地文案，插件任务用服务端给的 `job_type_label`，都没有显示原始类型（与网页、iOS 同序）。 */
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
class JobTypeLabelTest {
    private val json = Json {
        ignoreUnknownKeys = true
        namingStrategy = JsonNamingStrategy.SnakeCase
    }

    private fun job(type: String, label: String?): JobView {
        val labelField = if (label == null) "" else ",\"job_type_label\":\"$label\""
        return json.decodeFromString(
            """{"id":"j1","job_type":"$type"$labelField,"status":"succeeded"}""",
        )
    }

    @Test fun localLabelWinsForBuiltInTypes() {
        assertEquals("扫描媒体库", jobTypeLabel(job("library.scan", null)))
        assertEquals("扫描媒体库", jobTypeLabel(job("library.scan", "Scan")))
    }

    @Test fun pluginJobsUseTheServerName() {
        val plugin = job("strm-prefetch:backfill", "网盘规格预探")
        assertEquals("网盘规格预探", jobTypeLabel(plugin))
        assertEquals("网盘规格预探完成", historicalJobTitle(plugin))
    }

    @Test fun rawTypeWhenNothingElse() {
        assertEquals("acme:sync", jobTypeLabel(job("acme:sync", null)))
        assertEquals("acme:sync", jobTypeLabel(job("acme:sync", "")))
    }
}
