import Foundation

/// Bounds both metadata and payload transfers, including every redirect hop.
final class UpdateNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var output: FileHandle?
    private var destination: URL?
    private var limit = 0
    private var count = 0
    private var session: URLSession?
    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil &&
        ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    func fetch(_ url: URL, to destination: URL, limit: Int) async throws {
        guard Self.allows(url) else { throw AppFailure("更新下载地址不受信任。") }
        self.destination = destination; self.limit = limit
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        output = try FileHandle(forWritingTo: destination)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.invalidateAndCancel(); self.session = nil; try? output?.close(); output = nil }
        var request = URLRequest(url: url); request.setValue("Yabaibye-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        _ = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.continuation = continuation; session.dataTask(with: request).resume()
            }
        }, onCancel: { session.invalidateAndCancel() })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url.map(Self.allows) == true, response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        count += data.count
        guard count <= limit else { dataTask.cancel(); return }
        do { try output?.write(contentsOf: data) } catch { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation; self.continuation = nil
        if let error { continuation?.resume(throwing: error) }
        else if let destination { continuation?.resume(returning: destination) }
    }
}
