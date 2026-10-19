import DeskCore
import Foundation
import Testing

@Suite struct DeskConfigTests {
    /// A config.json from before a setting went away still loads: the key it names is ignored.
    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"githubOrg":"Other","reviewTimeoutMinutes":45,"reviewBudgetUSD":2.5,"stalePullRequestDays":3}"#
        let config = try JSON.decoder().decode(DeskConfig.self, from: Data(json.utf8))
        #expect(config.githubOrg == "Other")
        #expect(config.reviewTimeoutMinutes == 45)
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
