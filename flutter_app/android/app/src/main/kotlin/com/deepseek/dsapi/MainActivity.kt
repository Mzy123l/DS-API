package com.deepseek.dsapi

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 原生能力：MediaStore 保存文件到公共 Download（无需权限）。
 *
 * 历史：这里还实现过「裸 PCM 流式播放」（AudioTrack，边合成边出声）。
 * 那条路线因爆音、电流声、以及下载出来的音频没有容器头（播放器报
 * 「格式不对」）已整体废弃并删除；现在音频一律走 WAV 容器，由
 * audioplayers 播放。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val source = call.argument<String>("path")
                    val fileName = call.argument<String>("fileName") ?: "audio.wav"
                    if (source.isNullOrEmpty()) {
                        result.error("bad_args", "path 不能为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(saveToDownloads(source, fileName))
                    } catch (e: Exception) {
                        result.error("save_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // -------------------------------------------------------- 保存到下载目录

    /** 返回给用户看的位置描述（真实落盘路径或公共目录名）。 */
    private fun saveToDownloads(source: String, fileName: String): String {
        val src = File(source)
        if (!src.exists()) throw IllegalStateException("源文件不存在")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS,
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: throw IllegalStateException("无法在下载目录创建文件")

            resolver.openOutputStream(uri).use { out ->
                if (out == null) throw IllegalStateException("无法写入下载目录")
                src.inputStream().use { input -> input.copyTo(out) }
            }

            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Download/$fileName"
        }

        @Suppress("DEPRECATION")
        val dir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        if (!dir.exists()) dir.mkdirs()
        val target = File(dir, fileName)
        src.inputStream().use { input ->
            target.outputStream().use { out -> input.copyTo(out) }
        }
        return target.absolutePath
    }

    private companion object {
        const val MEDIA_CHANNEL = "com.deepseek.dsapi/media_store"
    }
}
