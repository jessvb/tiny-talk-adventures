package com.jessvb.tinytalk.core.chat

import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response

/** Typed Groq failures. Messages never contain the API key. */
sealed class GroqException(message: String) : Exception(message) {
    class KeyMissing : GroqException("No Groq API key is set")
    class KeyRejected : GroqException("Groq rejected the API key")
    class RateLimited(val retryAfterSeconds: Int?) : GroqException("Groq rate limit reached")
    class Failure(val detail: String) : GroqException("Groq request failed: $detail")
    class Network(cause: Throwable) : GroqException("Network error talking to Groq") {
        init { initCause(cause) }
    }
}

/** Resolves the key or throws [GroqException.KeyMissing] before any request is made. */
internal fun requireKey(provider: () -> String?): String {
    val key = provider()
    if (key.isNullOrBlank()) throw GroqException.KeyMissing()
    return key
}

/**
 * Runs [call] asynchronously (OkHttp's dispatcher thread, so no blocking
 * of the caller), cancelling it if the coroutine is cancelled. Returns the
 * response body of a 200, or throws a [GroqException].
 */
internal suspend fun executeForBody(call: Call): String {
    val response: Response = suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(GroqException.Network(e))
                }
                override fun onResponse(call: Call, response: Response) {
                    if (cont.isActive) cont.resume(response) else response.close()
                }
            })
    }
    response.use { r ->
        val text = try {
            r.body.string()
        } catch (e: IOException) {
            throw GroqException.Network(e)
        }
        when (r.code) {
            200 -> return text
            401, 403 -> throw GroqException.KeyRejected()
            429 -> throw GroqException.RateLimited(r.header("Retry-After")?.trim()?.toIntOrNull())
            else -> throw GroqException.Failure("HTTP ${r.code}: ${text.take(300)}")
        }
    }
}
