package io.movieclaw.android.feature.settings

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import io.movieclaw.android.core.designsystem.McType

/**
 * 扫码批准设备登录的取景页（全屏，iOS `PairingScannerScreen` 的对应物）：
 * 「批准设备登录」页里的「扫描二维码」打开它。
 *
 * 只认 MovieClaw 的登录二维码（[PairingQRCode]）：扫到就回调，由调用方关掉本页、填入配对码；
 * 扫到别的二维码只提示一句、继续扫，不把人带去任何地方。批准本身不在这里做——扫到 ≠ 同意，
 * 人必须在批准页上看过审批卡（设备名、类型、将获得的权限）再按批准，这是防钓鱼的那道闸。
 *
 * 相机不可用时（拒绝了权限、设备没有相机）给「改为手输」的出口。
 */
@Composable
fun PairingScannerScreen(
    onScanned: (code: String, host: String?) -> Unit,
    onManualEntry: () -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var askedOnce by remember { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        askedOnce = true
    }
    LaunchedEffect(Unit) {
        if (!granted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when {
            granted -> {
                Box(Modifier.fillMaxSize()) {
                    CameraScanner(onCode = onScanned)
                    Viewfinder()
                }
            }
            askedOnce -> UnavailablePane(
                title = "需要相机权限",
                message = "扫码登录要用相机读取电视或终端上的二维码。请在系统设置里允许 MovieClaw 使用相机，或者改为手动输入配对码。",
                onManualEntry = onManualEntry,
            )
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Color.White)
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                // 状态栏 / 刘海下移：不垫内边距时两颗按钮会被状态栏盖住、点不动（实机反馈）
                .statusBarsPadding()
                .padding(horizontal = 20.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            ScannerCircleButton(icon = Icons.Rounded.Close, label = "关闭", onClick = onClose)
            ScannerCircleButton(icon = Icons.Rounded.Edit, label = "手输配对码", onClick = onManualEntry)
        }
        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("对准电视或终端上的登录二维码", style = McType.title3, color = Color.White)
            Spacer(Modifier.height(6.dp))
            Text(
                "批准仍需在下一页核对设备信息后确认",
                style = McType.caption,
                color = Color.White.copy(alpha = 0.65f),
            )
        }
    }
}

/** 相机 + ML Kit 二维码识别；扫到 MovieClaw 配对码回调一次，别的码节流提示 */
@androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
@Composable
private fun CameraScanner(onCode: (code: String, host: String?) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hint by remember { mutableStateOf<String?>(null) }
    var lastRejected by remember { mutableStateOf<String?>(null) }
    var handled by remember { mutableStateOf(false) }

    val scanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
        )
    }
    DisposableEffect(Unit) { onDispose { scanner.close() } }

    Box(Modifier.fillMaxSize()) {
        androidx.compose.ui.viewinterop.AndroidView(
            factory = { ctx ->
                val previewView = PreviewView(ctx)
                val providerFuture = ProcessCameraProvider.getInstance(ctx)
                providerFuture.addListener({
                    val provider = providerFuture.get()
                    val preview = Preview.Builder().build().also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                    val analysis = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                    analysis.setAnalyzer(ContextCompat.getMainExecutor(ctx)) { proxy: ImageProxy ->
                        val media = proxy.image
                        if (media == null) {
                            proxy.close()
                            return@setAnalyzer
                        }
                        val input = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
                        scanner.process(input)
                            .addOnSuccessListener { barcodes ->
                                if (handled) return@addOnSuccessListener
                                val text = barcodes.firstNotNullOfOrNull { it.rawValue }
                                    ?: return@addOnSuccessListener
                                val scanned = PairingQRCode.parse(text)
                                if (scanned != null) {
                                    handled = true
                                    hint = null
                                    onCode(scanned.code, scanned.host)
                                } else if (text != lastRejected) {
                                    // 同一张码只提示一次：相机回调一秒十几次，别刷屏
                                    lastRejected = text
                                    hint = "这不是 MovieClaw 的登录二维码"
                                }
                            }
                            .addOnCompleteListener { proxy.close() }
                    }
                    runCatching {
                        provider.unbindAll()
                        provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                    }
                }, ContextCompat.getMainExecutor(ctx))
                previewView
            },
            modifier = Modifier.fillMaxSize(),
        )

        hint?.let {
            Text(
                it,
                style = McType.sub,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.Center)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}

/** 取景框：中央亮框 */
@Composable
private fun Viewfinder() {
    Box(
        Modifier
            .fillMaxSize()
            .padding(36.dp)
            .clip(RoundedCornerShape(24.dp))
            .border(2.dp, Color.White.copy(alpha = 0.75f), RoundedCornerShape(24.dp)),
    )
}

@Composable
private fun ScannerCircleButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.45f))
                .clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(4.dp))
        Text(label, style = McType.caption2, color = Color.White.copy(alpha = 0.8f))
    }
}

@Composable
private fun UnavailablePane(title: String, message: String, onManualEntry: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(title, style = McType.title3, color = Color.White)
        Spacer(Modifier.height(8.dp))
        Text(message, style = McType.footnote, color = Color.White.copy(alpha = 0.7f))
        Spacer(Modifier.height(16.dp))
        Box(
            Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(Color.White.copy(alpha = 0.12f))
                .clickable(onClick = onManualEntry)
                .padding(horizontal = 18.dp, vertical = 10.dp),
        ) {
            Text("改为手动输入配对码", style = McType.sub, color = Color.White)
        }
    }
}
