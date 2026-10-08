package io.movieclaw.androidtv.system

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * 只读交出「继续观看」的封面（系统桌面拉图用）：只认缓存目录 watchnext/ 下的文件名，别的一概拒绝。
 */
class WatchNextImageProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("只读")
        val name = uri.lastPathSegment?.takeIf { it.matches(Regex("[0-9]+-[0-9]+-[0-9]+\\.jpg")) } ?: throw FileNotFoundException()
        val file = File(File(requireNotNull(context).cacheDir, DIR), name)
        if (!file.exists()) throw FileNotFoundException()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "image/jpeg"
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0

    companion object {
        const val DIR = "watchnext"
        fun uri(context: Context, name: String): Uri = Uri.parse("content://${context.packageName}.watchnext/$name")
    }
}
