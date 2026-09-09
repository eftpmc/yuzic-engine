package dev.yuzic.engine

import java.io.ByteArrayInputStream
import java.net.URI
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import okhttp3.Call
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

/**
 * One memory-resident client identity shared by the bridge and audio fetches.
 *
 * Certificate replacement is an atomic client swap. Certificate setters are
 * serialized so two imports cannot complete out of invocation order. Parsing
 * and constructing the TLS stack finish before the client is swapped, so a
 * request either snapshots the complete old client or the complete new one; it
 * can never observe a half-built KeyManager. Existing calls may finish on their
 * snapshot, while every call created after a clear uses the ordinary
 * no-certificate client.
 *
 * [audioCallFactory] is deliberately stable. Media3 captures its DataSource
 * factory when each voice is built, so replacing a field on [AudioGraph] would
 * not update those voices. This factory snapshots the current client for every
 * new OkHttp Call instead, which makes an already-created player pick up an
 * imported, replaced, or cleared identity on its next network request.
 */
class ClientCertificateTransport(
  initialClient: OkHttpClient = OkHttpClient(),
) {
  data class Result(
    val status: Int,
    val headers: Map<String, String>,
    val bodyBase64: String,
  )

  private val lock = Any()
  private var client = initialClient
  private var certificateIsSet = false

  val audioCallFactory = SnapshotCallFactory { snapshotClient() }

  val hasClientCertificate: Boolean
    get() = synchronized(lock) { certificateIsSet }

  /**
   * Import a PKCS#12 identity now, or clear it when the blob is null/empty.
   *
   * Nothing is persisted and neither the blob nor password is logged. A failed
   * import leaves the prior client untouched, so a typo cannot silently replace
   * a working identity with one that will fail later at the handshake.
   */
  @Synchronized
  fun setClientCertificate(pkcs12Base64: String?, password: String?) {
    if (pkcs12Base64.isNullOrEmpty()) {
      replaceClient(OkHttpClient(), hasCertificate = false)
      return
    }

    val blob = pkcs12Base64.decodeBase64()?.toByteArray()
      ?: throw IllegalArgumentException("The client certificate is not valid base64.")
    val passphrase = (password ?: "").toCharArray()
    val keyStore = KeyStore.getInstance("PKCS12").apply {
      ByteArrayInputStream(blob).use { load(it, passphrase) }
    }
    val hasPrivateKey = keyStore.aliases().toList().any { keyStore.isKeyEntry(it) }
    require(hasPrivateKey) { "The PKCS#12 does not contain a private-key identity." }

    val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
      init(keyStore, passphrase)
    }.keyManagers

    // Supplying null to TrustManagerFactory means the platform's system trust
    // store. The client identity changes only client authentication; server
    // chains and hostnames retain OkHttp's strict platform-default validation.
    val trustManager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).run {
      init(null as KeyStore?)
      trustManagers.filterIsInstance<X509TrustManager>().singleOrNull()
        ?: throw IllegalStateException("The platform did not provide one X509 trust manager.")
    }
    val sslContext = SSLContext.getInstance("TLS").apply {
      init(keyManagers, arrayOf(trustManager), null)
    }
    val imported = OkHttpClient.Builder()
      .sslSocketFactory(sslContext.socketFactory, trustManager)
      .build()

    replaceClient(imported, hasCertificate = true)
  }

  /** Perform the narrow bridge request on the same pooled client audio uses. */
  fun request(
    url: String,
    method: String,
    headers: Map<String, String>,
    bodyBase64: String?,
    timeoutMs: Int,
  ): Result {
    val httpUrl = parseHttpUrl(url)
    val decodedBody = bodyBase64?.decodeBase64()?.toByteArray()
    val requestBody = when {
      decodedBody != null -> decodedBody.toRequestBody(null)
      methodNeedsBody(method) -> ByteArray(0).toRequestBody(null)
      else -> null
    }
    val request = Request.Builder()
      .url(httpUrl)
      .method(method, requestBody)
      .apply { headers.forEach { (name, value) -> header(name, value) } }
      .build()

    val call = snapshotClient().newCall(request)
    // Zero is an unsafe "forever" ceiling in OkHttp. The TypeScript contract
    // says omitted means 30 seconds, so non-positive bridge values take that
    // same safe default rather than creating an unbounded request.
    call.timeout().timeout(
      if (timeoutMs > 0) timeoutMs.toLong() else DEFAULT_TIMEOUT_MS,
      TimeUnit.MILLISECONDS,
    )
    return call.execute().use(::resultFrom)
  }

  private fun resultFrom(response: Response): Result {
    val loweredHeaders = response.headers.names().associate { name ->
      name.lowercase() to response.headers.values(name).joinToString(", ")
    }
    val bytes = response.body?.bytes() ?: ByteArray(0)
    return Result(response.code, loweredHeaders, bytes.toByteString().base64())
  }

  private fun parseHttpUrl(raw: String): HttpUrl {
    val uri = try {
      URI(raw)
    } catch (_: Exception) {
      throw IllegalArgumentException("Not a valid URL: $raw")
    }
    val scheme = uri.scheme?.lowercase()
    if (scheme != null && scheme != "http" && scheme != "https") {
      throw IllegalArgumentException("The URL must use HTTP or HTTPS: $raw")
    }
    return raw.toHttpUrlOrNull() ?: throw IllegalArgumentException("Not a valid URL: $raw")
  }

  private fun methodNeedsBody(method: String): Boolean = when (method.uppercase()) {
    "POST", "PUT", "PATCH", "PROPPATCH", "REPORT" -> true
    else -> false
  }

  private fun replaceClient(next: OkHttpClient, hasCertificate: Boolean) {
    val previous = synchronized(lock) {
      val old = client
      client = next
      certificateIsSet = hasCertificate
      old
    }
    // Stop the removed identity's pooled sockets from surviving a clear. Calls
    // that already hold a connection are allowed to finish on their snapshot;
    // no newly-created API or audio call can reach this old pool.
    previous.connectionPool.evictAll()
  }

  private fun snapshotClient(): OkHttpClient = synchronized(lock) { client }

  internal fun clientSnapshotForTesting(): OkHttpClient = snapshotClient()

  companion object {
    private const val DEFAULT_TIMEOUT_MS = 30_000L
  }
}

/** A stable Call.Factory whose calls follow the transport's atomic snapshots. */
class SnapshotCallFactory(
  private val clientProvider: () -> OkHttpClient,
) : Call.Factory {
  override fun newCall(request: Request): Call = clientProvider().newCall(request)

  internal fun clientSnapshotForTesting(): OkHttpClient = clientProvider()
}
