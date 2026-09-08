import Foundation
import Security

/**
 A client certificate, for a server that asks the client to prove who it is.

 Mutual TLS: the server presents a certificate as every HTTPS server does, and
 then asks the client for one too. It is how a self-hosted library can be
 exposed to the internet without a VPN — a reverse proxy in front of Navidrome
 refuses anyone who cannot present a certificate it trusts, so the server is
 reachable by domain and still closed to everyone else.

 Without this the connection does not fail in an interesting way. The server
 asks, `URLSession` has nothing to offer, and the handshake ends — which
 surfaces as "cannot connect" with no indication that a certificate was ever
 wanted.

 The certificate and its private key arrive together in a PKCS#12 file, which
 is what every tool that issues one produces and what the other apps people
 compare this to accept. It is password-protected by construction; that
 password is a decryption key rather than a credential to check, so a wrong one
 is indistinguishable from a corrupt file until the import fails.
 */
public final class ClientCertificate {

  public enum ImportError: Error, Equatable {
    /// The blob is not a PKCS#12 file, or the password does not decrypt it.
    /// One case rather than two on purpose: `SecPKCS12Import` reports
    /// `errSecAuthFailed` for both, and guessing which would be a guess.
    case cannotDecrypt(OSStatus)
    /// Decrypted, but carried no identity — a PKCS#12 holding only
    /// certificates and no private key. It will import cleanly in a viewer and
    /// is useless for authenticating.
    case noIdentity
  }

  /// The identity — certificate plus private key — that answers the challenge.
  public let identity: SecIdentity
  /// Intermediates shipped alongside it, which a server may need to build a
  /// chain to its trust anchor. Empty is normal and fine.
  public let chain: [SecCertificate]

  /// What `URLSession` wants handed back. Built once: constructing it per
  /// challenge would be re-doing work on every request, and there is one
  /// challenge per connection.
  public private(set) lazy var credential = URLCredential(
    identity: identity,
    certificates: chain.isEmpty ? nil : chain,
    persistence: .forSession
  )

  /**
   Read an identity out of a PKCS#12 blob.

   `SecPKCS12Import` puts the result in the keychain's *access* scope for the
   life of the process rather than writing to the keychain proper, so nothing
   here is persisted — storing the blob is the caller's business, and on the
   app side that means the system keychain rather than anywhere this can see.
   */
  public init(pkcs12: Data, password: String) throws {
    var items: CFArray?
    let options: [String: Any] = [kSecImportExportPassphrase as String: password]
    let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess else { throw ImportError.cannotDecrypt(status) }

    guard let entries = items as? [[String: Any]],
          let first = entries.first,
          let rawIdentity = first[kSecImportItemIdentity as String] else {
      throw ImportError.noIdentity
    }
    // Unchecked cast because `SecIdentity` is a CoreFoundation type and the
    // dictionary is `Any`; the key guarantees what is behind it.
    self.identity = rawIdentity as! SecIdentity

    let trustChain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
    // The leaf is already inside the identity. Sending it twice is harmless
    // but pointless, and dropping it here keeps the credential minimal.
    var leaf: SecCertificate?
    SecIdentityCopyCertificate(identity, &leaf)
    if let leaf {
      self.chain = trustChain.filter { !CFEqual($0, leaf) }
    } else {
      self.chain = trustChain
    }
  }

  /// The common name on the certificate, for showing someone which one they
  /// imported. Nil when the certificate has no common name, which is unusual
  /// but permitted.
  public var commonName: String? {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let certificate else { return nil }
    var name: CFString?
    guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
    return name as String?
  }
}

/**
 Answers a server's request for a client certificate, and nothing else.

 `answerAuthenticationChallenge` is the whole rule, kept as one function
 because two call sites need it and it is a security boundary: the streaming
 producer is already its own `URLSessionDataDelegate` and cannot borrow this
 class, so without a shared implementation the "leave server trust alone" part
 would exist twice and could drift.

 Deliberately narrow. This is attached to sessions that already have their own
 delegates or none at all, so it implements exactly one method and defers
 every other challenge — including server trust — to the default handling.
 Taking over server-trust evaluation here is how apps accidentally disable
 certificate validation, and there is no reason to touch it: the client
 presenting a certificate says nothing about how the server's own should be
 checked.
 */
public func answerAuthenticationChallenge(
  _ challenge: URLAuthenticationChallenge,
  with certificate: ClientCertificate?,
  completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) {
  guard challenge.protectionSpace.authenticationMethod
          == NSURLAuthenticationMethodClientCertificate,
        let certificate else {
    completionHandler(.performDefaultHandling, nil)
    return
  }
  completionHandler(.useCredential, certificate.credential)
}

public final class ClientCertificateDelegate: NSObject, URLSessionTaskDelegate {

  private let certificate: ClientCertificate

  public init(certificate: ClientCertificate) {
    self.certificate = certificate
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    answerAuthenticationChallenge(challenge, with: certificate, completionHandler: completionHandler)
  }
}

/**
 A session that will present `certificate` when asked for one.

 One session for the whole engine rather than one per request: `URLSession`
 pools connections, and a TLS handshake with a client certificate is the
 expensive kind. A new session per track would redo it for every track, on the
 connection the audio is already competing for.
 */
public func makeClientCertificateSession(
  certificate: ClientCertificate,
  configuration: URLSessionConfiguration = .default
) -> URLSession {
  URLSession(
    configuration: configuration,
    delegate: ClientCertificateDelegate(certificate: certificate),
    delegateQueue: nil
  )
}
