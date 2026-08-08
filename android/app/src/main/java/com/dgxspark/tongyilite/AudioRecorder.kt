/**
 * AudioRecorder — microphone capture for on-device speech input.
 *
 * Records 16-bit PCM mono at the model's required sample rate (queried from the
 * native mtmd audio encoder via [InferenceEngine.getAudioSampleRate]), then on
 * [stop] writes a standard 44-byte-header WAV file to the app cache dir.
 *
 * The WAV file is later fed through the existing mtmd media path, which
 * auto-detects audio by magic bytes (wav/mp3/flac) — no extra decode needed.
 */

package com.dgxspark.tongyilite

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

class AudioRecorder(private val context: Context, private val sampleRate: Int) {

    companion object {
        private const val TAG = "AudioRecorder"
        /** Drop recordings shorter than ~0.5s (16-bit mono @16k ≈ 1600 bytes). */
        private const val MIN_PCM_BYTES = 1600
    }

    @Volatile private var recording = false
    private val pcm = ByteArrayOutputStream()
    private var recordThread: Thread? = null

    /** Begin capturing from the microphone. Returns false if AudioRecord failed. */
    fun start(): Boolean {
        if (recording) return true
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = maxOf(minBuf, 4096)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufSize
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.w(TAG, "AudioRecord failed to initialize (sr=$sampleRate)")
            rec.release()
            return false
        }
        pcm.reset()
        recording = true
        rec.startRecording()
        recordThread = Thread {
            val buf = ByteArray(bufSize)
            while (recording) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) pcm.write(buf, 0, n)
            }
            try { rec.stop() } catch (_: Exception) {}
            rec.release()
        }.apply { start() }
        return true
    }

    /** Stop recording and finalize the WAV file. Returns its path, or null if
     *  not recording / too short / write failed. */
    fun stop(): String? {
        if (!recording) return null
        recording = false
        recordThread?.join(3000)
        recordThread = null
        val data = pcm.toByteArray()
        if (data.size < MIN_PCM_BYTES) {
            Log.i(TAG, "Recording too short (${data.size} bytes) -> discarded")
            return null
        }
        val file = File(context.cacheDir, "mic_${System.currentTimeMillis()}.wav")
        return try {
            writeWav(file, data)
            file.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "WAV write failed", e)
            null
        }
    }

    fun isRecording(): Boolean = recording

    /** Write a standard PCM WAV file (44-byte header + little-endian 16-bit data). */
    private fun writeWav(file: File, pcmData: ByteArray) {
        val byteRate = sampleRate * 2 // 16-bit mono
        FileOutputStream(file).use { out ->
            out.write("RIFF".toByteArray())
            out.write(intLE(36 + pcmData.size))
            out.write("WAVE".toByteArray())
            out.write("fmt ".toByteArray())
            out.write(intLE(16))
            out.write(shortLE(1))          // PCM format
            out.write(shortLE(1))          // 1 channel (mono)
            out.write(intLE(sampleRate))
            out.write(intLE(byteRate))
            out.write(shortLE(2))          // block align = channels * bits/8
            out.write(shortLE(16))         // bits per sample
            out.write("data".toByteArray())
            out.write(intLE(pcmData.size))
            out.write(pcmData)
        }
    }

    private fun intLE(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(), ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(), ((v ushr 24) and 0xFF).toByte()
    )

    private fun shortLE(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(), ((v ushr 8) and 0xFF).toByte()
    )
}
