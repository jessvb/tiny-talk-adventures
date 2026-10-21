package com.jessvb.tinytalk.core.chat

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class GroqChatClientTest {
    private lateinit var server: MockWebServer
    private val msgs = listOf(ChatMessage("system", "be kind"), ChatMessage("user", "hi"))

    @Before fun setUp() { server = MockWebServer().apply { start() } }
    @After fun tearDown() { try { server.shutdown() } catch (_: Exception) {} }

    private fun host() = server.url("/").toString().trimEnd('/')
    private fun client(key: String? = "fake-key", effort: String? = null) =
        GroqChatClient(apiKey = { key }, host = host(), reasoningEffort = effort)
    private fun ok(content: String = "hello") = MockResponse().setBody(
        """{"choices":[{"message":{"role":"assistant","content":"$content"}}]}"""
    )
    private suspend fun expectError(c: GroqChatClient = client()): GroqException = try {
        c.complete(msgs); fail("expected GroqException"); throw IllegalStateException()
    } catch (e: GroqException) { e }

    @Test fun requestShapeAndResult() = runBlocking {
        server.enqueue(ok("Once upon a time"))
        assertEquals("Once upon a time", client().complete(msgs))
        val req = server.takeRequest()
        assertEquals("/openai/v1/chat/completions", req.path)
        assertEquals("POST", req.method)
        assertEquals("Bearer fake-key", req.getHeader("Authorization"))
        val body = Json.parseToJsonElement(req.body.readUtf8()).jsonObject
        assertEquals("openai/gpt-oss-20b", body["model"]!!.jsonPrimitive.content)
        assertEquals("false", body["stream"]!!.jsonPrimitive.content)
        val m = body["messages"]!!.jsonArray
        assertEquals(2, m.size)
        assertEquals("user", m[1].jsonObject["role"]!!.jsonPrimitive.content)
        assertEquals("hi", m[1].jsonObject["content"]!!.jsonPrimitive.content)
        assertFalse(body.containsKey("reasoning_effort"))
    }

    @Test fun reasoningEffortIncludedWhenSet() = runBlocking {
        server.enqueue(ok())
        client(effort = "low").complete(msgs)
        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("low", body["reasoning_effort"]!!.jsonPrimitive.content)
    }

    @Test fun unauthorizedAndForbiddenAreKeyRejected() = runBlocking {
        for (code in listOf(401, 403)) {
            server.enqueue(MockResponse().setResponseCode(code).setBody("nope"))
            assertTrue(expectError() is GroqException.KeyRejected)
        }
    }

    @Test fun rateLimitedWithRetryAfter() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "7"))
        assertEquals(7, (expectError() as GroqException.RateLimited).retryAfterSeconds)
    }

    @Test fun rateLimitedWithoutRetryAfter() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429))
        assertNull((expectError() as GroqException.RateLimited).retryAfterSeconds)
    }

    @Test fun serverErrorIsFailure() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(500).setBody("boom"))
        assertTrue(expectError() is GroqException.Failure)
    }

    @Test fun emptyChoicesIsFailure() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"choices":[]}"""))
        assertTrue(expectError() is GroqException.Failure)
    }

    @Test fun malformedBodyIsFailure() = runBlocking {
        server.enqueue(MockResponse().setBody("not json"))
        assertTrue(expectError() is GroqException.Failure)
    }

    @Test fun connectionRefusedIsNetwork() = runBlocking {
        val c = client()
        server.shutdown()
        assertTrue(expectError(c) is GroqException.Network)
    }

    @Test fun nullOrBlankKeyIsKeyMissingWithNoRequest() = runBlocking {
        for (k in listOf(null, "", "   ")) {
            assertTrue(expectError(client(key = k)) is GroqException.KeyMissing)
        }
        assertEquals(0, server.requestCount)
    }

    @Test fun keyIsReadPerCall() = runBlocking {
        var key: String? = null
        val c = GroqChatClient(apiKey = { key }, host = host())
        assertTrue(expectError(c) is GroqException.KeyMissing)
        key = "later-key"
        server.enqueue(ok())
        c.complete(msgs)
        assertEquals("Bearer later-key", server.takeRequest().getHeader("Authorization"))
    }

    @Test fun errorMessagesNeverContainKey() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))
        val e = expectError(client(key = "super-secret-fake"))
        assertFalse(e.message!!.contains("super-secret-fake"))
    }

    @Test fun cancellingPromptlyCancelsTheCall() = runBlocking {
        server.enqueue(ok().setHeadersDelay(10, TimeUnit.SECONDS))
        val c = client()
        val job = launch(Dispatchers.Default) { c.complete(msgs) }
        withTimeout(5000) { server.takeRequest() }
        val t0 = System.nanoTime()
        job.cancel()
        withTimeout(1000) { job.join() }
        assertTrue(job.isCancelled)
        assertTrue((System.nanoTime() - t0) < 1_000_000_000L)
    }
}
