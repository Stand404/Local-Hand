package com.stand.localhand

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.stand.localhand/platform"
    private val storageRequestCode = 4201

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasStorageAccess" -> result.success(hasStorageAccess())
                    "requestStorageAccess" -> {
                        requestStorageAccess()
                        result.success(hasStorageAccess())
                    }
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        val mimeType = call.argument<String>("mimeType")
                        if (path != null) scanFile(path, mimeType)
                        result.success(null)
                    }
                    "openFolder" -> {
                        val path = call.argument<String>("path")
                        result.success(path != null && openFolder(path))
                    }
                    "openFile" -> {
                        val path = call.argument<String>("path")
                        result.success(if (path == null) "failed" else openFile(path))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasStorageAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    private fun requestStorageAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                intent.data = Uri.parse("package:$packageName")
                startActivity(intent)
            } catch (_: Exception) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (_: Exception) {
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            requestPermissions(
                arrayOf(
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ),
                storageRequestCode
            )
        }
    }

    // 通知 MediaStore 有新文件，其他应用与文件管理器才能立即看到。
    private fun scanFile(path: String, mimeType: String?) {
        val file = File(path)
        MediaScannerConnection.scanFile(
            this,
            arrayOf(file.absolutePath),
            arrayOf(mimeType)
        ) { _, _ -> }
    }

    // 用系统文件管理器打开接收目录；
    // 优先选择支持重命名/删除/复制等文件操作的“文件”应用。
    private fun openFolder(path: String): Boolean {
        val root = Environment.getExternalStorageDirectory().absolutePath
        val downloads =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        var target = File(path)
        if (!target.isDirectory) {
            // 还没收到过文件时目录可能不存在，先创建，否则文件管理器只能落到下载根目录。
            val localHand = File(downloads, "LocalHand")
            target = if (localHand.isDirectory || localHand.mkdirs()) localHand else downloads
        }
        val relative = target.absolutePath.removePrefix("$root/").ifEmpty { "Download" }
        val uri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:$relative"
        )

        // DocumentsUI 是 Android 自带的“文件”应用，能定位指定目录且支持文件操作。
        if (startDirectoryView(uri, "com.google.android.documentsui")) return true
        if (startDirectoryView(uri, "com.android.documentsui")) return true
        // 交给系统默认的目录浏览应用。
        if (startDirectoryView(uri, null)) return true
        // 厂商文件管理器直接定位到该目录。
        for (pkg in fileManagerPackages) {
            if (startDirectoryView(uri, pkg)) return true
        }
        if (openDocumentsUi(uri)) return true
        if (openAnyFileManager()) return true
        return browseFolder(uri)
    }

    private val fileManagerPackages = listOf(
        "com.google.android.apps.nbu.files",
        "com.mi.android.globalFileexplorer",
        "com.android.fileexplorer",
        "com.sec.android.app.myfiles",
        "com.huawei.hidisk",
        "com.coloros.filemanager",
        "com.vivo.filemanager"
    )

    private fun startDirectoryView(uri: Uri, pkg: String?): Boolean {
        return try {
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                if (pkg != null) setPackage(pkg)
            })
            true
        } catch (_: Exception) {
            false
        }
    }

    // DocumentsUI 的“文件”界面支持重命名、删除、复制、移动。
    private fun openDocumentsUi(uri: Uri): Boolean {
        val components = listOf(
            "com.google.android.documentsui" to "com.android.documentsui.files.FilesActivity",
            "com.android.documentsui" to "com.android.documentsui.files.FilesActivity"
        )
        for ((pkg, activity) in components) {
            try {
                startActivity(Intent(Intent.ACTION_MAIN).apply {
                    setClassName(pkg, activity)
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
                return true
            } catch (_: Exception) {
                // 未内置该文件管理器，继续尝试下一个。
            }
        }
        return false
    }

    // 兜底打开已安装的厂商文件管理器首页。
    private fun openAnyFileManager(): Boolean {
        for (pkg in fileManagerPackages) {
            try {
                val intent = packageManager.getLaunchIntentForPackage(pkg) ?: continue
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    // 最后兜底：用文件选择器定位到该目录，至少能浏览文件。
    private fun browseFolder(uri: Uri): Boolean {
        return try {
            startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            })
            true
        } catch (_: Exception) {
            false
        }
    }

    // 通过 FileProvider 打开文件，兼容 Android 7+ 的 file:// 限制；APK 会先检查安装权限。
    private fun openFile(path: String): String {
        val file = File(path)
        if (!file.exists()) return "missing"
        if (!file.canRead()) return "failed"
        val isApk = path.endsWith(".apk", ignoreCase = true)
        val mimeType = if (isApk) {
            "application/vnd.android.package-archive"
        } else {
            mimeTypeOf(path)
        }
        if (isApk && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                })
            } catch (_: Exception) {
            }
            return "installPermission"
        }

        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (_: IllegalArgumentException) {
            return "failed"
        }
        return try {
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            "opened"
        } catch (_: ActivityNotFoundException) {
            "noApp"
        } catch (_: Exception) {
            "failed"
        }
    }

    private fun mimeTypeOf(path: String): String {
        val extension = path.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
    }
}
