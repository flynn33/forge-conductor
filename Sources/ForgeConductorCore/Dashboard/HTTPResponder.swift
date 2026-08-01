// HTTPResponder.swift
// What: Encodes HTTP responses and retains continuous SSE sessions.
// How: It builds bounded headers/bodies, serializes JSON, and queues streaming frames
// through one send pipeline until the client, timer, or network closes the session.
// Why: Central response mechanics keep every route consistent and prevent stream loss.

import Foundation
import Network

/// Low-level HTTP response writer for the loopback control surface.
/// Extracted from DashboardServer so route handlers stay free of socket details.
public final class HTTPResponder: @unchecked Sendable {
    /// Retain live SSE sessions until they close (otherwise ARC ends the stream after 1 frame).
    private let streamLock = NSLock()
    private var liveStreams: [ObjectIdentifier: SSEStreamSession] = [:]

    public init() {}

    fileprivate func retainStream(_ session: SSEStreamSession) {
        streamLock.lock()
        liveStreams[ObjectIdentifier(session)] = session
        streamLock.unlock()
    }

    fileprivate func releaseStream(_ session: SSEStreamSession) {
        streamLock.lock()
        liveStreams[ObjectIdentifier(session)] = nil
        streamLock.unlock()
    }

    public func respondJSON(_ connection: NWConnection, status: Int, object: [String: Any]) {
        let data = (try? JSONSupport.data(from: object)) ?? Data("{}".utf8)
        let body = String(data: data, encoding: .utf8) ?? "{}"
        respond(connection, status: status, body: body, contentType: "application/json; charset=utf-8")
    }

