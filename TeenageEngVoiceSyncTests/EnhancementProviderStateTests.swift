//
//  EnhancementProviderStateTests.swift
//  TeenageEngVoiceSyncTests
//

import XCTest
@testable import TP_7_VoiceSync

final class EnhancementProviderStateTests: XCTestCase {
    func testConfiguringInactiveProviderPreservesActiveProviderModels() {
        var state = EnhancementProviderState(configuredProvider: .openRouter)
        let openRouterModel = model(id: "openrouter/model")

        state.update(.openRouter) {
            $0.apiKey = "openrouter-key"
            $0.models = [openRouterModel]
            $0.status = .valid(1)
        }

        state.configure(.custom)

        XCTAssertEqual(state.configuredProvider, .custom)
        XCTAssertEqual(state.configuration(for: .openRouter).models.map(\.id), [openRouterModel.id])
        XCTAssertEqual(state.configuration(for: .openRouter).apiKey, "openrouter-key")
        XCTAssertEqual(state.configuration(for: .openRouter).status, .valid(1))
        XCTAssertTrue(state.configuration(for: .custom).models.isEmpty)
    }

    func testProviderModelsCredentialsAndErrorsAreCachedIndependently() {
        var state = EnhancementProviderState()

        state.update(.openRouter) {
            $0.apiKey = "openrouter-key"
            $0.models = [model(id: "openrouter/model")]
            $0.status = .valid(1)
        }
        state.update(.custom) {
            $0.apiKey = "custom-key"
            $0.models = [model(id: "custom/model")]
            $0.modelLoadError = "Custom provider error"
            $0.status = .error("Custom provider error")
        }

        XCTAssertEqual(state.configuration(for: .openRouter).models.map(\.id), ["openrouter/model"])
        XCTAssertNil(state.configuration(for: .openRouter).modelLoadError)
        XCTAssertEqual(state.configuration(for: .custom).models.map(\.id), ["custom/model"])
        XCTAssertEqual(state.configuration(for: .custom).apiKey, "custom-key")
        XCTAssertEqual(state.configuration(for: .custom).modelLoadError, "Custom provider error")
    }

    private func model(id: String) -> OpenRouterModel {
        OpenRouterModel(
            id: id,
            name: id,
            description: "",
            contextLength: 8_192,
            promptPrice: "0",
            completionPrice: "0"
        )
    }
}
