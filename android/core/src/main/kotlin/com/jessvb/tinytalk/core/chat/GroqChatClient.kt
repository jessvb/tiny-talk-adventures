package com.jessvb.tinytalk.core.chat

import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

internal fun defaultGroqHttp(callSeconds: Long) = OkHttpClient.Builder()
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(callSeconds, TimeUnit.SECONDS)
    .callTimeout(callSeconds, TimeUnit.SECONDS)
    .build()

/** Groq's OpenAI-compatible chat completions (non-streaming). Mirrors GroqChatClient.swift. */
class GroqChatClient(
    private val apiKey: () -> String?,
    private val model: String = "openai/gpt-oss-20b",
    private val host: String = "https://api.groq.com",
    private val reasoningEffort: String? = null,
    private val http: OkHttpClient = defaultGroqHttp(30),
) : ChatCompleting {

    override suspend fun complete(messages: List<ChatMessage>): String {
        val key = requireKey(apiKey)
        val body = buildJsonObject {
            put("model", model)
            put("messages", JsonArray(messages.map {
                buildJsonObject { put("role", it.role); put("content", it.content) }
            }))
            put("stream", false)
            // Omit entirely (not null) when unset, like the iOS client.
            if (reasoningEffort != null) put("reasoning_effort", reasoningEffort)
        }.toString()
        val request = Request.Builder()
            .url("$host/openai/v1/chat/completions")
            .header("Authorization", "Bearer $key")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()
        val text = executeForBody(http.newCall(request))
        val content = try {
            val choices = Json.parseToJsonElement(text).jsonObject["choices"]?.jsonArray
                ?: throw GroqException.Failure("response had no choices")
            val first = choices.firstOrNull()
                ?: throw GroqException.Failure("response had no choices")
            first.jsonObject["message"]!!.jsonObject["content"]!!.jsonPrimitive.contentOrNull
        } catch (e: GroqException) {
            throw e
        } catch (e: Exception) {
            throw GroqException.Failure("malformed response")
        }
        return content ?: throw GroqException.Failure("response had no content")
    }
}
