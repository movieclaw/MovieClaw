package io.movieclaw.androidtv.ui.library

import androidx.compose.runtime.Composable
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.shell.WallSource

/** 媒体库海报墙（TVLibraryView）——待实现 */
@Composable
fun LibraryWallScreen(libraryId: Long) = StateView(McIcons.Grid, "媒体库 $libraryId")

/** 合集墙（TVCollectionView）——待实现 */
@Composable
fun CollectionWallScreen(collectionId: Long, name: String) = StateView(McIcons.Stack, name)

/** 行的「查看全部」/ 按类型墙（TVRowWallView）——待实现 */
@Composable
fun RowWallScreen(title: String, source: WallSource) = StateView(McIcons.Grid, title)
