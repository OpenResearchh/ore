#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Darwin types `SOCK_STREAM` as `Int32`. Glibc types it as `__socket_type`.
public enum UnixStreamSocket {
    public static func open() -> Int32 {
        #if canImport(Glibc)
        socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }
}
