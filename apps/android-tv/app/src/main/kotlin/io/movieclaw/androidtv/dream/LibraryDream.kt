package io.movieclaw.androidtv.dream

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.service.dreams.DreamService
import android.util.Log
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import io.movieclaw.androidtv.system.WatchNextImageProvider
import io.movieclaw.androidtv.system.WatchNextPublisher
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 海报屏保（androidtv-mc-screensaver.md）：待机轮播「继续观看」的剧照，角标 MovieClaw。
 *
 * 数据来自 [WatchNextPublisher] 顺手落盘的 dream.json 与同目录剧照（cacheDir/watchnext）——
 * 待机期间一帧网络都不拉；没有内容（未登录/空库）退到 MovieClaw 标 + 时钟。
 * 纪律与桌面壳一致：这是最不能失败的表面，任何异常都只往降级走，不重试轰炸、不崩循环。
 */
class LibraryDream : DreamService() {

    private data class Entry(val title: String, val subtitle: String, val image: File)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var entries: List<Entry> = emptyList()
    private var index = -1
    private var imageView: ImageView? = null
    private var caption: TextView? = null
    private var fallbackClock: TextView? = null

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        entries = load()
        setContentView(buildView())
        handler.post(::advance)
    }

    override fun onDetachedFromWindow() {
        handler.removeCallbacksAndMessages(null)
        scope.cancel()
        imageView?.setImageDrawable(null)
        super.onDetachedFromWindow()
    }

    private fun load(): List<Entry> = runCatching {
        val dir = File(cacheDir, WatchNextImageProvider.DIR)
        val state = File(dir, WatchNextImageProvider.DREAM_STATE)
        if (!state.isFile) return emptyList()
        val array = org.json.JSONArray(state.readText())
        (0 until array.length()).mapNotNull { i ->
            val item = array.getJSONObject(i)
            val file = File(dir, item.getString("image"))
            if (file.isFile) Entry(item.getString("title"), item.optString("subtitle"), file) else null
        }
    }.getOrDefault(emptyList())

    private fun buildView(): android.view.View {
        val root = FrameLayout(this).apply { setBackgroundColor(0xFF0B0D12.toInt()) }
        imageView = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            alpha = 0f
        }
        root.addView(imageView, FrameLayout.LayoutParams(-1, -1))

        caption = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 18f
            setShadowLayer(6f, 0f, 2f, 0xAA000000.toInt())
        }
        root.addView(
            caption,
            FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START).apply { setMargins(48, 0, 48, 56) },
        )

        val brand = TextView(this).apply {
            text = "MovieClaw"
            setTextColor(0xB3FFFFFF.toInt())
            textSize = 13f
        }
        root.addView(
            brand,
            FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.END).apply { setMargins(0, 0, 48, 56) },
        )

        fallbackClock = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 40f
            gravity = Gravity.CENTER
            visibility = android.view.View.GONE
        }
        root.addView(
            fallbackClock,
            FrameLayout.LayoutParams(-2, -2, Gravity.CENTER),
        )
        return root
    }

    /** 轮播一帧：有条目就淡入下一张剧照；没有就退到「MovieClaw + 时钟」，同样按节奏走（给时钟刷新留口子）。 */
    private fun advance() {
        if (entries.isEmpty()) showFallback() else showNext()
        handler.postDelayed(::advance, PERIOD_MS)
    }

    private fun showNext() {
        val entry = entries[(index + 1).mod(entries.size)]
        index = (index + 1).mod(entries.size)
        val view = imageView ?: return
        scope.launch {
            val bitmap = withContext(Dispatchers.IO) { decode(entry.image) }
            if (bitmap == null) return@launch
            fallbackClock?.visibility = android.view.View.GONE
            view.setImageBitmap(bitmap)
            view.animate().alpha(1f).setDuration(900).start()
            caption?.text = buildString {
                append(entry.title)
                if (entry.subtitle.isNotBlank()) append(" · ").append(entry.subtitle)
            }
        }
    }

    private fun showFallback() {
        imageView?.alpha = 0f
        caption?.text = ""
        fallbackClock?.apply {
            visibility = android.view.View.VISIBLE
            text = SimpleDateFormat("HH:mm\nEE", Locale.getDefault()).format(Date())
        }
    }

    /** 按屏宽降采样解码；失败返回 null（本张跳过，下一轮再试）。 */
    private fun decode(file: File): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val target = resources.displayMetrics.widthPixels
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= target) sample *= 2
        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }.onFailure { Log.w(TAG, "屏保剧照解码失败：${file.name}", it) }.getOrNull()

    private companion object {
        const val TAG = "LibraryDream"
        const val PERIOD_MS = 10_000L
    }
}
