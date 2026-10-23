package com.jessvb.tinytalk.core.stt

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** 16-bit PCM WAV with the same 44-byte header as the iOS `wavData`. */
fun wavFromPcm16(pcm16: ShortArray, sampleRate: Int, channels: Int = 1): ByteArray {
    val dataLen = pcm16.size * 2
    val b = ByteBuffer.allocate(44 + dataLen).order(ByteOrder.LITTLE_ENDIAN)
    b.put("RIFF".toByteArray(Charsets.US_ASCII))
    b.putInt(36 + dataLen)
    b.put("WAVE".toByteArray(Charsets.US_ASCII))
    b.put("fmt ".toByteArray(Charsets.US_ASCII))
    b.putInt(16)
    b.putShort(1) // PCM
    b.putShort(channels.toShort())
    b.putInt(sampleRate)
    b.putInt(sampleRate * channels * 2)
    b.putShort((channels * 2).toShort())
    b.putShort(16)
    b.put("data".toByteArray(Charsets.US_ASCII))
    b.putInt(dataLen)
    for (s in pcm16) b.putShort(s)
    return b.array()
}
