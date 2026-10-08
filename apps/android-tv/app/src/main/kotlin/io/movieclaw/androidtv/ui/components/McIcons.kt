package io.movieclaw.androidtv.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.ContactPage
import androidx.compose.material.icons.outlined.FolderOff
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.ManageSearch
import androidx.compose.material.icons.outlined.MovieFilter
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.WarningAmber

/** SF Symbols → Material 图标的对照（名字照 Apple 端写，方便对着源码找） */
object McIcons {
    /** play.fill */
    val Play = Icons.Filled.PlayArrow
    /** info.circle */
    val Info = Icons.Outlined.Info
    /** square.grid.2x2 */
    val Grid = Icons.Filled.GridView
    /** person.crop.circle */
    val Account = Icons.Filled.AccountCircle
    /** magnifyingglass */
    val Search = Icons.Filled.Search
    val SearchOutline = Icons.Outlined.Search
    /** text.magnifyingglass */
    val TextSearch = Icons.Outlined.ManageSearch
    /** house */
    val Home = Icons.Filled.Home
    /** heart / heart.fill */
    val Heart = Icons.Filled.FavoriteBorder
    val HeartFill = Icons.Filled.Favorite
    /** checkmark / checkmark.circle.fill */
    val Check = Icons.Filled.Check
    val CheckCircle = Icons.Filled.CheckCircle
    /** backward.end.fill */
    val Restart = Icons.Filled.SkipPrevious
    /** forward.end.fill */
    val SkipForward = Icons.Filled.SkipNext
    /** plus */
    val Plus = Icons.Filled.Add
    /** rectangle.portrait.and.arrow.right */
    val Logout = Icons.AutoMirrored.Filled.Logout
    /** wifi / wifi.exclamationmark */
    val Wifi = Icons.Filled.Wifi
    val WifiError = Icons.Filled.WifiOff
    /** server.rack */
    val Server = Icons.Filled.Dns
    /** exclamationmark.triangle(.fill) */
    val Warning = Icons.Filled.Warning
    val WarningOutline = Icons.Outlined.WarningAmber
    /** film / film.stack */
    val Film = Icons.Filled.Movie
    val FilmStack = Icons.Outlined.MovieFilter
    /** rectangle.stack */
    val Stack = Icons.Outlined.Layers
    /** person.fill */
    val Person = Icons.Filled.Person
    /** person.crop.rectangle */
    val PersonCard = Icons.Outlined.ContactPage
    /** questionmark.folder */
    val MissingFolder = Icons.Outlined.FolderOff
    /** line.3.horizontal.decrease */
    val Filter = Icons.Filled.FilterList
    /** ‹ */
    val Back = Icons.Filled.ChevronLeft
}
