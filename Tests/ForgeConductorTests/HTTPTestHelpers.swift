// HTTPTestHelpers.swift
// Supplies synchronous, thread-safe URLSession helpers for dashboard integration tests.
// The locked result box satisfies Swift concurrency checks without weakening assertions.

import Foundation
import XCTest

/// Thread-safe HTTP helpers for XCTest (avoids Swift 6 Sendable closure warnings).
enum HTTPTestHelpers {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var response: URLResponse?
        private var error: Error?

        func set(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            self.data = data
            self.response = response
            self.error = error
            lock.unlock()
        }

        func take() -> (Data?, URLResponse?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (data, response, error)
        }
    }

    static func fetch(
        _ url: URL,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Data, HTTPURLResponse) {
        try fetch(URLRequest(url: url), timeout: timeout, file: file, line: line)
    }

    static func fetch(
        _ request: URLRequest,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (Data, HTTPURLResponse) {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.set(data: data, response: response, error: error)
            sem.signal()
        }.resume()
        let wait = sem.wait(timeout: .now() + timeout)
        XCTAssertEqual(wait, .success, "HTTP timeout for \(request.url?.absoluteString ?? "request")", file: file, line: line)
        let (data, response, error) = box.take()
        if let error { throw error }
        guard let data, let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "HTTPTestHelpers",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing response for \(request.url?.absoluteString ?? "request")"]
            )
        }
        return (data, http)
    }

    static func fetchJSON(
        _ url: URL,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let (data, _) = try fetch(url, timeout: timeout, file: file, line: line)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    static func fetchStatusCode(
        _ url: URL,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let (_, http) = try fetch(url, timeout: timeout, file: file, line: line)
        return http.statusCode
    }
}
