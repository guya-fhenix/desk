import DeskCore
import Foundation
import Testing

@Suite struct DeskConfigTests {
    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"githubOrg":"Other","reviewBudgetUSD":2.5}"#
        let config = try JSON.decoder().decode(DeskConfig.self, from: Data(json.utf8))
        #expect(config.githubOrg == "Other")
        #expect(config.reviewBudgetUSD == 2.5)
        #expect(config.repoRoots == DeskConfig().repoRoots)
        #expect(config.reviewRoot == "~/Repos/.reviews")
        #expect(config.cleanupReviewsOnMerge)
    }

    @Test func roundTripsThroughJSON() throws {
        var config = DeskConfig()
        config.claudePath = "/opt/claude"
        config.reviewModel = "opus"
        config.notificationsEnabled = false
        let data = try JSON.encoder().encode(config)
        let decoded = try JSON.decoder().decode(DeskConfig.self, from: data)
        #expect(decoded == config)
    }

}
