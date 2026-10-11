//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import Testing

@testable import ContainerImagesService

struct SnapshotCapacityValidationTests {
    @Test func acceptsBoundsAndInteriorValues() throws {
        #expect(try SnapshotStore.validatedSnapshotCapacity(1_073_741_824) == 1_073_741_824)
        #expect(try SnapshotStore.validatedSnapshotCapacity(549_755_813_888) == 549_755_813_888)
        #expect(try SnapshotStore.validatedSnapshotCapacity(10_737_741_824) == 10_737_741_824)
    }

    @Test func rejectsOutOfBounds() {
        #expect(throws: (any Error).self) { try SnapshotStore.validatedSnapshotCapacity(0) }
        #expect(throws: (any Error).self) { try SnapshotStore.validatedSnapshotCapacity(1_073_741_823) }
        #expect(throws: (any Error).self) { try SnapshotStore.validatedSnapshotCapacity(549_755_813_889) }
    }

    @Test func constantsAreOrdered() {
        #expect(SnapshotStore.minimumSnapshotCapacityBytes <= SnapshotStore.defaultSnapshotCapacityBytes)
        #expect(SnapshotStore.defaultSnapshotCapacityBytes <= SnapshotStore.maximumSnapshotCapacityBytes)
        #expect(SnapshotStore.minimumDynamicCapacityBytes <= SnapshotStore.defaultSnapshotCapacityBytes)
    }
}
