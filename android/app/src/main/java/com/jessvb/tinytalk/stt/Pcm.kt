package com.jessvb.tinytalk.stt

/** Whisper (sherpa-onnx) wants float samples in [-1, 1): int16 / 32768. Pure; JVM-tested. */
internal fun pcm16ToFloat(pcm16: ShortArray): FloatArray = FloatArray(pcm16.size) { pcm16[it] / 32768f }
