package xyz.copysync.copysync

import org.junit.Assert.assertEquals
import org.junit.Test

/// 覆盖基线矩阵 Android「重复文件名处理」：命名冲突时在扩展名前追加时间戳。
class ReceiveNamingTest {

    @Test
    fun safeNameStripsDirectoryAndIllegalChars() {
        assertEquals("report.pdf", ReceiveNaming.safeName("report.pdf"))
        assertEquals("report.pdf", ReceiveNaming.safeName("/downloads/report.pdf"))
        assertEquals("a_b_c_.txt", ReceiveNaming.safeName("a:b*c?.txt"))
    }

    @Test
    fun safeNameFallsBackWhenEmpty() {
        assertEquals("CopySync-file", ReceiveNaming.safeName(""))
        assertEquals("CopySync-file", ReceiveNaming.safeName("///"))
    }

    @Test
    fun uniqueNameKeepsNameWhenNoCollision() {
        assertEquals(
            "report.pdf",
            ReceiveNaming.uniqueName("report.pdf", exists = { false }, clock = { 1234L }),
        )
    }

    @Test
    fun uniqueNameAppendsTimestampBeforeExtensionOnCollision() {
        assertEquals(
            "report-1234.pdf",
            ReceiveNaming.uniqueName("report.pdf", exists = { true }, clock = { 1234L }),
        )
    }

    @Test
    fun uniqueNameHandlesNoExtension() {
        assertEquals(
            "README-1234",
            ReceiveNaming.uniqueName("README", exists = { true }, clock = { 1234L }),
        )
    }

    @Test
    fun uniqueNameTreatsLeadingDotAsNoExtension() {
        // lastIndexOf('.') == 0，非 > 0，故整体视为基名，无扩展名
        assertEquals(
            ".env-1234",
            ReceiveNaming.uniqueName(".env", exists = { true }, clock = { 1234L }),
        )
    }

    @Test
    fun pickerSizeGateAllowsUnknownAndBoundaryButRejectsOversize() {
        val limit = 100L * 1024L * 1024L
        assertEquals(true, CopySyncBridge.pickerSizeAllowed(-1L))
        assertEquals(true, CopySyncBridge.pickerSizeAllowed(limit))
        assertEquals(false, CopySyncBridge.pickerSizeAllowed(limit + 1L))
    }
}
