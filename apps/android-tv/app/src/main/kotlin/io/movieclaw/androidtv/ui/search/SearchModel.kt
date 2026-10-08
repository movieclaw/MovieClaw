package io.movieclaw.androidtv.ui.search

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.movieclaw.androidtv.core.model.generated.LibrarySearchHit
import io.movieclaw.androidtv.core.model.generated.LibrarySearchPerson
import io.movieclaw.androidtv.core.model.generated.LibrarySearchSuggestion
import io.movieclaw.androidtv.core.network.generated.McApi
import io.movieclaw.androidtv.core.session.SearchResults
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 搜索状态（TVSearchModel）：输入防抖 350 毫秒、按键盘上的「搜索」立即搜；请求序号保护搜索和翻页，旧响应不能覆盖新输入。
 * 一轮浏览的结果不随后台索引刷新换序；翻页只追加、按作品 ID 去重。
 *
 * 放在 ViewModel 里（按账号区分）：搜索页签里点进详情再退回来，页面会重建，结果、输入和焦点要原样还在。
 */
class SearchModel(private val api: McApi) : ViewModel() {
    var query by mutableStateOf("")
        private set
    var items by mutableStateOf<List<LibrarySearchHit>>(emptyList())
        private set
    var people by mutableStateOf<List<LibrarySearchPerson>>(emptyList())
        private set
    var suggestions by mutableStateOf<List<LibrarySearchSuggestion>>(emptyList())
        private set
    var nextCursor by mutableStateOf<String?>(null)
        private set
    var searching by mutableStateOf(false)
        private set
    var loadingMore by mutableStateOf(false)
        private set
    var failed by mutableStateOf<String?>(null)
        private set

    /** 最后获得焦点的是哪一张（「item:id」「person:id」「more」「field」）：退回本页时还给它 */
    var focusedKey: String? = null

    val trimmed: String get() = query.trim()

    private var input = ""
    private var loadedInput: String? = null
    private var generation = 0
    private var job: Job? = null

    /** 输入变了：去掉首尾空白后真的变了才重搜（防抖） */
    fun onQueryChange(text: String) {
        query = text
        val next = text.trim()
        if (next == input && (loadedInput == next || searching)) return
        search(next, immediately = false)
    }

    /** 键盘上按「搜索」、点联想词、点「重试」：立即搜 */
    fun submit(text: String = query) {
        query = text
        search(text.trim(), immediately = true)
    }

    private fun search(text: String, immediately: Boolean) {
        job?.cancel()
        generation++
        val request = generation
        input = text
        loadedInput = null
        failed = null
        nextCursor = null
        loadingMore = false
        // 新的输入：上一轮的焦点不再有意义
        focusedKey = null
        if (text.isEmpty()) {
            items = emptyList()
            people = emptyList()
            suggestions = emptyList()
            searching = false
            loadedInput = text
            return
        }
        searching = true
        job = viewModelScope.launch {
            try {
                if (!immediately) delay(350)
                val result = api.searchLibrary(q = text)
                if (generation != request) return@launch
                items = result.items
                people = result.people
                suggestions = result.suggestions
                nextCursor = result.nextCursor
                loadedInput = text
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation == request) failed = e.message ?: "搜索失败"
            } finally {
                if (generation == request) searching = false
            }
        }
    }

    /** 「更多结果」：按游标取下一页，追加并去重 */
    fun loadMore() {
        val cursor = nextCursor ?: return
        if (loadingMore || searching) return
        val request = generation
        loadingMore = true
        viewModelScope.launch {
            try {
                val result = api.searchLibrary(q = input, cursor = cursor)
                if (generation != request) return@launch
                items = SearchResults.merge(items, result.items)
                nextCursor = result.nextCursor
                failed = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation == request) failed = e.message ?: "搜索失败"
            } finally {
                if (generation == request) loadingMore = false
            }
        }
    }
}
