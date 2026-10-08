package io.movieclaw.androidtv.ui.detail

import androidx.compose.runtime.Composable
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.shell.Route

/** 条目详情（TVItemDetailView）——待实现 */
@Composable
fun ItemDetailScreen(libraryId: Long, itemId: Long) = StateView(McIcons.Film, "详情 $libraryId/$itemId")

/** 影人页（TVPersonView）——待实现 */
@Composable
fun PersonScreen(route: Route.Person) = StateView(McIcons.Person, route.name)
