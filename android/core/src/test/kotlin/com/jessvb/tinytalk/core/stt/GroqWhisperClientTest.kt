package com.jessvb.tinytalk.core.stt

import com.jessvb.tinytalk.core.chat.GroqException
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class GroqWhisperClientTest {
    private lateinit var server: MockWebServer
    private val pcm = shortArrayOf(1, 2, 3, -4, 300)

    @Before fun setUp() { server = MockWebServer().apply { start() } }
    @After fun tearDown() { try { server.shutdown() } catch (_: Exception) {} }

    private fun client(key: String? = "fake-key") = GroqWhisperClient(
        apiKey = { key }, host = server.url("/").toString().trimEnd('/')
    )
    private suspend fun expectError(c: GroqWhisperClient = client()): GroqException = try {
        c.transcribe(pcm, 16000); fail("expected GroqException"); throw IllegalStateException()
    } catch (e: GroqException) { e }

    @Test fun multipartRequestAndResult() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"text":"the fox ran"}"""))
        assertEquals("the fox ran", client().transcribe(pcm, 16000))
        val req = server.takeRequest()
        assertEquals("/openai/v1/audio/transcriptions", req.path)
        assertEquals("Bearer fake-key", req.getHeader("Authorization"))
        val ct = req.getHeader("Content-Type")!!
        assertTrue(ct.startsWith("multipart/form-data"))
        val boundary = ct.substringAfter("boundary=").trim('"')
        val text = String(req.body.readByteArray(), Charsets.ISO_8859_1)
        val parts = text.split("--$boundary").filter { it.startsWith("\r\n") }
        fun part(name: String) = parts.first { it.contains("name=\"$name\"") }
        fun valueOf(name: String) = part(name).substringAfter("\r\n\r\n").removeSuffix("\r\n")
        assertEquals("whisper-large-v3-turbo", valueOf("model"))
        assertEquals("en", valueOf("language"))
        val file = part("file")
        assertTrue(file.contains("filename=\"utterance.wav\""))
        assertTrue(file.lowercase().contains("content-type: audio/wav"))
        val payload = file.substringAfter("\r\n\r\n").removeSuffix("\r\n")
        assertArrayEquals(wavFromPcm16(pcm, 16000), payload.toByteArray(Charsets.ISO_8859_1))
    }

    @Test fun errorMapping() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))
        assertTrue(expectError() is GroqException.KeyRejected)
        server.enqueue(MockResponse().setResponseCode(403))
        assertTrue(expectError() is GroqException.KeyRejected)
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "3"))
        assertEquals(3, (expectError() as GroqException.RateLimited).retryAfterSeconds)
        server.enqueue(MockResponse().setResponseCode(429))
        assertNull((expectError() as GroqException.RateLimited).retryAfterSeconds)
        server.enqueue(MockResponse().setResponseCode(500))
        assertTrue(expectError() is GroqException.Failure)
        server.enqueue(MockResponse().setBody("""{"nope":1}"""))
        assertTrue(expectError() is GroqException.Failure)
    }

    @Test fun connectionRefusedIsNetwork() = runBlocking {
        val c = client()
        server.shutdown()
        assertTrue(expectError(c) is GroqException.Network)
    }

    @Test fun missingKeyMakesNoRequest() = runBlocking {
        assertTrue(expectError(client(key = null)) is GroqException.KeyMissing)
        assertTrue(expectError(client(key = " ")) is GroqException.KeyMissing)
        assertEquals(0, server.requestCount)
    }
}
