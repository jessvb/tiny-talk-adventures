package com.jessvb.tinytalk.core.chat

import java.io.IOException
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

private class Reply(val code: Int, val retryAfter: String?, val body: String)

/**
 * Runs [call] on OkHttp's dispatcher thread and reads the whole body there,
 * before the continuation resumes, so nothing blocks the caller's thread
 * (safe from any dispatcher, including Main) and cancelling the coroutine
 * (Call.cancel) interrupts the download too. Returns the body of a 200, or
 * throws a [GroqException]; coroutine cancellation propagates as such.
 */
internal suspend fun executeForBody(call: Call): String {
    val reply: Reply = suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (cont.isActive) cont.resumeWithException(GroqException.Network(e))
            }
            override fun onResponse(call: Call, response: Response) {
                val result: Result<Reply> = response.use { r ->
                    try {
                        Result.success(Reply(r.code, r.header("Retry-After"), r.body.string()))
                    } catch (e: IOException) {
                        Result.failure(GroqException.Network(e))
                    }
                }
                if (cont.isActive) cont.resumeWith(result)
            }
        })
    }
    when (reply.code) {
        200 -> return reply.body
        401, 403 -> throw GroqException.KeyRejected()
        429 -> throw GroqException.RateLimited(reply.retryAfter?.trim()?.toIntOrNull())
        else -> throw GroqException.Failure("HTTP ${reply.code}: ${reply.body.take(300)}")
    }
}
