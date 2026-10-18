#if os(macOS)
import Darwin
import Foundation

/// An advisory lock retained for the app's lifetime. The kernel releases it even after a crash;
/// the file is never unlinked, which would let another process lock a different inode.
public final class SingleInstanceLock {
    private let descriptor: Int32

    /// Returns nil when another process owns the lock, and throws for filesystem errors.
    public init?(url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
#endif
