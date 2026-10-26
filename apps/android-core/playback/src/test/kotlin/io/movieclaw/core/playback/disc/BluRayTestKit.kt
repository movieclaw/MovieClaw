package io.movieclaw.core.playback.disc

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.common.Format
import androidx.media3.common.util.ParsableByteArray
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.extractor.DefaultExtractorInput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.TrackOutput
import java.io.ByteArrayOutputStream

/** 收集解析结果的假输出：每条轨的格式与样本（时间、标志、字节） */
class FakeOutput : ExtractorOutput {
    val tracks = linkedMapOf<Int, FakeTrack>()
    var seekMap: SeekMap? = null
    var tracksEnded = false

    override fun track(id: Int, type: Int): TrackOutput = tracks.getOrPut(id) { FakeTrack(type) }
    override fun endTracks() {
        tracksEnded = true
    }
    override fun seekMap(seekMap: SeekMap) {
        this.seekMap = seekMap
    }
}

class FakeTrack(val type: Int) : TrackOutput {
    data class Sample(val timeUs: Long, val flags: Int, val data: ByteArray) {
        val isKey: Boolean get() = flags and C.BUFFER_FLAG_KEY_FRAME != 0
    }

    var format: Format? = null
    val samples = mutableListOf<Sample>()
    private val bytes = ByteArrayOutputStream()

    override fun format(format: Format) {
        this.format = format
    }

    override fun sampleData(input: DataReader, length: Int, allowEndOfInput: Boolean, sampleDataPart: Int): Int {
        val chunk = ByteArray(length)
        val n = input.read(chunk, 0, length)
        if (n == C.RESULT_END_OF_INPUT) return n
        bytes.write(chunk, 0, n)
        return n
    }

    override fun sampleData(data: ParsableByteArray, length: Int, sampleDataPart: Int) {
        val chunk = ByteArray(length)
        data.readBytes(chunk, 0, length)
        bytes.write(chunk)
    }

    override fun sampleMetadata(timeUs: Long, flags: Int, size: Int, offset: Int, cryptoData: TrackOutput.CryptoData?) {
        val all = bytes.toByteArray()
        val end = all.size - offset
        samples += Sample(timeUs, flags, all.copyOfRange(end - size, end))
    }
}

/** 初始化后从头读到底，返回收集到的结果 */
fun extractM2ts(extractor: Extractor, m2ts: ByteArray, output: FakeOutput = FakeOutput()): FakeOutput {
    extractor.init(output)
    readM2ts(extractor, m2ts, 0)
    return output
}

/** 从去头后的 [position] 起把 m2ts 读到底（解析器要求跳转时照办） */
fun readM2ts(extractor: Extractor, m2ts: ByteArray, position: Long) {
    val holder = PositionHolder()
    var at = position
    while (true) {
        val source = M2tsDataSource(ByteArrayDataSource(m2ts))
        source.open(DataSpec.Builder().setUri(Uri.EMPTY).setPosition(at).build())
        val input = DefaultExtractorInput(source, at, C.LENGTH_UNSET.toLong())
        var result = Extractor.RESULT_CONTINUE
        while (result == Extractor.RESULT_CONTINUE) result = extractor.read(input, holder)
        source.close()
        if (result == Extractor.RESULT_END_OF_INPUT) return
        at = holder.position
    }
}

fun hex(text: String): ByteArray = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

fun resource(name: String): ByteArray = requireNotNull(FakeOutput::class.java.classLoader!!.getResourceAsStream(name)) { name }.readBytes()
