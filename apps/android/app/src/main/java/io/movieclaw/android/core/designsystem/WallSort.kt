package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.SwapVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 海报墙排序（iOS `WallSortMenu` / Web `lib/wall-sort.ts`）：
 * 每个档位一项，**当前档位再点一次翻转方向**；菜单底再放一条「方向：X」的显式开关。
 * 同一个方向档案表：title/probing A→Z、时间类 旧→新、评分 低→高、片长 短→长、体积 小→大、最近观看 远→近。
 */
data class WallSortDirection(
    val naturalAsc: Boolean,
    val asc: String,
    val desc: String,
) {
    /** 反转了自然方向才带 order（与 Web `orderParam` 同一条规矩） */
    fun orderParam(reversed: Boolean): String? = if (!reversed) null else if (naturalAsc) "desc" else "asc"

    /** 当前方向的人话 */
    fun label(reversed: Boolean): String = if (naturalAsc != reversed) asc else desc

    companion object {
        fun of(sort: String): WallSortDirection? = when (sort) {
            "title", "probing" -> WallSortDirection(naturalAsc = true, asc = "A→Z", desc = "Z→A")
            "added_at", "release_date", "favorited_at" -> WallSortDirection(naturalAsc = false, asc = "旧→新", desc = "新→旧")
            "rating" -> WallSortDirection(naturalAsc = false, asc = "低→高", desc = "高→低")
            "runtime" -> WallSortDirection(naturalAsc = true, asc = "短→长", desc = "长→短")
            "size" -> WallSortDirection(naturalAsc = false, asc = "小→大", desc = "大→小")
            "last_played" -> WallSortDirection(naturalAsc = false, asc = "远→近", desc = "近→远")
            else -> null
        }
    }
}

data class WallSortOption(val value: String, val label: String, val direction: WallSortDirection? = null)

data class WallSortState(val sort: String = "default", val reversed: Boolean = false)

/** 我的收藏的档位表（iOS `FavoritesView.sortOptions`）：默认档叫「最近收藏」 */
val FavoritesSortOptions: List<WallSortOption> = listOf(
    WallSortOption("default", "最近收藏", WallSortDirection.of("favorited_at")),
    WallSortOption("title", "按标题", WallSortDirection.of("title")),
    WallSortOption("added_at", "最近添加", WallSortDirection.of("added_at")),
    WallSortOption("release_date", "按上映时间", WallSortDirection.of("release_date")),
    WallSortOption("rating", "按评分", WallSortDirection.of("rating")),
    WallSortOption("runtime", "按片长", WallSortDirection.of("runtime")),
    WallSortOption("size", "按体积", WallSortDirection.of("size")),
    WallSortOption("last_played", "最近观看", WallSortDirection.of("last_played")),
)

/** 默认档在请求里叫 `favorited_at`（iOS `effectiveSort`） */
fun WallSortState.effectiveSort(): String = if (sort == "default") "favorited_at" else sort

/** 胶囊触发键：当前档名 + 方向箭头（自然方向时朝上）+ 展开箭头 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WallSortMenu(
    options: List<WallSortOption>,
    state: WallSortState,
    onPick: (WallSortState) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.value == state.sort } ?: options.firstOrNull()
    Box(modifier) {
        Row(
            Modifier
                .height(34.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color.White.copy(alpha = 0.06f))
                .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                .clickable { open = true }
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(current?.label ?: "排序", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            current?.direction?.let { direction ->
                Spacer(Modifier.width(4.dp))
                Icon(
                    if (direction.naturalAsc != state.reversed) Icons.Rounded.ArrowUpward else Icons.Rounded.ArrowDownward,
                    contentDescription = null, tint = TextPrimary,
                    modifier = Modifier.size(14.dp),
                )
            }
            Spacer(Modifier.width(4.dp))
            Icon(
                Icons.Rounded.KeyboardArrowDown, contentDescription = null,
                tint = TextMuted, modifier = Modifier.size(16.dp),
            )
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            shape = RoundedCornerShape(14.dp),
            containerColor = Color(0xFF15161A),
        ) {
            options.forEach { option ->
                val active = option.value == state.sort
                DropdownMenuItem(
                    text = {
                        Text(
                            // 当前档把方向也写出来（「按评分 · 高→低」）
                            option.label + (if (active) option.direction?.let { " · ${it.label(state.reversed)}" } ?: "" else ""),
                            fontSize = 14.sp,
                            color = if (active) TextPrimary else TextMuted,
                            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    },
                    onClick = {
                        open = false
                        // 当前档再点一次 = 翻方向（iOS WallSortMenu 同一手势）
                        onPick(
                            if (active && option.direction != null) state.copy(reversed = !state.reversed)
                            else WallSortState(option.value, reversed = false),
                        )
                    },
                    leadingIcon = if (active) {
                        { Icon(Icons.Rounded.Check, contentDescription = null, tint = Accent, modifier = Modifier.size(18.dp)) }
                    } else null,
                )
            }
            current?.direction?.let { direction ->
                HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                DropdownMenuItem(
                    text = {
                        Text(
                            "方向：${direction.label(state.reversed)}",
                            fontSize = 14.sp, color = TextMuted,
                        )
                    },
                    onClick = { open = false; onPick(state.copy(reversed = !state.reversed)) },
                    leadingIcon = {
                        Icon(Icons.Rounded.SwapVert, contentDescription = null, tint = TextMuted, modifier = Modifier.size(18.dp))
                    },
                )
            }
        }
    }
}
