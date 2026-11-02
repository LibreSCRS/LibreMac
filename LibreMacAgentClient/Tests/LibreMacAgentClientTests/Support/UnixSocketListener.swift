// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 hirashix0

import Darwin
import Foundation

/// A listening AF_UNIX socket bound at `s` inside a fresh private temporary
/// directory, for tests that reach a client through a socket path. The fd,
/// the socket file and the directory all go when the listener is released.
final class UnixSocketListener: Sendable {
    let path: String
    private let directory: String
    private let fd: Int32

    /// `prefix` names the directory (`<prefix>.XXXXXX`), so one left behind
    /// by a killed test run says which suite made it.
    init(prefix: String, backlog: Int32) throws {
        let pattern = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix).XXXXXX")
        var template = Array(pattern.utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        let directory = String(cString: made)
        let path = directory + "/s"
        let listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            rmdir(directory)
            throw POSIXError(code)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFd, backlog) == 0 else {
            Darwin.close(listenFd)
            unlink(path)
            rmdir(directory)
            throw POSIXError(.EIO)
        }
        // Non-blocking, so a connection that went away between poll and
        // accept cannot park the waiting thread in accept.
        _ = fcntl(listenFd, F_SETFL, fcntl(listenFd, F_GETFL, 0) | O_NONBLOCK)
        self.path = path
        self.directory = directory
        self.fd = listenFd
    }

    deinit {
        Darwin.close(fd)
        unlink(path)
        rmdir(directory)
    }

    /// Waits up to `timeout` for one connection and returns its fd, in
    /// blocking mode; nil when nobody connected in time, or once
    /// `stillWanted` answers false. The wait goes in short slices, so a
    /// caller that no longer needs the connection ends it within one.
    func acceptConnection(within timeout: TimeInterval, while stillWanted: () -> Bool = { true }) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while stillWanted() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, Int32(max(1, min(remaining, 0.05) * 1000)))
            if polled < 0, errno != EINTR { return nil }
            guard polled > 0 else { continue }
            let conn = Darwin.accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL, 0) & ~O_NONBLOCK)
            return conn
        }
        return nil
    }
}
