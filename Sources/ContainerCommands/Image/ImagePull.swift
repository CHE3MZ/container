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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

extension Application {
    public struct ImagePull: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Pull an image"
        )

        @OptionGroup
        var registry: Flags.Registry

        @OptionGroup
        var progressFlags: Flags.Progress

        @OptionGroup
        var imageFetchFlags: Flags.ImageFetch

        @Option(
            name: .shortAndLong,
            help: "Limit the pull to the specified architecture"
        )
        var arch: String?

        @Option(
            help: "Limit the pull to the specified OS"
        )
        var os: String?

        @Option(
            help: "Limit the pull to the specified platform (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]"
        )
        var platform: String?

        @Option(
            help: "Virtual size of the unpacked snapshot (for example 10g, 1GiB to 512GiB)."
        )
        var size: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument var reference: String

        public init() {}

        public init(platform: String? = nil, scheme: String = "auto", reference: String) {
            self.logOptions = Flags.Logging()
            self.registry = Flags.Registry(scheme: scheme)
            self.platform = platform
            self.reference = reference
        }

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
            let p = try DefaultPlatform.resolve(platform: platform, os: os, arch: arch, log: log)

            let scheme = try RequestScheme(registry.scheme)

            let processedReference = try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig)

            let progressConfig = try self.progressFlags.makeConfig(
                showTasks: true,
                showItems: true,
                ignoreSmallSize: true,
                totalTasks: 2
            )

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            progress.set(description: "Fetching image")
            progress.set(itemsName: "blobs")
            let taskManager = ProgressTaskCoordinator()
            let fetchTask = await taskManager.startTask()
            let image = try await ClientImage.pull(
                reference: processedReference, platform: p, scheme: scheme, containerSystemConfig: containerSystemConfig,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progress.handler),
                maxConcurrentDownloads: self.imageFetchFlags.maxConcurrentDownloads
            )

            progress.set(description: "Unpacking image")
            progress.set(itemsName: "entries")
            let unpackTask = await taskManager.startTask()
            // Client-side early validation; the server re-validates authoritatively
            // at the XPC boundary (SnapshotStore.validatedSnapshotCapacity).
            let snapshotSizeBytes = try Self.parseSize(size)
            try await image.unpack(platform: p, snapshotSizeBytes: snapshotSizeBytes, progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progress.handler))
            await taskManager.finish()
            progress.finish()
        }

        /// Parses a `--size` value (for example `10g`) into bytes, or nil when omitted.
        /// Bounds mirror SnapshotStore.minimum/maximumSnapshotCapacityBytes (1GiB
        /// to 512GiB); the server enforces them authoritatively.
        static func parseSize(_ sizeString: String?) throws -> UInt64? {
            guard let sizeString else {
                return nil
            }
            let bytes = try Measurement.parse(parsing: sizeString).converted(to: .bytes).value
            // Range-check on Double first: converting an out-of-range Double
            // with UInt64() would trap instead of throwing.
            guard bytes >= 1_073_741_824 else {
                throw ContainerizationError(.invalidArgument, message: "snapshot size too small: minimum is 1GiB (got \(sizeString))")
            }
            guard bytes <= 549_755_813_888 else {
                throw ContainerizationError(.invalidArgument, message: "snapshot size too large: maximum is 512GiB (got \(sizeString))")
            }
            return UInt64(bytes)
        }
    }
}
