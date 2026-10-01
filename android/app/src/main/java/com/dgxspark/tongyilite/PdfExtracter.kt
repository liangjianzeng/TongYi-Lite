package com.dgxspark.tongyilite

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.File
import java.io.IOException

/**
 * PDF 文本抽取（TomRoush/PdfBox-Android 桥接）。
 *
 * 替代原手搓纯 Dart 解析器（2026-09-30 弃用）。纯 JVM/Java 依赖，无 Android
 * 框架依赖（本对象不持有 Context），故可 JVM 单测；`PDFBoxResourceLoader.init(Context)`
 * 由 MainActivity 的 pdf 通道 handler 惰性调用（文档要求：任何 PDFBox API 之前须初始化一次）。
 *
 * 注意：此 Android 移植版没有 `PDPage.getText()`；逐页文本经 `PDFTextStripper.getText(PDDocument)`
 * 整份抽取（内部用 ToUnicode CMap 解码，支持 CJK），返回时按文档页数拆为单文本块 + 真实页数。
 *
 * 异常：
 * - 需密码但未提供 → 抛 [com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException]（IOException 子类）。
 * - 非 PDF / 损坏文件 → 抛 [com.tom_roush.pdfbox.pdmodel.io.InvalidPDFException]（IOException 子类）。
 */
object PdfExtracter {

    /** 整份文档抽取结果：真实页数 + 文本。 */
    data class ExtractResult(val pageCount: Int, val text: String)

    /**
     * 抽取 PDF 文本。
     *
     * @param path 文件绝对路径
     * @return 真实页数 + 整份文本（PDFTextStripper 用页分隔符拼接各页）
     * @throws IOException 需密码/非 PDF/损坏
     */
    fun extract(path: String): ExtractResult {
        return PDDocument.load(File(path)).use { doc ->
            val stripper = PDFTextStripper()
            val text = stripper.getText(doc)
            ExtractResult(
                pageCount = doc.numberOfPages,
                text = text,
            )
        }
    }
}
