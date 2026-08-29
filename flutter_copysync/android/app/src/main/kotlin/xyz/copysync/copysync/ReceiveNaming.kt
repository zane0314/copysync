package xyz.copysync.copysync

import java.io.File

/// 接收文件命名的纯逻辑（从 CopySyncBridge 抽出，便于 JVM 单元测试）。
/// 与旧工程 MainActivity 语义一致：清理非法字符 + 命名冲突时在扩展名前追加时间戳。
object ReceiveNaming {
    /// 取路径末段、清理路径分隔符/非法字符，空名回退默认名。
    fun safeName(originalName: String): String {
        var name = File(originalName).name.trim()
        name = name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
        return name.ifEmpty { "CopySync-file" }
    }

    /// 若清理后的名字已存在（由 [exists] 判定），在扩展名前追加时间戳保证唯一。
    fun uniqueName(
        originalName: String,
        exists: (String) -> Boolean,
        clock: () -> Long = { System.currentTimeMillis() },
    ): String {
        val name = safeName(originalName)
        if (!exists(name)) return name
        val dot = name.lastIndexOf('.')
        val extension = if (dot > 0) name.substring(dot) else ""
        val base = if (extension.isEmpty()) name else name.substring(0, name.length - extension.length)
        return base + "-" + clock() + extension
    }
}
