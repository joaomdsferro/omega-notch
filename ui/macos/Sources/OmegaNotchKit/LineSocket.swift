import Darwin
import Foundation

/// A Unix socket carrying newline-delimited messages. Lines arrive on the
/// main queue; a closed or failed connection is reported once, through
/// `onClose`.
public final class LineSocket {
  public var onLine: ((Data) -> Void)?
  public var onClose: (() -> Void)?

  private let fd: Int32
  private let source: DispatchSourceRead
  private var buffer = Data()
  private var closed = false

  /// Connects to `path`, or returns nil when nothing listens there.
  public init?(path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard path.utf8.count < capacity else {
      Darwin.close(fd)
      return nil
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
      bytes.copyBytes(from: path.utf8)
      bytes[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      Darwin.close(fd)
      return nil
    }
    // A write to a peer that just went away must fail, not kill the app.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    self.fd = fd
    self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in self?.readAvailable() }
    source.setCancelHandler { Darwin.close(fd) }
    source.resume()
  }

  deinit {
    close()
  }

  public func send(_ line: Data) {
    guard !closed else { return }
    var payload = line
    payload.append(0x0A)
    let ok = payload.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += n
      }
      return true
    }
    if !ok { fail() }
  }

  public func close() {
    guard !closed else { return }
    closed = true
    source.cancel()
  }

  private func readAvailable() {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    let n = Darwin.read(fd, &chunk, chunk.count)
    guard n > 0 else {
      if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
      fail()
      return
    }
    buffer.append(contentsOf: chunk[0..<n])
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer.removeSubrange(buffer.startIndex...newline)
      if !line.isEmpty { onLine?(Data(line)) }
    }
  }

  private func fail() {
    guard !closed else { return }
    close()
    onClose?()
  }
}
