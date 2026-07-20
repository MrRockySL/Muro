import Foundation
import CryptoKit

// Native S3-compatible uploads to Cloudflare R2 — a signed PUT per object,
// no rclone/aws dependency. R2 speaks AWS Signature V4 with region "auto";
// path-style URLs (https://<account>.r2.cloudflarestorage.com/<bucket>/<key>).
//
// Credentials live ONLY in ~/.config/muro/r2.json (chmod 600) on the owner's
// machine. The app never sees them — it performs plain public GETs against
// the bucket's public URL.

struct R2Config: Codable {
    var accountId: String
    var accessKeyId: String
    var secretAccessKey: String
    var bucket: String
    var publicBaseURL: String

    static var configPath: String {
        NSString(string: "~/.config/muro/r2.json").expandingTildeInPath
    }

    static func load() -> R2Config? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return try? JSONDecoder().decode(R2Config.self, from: data)
    }

    var endpointHost: String { "\(accountId).r2.cloudflarestorage.com" }
}

enum R2Error: Error, CustomStringConvertible {
    case requestFailed(key: String, status: Int, body: String)
    case transport(key: String, underlying: String)

    var description: String {
        switch self {
        case .requestFailed(let key, let status, let body):
            return "R2 PUT \(key) failed: HTTP \(status) — \(body.prefix(300))"
        case .transport(let key, let underlying):
            return "R2 PUT \(key) failed: \(underlying)"
        }
    }
}

private func hmac(_ key: Data, _ message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(
        for: Data(message.utf8), using: SymmetricKey(data: key)
    ))
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Streaming SHA-256 so 60 MB masters aren't loaded into memory.
private func sha256HexOfFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// One session for all uploads; generous timeouts for 60 MB files on slow
/// uplinks.
private let r2Session: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 300
    cfg.timeoutIntervalForResource = 3600
    return URLSession(configuration: cfg)
}()

/// Uploads one file as `key`, blocking until done. Cache-Control is stored
/// with the object and served on every GET — this is what lets new catalogs
/// propagate in ~1 minute while immutable assets cache for a year.
func r2Put(
    file: URL,
    key: String,
    contentType: String,
    cacheControl: String,
    config: R2Config
) throws {
    let payloadHash = try sha256HexOfFile(file)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    dateFormatter.timeZone = TimeZone(identifier: "UTC")
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    let amzDate = dateFormatter.string(from: Date())
    let shortDate = String(amzDate.prefix(8))

    let host = config.endpointHost
    let canonicalURI = "/\(config.bucket)/\(key)"   // keys are [a-z0-9./-], no escaping needed

    // Sign every header we send. Order and lowercase are mandated by SigV4.
    let headers: [(String, String)] = [
        ("cache-control", cacheControl),
        ("content-type", contentType),
        ("host", host),
        ("x-amz-content-sha256", payloadHash),
        ("x-amz-date", amzDate)
    ]
    let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
    let signedHeaders = headers.map(\.0).joined(separator: ";")

    let canonicalRequest = [
        "PUT", canonicalURI, "",
        canonicalHeaders, signedHeaders, payloadHash
    ].joined(separator: "\n")

    let scope = "\(shortDate)/auto/s3/aws4_request"
    let stringToSign = [
        "AWS4-HMAC-SHA256", amzDate, scope,
        sha256Hex(Data(canonicalRequest.utf8))
    ].joined(separator: "\n")

    let kDate = hmac(Data(("AWS4" + config.secretAccessKey).utf8), shortDate)
    let kRegion = hmac(kDate, "auto")
    let kService = hmac(kRegion, "s3")
    let kSigning = hmac(kService, "aws4_request")
    let signature = hmac(kSigning, stringToSign)
        .map { String(format: "%02x", $0) }.joined()

    var request = URLRequest(url: URL(string: "https://\(host)\(canonicalURI)")!)
    request.httpMethod = "PUT"
    request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
    request.setValue(
        "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(scope), "
        + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
        forHTTPHeaderField: "Authorization"
    )

    var result: Result<Void, R2Error>?
    let done = DispatchSemaphore(value: 0)
    r2Session.uploadTask(with: request, fromFile: file) { data, response, error in
        if let error {
            result = .failure(.transport(key: key, underlying: error.localizedDescription))
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            result = .failure(.requestFailed(key: key, status: http.statusCode, body: body))
        } else {
            result = .success(())
        }
        done.signal()
    }.resume()
    done.wait()
    if case .failure(let error) = result! { throw error }
}
