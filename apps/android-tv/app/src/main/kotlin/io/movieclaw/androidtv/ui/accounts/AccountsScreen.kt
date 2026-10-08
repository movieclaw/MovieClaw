package io.movieclaw.androidtv.ui.accounts

import androidx.compose.runtime.Composable
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.StateView

/** 谁在看（TVAccountViews）——待实现 */
@Composable
fun AccountsScreen() = StateView(McIcons.Account, "谁在看？")

/** 关于（TVAboutView）——待实现 */
@Composable
fun AboutScreen() = StateView(McIcons.Info, "关于")

/** 许可全文（TVLicenseTextView）——待实现 */
@Composable
fun LicenseScreen(componentName: String) = StateView(McIcons.Info, componentName)
