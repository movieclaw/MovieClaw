package io.movieclaw.android.core.offline

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.core.model.McJson
import io.movieclaw.core.model.generated.AudioPlanView
import io.movieclaw.core.model.generated.AudioTrackView
import io.movieclaw.core.model.generated.PlaybackChapterMarkView
import io.movieclaw.core.model.generated.PlaybackDecisionView
import io.movieclaw.core.model.generated.PlaybackItemView
import io.movieclaw.core.model.generated.PlaybackSegmentView
import io.movieclaw.core.model.generated.PlaybackSessionView
import io.movieclaw.core.model.generated.PlaybackSourceView
import io.movieclaw.core.model.generated.PlaybackStateView
import io.movieclaw.core.model.generated.SeasonEpisodesView
import io.movieclaw.core.model.generated.SubtitlePlanView
import io.movieclaw.core.playback.LocalPlayback
import io.movieclaw.core.playback.LocalPlaybackSource
import io.movieclaw.core.playback.PlaybackUnit
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement

/**
 * 统一播放引擎的本机副本来源（docs/design/offline-download.md §6；iOS `PlaybackController.startLocal` 那一段）：
 * 这一集有下完的副本就按本机存的播放数据拼一个与服务端会话同形的会话，交给同一段装载逻辑——
 * 字幕、片头片尾跳过、章节、轨道菜单、自动下一集都与在线一致。
 */
@Singleton
class OfflineLocalSource @Inject constructor(
    @ApplicationContext private val context: Context,
    private val store: OfflineStore,
    private val reachability: ServerReachability,
    private val apiFactory: ApiFactory,
) : LocalPlaybackSource {

    private fun online(): Boolean = !reachability.isOffline && reachability.status.value != ServerReachability.Status.UNREACHABLE

    override suspend fun awaitLoaded() = store.waitUntilLoaded()

    override suspend fun open(unit: PlaybackUnit, startMs: Long?): LocalPlayback? {
        val local = store.playableUnit(unit.mediaItemId, unit.season.toInt(), unit.episode.toInt()) ?: return null
        val file = store.mediaFile(local)?.takeIf { it.isFile } ?: return null
        val dir = store.unitDir(local) ?: return null
        val key = store.key ?: return null
        val spec = store.spec(local)
        val subtitles = spec?.subtitles.orEmpty()
        var progress = store.localProgress(local.mediaItemId, local.season, local.episode)
        if (startMs == null) {
            serverResume(local, unit)?.let { fresh ->
                // 在线：续播点以服务器为准（别的设备可能看到了更后面）；本机有没发出去的观看记录时仍用本机的
                progress = OfflineProgress(fresh.first, fresh.second, fresh.third, System.currentTimeMillis())
                store.recordProgress(local.mediaItemId, local.season, local.episode, fresh.first, fresh.second, fresh.third)
            }
        }
        val resume = startMs ?: progress?.positionMs ?: 0
        val decision = PlaybackDecisionView(
            outcome = "plan", tier = 0, fileId = local.fileId, container = spec?.container,
            audio = AudioPlanView(action = "copy", trackRef = spec?.defaultAudio),
            audioTracks = decode(spec?.audioTracks, AudioTrackView.serializer()),
            subtitles = subtitles.map {
                SubtitlePlanView(trackRef = it.ref, kind = it.kind, language = it.language, isDefault = it.isDefault, isAi = it.isAi, title = it.title, isForced = it.isForced)
            },
            reason = "播放${OfflineFormat.deviceName(context)}上的副本",
        )
        val session = PlaybackSessionView(
            decision = decision,
            sessionId = null,
            streamUrl = android.net.Uri.fromFile(file).toString(),
            startMs = resume,
            timeline = "file",
            subtitleUrls = subtitles.map { android.net.Uri.fromFile(File(dir, "subs/${it.fileName}")).toString() },
            watch = PlaybackStateView(positionMs = resume, played = progress?.played ?: false, durationMs = spec?.durationMs),
            source = PlaybackSourceView(container = spec?.container, resolution = spec?.resolution, videoCodec = spec?.videoCodec, sizeBytes = local.receivedBytes),
            chapters = decode(spec?.chapters, PlaybackChapterMarkView.serializer()),
            segments = decode(spec?.segments, PlaybackSegmentView.serializer()),
        )
        val origin = store.owner?.origin
        val recorder = OfflineViewingRecorder(local, resume, spec?.durationMs, store, key) {
            origin?.takeIf { online() }?.let { apiFactory.forOrigin(it) }
        }
        return LocalPlayback(session, recorder)
    }

    /** 在线时问一下服务器的续播点（最多等 2 秒，问不到就用本机的） */
    private suspend fun serverResume(local: OfflineUnit, unit: PlaybackUnit): Triple<Long, Boolean, Long?>? {
        val key = store.key ?: return null
        val origin = store.owner?.origin ?: return null
        if (!online() || OfflineViewingUploader.hasPending(key, local.mediaItemId, local.season, local.episode)) return null
        return withTimeoutOrNull(2_000) {
            runCatching {
                val state = apiFactory.forOrigin(origin).resumeState(local.mediaItemId, unit.season.toInt(), unit.episode.toInt()).dataOrThrow()
                Triple(state.positionMs, state.played, state.durationMs)
            }.getOrNull()
        }
    }

    override suspend fun itemInfo(mediaItemId: Long, remote: suspend () -> PlaybackItemView): PlaybackItemView {
        store.waitUntilLoaded()
        val summary = store.state.value.items[mediaItemId]
        val downloaded = store.downloadedItemIds.value.contains(mediaItemId)
        if (summary == null || !(reachability.isOffline || downloaded)) return remote()
        // 离线时条目信息从本机取；在线取不到（连不上）而本机有副本时同样回落，不因此停掉本机播放
        val local = PlaybackItemView(
            mediaItemId = summary.mediaItemId, libraryId = summary.libraryId, kind = summary.kind,
            title = summary.title, year = summary.year?.toLong(), posterUrl = summary.posterUrl,
        )
        if (reachability.isOffline) return local
        return runCatching { remote() }.getOrDefault(local)
    }

    override suspend fun episodes(mediaItemId: Long, season: Long, remote: suspend () -> SeasonEpisodesView): SeasonEpisodesView {
        if (!store.downloadedItemIds.value.contains(mediaItemId)) return remote()
        // 离线（或连不上）：分集取本机存档，「在库」= 本机有，下一集只在本机有的集里找
        if (!reachability.isOffline) runCatching { return remote() }
        val view = store.season(mediaItemId, season.toInt()) ?: return remote()
        val transformed = store.offlineSeason(view.copy(seasonNumber = season.toInt()), mediaItemId)
        val text = store.encodeSeason(transformed)
        return McJson.decodeFromString(SeasonEpisodesView.serializer(), text)
    }

    override fun damaged(unit: PlaybackUnit, fileId: Long): Boolean {
        store.state.value.units[fileId]?.let { store.upsert(it.copy(damaged = true)) }
        return online()
    }

    override fun canUseServer(): Boolean = online()

    private fun <T> decode(element: JsonElement?, serializer: kotlinx.serialization.KSerializer<T>): List<T> =
        element?.let { runCatching { McJson.decodeFromJsonElement(ListSerializer(serializer), it) }.getOrNull() }.orEmpty()
}
