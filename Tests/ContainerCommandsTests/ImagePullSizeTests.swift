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

import Foundation
import Testing

@testable import ContainerCommands

struct ImagePullSizeTests {
    @Test func nilSizeReturnsNil() throws {
        #expect(try Application.ImagePull.parseSize(nil) == nil)
    }

    @Test func gibibytesParseToExactBytes() throws {
        #expect(try Application.ImagePull.parseSize("10g") == 10_737_418_240)
        #expect(try Application.ImagePull.parseSize("1g") == 1_073_741_824)
        #expect(try Application.ImagePull.parseSize("512g") == 549_755_813_888)
    }

    @Test func belowMinimumThrows() {
        #expect(throws: (any Error).self) { try Application.ImagePull.parseSize("512m") }
    }

    @Test func aboveMaximumThrows() {
        #expect(throws: (any Error).self) { try Application.ImagePull.parseSize("1t") }
        #expect(throws: (any Error).self) { try Application.ImagePull.parseSize("9999999999999999999g") }
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try Application.ImagePull.parseSize("bogus") }
        #expect(throws: (any Error).self) { try Application.ImagePull.parseSize("") }
    }
}
