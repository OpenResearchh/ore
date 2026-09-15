import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A file descriptor pinned to the file it referred to when it was recorded.
///
/// Descriptor numbers are reused as soon as they're closed, often by another
/// thread, so "is descriptor 42 open?" says nothing about whether a particular
/// pipe still is. The device and inode do: the same number on a different
/// inode is someone else's file.
struct DescriptorIdentity: Hashable, Sendable {
    let descriptor: Int32
    let device: UInt64
    let inode: UInt64

    init?(_ descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.descriptor = descriptor
        self.device = UInt64(truncatingIfNeeded: info.st_dev)
        self.inode = UInt64(truncatingIfNeeded: info.st_ino)
    }

    /// Whether the descriptor still refers to the file it did when recorded.
    var isStillOpen: Bool {
        DescriptorIdentity(descriptor) == self
    }
}
