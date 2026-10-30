package com.jessvb.tinytalk.core.stt

import com.jessvb.tinytalk.core.chat.GroqException
import com.jessvb.tinytalk.core.chat.defaultGroqHttp
import com.jessvb.tinytalk.core.chat.executeForBody
import com.jessvb.tinytalk.core.chat.requireKey
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Groq's Whisper transcription; only used behind the optional "better listening" switch. */
class GroqWhisperClient(
    private val apiKey: () -> String?,
    private val model: String = "whisper-large-v3-turbo",
    private val host: String = "https://api.groq.com",
    private val http: OkHttpClient = defaultGroqHttp(60),
) : SpeechTranscribing {

    override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String {
        val key = requireKey(apiKey)
        val wav = wavFromPcm16(pcm16, sampleRate)
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model", model)
            // Without this Whisper auto-detects language (same reason as iOS).
            .addFormDataPart("language", "en")
            .addFormDataPart("file", "utterance.wav", wav.toRequestBody("audio/wav".toMediaType()))
            .build()
        val request = Request.Builder()
            .url("$host/openai/v1/audio/transcriptions")
            .header("Authorization", "Bearer $key")
            .post(body)
            .build()
        val text = executeForBody(http.newCall(request))
        val transcript = try {
            Json.parseToJsonElement(text).jsonObject["text"]!!.jsonPrimitive.contentOrNull
        } catch (e: Exception) {
            throw GroqException.Failure("malformed response")
        }
        return transcript ?: throw GroqException.Failure("response text was null")
    }
}