    public func respondData(
        _ connection: NWConnection,
        status: Int,
        data: Data,
        contentType: String
    ) {
        let reason = status == 200 ? "OK" : "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(data.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += securityHeaders
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    public func respond(
        _ connection: NWConnection,
        status: Int,
        body: String,
        contentType: String,
        extraHeaders: [String] = []
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 413: reason = "Content Too Large"
        case 415: reason = "Unsupported Media Type"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 431: reason = "Request Header Fields Too Large"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += securityHeaders
        for h in extraHeaders { header += h + "\r\n" }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Legacy one-shot SSE (compat). Prefer `startRealtimeSSE`.
    public func respondSSE(connection: NWConnection, snapshot: [String: Any]) {
        let json = (try? JSONSupport.string(from: snapshot)) ?? "{}"
        var body = ": connected\n\n"
        body += "data: \(json)\n\n"
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream; charset=utf-8\r\n"
        header += "Cache-Control: no-cache, no-transform\r\n"
        header += "Connection: close\r\n"
        header += securityHeaders
        header += "Content-Length: \(bodyData.count)\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private var securityHeaders: String {
        "X-Content-Type-Options: nosniff\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "Cross-Origin-Resource-Policy: same-origin\r\n"
            + "Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'\r\n"
    }

    /// Continuous SSE: keep-alive stream of live frames from the realtime metrics engine.
    @discardableResult
    public func startRealtimeSSE(
        connection: NWConnection,
        telemetry: TelemetryService,
        targetHz: Double = 20,
        maxDurationSec: TimeInterval = 3600
    ) -> SSEStreamSession {
        let session = SSEStreamSession(
            connection: connection,
            telemetry: telemetry,
            targetHz: targetHz,
            maxDurationSec: maxDurationSec,
            responder: self
        )
        retainStream(session)
        return session
    }
}

/// Continuous SSE over an accepted `NWConnection`.
///
/// Uses a serial send pipeline with `isComplete: false` (TCP stream semantics)
/// and a Dispatch timer as the product clock for frames (engine advances host metrics).
///
/// **Must be retained** by `HTTPResponder` for the life of the stream.
public final class SSEStreamSession: @unchecked Sendable {
    private let connection: NWConnection
    private let telemetry: TelemetryService
    private weak var responder: HTTPResponder?
    private let periodMs: Int
    private let maxDurationSec: TimeInterval
    private let queue = DispatchQueue(label: "forge.telemetry.sse", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var closed = false
    private var eventCount = 0
    private var sendChain: [(Data, Bool)] = []
    private var sending = false
    private var tick = 0

    public var eventsSent: Int {
        lock.lock(); defer { lock.unlock() }
        return eventCount
    }

    public init(
        connection: NWConnection,
        telemetry: TelemetryService,
        targetHz: Double,
        maxDurationSec: TimeInterval,
        responder: HTTPResponder? = nil
    ) {
        self.connection = connection
        self.telemetry = telemetry
        self.responder = responder
        let hz = min(max(targetHz, 1), 60)
        self.periodMs = max(20, Int((1000.0 / hz).rounded()))
        self.maxDurationSec = maxDurationSec
        begin()
    }

    private func begin() {
        if !telemetry.realtimeEngine.isRunning {
            telemetry.startBackgroundRefresh(intervalSec: 0.5)
        }

        var bootstrap = "HTTP/1.1 200 OK\r\n"
        bootstrap += "Content-Type: text/event-stream; charset=utf-8\r\n"
        bootstrap += "Cache-Control: no-cache, no-transform\r\n"
        bootstrap += "Connection: keep-alive\r\n"
        bootstrap += "X-Content-Type-Options: nosniff\r\n"
        bootstrap += "Cross-Origin-Resource-Policy: same-origin\r\n"
        bootstrap += "X-Accel-Buffering: no\r\n"
        bootstrap += "\r\n"
        bootstrap += ": connected realtime\n\n"
        bootstrap += framePayload(full: false)

        enqueue(Data(bootstrap.utf8), countsAsEvent: true)
        queue.async { [weak self] in
            self?.startTimer()
        }
        queue.asyncAfter(deadline: .now() + maxDurationSec) { [weak self] in
            self?.close()
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(periodMs),
            repeating: .milliseconds(periodMs),
            leeway: .milliseconds(max(2, periodMs / 5))
        )
        t.setEventHandler { [weak self] in
            self?.onTick()
        }
        t.resume()
        lock.lock()
        timer = t
        lock.unlock()
    }

    private func onTick() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if Date().timeIntervalSince(startedAt) > maxDurationSec {
            lock.unlock()
            close()
            return
        }
        tick += 1
        let full = tick % 10 == 0
        lock.unlock()
        enqueue(Data(framePayload(full: full).utf8), countsAsEvent: true)
    }

    private func enqueue(_ data: Data, countsAsEvent: Bool) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        sendChain.append((data, countsAsEvent))
        let kick = !sending
        if kick { sending = true }
        lock.unlock()
        if kick { drainSendChain() }
    }

    private func drainSendChain() {
        lock.lock()
        if closed {
            sending = false
            sendChain.removeAll()
            lock.unlock()
            return
        }
        guard !sendChain.isEmpty else {
            sending = false
            lock.unlock()
            return
        }
        let (data, counts) = sendChain.removeFirst()
        if counts { eventCount += 1 }
        lock.unlock()

        connection.send(
            content: data,
            contentContext: .defaultStream,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.queue.async { self.close() }
                    return
                }
                self.queue.async { self.drainSendChain() }
            }
        )
    }

    private func framePayload(full: Bool) -> String {
        let frame = telemetry.currentFrame()
        let system = frame.system
        var dict: [String: Any]
        if full {
            dict = frame.asDictionary()
        } else {
            dict = [
                "updated": system.ts,
                "runtime": frame.runtime,
                "system": [
                    "ts": system.ts,
                    "host": system.host,
                    "platform": system.platform,
                    "arch": system.arch,
                    "cpu": system.cpu.asDictionary(),
                    "ram": system.ram.asDictionary(),
                    "disk_io": system.diskIO.asDictionary(),
                    "gpu": system.gpu.map { $0.asDictionary() },
                    "disk": system.disk.map { $0.asDictionary() },
                    "processes": system.processes.prefix(8).map { $0.asDictionary() },
                ] as [String: Any],
                "history": frame.history.suffix(20).map { $0.asDictionary() },
            ]
        }
        dict["stream"] = "realtime"
        dict["sample_hz"] = telemetry.realtimeEngine.measuredSampleHz
        let json = (try? JSONSupport.string(from: dict)) ?? "{}"
        return "event: telemetry\ndata: \(json)\n\n"
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        timer?.cancel()
        timer = nil
        sendChain.removeAll()
        sending = false
        lock.unlock()
        responder?.releaseStream(self)
        connection.send(
            content: nil,
            contentContext: .defaultStream,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            }
        )
    }
}
