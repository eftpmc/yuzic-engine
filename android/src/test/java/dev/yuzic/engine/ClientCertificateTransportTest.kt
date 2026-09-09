package dev.yuzic.engine

import java.net.ServerSocket
import java.util.Base64
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ClientCertificateTransportTest {
  private val fixture by lazy {
    val bytes = checkNotNull(javaClass.getResourceAsStream("/client-certificate.p12")) {
      "missing client-certificate.p12 test fixture"
    }.use { it.readBytes() }
    Base64.getEncoder().encodeToString(bytes)
  }

  @Test
  fun importsPkcs12EagerlyAndSharesTheClientWithAudio() {
    val transport = ClientCertificateTransport()
    val before = transport.clientSnapshotForTesting()
    val audioFactory = transport.audioCallFactory

    transport.setClientCertificate(fixture, "correct-password")

    val active = transport.clientSnapshotForTesting()
    assertTrue(transport.hasClientCertificate)
    assertNotSame(before, active)
    assertSame(active, audioFactory.clientSnapshotForTesting())
  }

  @Test
  fun wrongPasswordThrowsAtImportAndLeavesTheExistingIdentityAlone() {
    val transport = ClientCertificateTransport()
    transport.setClientCertificate(fixture, "correct-password")
    val existing = transport.clientSnapshotForTesting()

    try {
      transport.setClientCertificate(fixture, "wrong-password")
      fail("wrong password should fail while importing")
    } catch (_: Exception) {
      // The failure is the contract. It must happen here, before any request.
    }

    assertTrue(transport.hasClientCertificate)
    assertSame(existing, transport.clientSnapshotForTesting())
    assertSame(existing, transport.audioCallFactory.clientSnapshotForTesting())
  }

  @Test
  fun nullAndEmptyBothClearTheIdentityForApiAndAudio() {
    val transport = ClientCertificateTransport()
    transport.setClientCertificate(fixture, "correct-password")
    val certificateClient = transport.clientSnapshotForTesting()

    transport.setClientCertificate(null, null)
    val cleared = transport.clientSnapshotForTesting()
    assertFalse(transport.hasClientCertificate)
    assertNotSame(certificateClient, cleared)
    assertSame(cleared, transport.audioCallFactory.clientSnapshotForTesting())

    transport.setClientCertificate(fixture, "correct-password")
    transport.setClientCertificate("", "ignored")
    assertFalse(transport.hasClientCertificate)
    assertSame(
      transport.clientSnapshotForTesting(),
      transport.audioCallFactory.clientSnapshotForTesting(),
    )
  }

  @Test
  fun malformedBase64ThrowsBeforeAnyRequest() {
    val transport = ClientCertificateTransport()
    val existing = transport.clientSnapshotForTesting()

    try {
      transport.setClientCertificate("not base64!", "password")
      fail("malformed base64 should fail while importing")
    } catch (_: IllegalArgumentException) {
      // Expected.
    }

    assertFalse(transport.hasClientCertificate)
    assertSame(existing, transport.clientSnapshotForTesting())
  }

  @Test
  fun requestReturnsHttpStatusLowercaseHeadersAndArbitraryBytes() {
    ServerSocket(0).use { server ->
      val serving = thread(name = "client-certificate-http-fixture") {
        server.accept().use { socket ->
          val reader = socket.getInputStream().bufferedReader()
          while (!reader.readLine().isNullOrEmpty()) Unit
          val body = byteArrayOf(0, 0xff.toByte(), 0x41, 0x42)
          socket.getOutputStream().apply {
            write("HTTP/1.1 418 Teapot\r\nX-Fixture: yes\r\nContent-Length: 4\r\nConnection: close\r\n\r\n".toByteArray())
            write(body)
            flush()
          }
        }
      }

      val result = ClientCertificateTransport().request(
        url = "http://127.0.0.1:${server.localPort}/bytes",
        method = "GET",
        headers = mapOf("X-Request" to "present"),
        bodyBase64 = null,
        timeoutMs = 5_000,
      )
      serving.join(5_000)

      assertEquals(418, result.status)
      assertEquals("yes", result.headers["x-fixture"])
      assertEquals("AP9BQg==", result.bodyBase64)
    }
  }

  @Test
  fun invalidAndNonHttpUrlsAreLegible() {
    val transport = ClientCertificateTransport()

    try {
      transport.request("not a url", "GET", emptyMap(), null, 1_000)
      fail("malformed URL should throw")
    } catch (error: IllegalArgumentException) {
      assertTrue(error.message.orEmpty().contains("Not a valid URL"))
    }

    try {
      transport.request("file:///tmp/audio", "GET", emptyMap(), null, 1_000)
      fail("non-HTTP URL should throw")
    } catch (error: IllegalArgumentException) {
      assertTrue(error.message.orEmpty().contains("HTTP or HTTPS"))
    }
  }
}
