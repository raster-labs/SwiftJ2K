// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2KJPIP

struct R2CacheRecencyTests {
    @Test func readingAnOlderBinPreservesItUnderEitherCacheLimit() {
        for (bytes, entries) in [(2, 10), (100, 2)] {
            var cache = JPIPCacheModel(maxCacheSize: bytes, maxEntries: entries)
            func bin(_ id: Int) -> JPIPDataBin {
                JPIPDataBin(binClass: .precinct, binID: id, data: Data([UInt8(id)]), isComplete: true)
            }
            cache.addDataBin(bin(1))
            cache.addDataBin(bin(2))
            #expect(cache.getDataBin(binClass: .precinct, binID: 1)?.data == Data([1]))
            cache.addDataBin(bin(3))
            #expect(cache.hasDataBin(binClass: .precinct, binID: 1))
            #expect(!cache.hasDataBin(binClass: .precinct, binID: 2))
            #expect(cache.hasDataBin(binClass: .precinct, binID: 3))
            #expect(cache.statistics.totalSize == 2)
            #expect(cache.statistics.evictions == 1)
            #expect(cache.statistics.hits == 1)
        }
    }
}
