package com.dgxspark.tongyilite

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

/**
 * PdfExtracter 的 JVM 单测（TomRoush/PdfBox-Android）。
 *
 * fixture PDF 在 src/test/resources（ascii/cjk 含 CMap 自定义编码，
 * encrypted_* 为 RC4-128 加密，notapdf.txt 为非 PDF 字节）。
 * 类路径资源在 @Before 拷到临时目录，避免 PDFBox 对类路径路径的兼容问题。
 */
class PdfExtractTest {
    private var tempDir: File = File("")
    private lateinit var asciiFile: File
    private lateinit var cjkFile: File
    private lateinit var encryptedOwnerFile: File
    private lateinit var encryptedUserFile: File
    private lateinit var notapdfFile: File

    @Before
    fun setup() {
        val dir = Files.createTempDirectory("pdfextract-")
        this.tempDir = dir.toAbsolutePath().toFile()
        this.asciiFile = copyResource("ascii.pdf")
        this.cjkFile = copyResource("cjk.pdf")
        this.encryptedOwnerFile = copyResource("encrypted_owner.pdf")
        this.encryptedUserFile = copyResource("encrypted_user.pdf")
        this.notapdfFile = File(tempDir, "notapdf.txt").also {
            Files.write(it.toPath(), "this is not a valid pdf".toByteArray())
        }
    }

    /** 类路径资源 → 临时目录的实体文件。 */
    private fun copyResource(name: String): File {
        val src = this::class.java.classLoader.getResourceAsStream(name)
            ?: error("fixture resource not found: $name")
        val dest = File(tempDir, name)
        src.use { in_ -> dest.outputStream().use { out_ -> in_.copyTo(out_) } }
        return dest
    }

    private fun textOf(file: File): String =
        PdfExtracter.extract(file.absolutePath).text

    @Test
    fun `extracts ascii text`() {
        val text = textOf(asciiFile)
        assertTrue("ascii text should contain the sample sentence, got: $text",
            text.contains("Hello from TomRoush PdfBox"))
    }

    @Test
    fun `extracts cjk text via custom cmap`() {
        val text = textOf(cjkFile)
        assertTrue("cjk text should contain 一字语测, got: <<$text>>", text.contains("一字语测"))
    }

    @Test
    fun `throws InvalidPasswordException when encrypted and no password given`() {
        try {
            textOf(encryptedUserFile)
            fail("expected InvalidPasswordException for encrypted doc")
        } catch (e: InvalidPasswordException) {
            // expected
        } catch (e: Exception) {
            fail("expected InvalidPasswordException, got ${e::class.java.name}: ${e.message}")
        }
    }

    @Test
    fun `opens encrypted doc with owner password and extracts text`() {
        PDDocument.load(encryptedOwnerFile, "ownerpw").use { doc ->
            val text = PDFTextStripper().getText(doc)
            assertTrue("owner-opened encrypted doc should extract, got: $text",
                text.contains("TomRoush"))
        }
    }

    @Test
    fun `throws IOException for non-pdf file`() {
        try {
            textOf(notapdfFile)
            fail("expected IOException for non-pdf file")
        } catch (e: IOException) {
            // expected
        }
    }
}
