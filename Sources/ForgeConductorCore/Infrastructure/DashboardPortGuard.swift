// DashboardPortGuard.swift
// What: Determines whether the configured loopback dashboard port is safely available.
// How: Native socket probes distinguish free, Forge-owned, and foreign listeners before
// ManagerNode attempts to bind or the GUI decides to attach.
// Why: Explicit ownership prevents duplicate listeners and accidental process conflicts.

import Foundation
import Darwin

/// Detects who holds the dashboard TCP port so dual Forge instances cannot silently fight.
public enum DashboardPortGuard {
    public struct Holder: Sendable, Equatable {
        public var pid: Int32?
        public var command: String?
        public var isForge: Bool
        public var detail: String
    }

    public enum PortState: Sendable, Equatable {
        case free
        case heldBySelf
        case heldByOtherForge(Holder)
        case heldByForeign(Holder)
        case unknown(String)
    }

    /// Best-effort: free if nothing listens; classify Forge vs foreign if occupied.
    public static func inspect(host: String, port: Int, selfPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> PortState {
        // Try connect — if nothing accepts, treat as free (may race).
        if !isPortOpen(host: host == "0.0.0.0" ? "127.0.0.1" : host, port: port) {
            // Also check wildcard LISTEN via lsof if available
            if let holders = lsofHolders(port: port), holders.isEmpty {
                return .free
            }
            if let holders = lsofHolders(port: port) {
                return classify(holders: holders, selfPID: selfPID)
            }
            return .free
        }
        if let holders = lsofHolders(port: port) {
            return classify(holders: holders, selfPID: selfPID)
        }
        return .unknown("port \(port) appears open but holder could not be identified")
    }

    private static func classify(holders: [Holder], selfPID: Int32) -> PortState {
        if holders.isEmpty { return .free }
        if holders.contains(where: { $0.pid == selfPID }) {
            return .heldBySelf
        }
        if let forge = holders.first(where: \.isForge) {
            return .heldByOtherForge(forge)
        }
        return .heldByForeign(holders[0])
    }

    private static func isPortOpen(host: String, port: Int) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        guard getaddrinfo(host, portStr, &hints, &result) == 0, let res = result else {
            return false
        }
        defer { freeaddrinfo(res) }
        var open = false
        var ptr: UnsafeMutablePointer<addrinfo>? = res
        while let ai = ptr {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if rc == 0 {
                    open = true
                } else if errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pr = poll(&pfd, 1, 80)
                    if pr > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 { open = true }
                    }
                }
                close(fd)
                if open { break }
            }
            ptr = ai.pointee.ai_next
        }
        return open
    }

    private static func lsofHolders(port: Int) -> [Holder]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -nP -iTCP:PORT -sTCP:LISTEN
        proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }
        var holders: [Holder] = []
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2, let pid = Int32(parts[1]) else { continue }
            let cmd = parts[0]
            let isForge = cmd.localizedCaseInsensitiveContains("Forge")
                || cmd.localizedCaseInsensitiveContains("forge-conductor")
            holders.append(Holder(
                pid: pid,
                command: cmd,
                isForge: isForge,
                detail: String(line)
            ))
        }
        return holders
    }
}
