package io.movieclaw.androidtv.ui.accounts

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class OpenSourceComponentTest {
    @Test
    fun everyListedLicenseTextShipsInTheApk() {
        // 单测的工作目录是 app/：许可全文在 src/main/assets/licenses/<名字>.txt
        for (component in OpenSourceComponent.all) {
            for (name in component.licenseFiles) {
                assertTrue("${component.name} 缺许可全文 $name.txt", File("src/main/assets/licenses/$name.txt").isFile)
            }
        }
        // FFmpeg 是 LGPL：许可、源码地址与编译脚本位置都要写明（§4.3）
        val ffmpeg = OpenSourceComponent.all.single { it.name.startsWith("FFmpeg") }
        assertTrue("LGPL-2.1" in ffmpeg.licenseFiles && "native/ffmpeg/build.sh" in ffmpeg.source)
    }
}
