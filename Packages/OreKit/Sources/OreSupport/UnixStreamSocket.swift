#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Darwin types `SOCK_STREAM` as `Int32`. Glibc types it as `__socket_type`.
public enum UnixStreamSocket {
    public static func open() -> Int32 {
        #if canImport(Glibc)
        // Glibc's SOCK_STREAM is an enum; SOCK_CLOEXEC is 02000000 and keeps
        // git child processes from inheriting the listen fd.
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | 0o2000000, 0)
        #else
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        if descriptor >= 0 {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        #endif
        return descriptor
    }
}
