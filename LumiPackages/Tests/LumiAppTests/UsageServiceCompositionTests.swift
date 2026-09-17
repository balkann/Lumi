import Foundation
import XCTest
import LumiKit
@testable import LumiAppCore

/// K38-A: üretim grafiğinde her kullanım servisi TTL cache dekoratörüyle
/// sarılır (design/05 §cache "≥5 dk TTL"). Somut dekoratör tipini isimlemek
/// yerine yeteneğine bakılır — dekoratör değişse de sözleşme aynı kalır.
///
/// Karar 55: en küçük otomatik aralık (1 dk) TTL'den kısadır ve bu bir çelişki
/// DEĞİLDİR — döngü `UsageStore.refresh()`'ten geçip cache'i geçersizler.
/// Kilitlenen sözleşme burada "cache boşaltılabilir olmalı"dır.
@MainActor
final class UsageServiceCompositionTests: XCTestCase {
    func testEveryProviderGetsACacheDecoratedUsageService() {
        let registry = LiveServiceRegistry(mode: .development)

        for provider in AgentProvider.allCases {
            let service = registry.usage(for: provider)
            XCTAssertEqual(service.provider, provider)
            XCTAssertTrue(
                service is any UsageCacheInvalidating,
                "\(provider.rawValue) servisi TTL cache ile sarılmamış (K38-A)"
            )
        }
    }

    func testCacheTTLMatchesTheDesignRecord() {
        XCTAssertEqual(LiveServiceRegistry.usageCacheTTL, .seconds(300))
    }

}
