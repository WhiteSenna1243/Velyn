import Foundation
import Network

// MARK: - HTTP

/// The parts of an HTTP request the phone remote needs.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]      // lowercased names
    let body: Data

    static let maxSize = 64 * 1024

    /// A complete request from the bytes so far, or nil if more are needed (or it's not HTTP).
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard length >= 0, data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let comps = URLComponents(string: "http://velyn" + first[1])
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: first[0].uppercased(), path: comps?.path ?? "/", query: query,
                           headers: headers, body: Data(body))
    }

    /// The JSON body as a dictionary.
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

struct HTTPResponse {
    var status = 200
    var type = "application/json; charset=utf-8"
    var body = Data()

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8))
    }
    static func encoded<T: Encodable>(_ value: T) -> HTTPResponse {
        HTTPResponse(body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
    static let ok = json(["ok": true])
    static func error(_ status: Int, _ message: String) -> HTTPResponse { json(["error": message], status: status) }

    var data: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Server

/// A tiny HTTP server on the local network (one request per connection).
/// `handler` is called on the main thread and must call `respond` exactly once.
final class RemoteServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "velyn.remote")
    private let handler: Handler
    /// Called on the main thread with the port once listening, or nil when it stopped or failed.
    var onState: ((UInt16?) -> Void)?

    init(handler: @escaping Handler) { self.handler = handler }

    /// Listens on `port`, or the next free one of the 10 after it. `loopbackOnly` (tests) accepts
    /// connections from this Mac only.
    func start(port: UInt16, loopbackOnly: Bool = false) {
        stop()
        for p in port..<(port &+ 10) {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if loopbackOnly {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: p) ?? .any)
            }
            guard let l = try? (loopbackOnly ? NWListener(using: params)
                                             : NWListener(using: params, on: NWEndpoint.Port(rawValue: p) ?? .any)) else { continue }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                switch state {
                case .ready:
                    let actual = l?.port?.rawValue ?? p
                    DispatchQueue.main.async { self?.onState?(actual) }
                case .failed, .cancelled:
                    DispatchQueue.main.async { self?.onState?(nil) }
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
            return
        }
        DispatchQueue.main.async { self.onState?(nil) }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
        // Drop connections that never finish a request.
        queue.asyncAfter(deadline: .now() + 15) { if c.state != .cancelled { c.cancel() } }
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > HTTPRequest.maxSize {
                self.send(.error(413, "too big"), on: c)
            } else if let req = HTTPRequest.parse(buf) {
                DispatchQueue.main.async {
                    self.handler(req) { resp in self.queue.async { self.send(resp, on: c) } }
                }
            } else if done || error != nil {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    private func send(_ r: HTTPResponse, on c: NWConnection) {
        c.send(content: r.data, completion: .contentProcessed { _ in c.cancel() })
    }
}
