//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import TerminalProgress

public actor SnapshotStore {
    private static let snapshotFileName = "snapshot"
    private static let snapshotInfoFileName = "snapshot-info"
    private static let ingestDirName = "ingest"

    /// Return the Unpacker to use for a given image.
    /// If the given platform for the image cannot be unpacked return `nil`.
    public typealias UnpackStrategy = @Sendable (Containerization.Image, Platform) async throws -> Unpacker?

    /// Default virtual capacity for unpacked image snapshots.
    ///
    /// Used as the fallback when the image content size cannot be determined.
    /// Snapshots are APFS sparse files, so this is the size the filesystem can
    /// grow to rather than the space it occupies on disk. It must comfortably
    /// cover both the unpacked image content and later runtime writes, since the
    /// snapshot is cloned as the container's writable root filesystem and there
    /// is no post-mount grow path. Kept moderate (was 512 GiB) so Finder and
    /// Time Machine report sane logical sizes.
    public static let defaultSnapshotCapacityBytes: UInt64 = 128.gib()

    /// Floor for dynamically computed snapshot capacities.
    ///
    /// Even tiny images get this much virtual capacity so normal runtime writes
    /// (logs, caches, package installs) into the cloned root filesystem can
    /// never hit ENOSPC.
    public static let minimumDynamicCapacityBytes: UInt64 = 4.gib()

    /// Headroom added on top of the estimated unpacked content size.
    public static let dynamicCapacityHeadroomBytes: UInt64 = 1.gib()

    /// Assumed worst-case compression ratio when estimating unpacked layer size
    /// from compressed layer sizes. Deliberately pessimistic: overestimating
    /// only costs virtual address space in a sparse file.
    private static let maxCompressionRatio: UInt64 = 4

    /// Estimates a snapshot capacity from the image manifest.
    ///
    /// Returns a value within [minimumDynamicCapacityBytes,
    /// maximumSnapshotCapacityBytes], so the result never provisions more than
    /// the historic default. Falls back to the default when the manifest or
    /// layer sizes cannot be read: sizing must never fail an unpack. Layer
    /// sizes come from the registry and are therefore untrusted, which is
    /// exactly why the result is clamped instead of used directly.
    static func estimatedCapacity(image: Containerization.Image, platform: Platform) async -> UInt64 {
        do {
            let manifest = try await image.manifest(for: platform)
            var compressed: UInt64 = 0
            for layer in manifest.layers {
                guard layer.size >= 0 else {
                    return defaultSnapshotCapacityBytes
                }
                let (partial, overflow) = compressed.addingReportingOverflow(UInt64(layer.size))
                guard !overflow else {
                    return maximumSnapshotCapacityBytes
                }
                compressed = partial
            }
            let (scaled, overflow) = compressed.multipliedReportingOverflow(by: maxCompressionRatio)
            guard !overflow else {
                return maximumSnapshotCapacityBytes
            }
            let (total, overflow2) = scaled.addingReportingOverflow(dynamicCapacityHeadroomBytes)
            guard !overflow2 else {
                return maximumSnapshotCapacityBytes
            }
            return min(max(total, minimumDynamicCapacityBytes), maximumSnapshotCapacityBytes)
        } catch {
            return defaultSnapshotCapacityBytes
        }
    }

    /// Minimum virtual capacity accepted for an image snapshot.
    ///
    /// Snapshots double as the container's writable root filesystem with no
    /// post-mount grow path, so capacities below this floor risk ENOSPC during
    /// normal runtime writes.
    public static let minimumSnapshotCapacityBytes: UInt64 = 1.gib()

    /// Maximum virtual capacity accepted for an image snapshot.
    ///
    /// Matches the historic default, which is the largest capacity this
    /// codebase has ever provisioned. Requests above it are rejected instead of
    /// risking block-count overflow in the ext4 formatter.
    public static let maximumSnapshotCapacityBytes: UInt64 = 512.gib()

    /// Validates an explicitly requested snapshot capacity.
    public static func validatedSnapshotCapacity(_ bytes: UInt64) throws -> UInt64 {
        guard bytes >= minimumSnapshotCapacityBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "snapshot size too small: minimum is 1GiB (got \(bytes) bytes)"
            )
        }
        guard bytes <= maximumSnapshotCapacityBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "snapshot size too large: maximum is 512GiB (got \(bytes) bytes)"
            )
        }
        return bytes
    }

    public static func defaultUnpackStrategy(initImage: String) -> UnpackStrategy {
        { image, platform in
            guard platform.os == "linux" else {
                return nil
            }
            let capacityInBytes: UInt64
            if image.reference == initImage {
                capacityInBytes = 512.mib()
            } else {
                // Measured capacity with a safe fallback: tiny images (alpine)
                // get a few GiB instead of hundreds, while the fallback and the
                // maximum cap preserve the old guarantees for anything unusual.
                capacityInBytes = await Self.estimatedCapacity(image: image, platform: platform)
            }
            return EXT4Unpacker(capacityInBytes: capacityInBytes, journal: .init(defaultMode: .ordered))
        }
    }

    let path: URL
    let fm = FileManager.default
    let ingestDir: URL
    let unpackStrategy: UnpackStrategy
    let log: Logger?

    public init(path: URL, unpackStrategy: @escaping UnpackStrategy, log: Logger?) throws {
        let root = path.appendingPathComponent("snapshots")
        self.path = root
        self.ingestDir = self.path.appendingPathComponent(Self.ingestDirName)
        self.unpackStrategy = unpackStrategy
        self.log = log
        try self.fm.createDirectory(at: root, withIntermediateDirectories: true)
        try self.fm.createDirectory(at: self.ingestDir, withIntermediateDirectories: true)
    }

    public func unpack(image: Containerization.Image, platform: Platform? = nil, snapshotSizeBytes: UInt64? = nil, progressUpdate: ProgressUpdateHandler?) async throws {
        // An explicitly requested capacity overrides the unpack strategy.
        // Validated here (server side, authoritative) so no caller can provision
        // outside the [minimum, maximum] range, regardless of transport.
        let requestedCapacity = try snapshotSizeBytes.map(Self.validatedSnapshotCapacity)
        var toUnpack: [Descriptor] = []
        if let platform {
            let desc = try await image.descriptor(for: platform)
            toUnpack = [desc]
        } else {
            toUnpack = try await image.unpackableDescriptors()
        }

        let taskManager = ProgressTaskCoordinator()
        var taskUpdateProgress: ProgressUpdateHandler?

        for desc in toUnpack {
            try Task.checkCancellation()
            let snapshotDir = try self.snapshotDir(desc)
            guard !self.fm.fileExists(atPath: snapshotDir.absolutePath()) else {
                // We have already unpacked this image + platform. Skip
                continue
            }
            guard let platform = desc.platform else {
                throw ContainerizationError(.internalError, message: "missing platform for descriptor \(desc.digest)")
            }
            guard var unpacker = try await self.unpackStrategy(image, platform) else {
                self.log?.warning("no unpacker configured, skipping unpack for \(image.reference) for platform \(platform.description)")
                continue
            }
            if let requestedCapacity {
                // Explicit user request wins over the strategy default. The journal
                // matches the default strategy so behavior is identical apart from size.
                unpacker = EXT4Unpacker(capacityInBytes: requestedCapacity, journal: .init(defaultMode: .ordered))
            }
            let currentSubTask = await taskManager.startTask()
            if let progressUpdate {
                let _taskUpdateProgress = ProgressTaskCoordinator.handler(for: currentSubTask, from: progressUpdate)
                await _taskUpdateProgress([
                    .setSubDescription("for platform \(platform.description)")
                ])
                taskUpdateProgress = _taskUpdateProgress
            }

            let tempDir = try self.tempUnpackDir()

            let tempSnapshotPath = tempDir.appendingPathComponent(Self.snapshotFileName, isDirectory: false)
            let infoPath = tempDir.appendingPathComponent(Self.snapshotInfoFileName, isDirectory: false)
            do {
                let progress = ContainerizationProgressAdapter.handler(from: taskUpdateProgress)
                let mount = try await unpacker.unpack(image, for: platform, at: tempSnapshotPath, progress: progress)
                let fs = Filesystem.block(
                    format: mount.type,
                    source: try self.snapshotPath(desc).absolutePath(),
                    destination: mount.destination,
                    options: mount.options
                )
                let snapshotInfo = try JSONEncoder().encode(fs)
                self.fm.createFile(atPath: infoPath.absolutePath(), contents: snapshotInfo)
            } catch {
                try? self.fm.removeItem(at: tempDir)
                throw error
            }
            do {
                try fm.moveItem(at: tempDir, to: snapshotDir)
            } catch let err as NSError {
                guard err.code == NSFileWriteFileExistsError else {
                    throw err
                }
                try? self.fm.removeItem(at: tempDir)
            }
        }
        await taskManager.finish()
    }

    public func delete(for image: Containerization.Image, platform: Platform? = nil) async throws {
        var toDelete: [Descriptor] = []
        if let platform {
            let desc = try await image.descriptor(for: platform)
            toDelete.append(desc)
        } else {
            toDelete = try await image.unpackableDescriptors()
        }
        for desc in toDelete {
            let p = try self.snapshotDir(desc)
            guard self.fm.fileExists(atPath: p.absolutePath()) else {
                continue
            }
            try self.fm.removeItem(at: p)
        }
    }

    public func get(for image: Containerization.Image, platform: Platform) async throws -> Filesystem {
        let desc = try await image.descriptor(for: platform)
        let infoPath = try snapshotInfoPath(desc)
        let fsPath = try snapshotPath(desc)

        guard self.fm.fileExists(atPath: infoPath.absolutePath()),
            self.fm.fileExists(atPath: fsPath.absolutePath())
        else {
            throw ContainerizationError(.notFound, message: "image snapshot for \(image.reference) with platform \(platform.description)")
        }
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: infoPath)
        let fs = try decoder.decode(Filesystem.self, from: data)
        return fs
    }

    public func clean(keepingSnapshotsFor images: [Containerization.Image] = []) async throws -> UInt64 {
        var toKeep: [String] = [Self.ingestDirName]
        for image in images {
            for manifest in try await image.index().manifests {
                guard let platform = manifest.platform else {
                    continue
                }
                let desc = try await image.descriptor(for: platform)
                toKeep.append(try desc.digest.validatedDigestEncoding())
            }
        }
        let all = try self.fm.contentsOfDirectory(at: self.path, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]).map {
            $0.lastPathComponent
        }
        let delete = Set(all).subtracting(Set(toKeep))
        var deletedBytes: UInt64 = 0
        for dir in delete {
            let unpackedPath = self.path.appending(path: dir, directoryHint: .isDirectory)
            guard self.fm.fileExists(atPath: unpackedPath.absolutePath()) else {
                continue
            }
            deletedBytes += self.fm.allocatedSize(of: unpackedPath)
            try self.fm.removeItem(at: unpackedPath)
        }
        return deletedBytes
    }

    private func snapshotDir(_ desc: Descriptor) throws -> URL {
        let p = self.path.appendingPathComponent(try desc.digest.validatedDigestEncoding(), isDirectory: true)
        return p
    }

    private func snapshotPath(_ desc: Descriptor) throws -> URL {
        let p = try self.snapshotDir(desc)
            .appendingPathComponent(Self.snapshotFileName, isDirectory: false)
        return p
    }

    private func snapshotInfoPath(_ desc: Descriptor) throws -> URL {
        let p = try self.snapshotDir(desc)
            .appendingPathComponent(Self.snapshotInfoFileName, isDirectory: false)
        return p
    }

    private func tempUnpackDir() throws -> URL {
        let uniqueDirectoryURL = ingestDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try self.fm.createDirectory(at: uniqueDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        return uniqueDirectoryURL
    }

    /// Get the disk size for a specific snapshot descriptor
    public func getSnapshotSize(descriptor: Descriptor) throws -> UInt64 {
        let snapshotPath = try self.snapshotDir(descriptor)
        guard self.fm.fileExists(atPath: snapshotPath.path) else {
            return 0
        }
        return self.fm.allocatedSize(of: snapshotPath)
    }

    /// Returns (trimmed digest, size) pairs for every unpackable snapshot owned by the image.
    public func getSnapshotSizes(for image: Containerization.Image) async throws -> [(digest: String, size: UInt64)] {
        var results: [(digest: String, size: UInt64)] = []
        for descriptor in try await image.unpackableDescriptors() {
            let size = try self.getSnapshotSize(descriptor: descriptor)
            guard size > 0 else { continue }
            results.append((try descriptor.digest.validatedDigestEncoding(), size))
        }
        return results
    }

    /// Total allocated bytes across all snapshot storage (including orphans).
    public func totalAllocatedSize() -> UInt64 {
        self.fm.allocatedSize(of: self.path)
    }
}

extension Containerization.Image {
    fileprivate func unpackableDescriptors() async throws -> [Descriptor] {
        let index = try await self.index()
        return index.manifests.filter { desc in
            guard desc.platform != nil else {
                return false
            }
            if let referenceType = desc.annotations?["vnd.docker.reference.type"], referenceType == "attestation-manifest" {
                return false
            }
            return true
        }
    }
}
