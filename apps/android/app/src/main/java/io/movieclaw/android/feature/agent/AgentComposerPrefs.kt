package io.movieclaw.android.feature.agent

import android.content.Context
import io.movieclaw.android.core.model.LlmModelOption
import org.json.JSONObject

/**
 * 对话框「模型 / 思维链」选择的持久化（逐条对齐 iOS `AgentComposerPrefs`）：
 * iOS 用 UserDefaults 存 JSON（key `movieclaw.composer.choice`），这里用 SharedPreferences，
 * 同样的 JSON 结构、同样的「两者都为 null 就删掉」与「对着清单校验」语义。
 *
 * 校验（iOS `reconciled(with:)`）：模型不在清单里 → 模型与档位一起丢弃；档位不在生效模型的
 * 菜单里 → 只丢档位。这样设置页改了默认模型、或模型被下线时，选择不会卡在无效值上。
 */
internal object AgentComposerPrefs {

    private const val PREF = "movieclaw_agent"
    private const val KEY = "movieclaw.composer.choice"

    data class Choice(val model: String? = null, val thinking: String? = null)

    fun load(context: Context): Choice {
        val raw = context.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString(KEY, null)
            ?: return Choice()
        return runCatching {
            val o = JSONObject(raw)
            Choice(model = o.optNullable("model"), thinking = o.optNullable("thinking"))
        }.getOrElse { Choice() }
    }

    fun save(context: Context, choice: Choice) {
        val prefs = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        if (choice.model == null && choice.thinking == null) {
            prefs.edit().remove(KEY).apply()
            return
        }
        val o = JSONObject()
        choice.model?.let { o.put("model", it) }
        choice.thinking?.let { o.put("thinking", it) }
        prefs.edit().putString(KEY, o.toString()).apply()
    }

    fun reconcile(choice: Choice, options: List<LlmModelOption>): Choice {
        if (options.isEmpty()) return choice
        val effective = if (choice.model != null) {
            options.firstOrNull { it.ref == choice.model } ?: return Choice()
        } else {
            options.firstOrNull { it.isDefault } ?: options.first()
        }
        val stops = AgentThinking.stops(effective.thinkingLevels)
        return Choice(choice.model, choice.thinking?.takeIf { it in stops })
    }

    private fun JSONObject.optNullable(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }
}
