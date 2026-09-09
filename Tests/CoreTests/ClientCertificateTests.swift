import XCTest
import Security
@testable import YuzicEngineCore

/**
 Reading a client certificate, and offering it when a server asks.

 The PKCS#12 is generated here rather than committed. A throwaway self-signed
 key is not much of a secret, but a repository is the wrong place to learn the
 habit of keeping private keys in, and generating it also exercises the format
 real tooling actually emits rather than one blob frozen years ago.
 */
final class ClientCertificateTests: XCTestCase {

  private static let password = "correct horse battery staple"

  /**
   A throwaway keychain for the import to land in.

   `SecPKCS12Import` decrypts the private key into a keychain, and **on macOS
   it will not choose one itself** — without `kSecImportExportKeychain` it
   returns errSecPkcs12VerifyFailure (-26276) for every PKCS#12 regardless of
   how the file was produced. iOS neither needs this nor has the API, so this
   is scaffolding for `swift test` and nothing the app ever executes.

   Worth stating because the symptom is so misleading: -26276 reads as "this
   file is corrupt", and it sent an earlier reading of this failure off after
   the blob's encoding. LibreSSL's default, OpenSSL 3's default, `-legacy`, a
   sha1 MAC and 3DES all fail the same way with no keychain and all import
   cleanly with one. The file was never the variable.
   */
  private static var keychain: SecKeychain? = {
    let path = NSTemporaryDirectory() + "yuzic-engine-tests-\(UUID().uuidString).keychain"
    var created: SecKeychain?
    guard SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created)
      == errSecSuccess else { return nil }
    return created
  }()

  override class func setUp() {
    super.setUp()
    ClientCertificate.importKeychain = keychain
  }

  /// A PKCS#12 holding a self-signed identity, or nil where `openssl` is not
  /// available to make one.
  private func makePKCS12(commonName: String = "yuzic-test-client") throws -> Data? {
    let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
    guard FileManager.default.isExecutableFile(atPath: openssl.path) else { return nil }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let key = directory.appendingPathComponent("key.pem")
    let cert = directory.appendingPathComponent("cert.pem")
    let bundle = directory.appendingPathComponent("identity.p12")

    try run(openssl, [
      "req", "-x509", "-newkey", "rsa:2048",
      "-keyout", key.path, "-out", cert.path,
      "-days", "1", "-nodes", "-subj", "/CN=\(commonName)",
    ])
    try run(openssl, [
      "pkcs12", "-export", "-out", bundle.path,
      "-inkey", key.path, "-in", cert.path,
      "-passout", "pass:\(Self.password)",
    ])
    return try Data(contentsOf: bundle)
  }

  private func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "openssl \(arguments.first ?? "") failed")
  }

  // MARK: - Import

  func testAPKCS12IsReadIntoAnIdentity() throws {
    guard let blob = try makePKCS12() else {
      throw XCTSkip("openssl is not available on this machine")
    }
    let certificate = try ClientCertificate(pkcs12: blob, password: Self.password)
    XCTAssertEqual(certificate.commonName, "yuzic-test-client")
  }

  /**
   A wrong password is refused rather than half-read.

   `SecPKCS12Import` reports the same `errSecAuthFailed` for a wrong password
   and for a file that is not a PKCS#12 at all, which is why there is one error
   case covering both — a message claiming to know which would be inventing the
   distinction.
   */
  func testAWrongPasswordIsRefused() throws {
    guard let blob = try makePKCS12() else {
      throw XCTSkip("openssl is not available on this machine")
    }
    XCTAssertThrowsError(try ClientCertificate(pkcs12: blob, password: "not it")) { error in
      guard case ClientCertificate.ImportError.cannotDecrypt = error else {
        return XCTFail("expected a decryption failure, got \(error)")
      }
    }
  }

  func testSomethingThatIsNotAPKCS12IsRefused() {
    let blob = Data("this is a text file, not a certificate".utf8)
    XCTAssertThrowsError(try ClientCertificate(pkcs12: blob, password: Self.password))
  }

  // MARK: - The challenge

  /// Stands in for the sender `URLAuthenticationChallenge` requires. Nothing
  /// calls back into it: the delegate answers through its completion handler.
  private final class NullSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
  }

  private func challenge(method: String) -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
      protectionSpace: URLProtectionSpace(
        host: "music.example.test", port: 443, protocol: "https",
        realm: nil, authenticationMethod: method
      ),
      proposedCredential: nil,
      previousFailureCount: 0,
      failureResponse: nil,
      error: nil,
      sender: NullSender()
    )
  }

  func testAClientCertificateChallengeIsAnsweredWithTheIdentity() throws {
    guard let blob = try makePKCS12() else {
      throw XCTSkip("openssl is not available on this machine")
    }
    let certificate = try ClientCertificate(pkcs12: blob, password: Self.password)
    let delegate = ClientCertificateDelegate(certificate: certificate)

    var disposition: URLSession.AuthChallengeDisposition?
    var offered: URLCredential?
    delegate.urlSession(
      URLSession.shared,
      task: URLSession.shared.dataTask(with: URL(string: "https://music.example.test")!),
      didReceive: challenge(method: NSURLAuthenticationMethodClientCertificate)
    ) { disposition = $0; offered = $1 }

    XCTAssertEqual(disposition, .useCredential)
    XCTAssertNotNil(offered?.identity, "the credential must carry the identity, not just a certificate")
  }

  /**
   Server trust is left alone.

   Answering every challenge here is how an app ends up not validating the
   server's own certificate. Presenting a client certificate says nothing
   about how the server's should be checked, so anything that is not a request
   for a client certificate falls through to the default handling.
   */
  func testServerTrustIsLeftToTheDefaultHandling() throws {
    guard let blob = try makePKCS12() else {
      throw XCTSkip("openssl is not available on this machine")
    }
    let certificate = try ClientCertificate(pkcs12: blob, password: Self.password)
    let delegate = ClientCertificateDelegate(certificate: certificate)

    for method in [
      NSURLAuthenticationMethodServerTrust,
      NSURLAuthenticationMethodHTTPBasic,
      NSURLAuthenticationMethodNTLM,
    ] {
      var disposition: URLSession.AuthChallengeDisposition?
      var offered: URLCredential?
      delegate.urlSession(
        URLSession.shared,
        task: URLSession.shared.dataTask(with: URL(string: "https://music.example.test")!),
        didReceive: challenge(method: method)
      ) { disposition = $0; offered = $1 }

      XCTAssertEqual(disposition, .performDefaultHandling, "\(method) must not be answered here")
      XCTAssertNil(offered, "\(method) must not be handed a credential")
    }
  }
}
