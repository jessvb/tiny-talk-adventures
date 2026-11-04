package com.jessvb.tinytalk.core.facts

import com.jessvb.tinytalk.core.chat.executeForBody
import com.jessvb.tinytalk.core.chat.defaultGroqHttp
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

interface AnimalFactFetching {
    /** Facts for [canonical], or null when unavailable (no key, network/HTTP/JSON failure). */
    suspend fun fetchFacts(canonical: String): List<String>?
}

/**
 * API Ninjas' Animals endpoint; mirrors AnimalFactsAPIClient.swift. Optional by
 * design: a null/blank key is a silent no-op (no request at all), and every
 * failure is null -- facts must never break the story loop. The key is never logged.
 */
class AnimalFactsApiClient(
    private val apiKey: () -> String?,
    private val host: String = "https://api.api-ninjas.com",
    private val http: OkHttpClient = defaultGroqHttp(15),
) : AnimalFactFetching {

    override suspend fun fetchFacts(canonical: String): List<String>? {
        val key = apiKey()
        if (key.isNullOrEmpty() || key.isBlank()) return null
        return try {
            val url = "$host/v1/animals".toHttpUrl().newBuilder()
                .addQueryParameter("name", canonical).build()
            val request = Request.Builder().url(url).header("X-Api-Key", key).build()
            parse(executeForBody(http.newCall(request)))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        }
    }

    private fun str(o: JsonObject, name: String): String? = when (val v = o[name]) {
        null, JsonNull -> null
        is JsonPrimitive -> if (v.isString) v.content else throw IllegalArgumentException("not a string")
        else -> throw IllegalArgumentException("not a string")
    }

    private fun parse(text: String): List<String> {
        val records = Json.parseToJsonElement(text) as? JsonArray ?: throw IllegalArgumentException("not an array")
        val first = records.firstOrNull() as? JsonObject ?: return emptyList()
        val c = when (val ch = first["characteristics"]) {
            null, JsonNull -> return emptyList()
            is JsonObject -> ch
            else -> throw IllegalArgumentException("bad characteristics")
        }
        return AnimalFacts.extractFacts(
            AnimalCharacteristics(
                mostDistinctiveFeature = str(c, "most_distinctive_feature"),
                topSpeed = str(c, "top_speed"),
                diet = str(c, "diet"),
                habitat = str(c, "habitat"),
                slogan = str(c, "slogan"),
                color = str(c, "color"),
                groupBehavior = str(c, "group_behavior"),
                lifespan = str(c, "lifespan"),
            ),
        )
    }
}
