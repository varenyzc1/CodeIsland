import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateFeishuBridgeTests: XCTestCase {

    func testApprovePendingPermissionForSourceTargetsMatchingSource() async throws {
        let appState = AppState()

        let claudeEvent = try makePermissionRequestEvent(sessionId: "claude-session", source: "claude")
        let codexEvent = try makePermissionRequestEvent(sessionId: "codex-session", source: "codex")

        let claudeTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(claudeEvent, continuation: continuation)
            }
        }
        let codexTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(codexEvent, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 2)

        let result = appState.approvePendingPermission(forSource: "codex")
        XCTAssertEqual(result, "已批准：codex-session")

        let codexResponse = await codexTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: codexResponse), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.event.sessionId, "claude-session")

        appState.denyPermission()
        let claudeResponse = await claudeTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: claudeResponse), "deny")
    }

    func testAnswerPendingQuestionForSourceTargetsMatchingSource() async throws {
        let appState = AppState()

        let claudeEvent = try makeAskUserQuestionEvent(sessionId: "claude-session", source: "claude")
        let codexEvent = try makeAskUserQuestionEvent(sessionId: "codex-session", source: "codex")

        let claudeTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(claudeEvent, continuation: continuation)
            }
        }
        let codexTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(codexEvent, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 2)

        let result = appState.answerPendingQuestion(forSource: "codex", answer: "中文")
        XCTAssertEqual(result, "已回复：codex-session")

        let codexResponse = await codexTask.value
        let answers = try extractAnswers(from: codexResponse)
        XCTAssertEqual(answers["语言"] as? String, "中文")
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.questionQueue.first?.event.sessionId, "claude-session")

        appState.skipQuestion()
        _ = await claudeTask.value
    }

    private func makePermissionRequestEvent(sessionId: String, source: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "_source": source,
            "tool_name": "Bash",
            "tool_input": [
                "command": "echo test",
                "description": "approval"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func makeAskUserQuestionEvent(sessionId: String, source: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "_source": source,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "header": "语言",
                    "question": "使用哪种语言？",
                    "options": [
                        ["label": "中文", "description": ""],
                        ["label": "英文", "description": ""]
                    ]
                ]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    private func extractAnswers(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        return try XCTUnwrap(updatedInput["answers"] as? [String: Any])
    }
}
