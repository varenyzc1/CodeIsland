import Foundation
import os.log
import CodeIslandCore

private let feishuLog = Logger(subsystem: "com.codeisland", category: "FeishuBridge")
private let feishuDebugLogPath = "/tmp/codeisland-feishu.log"

private func appendFeishuDebugLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    let data = Data(line.utf8)
    if let handle = FileHandle(forWritingAtPath: feishuDebugLogPath) {
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: feishuDebugLogPath, contents: data)
    }
}

struct FeishuBotConfig: Codable, Equatable, Identifiable {
    var source: String
    var enabled: Bool
    var appID: String
    var appSecret: String
    var bindingKey: String
    var boundChatID: String

    init(source: String, enabled: Bool, appID: String, appSecret: String, bindingKey: String, boundChatID: String) {
        self.source = source
        self.enabled = enabled
        self.appID = appID
        self.appSecret = appSecret
        self.bindingKey = bindingKey
        self.boundChatID = boundChatID
    }

    var id: String { source }

    var normalizedSource: String {
        SessionSnapshot.normalizedSupportedSource(source) ?? source
    }

    var isConnectable: Bool {
        enabled
        && !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBound: Bool {
        Self.looksLikeChatID(boundChatID)
    }

    var effectiveBindingKey: String {
        let trimmed = bindingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.makeBindingKey(source: normalizedSource) : trimmed
    }

    static func makeBindingKey(source: String) -> String {
        let normalized = SessionSnapshot.normalizedSupportedSource(source) ?? source
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "codeisland-\(normalized)-\(suffix)"
    }

    static func looksLikeChatID(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("oc_")
    }

    static func empty(source: String) -> FeishuBotConfig {
        FeishuBotConfig(
            source: source,
            enabled: false,
            appID: "",
            appSecret: "",
            bindingKey: Self.makeBindingKey(source: source),
            boundChatID: ""
        )
    }

    enum CodingKeys: String, CodingKey {
        case source
        case enabled
        case appID
        case appSecret
        case bindingKey
        case boundChatID
        case chatID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
        appSecret = try container.decodeIfPresent(String.self, forKey: .appSecret) ?? ""
        bindingKey = try container.decodeIfPresent(String.self, forKey: .bindingKey)
            ?? Self.makeBindingKey(source: source)
        boundChatID = try container.decodeIfPresent(String.self, forKey: .boundChatID)
            ?? container.decodeIfPresent(String.self, forKey: .chatID)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(appID, forKey: .appID)
        try container.encode(appSecret, forKey: .appSecret)
        try container.encode(effectiveBindingKey, forKey: .bindingKey)
        try container.encode(boundChatID, forKey: .boundChatID)
    }
}

enum FeishuSettingsStore {
    static let key = "feishu_bot_configs_v1"
    static let configFilePath = NSHomeDirectory() + "/.codeisland/feishu-bots.json"
    static var configFileURL: URL { URL(fileURLWithPath: configFilePath) }

    static func load() -> [String: FeishuBotConfig] {
        let data = UserDefaults.standard.data(forKey: key)
            ?? FileManager.default.contents(atPath: configFilePath)
        guard let data,
              let items = try? JSONDecoder().decode([FeishuBotConfig].self, from: data) else { return [:] }
        var result: [String: FeishuBotConfig] = [:]
        for item in items {
            let source = SessionSnapshot.normalizedSupportedSource(item.source) ?? item.source
        result[source] = FeishuBotConfig(
            source: source,
            enabled: item.enabled,
            appID: item.appID,
            appSecret: item.appSecret,
            bindingKey: item.bindingKey.trimmingCharacters(in: .whitespacesAndNewlines),
            boundChatID: Self.sanitizedChatID(item.boundChatID)
        )
        }
        return result
    }

    private static func sanitizedChatID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeishuBotConfig.looksLikeChatID(trimmed) ? trimmed : ""
    }

    static func save(_ configs: [String: FeishuBotConfig]) {
        let items = configs.values
            .sorted { $0.normalizedSource < $1.normalizedSource }
            .map { config in
                FeishuBotConfig(
                    source: config.normalizedSource,
                    enabled: config.enabled,
                    appID: config.appID.trimmingCharacters(in: .whitespacesAndNewlines),
                    appSecret: config.appSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                    bindingKey: config.effectiveBindingKey,
                    boundChatID: sanitizedChatID(config.boundChatID)
                )
            }
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
        saveConfigFile(data)
    }

    private static func saveConfigFile(_ data: Data) {
        let dir = (configFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: configFileURL, options: .atomic)
    }
}

struct FeishuIncomingMessage {
    let source: String
    let chatID: String
    let messageID: String
    let text: String
}

struct FeishuIncomingAction {
    let source: String
    let chatID: String?
    let messageID: String?
    let action: String
    let answer: String?
    let rawValue: [String: Any]
}

private struct FeishuPostBuilder {
    static func content(title: String, markdown: String) -> String {
        let body: [String: Any] = [
            "zh_cn": [
                "title": title,
                "content": lines(from: markdown)
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"zh_cn":{"title":"CodeIsland","content":[[{"tag":"text","text":"invalid"}]]}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func lines(from markdown: String) -> [[[String: Any]]] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")
        var result: [[[String: Any]]] = []
        var inCodeBlock = false

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    result.append([text("└────────────────")])
                } else {
                    result.append([text("┌─ Code")])
                }
                inCodeBlock.toggle()
                continue
            }
            if trimmed.isEmpty {
                result.append([text(" ")])
                continue
            }
            if inCodeBlock {
                result.append([text("│ " + rawLine)])
                continue
            }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" || $0 == " " }
                result.append([text("▌ " + String(heading))])
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let content = String(trimmed.dropFirst(2))
                result.append(parseInline("• " + content))
                continue
            }
            result.append(parseInline(rawLine))
        }

        return result.isEmpty ? [[text(" ")]] : result
    }

    private static func parseInline(_ line: String) -> [[String: Any]] {
        var items: [[String: Any]] = []
        let nsLine = line as NSString
        let pattern = #"\[([^\]]+)\]\((https?://[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text(line)]
        }

        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        if matches.isEmpty {
            return [text(line)]
        }

        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                items.append(text(nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            if match.numberOfRanges >= 3 {
                let label = nsLine.substring(with: match.range(at: 1))
                let href = nsLine.substring(with: match.range(at: 2))
                items.append(link(label, href: href))
            } else {
                items.append(text(nsLine.substring(with: match.range)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsLine.length {
            items.append(text(nsLine.substring(with: NSRange(location: cursor, length: nsLine.length - cursor))))
        }
        return items.isEmpty ? [text(line)] : items
    }

    private static func text(_ value: String) -> [String: Any] {
        [
            "tag": "text",
            "text": value
        ]
    }

    private static func link(_ text: String, href: String) -> [String: Any] {
        [
            "tag": "a",
            "text": text,
            "href": href
        ]
    }
}

private enum FeishuCardTemplate: String {
    case blue
    case wathet
    case turquoise
    case green
    case yellow
    case orange
    case red
    case purple
    case grey
}

private struct FeishuCardBuilder {
    static func replyCard(title: String, message: String, template: FeishuCardTemplate = .green) -> String {
        content(
            title: title,
            template: template,
            elements: renderMessageElements(message)
        )
    }

    static func assistantReplyCard(sourceLabel: String, sessionTitle: String, folder: String?, message: String) -> String {
        content(
            title: "✅ \(sourceLabel) 回复完成",
            template: .green,
            elements: [
                markdown("""
                **\(sourceLabel)** 已完成一轮回复

                **会话：** \(sessionTitle)
                **文件夹：** \(folder ?? "未知")
                """)
            ] + [markdown("**AI 回复**")] + renderMessageElements(message)
        )
    }

    static func approvalCard(sourceLabel: String, sessionTitle: String, folder: String?, toolName: String, detail: String) -> String {
        content(
            title: "⚠️ CodeIsland · 待确认",
            template: .orange,
            elements: [
                markdown("""
                **\(sourceLabel)** 正在等待权限确认

                **会话：** \(sessionTitle)
                **文件夹：** \(folder ?? "未知")
                **工具：** \(toolName)
                """),
                markdown("""
                **请求内容**
                \(detail)
                """),
                actions([
                    button("Approve", type: "primary", value: ["ci_action": "approve"]),
                    button("Deny", type: "danger", value: ["ci_action": "deny"]),
                    button("Status", type: "default", value: ["ci_action": "status"]),
                ]),
                note("也可以直接回复 approve / deny / status。")
            ]
        )
    }

    static func questionCard(sourceLabel: String, sessionTitle: String, folder: String?, question: String, options: [String]?) -> String {
        var elements: [[String: Any]] = [
            markdown("""
            **\(sourceLabel)** 需要你回答

            **会话：** \(sessionTitle)
            **文件夹：** \(folder ?? "未知")
            """),
            markdown("""
            **问题**
            \(question)
            """)
        ]

        if let options, !options.isEmpty {
            let buttons = options.prefix(6).map { option in
                button(option, type: "primary", value: ["ci_action": "reply", "answer": option])
            }
            elements.append(actions(Array(buttons)))
        } else {
            elements.append(note("请直接回复：reply 你的答案"))
        }

        elements.append(note("也可以继续使用文字命令回复。"))
        return content(title: "❓ CodeIsland · 待回复", template: .blue, elements: elements)
    }

    static func readyCard(sourceName: String) -> String {
        content(
            title: "🟢 CodeIsland 已连接",
            template: .green,
            elements: [
                markdown("""
                **\(sourceName) 机器人已就绪**

                之后这里会收到：
                - AI 回复
                - 权限确认请求
                - 提问请求
                """),
                markdown("""
                **可用指令**
                - `status`
                - `approve`
                - `deny`
                - `reply 你的答案`
                - `run: 你的任务`
                """),
                actions([
                    button("Status", type: "default", value: ["ci_action": "status"])
                ])
            ]
        )
    }

    private static func content(title: String, template: FeishuCardTemplate, elements: [[String: Any]]) -> String {
        let card: [String: Any] = [
            "config": [
                "wide_screen_mode": true,
                "update_multi": false
            ],
            "header": [
                "template": template.rawValue,
                "title": [
                    "tag": "plain_text",
                    "content": title
                ]
            ],
            "elements": elements
        ]
        let data = (try? JSONSerialization.data(withJSONObject: card)) ?? Data(#"{"config":{"wide_screen_mode":true},"elements":[]}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func markdown(_ content: String) -> [String: Any] {
        [
            "tag": "div",
            "text": [
                "tag": "lark_md",
                "content": normalizeLarkMarkdown(content)
            ]
        ]
    }

    private static func plainText(_ content: String) -> [String: Any] {
        [
            "tag": "div",
            "text": [
                "tag": "plain_text",
                "content": content
            ]
        ]
    }

    private static func renderMessageElements(_ content: String) -> [[String: Any]] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var elements: [[String: Any]] = []
        var markdownLines: [String] = []
        var codeLines: [String] = []
        var inCodeBlock = false

        func flushMarkdown() {
            let text = markdownLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                markdownLines.removeAll()
                return
            }
            elements.append(markdown(text))
            markdownLines.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            elements.append(plainText(codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                } else {
                    flushMarkdown()
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            markdownLines.append(normalizeMarkdownLine(rawLine))
        }

        if inCodeBlock {
            flushCode()
        } else {
            flushMarkdown()
        }

        return elements.isEmpty ? [markdown(content)] : elements
    }

    private static func normalizeLarkMarkdown(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(normalizeMarkdownLine)
            .joined(separator: "\n")
    }

    private static func normalizeMarkdownLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }

        if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
            let title = trimmed.drop { $0 == "#" || $0 == " " }
            return "**\(title)**"
        }

        let indentCount = line.prefix { $0 == " " || $0 == "\t" }.count
        let indentPrefix = String(repeating: "  ", count: indentCount / 2)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return indentPrefix + "• " + normalizeInlineMarkdown(String(trimmed.dropFirst(2)))
        }

        if let ordered = normalizeOrderedList(trimmed) {
            return indentPrefix + ordered
        }

        return indentPrefix + normalizeInlineMarkdown(trimmed)
    }

    private static func normalizeOrderedList(_ line: String) -> String? {
        let pattern = #"^(\d+)\.\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 3 else { return nil }
        let index = nsLine.substring(with: match.range(at: 1))
        let content = nsLine.substring(with: match.range(at: 2))
        return "\(index). \(normalizeInlineMarkdown(content))"
    }

    private static func normalizeInlineMarkdown(_ line: String) -> String {
        let nsLine = line as NSString
        let pattern = #"`([^`]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else { return line }

        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            if match.numberOfRanges > 1 {
                let code = nsLine.substring(with: match.range(at: 1))
                result += "**\(code)**"
            } else {
                result += nsLine.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < nsLine.length {
            result += nsLine.substring(with: NSRange(location: cursor, length: nsLine.length - cursor))
        }
        return result
    }

    private static func note(_ content: String) -> [String: Any] {
        [
            "tag": "note",
            "elements": [[
                "tag": "plain_text",
                "content": content
            ]]
        ]
    }

    private static func actions(_ buttons: [[String: Any]]) -> [String: Any] {
        [
            "tag": "action",
            "actions": buttons
        ]
    }

    private static func button(_ text: String, type: String, value: [String: Any]) -> [String: Any] {
        [
            "tag": "button",
            "text": [
                "tag": "plain_text",
                "content": text
            ],
            "type": type,
            "value": value
        ]
    }
}

private struct FeishuEndpointEnvelope: Decodable {
    struct DataPayload: Decodable {
        let url: String
        let clientConfig: FeishuClientConfig?

        enum CodingKeys: String, CodingKey {
            case url = "URL"
            case clientConfig = "ClientConfig"
        }
    }

    let code: Int
    let msg: String
    let data: DataPayload?
}

private struct FeishuClientConfig: Decodable {
    let reconnectCount: Int?
    let reconnectInterval: Int?
    let reconnectNonce: Int?
    let pingInterval: Int?

    enum CodingKeys: String, CodingKey {
        case reconnectCount = "ReconnectCount"
        case reconnectInterval = "ReconnectInterval"
        case reconnectNonce = "ReconnectNonce"
        case pingInterval = "PingInterval"
    }
}

private struct FeishuTokenEnvelope: Decodable {
    let code: Int
    let msg: String
    let tenantAccessToken: String?
    let expire: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case msg
        case tenantAccessToken = "tenant_access_token"
        case expire
    }
}

private struct FeishuFragmentBuffer {
    var parts: [Int: Data] = [:]
    let total: Int

    mutating func append(seq: Int, data: Data) -> Data? {
        parts[seq] = data
        guard parts.count == total else { return nil }
        var result = Data()
        for index in 0..<total {
            guard let part = parts[index] else { return nil }
            result.append(part)
        }
        return result
    }
}

@MainActor
final class FeishuBridgeManager: ObservableObject {
    static let shared = FeishuBridgeManager()

    @Published private(set) var statusText: [String: String] = [:]
    @Published private(set) var configRevision: Int = 0
    @Published private(set) var lastBoundSource: String?
    @Published private(set) var bindingRevision: Int = 0

    private weak var appState: AppState?
    private var connectors: [String: FeishuConnector] = [:]
    private var lastReplyDigestBySession: [String: String] = [:]

    private init() {}

    private func publishConfigChange() {
        DispatchQueue.main.async {
            self.configRevision &+= 1
        }
    }

    private func publishBindingSuccess(source: String) {
        DispatchQueue.main.async {
            self.lastBoundSource = source
            self.bindingRevision &+= 1
        }
    }

    func start(appState: AppState) {
        self.appState = appState
        appendFeishuDebugLog("FeishuBridgeManager start")
        reload()
    }

    func stop() {
        let liveConnectors = connectors.values
        connectors.removeAll()
        statusText.removeAll()
        appendFeishuDebugLog("FeishuBridgeManager stop")
        for connector in liveConnectors {
            Task { await connector.stop() }
        }
    }

    func reload() {
        let configs = FeishuSettingsStore.load()
        let enabledSources = Set(configs.values.filter(\.isConnectable).map(\.normalizedSource))
        appendFeishuDebugLog("Reload configs: enabled sources = \(enabledSources.sorted().joined(separator: ","))")

        for (source, connector) in connectors where !enabledSources.contains(source) {
            connectors.removeValue(forKey: source)
            statusText.removeValue(forKey: source)
            appendFeishuDebugLog("Stop connector for source=\(source)")
            Task { await connector.stop() }
        }

        for config in configs.values where config.isConnectable {
            let source = config.normalizedSource
            if let existing = connectors[source] {
                appendFeishuDebugLog("Update connector for source=\(source), bound=\(config.isBound)")
                Task { await existing.update(config: config) }
            } else {
                let connector = FeishuConnector(config: config)
                connectors[source] = connector
                appendFeishuDebugLog("Start connector for source=\(source), bound=\(config.isBound)")
                Task { await connector.start() }
            }
        }

        publishConfigChange()
    }

    func notifyAssistantReply(sessionId: String, session: SessionSnapshot) {
        guard let connector = connectors[session.source],
              let message = session.lastAssistantMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return }

        let digest = "\(session.source)|\(session.projectDisplayName)|\(message)"
        if lastReplyDigestBySession[sessionId] == digest { return }
        lastReplyDigestBySession[sessionId] = digest

        let text = """
        ✅ \(session.sourceLabel) 回复完成
        ━━━━━━━━━━━━━━━━

        会话：\(session.displayTitle(sessionId: sessionId))
        文件夹：\(session.cwd ?? "未知")

        AI 回复

        \(message)
        """
        Task {
            await connector.sendInteractive(
                card: FeishuCardBuilder.assistantReplyCard(
                    sourceLabel: session.sourceLabel,
                    sessionTitle: session.displayTitle(sessionId: sessionId),
                    folder: session.cwd,
                    message: message
                ),
                fallbackTitle: "✅ \(session.sourceLabel) 回复完成",
                fallbackMarkdown: text
            )
        }
    }

    func resetAssistantReplyDedup(sessionId: String) {
        lastReplyDigestBySession.removeValue(forKey: sessionId)
    }

    func notifyPermissionRequest(sessionId: String, session: SessionSnapshot, event: HookEvent) {
        guard let connector = connectors[session.source] else { return }
        let toolName = event.toolName ?? "Unknown"
        let detail = event.toolDescription ?? toolName
        let text = """
        ⚠️ 需要权限确认
        ━━━━━━━━━━━━━━━━

        工具：\(toolName)
        会话：\(session.displayTitle(sessionId: sessionId))
        文件夹：\(session.cwd ?? "未知")

        请求内容
        \(detail)

        可回复指令
        - `approve`
        - `deny`
        - `status`
        """
        Task {
            await connector.sendInteractive(
                card: FeishuCardBuilder.approvalCard(
                    sourceLabel: session.sourceLabel,
                    sessionTitle: session.displayTitle(sessionId: sessionId),
                    folder: session.cwd,
                    toolName: toolName,
                    detail: detail
                ),
                fallbackTitle: "⚠️ CodeIsland · 待确认",
                fallbackMarkdown: text
            )
        }
    }

    func notifyQuestionRequest(sessionId: String, session: SessionSnapshot, question: QuestionRequest) {
        guard let connector = connectors[session.source] else { return }

        let body: String
        if let askState = question.askUserQuestionState, askState.items.count > 1 {
            let items = askState.items.enumerated().map { index, item in
                "\(index + 1). \(item.payload.question)"
            }.joined(separator: "\n")
            body = """
            ❓ 需要补充信息
            ━━━━━━━━━━━━━━━━

            会话：\(session.displayTitle(sessionId: sessionId))
            文件夹：\(session.cwd ?? "未知")

            当前是多问题表单，请在 CodeIsland 面板中完成：

            \(items)
            """
        } else {
            let options = question.question.options?.joined(separator: " / ")
            let optionsText = options.map { "\n可选项：\($0)" } ?? ""
            body = """
            ❓ 需要你回答
            ━━━━━━━━━━━━━━━━

            会话：\(session.displayTitle(sessionId: sessionId))
            文件夹：\(session.cwd ?? "未知")

            问题
            \(question.question.question)\(optionsText)

            直接回复
            - `reply 你的答案`
            """
        }

        Task {
            await connector.sendInteractive(
                card: FeishuCardBuilder.questionCard(
                    sourceLabel: session.sourceLabel,
                    sessionTitle: session.displayTitle(sessionId: sessionId),
                    folder: session.cwd,
                    question: question.question.question,
                    options: question.question.options
                ),
                fallbackTitle: "❓ CodeIsland · 待回复",
                fallbackMarkdown: body
            )
        }
    }

    func sendTestMessage(source: String) {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(source),
              let connector = connectors[normalizedSource] else { return }
        appendFeishuDebugLog("Manual test message for source=\(normalizedSource)")
        Task {
            let markdown = """
                🟢 \(displayName(for: normalizedSource)) 机器人已就绪
                ━━━━━━━━━━━━━━━━

                之后这里会收到：
                - AI 回复
                - 权限确认请求
                - 提问请求

                可用指令
                - `status`
                - `approve`
                - `deny`
                - `reply 你的答案`
                - `run: 你的任务`

                小提示：如果 Codex 正在等待你选择，可以直接回复 `approve` 或 `deny`。
                """
            await connector.sendInteractive(
                card: FeishuCardBuilder.readyCard(sourceName: displayName(for: normalizedSource)),
                fallbackTitle: "🟢 CodeIsland 已连接",
                fallbackMarkdown: markdown
            )
        }
    }

    func bindingKey(for source: String) -> String {
        FeishuSettingsStore.load()[source]?.effectiveBindingKey ?? FeishuBotConfig.makeBindingKey(source: source)
    }

    func regenerateBindingKey(for source: String) {
        var configs = FeishuSettingsStore.load()
        let current = configs[source] ?? .empty(source: source)
        configs[source] = FeishuBotConfig(
            source: source,
            enabled: current.enabled,
            appID: current.appID,
            appSecret: current.appSecret,
            bindingKey: FeishuBotConfig.makeBindingKey(source: source),
            boundChatID: ""
        )
        FeishuSettingsStore.save(configs)
        reload()
    }

    func bindChatIfNeeded(source: String, incoming: FeishuIncomingMessage) -> String? {
        var configs = FeishuSettingsStore.load()
        guard var config = configs[source] else { return nil }

        let trimmed = incoming.text
            .replacingOccurrences(of: #"@_user_\d+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed == config.effectiveBindingKey {
            appendFeishuDebugLog("Binding matched for source=\(source), chat_id=\(incoming.chatID)")
            config.boundChatID = incoming.chatID
            configs[source] = config
            FeishuSettingsStore.save(configs)
            reload()
            publishBindingSuccess(source: source)
            updateStatus(source: source, text: "Bound")
            return """
            🟢 绑定成功

            已将当前会话绑定为 \(displayName(for: source)) 的飞书接收会话。
            之后你会在这里收到回复、确认请求和问题提醒。

            你可以先发送 `status` 或 `run: 帮我看一下当前仓库状态` 试试。
            """
        }
        appendFeishuDebugLog("Binding not matched for source=\(source), incoming='\(trimmed)', expected='\(config.effectiveBindingKey)'")
        return nil
    }

    func updateStatus(source: String, text: String) {
        DispatchQueue.main.async {
            self.statusText[source] = text
        }
        appendFeishuDebugLog("Status update for source=\(source): \(text)")
    }

    func handleIncoming(_ incoming: FeishuIncomingMessage) {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(incoming.source),
              let connector = connectors[normalizedSource] else { return }
        appendFeishuDebugLog("Incoming message for source=\(normalizedSource), chat_id=\(incoming.chatID), message_id=\(incoming.messageID), text='\(incoming.text)'")

        if let bindingResponse = bindChatIfNeeded(source: normalizedSource, incoming: incoming) {
            appendFeishuDebugLog("Reply binding success for source=\(normalizedSource)")
            Task {
                await connector.replyInteractive(
                    messageID: incoming.messageID,
                    card: FeishuCardBuilder.replyCard(title: "🟢 绑定成功", message: bindingResponse, template: .green),
                    fallbackText: bindingResponse
                )
            }
            return
        }

        let config = FeishuSettingsStore.load()[normalizedSource] ?? .empty(source: normalizedSource)
        guard config.boundChatID == incoming.chatID else {
            appendFeishuDebugLog("Ignore incoming message for source=\(normalizedSource), unbound chat_id=\(incoming.chatID), expected=\(config.boundChatID)")
            return
        }

        let response = handleCommand(text: incoming.text, source: normalizedSource)
        guard let response, !response.isEmpty else {
            appendFeishuDebugLog("No command response for source=\(normalizedSource)")
            return
        }

        appendFeishuDebugLog("Reply command for source=\(normalizedSource): \(response)")
        Task {
            await connector.replyInteractive(
                messageID: incoming.messageID,
                card: FeishuCardBuilder.replyCard(title: "CodeIsland · 指令结果", message: response, template: .blue),
                fallbackText: response
            )
        }
    }

    func handleAction(_ incoming: FeishuIncomingAction) {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(incoming.source),
              let connector = connectors[normalizedSource] else { return }
        appendFeishuDebugLog("Incoming card action for source=\(normalizedSource), action=\(incoming.action), answer=\(incoming.answer ?? ""), chat_id=\(incoming.chatID ?? "")")

        let config = FeishuSettingsStore.load()[normalizedSource] ?? .empty(source: normalizedSource)
        if let chatID = incoming.chatID,
           !chatID.isEmpty,
           config.boundChatID != chatID {
            appendFeishuDebugLog("Ignore card action for source=\(normalizedSource), chat_id=\(chatID), expected=\(config.boundChatID)")
            return
        }

        let response = handleCardAction(incoming, source: normalizedSource)
        guard !response.isEmpty else { return }
        appendFeishuDebugLog("Reply card action result for source=\(normalizedSource): \(response)")
        Task {
            if let messageID = incoming.messageID, !messageID.isEmpty {
                await connector.replyInteractive(
                    messageID: messageID,
                    card: FeishuCardBuilder.replyCard(title: "CodeIsland · 操作结果", message: response, template: .blue),
                    fallbackText: response
                )
            } else {
                await connector.sendInteractive(
                    card: FeishuCardBuilder.replyCard(title: "CodeIsland · 操作结果", message: response, template: .blue),
                    fallbackTitle: "CodeIsland · 操作结果",
                    fallbackMarkdown: response
                )
            }
        }
    }

    private func handleCommand(text: String, source: String) -> String? {
        guard let appState else { return "CodeIsland 尚未初始化完成。" }

        let trimmed = text
            .replacingOccurrences(of: #"@_user_\d+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return helpText(for: source) }

        let lowercased = trimmed.lowercased()
        if lowercased == "help" || lowercased == "?" {
            return helpText(for: source)
        }
        if lowercased == "status" {
            return appState.feishuStatusSummary(forSource: source)
        }
        if lowercased == "approve" {
            return appState.approvePendingPermission(forSource: source)
        }
        if lowercased == "deny" {
            return appState.denyPendingPermission(forSource: source)
        }
        if lowercased.hasPrefix("reply ") {
            let answer = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return "请在 `reply` 后面附上回答内容。" }
            return appState.answerPendingQuestion(forSource: source, answer: answer)
        }
        if lowercased.hasPrefix("run:") {
            let prompt = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return appState.submitRemotePrompt(forSource: source, prompt: prompt)
        }
        if lowercased.hasPrefix("run ") {
            let prompt = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return appState.submitRemotePrompt(forSource: source, prompt: prompt)
        }

        if appState.hasAnswerableQuestion(forSource: source) {
            return appState.answerPendingQuestion(forSource: source, answer: trimmed)
        }

        return helpText(for: source)
    }

    private func handleCardAction(_ incoming: FeishuIncomingAction, source: String) -> String {
        guard let appState else { return "CodeIsland 尚未初始化完成。" }
        switch incoming.action {
        case "approve":
            return appState.approvePendingPermission(forSource: source)
        case "deny":
            return appState.denyPendingPermission(forSource: source)
        case "status":
            return appState.feishuStatusSummary(forSource: source)
        case "reply":
            guard let answer = incoming.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty else {
                return "按钮没有携带回答内容，请直接回复：reply 你的答案"
            }
            return appState.answerPendingQuestion(forSource: source, answer: answer)
        default:
            return "暂不支持这个卡片操作：\(incoming.action)"
        }
    }

    private func helpText(for source: String) -> String {
        """
        当前支持的指令：
        status
        approve
        deny
        reply 你的答案
        run: 你的任务

        当前机器人绑定：\(displayName(for: source))
        """
    }

    private func displayName(for source: String) -> String {
        ConfigInstaller.allCLIs.first(where: { $0.source == source })?.name
            ?? source
    }
}

private actor FeishuConnector {
    private var config: FeishuBotConfig
    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var shouldRun = false
    private var fragments: [String: FeishuFragmentBuffer] = [:]
    private var pingIntervalSeconds: Int = 120
    private var reconnectIntervalSeconds: Int = 120
    private var reconnectNonceSeconds: Int = 30
    private var reconnectAttempts: Int = -1
    private var currentServiceID: Int32 = 0
    private var accessToken: String?
    private var accessTokenExpiresAt: Date = .distantPast

    init(config: FeishuBotConfig) {
        self.config = config
        self.session = URLSession(configuration: .ephemeral)
    }

    func start() {
        guard runner == nil else { return }
        shouldRun = true
        appendFeishuDebugLog("Connector start source=\(config.normalizedSource)")
        runner = Task {
            await runLoop()
        }
    }

    func stop() {
        shouldRun = false
        runner?.cancel()
        runner = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        currentServiceID = 0
        appendFeishuDebugLog("Connector stop source=\(config.normalizedSource)")
    }

    func update(config: FeishuBotConfig) {
        let old = self.config
        self.config = config
        let changed = old.appID != config.appID
            || old.appSecret != config.appSecret
            || old.boundChatID != config.boundChatID
            || old.bindingKey != config.bindingKey
        appendFeishuDebugLog("Connector update source=\(config.normalizedSource), changed=\(changed), bound=\(config.isBound)")
        if changed {
            accessToken = nil
            accessTokenExpiresAt = .distantPast
            fragments.removeAll()
            currentServiceID = 0
            socketTask?.cancel(with: .goingAway, reason: nil)
            socketTask = nil
            if runner == nil {
                start()
            }
        }
    }

    func sendText(_ text: String) async {
        guard config.isConnectable, config.isBound else {
            appendFeishuDebugLog("Skip sendText source=\(config.normalizedSource), connectable=\(config.isConnectable), bound=\(config.isBound)")
            return
        }
        let source = config.normalizedSource
        do {
            let token = try await tenantAccessToken()
            appendFeishuDebugLog("Send text source=\(source), chat_id=\(config.boundChatID), text='\(text)'")
            try await postMessage(
                token: token,
                path: "/open-apis/im/v1/messages?receive_id_type=chat_id",
                body: [
                    "receive_id": config.boundChatID,
                    "msg_type": "text",
                    "content": Self.messageContent(text)
                ]
            )
        } catch {
            appendFeishuDebugLog("Send text failed source=\(source): \(error.localizedDescription)")
            await MainActor.run {
                FeishuBridgeManager.shared.updateStatus(source: source, text: "Send failed: \(error.localizedDescription)")
            }
        }
    }

    func sendPost(title: String, markdown: String) async {
        guard config.isConnectable, config.isBound else {
            appendFeishuDebugLog("Skip sendPost source=\(config.normalizedSource), connectable=\(config.isConnectable), bound=\(config.isBound)")
            return
        }
        let source = config.normalizedSource
        do {
            let token = try await tenantAccessToken()
            appendFeishuDebugLog("Send post source=\(source), chat_id=\(config.boundChatID), title='\(title)'")
            try await postMessage(
                token: token,
                path: "/open-apis/im/v1/messages?receive_id_type=chat_id",
                body: [
                    "receive_id": config.boundChatID,
                    "msg_type": "post",
                    "content": FeishuPostBuilder.content(title: title, markdown: markdown)
                ]
            )
        } catch {
            appendFeishuDebugLog("Send post failed source=\(source): \(error.localizedDescription)")
            await MainActor.run {
                FeishuBridgeManager.shared.updateStatus(source: source, text: "Send failed: \(error.localizedDescription)")
            }
        }
    }

    func sendInteractive(card: String, fallbackTitle: String, fallbackMarkdown: String) async {
        guard config.isConnectable, config.isBound else {
            appendFeishuDebugLog("Skip sendInteractive source=\(config.normalizedSource), connectable=\(config.isConnectable), bound=\(config.isBound)")
            return
        }
        let source = config.normalizedSource
        do {
            let token = try await tenantAccessToken()
            appendFeishuDebugLog("Send interactive source=\(source), chat_id=\(config.boundChatID), title='\(fallbackTitle)'")
            try await postMessage(
                token: token,
                path: "/open-apis/im/v1/messages?receive_id_type=chat_id",
                body: [
                    "receive_id": config.boundChatID,
                    "msg_type": "interactive",
                    "content": card
                ]
            )
        } catch {
            appendFeishuDebugLog("Send interactive failed source=\(source): \(error.localizedDescription)")
            await sendPost(title: fallbackTitle, markdown: fallbackMarkdown)
        }
    }

    func replyText(messageID: String, text: String) async {
        guard config.isConnectable else { return }
        let source = config.normalizedSource
        do {
            let token = try await tenantAccessToken()
            appendFeishuDebugLog("Reply text source=\(source), message_id=\(messageID), text='\(text)'")
            try await postMessage(
                token: token,
                path: "/open-apis/im/v1/messages/\(messageID)/reply",
                body: [
                    "msg_type": "text",
                    "content": Self.messageContent(text)
                ]
            )
        } catch {
            appendFeishuDebugLog("Reply text failed source=\(source): \(error.localizedDescription)")
            await MainActor.run {
                FeishuBridgeManager.shared.updateStatus(source: source, text: "Reply failed: \(error.localizedDescription)")
            }
        }
    }

    func replyInteractive(messageID: String, card: String, fallbackText: String) async {
        guard config.isConnectable else { return }
        let source = config.normalizedSource
        do {
            let token = try await tenantAccessToken()
            appendFeishuDebugLog("Reply interactive source=\(source), message_id=\(messageID)")
            try await postMessage(
                token: token,
                path: "/open-apis/im/v1/messages/\(messageID)/reply",
                body: [
                    "msg_type": "interactive",
                    "content": card
                ]
            )
        } catch {
            appendFeishuDebugLog("Reply interactive failed source=\(source): \(error.localizedDescription)")
            await replyText(messageID: messageID, text: fallbackText)
        }
    }

    private func runLoop() async {
        var attempt = 0
        let source = config.normalizedSource
        while shouldRun && !Task.isCancelled {
            do {
                try await connectAndReceive()
                attempt = 0
            } catch {
                if Task.isCancelled || !shouldRun { break }
                feishuLog.error("Feishu websocket for \(source, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                appendFeishuDebugLog("WebSocket failed source=\(source): \(error.localizedDescription)")
                await MainActor.run {
                    FeishuBridgeManager.shared.updateStatus(source: source, text: "Disconnected")
                }
                attempt += 1
                if reconnectAttempts >= 0 && attempt > reconnectAttempts { break }
                let jitter = reconnectNonceSeconds > 0 ? Int.random(in: 0...max(0, reconnectNonceSeconds)) : 0
                let delay = max(2, reconnectIntervalSeconds) + jitter
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    private func connectAndReceive() async throws {
        let endpoint = try await websocketURL()
        let source = config.normalizedSource
        appendFeishuDebugLog("Connect WebSocket source=\(source), endpoint=\(endpoint.absoluteString)")
        let task = session.webSocketTask(with: endpoint)
        socketTask = task
        task.resume()

        await MainActor.run {
            FeishuBridgeManager.shared.updateStatus(source: source, text: "Connected")
        }

        let pingTask = Task {
            await pingLoop()
        }
        defer {
            pingTask.cancel()
            task.cancel(with: .goingAway, reason: nil)
            socketTask = nil
        }

        while shouldRun && !Task.isCancelled {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                appendFeishuDebugLog("Received websocket data source=\(source), bytes=\(data.count)")
                try await handleFrameData(data, task: task)
            case .string:
                appendFeishuDebugLog("Received websocket string source=\(source)")
                continue
            @unknown default:
                continue
            }
        }
    }

    private func pingLoop() async {
        while shouldRun && !Task.isCancelled {
            guard let task = socketTask else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            let frame = FeishuWSFrame.ping(serviceID: currentServiceID)
            do {
                appendFeishuDebugLog("Send websocket ping source=\(config.normalizedSource), service_id=\(currentServiceID)")
                try await task.send(.data(FeishuWSCodec.encode(frame)))
            } catch {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(max(5, pingIntervalSeconds)) * 1_000_000_000)
        }
    }

    private func handleFrameData(_ data: Data, task: URLSessionWebSocketTask) async throws {
        let frame = try FeishuWSCodec.decode(data)
        appendFeishuDebugLog("Decoded frame source=\(config.normalizedSource), method=\(frame.method), service_id=\(frame.serviceID), headers=\(frame.headers.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        if frame.serviceID != 0 {
            currentServiceID = frame.serviceID
        }

        if frame.method == FeishuWSFrame.controlMethod,
           frame.headerValue(for: "type") == "pong" {
            if !frame.payload.isEmpty,
               let serverConfig = try? JSONDecoder().decode(FeishuClientConfig.self, from: frame.payload) {
                apply(serverConfig: serverConfig)
            }
            return
        }

        guard frame.method == FeishuWSFrame.dataMethod else { return }

        let payload: Data
        if let total = Int(frame.headerValue(for: "sum") ?? ""), total > 1 {
            let messageID = frame.headerValue(for: "message_id") ?? UUID().uuidString
            let seq = Int(frame.headerValue(for: "seq") ?? "") ?? 0
            var buffer = fragments[messageID] ?? FeishuFragmentBuffer(total: total)
            guard let joined = buffer.append(seq: seq, data: frame.payload) else {
                fragments[messageID] = buffer
                return
            }
            fragments.removeValue(forKey: messageID)
            payload = joined
        } else {
            payload = frame.payload
        }

        let action = parseIncomingAction(payload)
        let incoming = action == nil ? parseIncomingMessage(payload) : nil

        // Feishu card actions are latency-sensitive. A delayed ack can surface as code
        // 200340 in the client, so acknowledge the websocket frame before business work.
        let ackPayload: Data
        if action != nil {
            ackPayload = Data(#"{"toast":{"type":"info","content":"已收到，处理中","i18n":{"zh_cn":"已收到，处理中","en_us":"Received, processing"}}}"#.utf8)
        } else {
            ackPayload = Data(#"{}"#.utf8)
        }
        let responseFrame = frame.responseFrame(payload: ackPayload, bizRTMilliseconds: 0)
        try await task.send(.data(FeishuWSCodec.encode(responseFrame)))
        let ackPayloadText = String(data: ackPayload, encoding: .utf8) ?? "<non-utf8>"
        appendFeishuDebugLog("Ack websocket frame source=\(config.normalizedSource), service_id=\(frame.serviceID), is_action=\(action != nil), ack_payload=\(ackPayloadText)")

        if let action {
            Task { @MainActor in
                FeishuBridgeManager.shared.handleAction(action)
            }
        } else if let incoming {
            Task { @MainActor in
                FeishuBridgeManager.shared.handleIncoming(incoming)
            }
        } else {
            appendFeishuDebugLog("Payload ignored source=\(config.normalizedSource)")
        }
    }

    private func parseIncomingMessage(_ payload: Data) -> FeishuIncomingMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let eventType = header["event_type"] as? String,
              eventType == "im.message.receive_v1",
              let event = json["event"] as? [String: Any],
              let message = event["message"] as? [String: Any],
              let messageID = message["message_id"] as? String,
              let chatID = message["chat_id"] as? String,
              let messageType = message["message_type"] as? String,
              messageType == "text",
              let content = message["content"] as? String else { return nil }

        if let sender = event["sender"] as? [String: Any],
           let senderType = sender["sender_type"] as? String,
           senderType.lowercased() != "user" {
            appendFeishuDebugLog("Ignore non-user sender source=\(config.normalizedSource), sender_type=\(senderType)")
            return nil
        }

        guard let contentJSON = content.data(using: .utf8),
              let contentObject = try? JSONSerialization.jsonObject(with: contentJSON) as? [String: Any],
              let text = contentObject["text"] as? String else {
            appendFeishuDebugLog("Ignore content parse failure source=\(config.normalizedSource), raw_content=\(content)")
            return nil
        }

        return FeishuIncomingMessage(
            source: config.normalizedSource,
            chatID: chatID,
            messageID: messageID,
            text: text
        )
    }

    private func parseIncomingAction(_ payload: Data) -> FeishuIncomingAction? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }

        let header = json["header"] as? [String: Any]
        let eventType = (header?["event_type"] as? String)
            ?? (json["type"] as? String)
            ?? (json["event_type"] as? String)
        guard eventType == "card.action.trigger" || eventType == "card.action.trigger_v1" else {
            return nil
        }

        let event = (json["event"] as? [String: Any]) ?? json
        let actionObject = event["action"] as? [String: Any]
        let value = (actionObject?["value"] as? [String: Any])
            ?? (event["value"] as? [String: Any])
            ?? [:]

        let action = (value["ci_action"] as? String)
            ?? (value["action"] as? String)
            ?? (actionObject?["tag"] as? String)
            ?? ""
        guard !action.isEmpty else {
            appendFeishuDebugLog("Ignore card action without ci_action source=\(config.normalizedSource), payload=\(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")
            return nil
        }

        let context = event["context"] as? [String: Any]
        let openMessageID = (context?["open_message_id"] as? String)
            ?? (event["open_message_id"] as? String)
        let chatID = (event["chat_id"] as? String)
            ?? (context?["open_chat_id"] as? String)
            ?? (context?["chat_id"] as? String)

        let answer = value["answer"] as? String ?? ""
        let payloadText = String(data: payload, encoding: .utf8) ?? "<non-utf8>"
        appendFeishuDebugLog(
            "Parsed card action source=\(config.normalizedSource), open_message_id=\(openMessageID ?? ""), chat_id=\(chatID ?? ""), action=\(action), answer=\(answer), value=\(value), payload=\(payloadText)"
        )
        return FeishuIncomingAction(
            source: config.normalizedSource,
            chatID: chatID,
            messageID: openMessageID,
            action: action,
            answer: value["answer"] as? String,
            rawValue: value
        )
    }

    private func apply(serverConfig: FeishuClientConfig) {
        if let ping = serverConfig.pingInterval, ping > 0 {
            pingIntervalSeconds = ping
        }
        if let reconnect = serverConfig.reconnectInterval, reconnect > 0 {
            reconnectIntervalSeconds = reconnect
        }
        if let nonce = serverConfig.reconnectNonce, nonce >= 0 {
            reconnectNonceSeconds = nonce
        }
        if let count = serverConfig.reconnectCount {
            reconnectAttempts = count
        }
    }

    private func websocketURL() async throws -> URL {
        let candidates: [[String: Any]] = [
            [
                "app_id": config.appID,
                "app_secret": config.appSecret
            ],
            [
                "AppID": config.appID,
                "AppSecret": config.appSecret
            ]
        ]

        var lastError: Error = FeishuBridgeError.invalidResponse
        for body in candidates {
            do {
                return try await websocketURL(body: body)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func websocketURL(body: [String: Any]) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://open.feishu.cn/callback/ws/endpoint")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("zh", forHTTPHeaderField: "locale")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard let http = response as? HTTPURLResponse else {
            appendFeishuDebugLog("Fetch websocket endpoint invalid HTTP response source=\(config.normalizedSource), body=\(body.keys.sorted())")
            throw FeishuBridgeError.invalidResponse
        }
        appendFeishuDebugLog("Fetch websocket endpoint response source=\(config.normalizedSource), status=\(http.statusCode), request_keys=\(body.keys.sorted()), body=\(responseText)")
        guard http.statusCode == 200 else {
            throw FeishuBridgeError.server("WS endpoint http \(http.statusCode)")
        }

        let envelope = try JSONDecoder().decode(FeishuEndpointEnvelope.self, from: data)
        guard envelope.code == 0, let urlString = envelope.data?.url, let url = URL(string: urlString) else {
            appendFeishuDebugLog("Fetch websocket endpoint failed source=\(config.normalizedSource), code=\(envelope.code), msg=\(envelope.msg)")
            throw FeishuBridgeError.server(envelope.msg)
        }
        appendFeishuDebugLog("Fetched websocket endpoint source=\(config.normalizedSource)")
        if let serverConfig = envelope.data?.clientConfig {
            apply(serverConfig: serverConfig)
        }
        currentServiceID = Self.serviceID(from: url) ?? currentServiceID
        appendFeishuDebugLog("Resolved websocket service_id source=\(config.normalizedSource), service_id=\(currentServiceID)")
        return url
    }

    private static func serviceID(from url: URL) -> Int32? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "service_id" })?.value,
              let parsed = Int32(value) else { return nil }
        return parsed
    }

    private func tenantAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiresAt > Date().addingTimeInterval(60) {
            return accessToken
        }

        var request = URLRequest(url: URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "app_id": config.appID,
            "app_secret": config.appSecret
        ])

        let (data, response) = try await session.data(for: request)
        let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            appendFeishuDebugLog("Fetch tenant_access_token http failure source=\(config.normalizedSource), body=\(responseText)")
            throw FeishuBridgeError.invalidResponse
        }

        let envelope = try JSONDecoder().decode(FeishuTokenEnvelope.self, from: data)
        guard envelope.code == 0, let token = envelope.tenantAccessToken else {
            appendFeishuDebugLog("Fetch tenant_access_token failed source=\(config.normalizedSource), code=\(envelope.code), msg=\(envelope.msg)")
            throw FeishuBridgeError.server(envelope.msg)
        }

        accessToken = token
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(envelope.expire ?? 7200))
        appendFeishuDebugLog("Fetched tenant_access_token source=\(config.normalizedSource)")
        return token
    }

    private func postMessage(token: String, path: String, body: [String: Any]) async throws {
        guard let url = URL(string: "https://open.feishu.cn\(path)") else {
            throw FeishuBridgeError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            appendFeishuDebugLog("HTTP request failed source=\(config.normalizedSource), path=\(path), body=\(responseText)")
            throw FeishuBridgeError.server("HTTP request failed: \(responseText)")
        }
        appendFeishuDebugLog("HTTP request success source=\(config.normalizedSource), path=\(path), status=\(http.statusCode)")
    }

    private static func messageContent(_ text: String) -> String {
        let payload = ["text": text]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"text":"invalid"}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private enum FeishuBridgeError: LocalizedError {
    case invalidResponse
    case server(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid Feishu response"
        case .server(let message):
            return message
        case .decode(let message):
            return message
        }
    }
}

private struct FeishuWSHeader {
    let key: String
    let value: String
}

private struct FeishuWSFrame {
    static let controlMethod = 0
    static let dataMethod = 1

    var seqID: UInt64
    var logID: UInt64
    var serviceID: Int32
    var method: Int32
    var headers: [FeishuWSHeader]
    var payloadEncoding: String
    var payloadType: String
    var payload: Data
    var logIDNew: String

    func headerValue(for key: String) -> String? {
        headers.first(where: { $0.key == key })?.value
    }

    static func ping(serviceID: Int32) -> FeishuWSFrame {
        FeishuWSFrame(
            seqID: UInt64(Date().timeIntervalSince1970),
            logID: 0,
            serviceID: serviceID,
            method: Int32(controlMethod),
            headers: [FeishuWSHeader(key: "type", value: "ping")],
            payloadEncoding: "",
            payloadType: "",
            payload: Data(),
            logIDNew: ""
        )
    }

    func responseFrame(
        payload payloadData: Data = Data(#"{"code":200}"#.utf8),
        bizRTMilliseconds: Int? = nil
    ) -> FeishuWSFrame {
        var responseHeaders = headers
        if let bizRTMilliseconds {
            responseHeaders.append(FeishuWSHeader(key: "biz_rt", value: String(bizRTMilliseconds)))
        }
        return FeishuWSFrame(
            seqID: seqID,
            logID: logID,
            serviceID: serviceID,
            method: method,
            headers: responseHeaders,
            payloadEncoding: payloadEncoding,
            payloadType: payloadType,
            payload: payloadData,
            logIDNew: logIDNew
        )
    }
}

private enum FeishuWSCodec {
    static func decode(_ data: Data) throws -> FeishuWSFrame {
        let bytes = [UInt8](data)
        var index = 0
        var seqID: UInt64 = 0
        var logID: UInt64 = 0
        var serviceID: Int32 = 0
        var method: Int32 = 0
        var headers: [FeishuWSHeader] = []
        var payloadEncoding = ""
        var payloadType = ""
        var payload = Data()
        var logIDNew = ""

        while index < bytes.count {
            let tag = try readVarint(bytes, &index)
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)

            switch (field, wire) {
            case (1, 0):
                seqID = try readVarint(bytes, &index)
            case (2, 0):
                logID = try readVarint(bytes, &index)
            case (3, 0):
                serviceID = Int32(try readVarint(bytes, &index))
            case (4, 0):
                method = Int32(try readVarint(bytes, &index))
            case (5, 2):
                let nested = try readLengthDelimited(bytes, &index)
                headers.append(try decodeHeader(nested))
            case (6, 2):
                payloadEncoding = try decodeString(bytes, &index)
            case (7, 2):
                payloadType = try decodeString(bytes, &index)
            case (8, 2):
                payload = try readLengthDelimited(bytes, &index)
            case (9, 2):
                logIDNew = try decodeString(bytes, &index)
            default:
                try skipField(bytes, &index, wireType: wire)
            }
        }

        return FeishuWSFrame(
            seqID: seqID,
            logID: logID,
            serviceID: serviceID,
            method: method,
            headers: headers,
            payloadEncoding: payloadEncoding,
            payloadType: payloadType,
            payload: payload,
            logIDNew: logIDNew
        )
    }

    static func encode(_ frame: FeishuWSFrame) -> Data {
        var output = Data()
        appendVarintField(1, value: frame.seqID, to: &output)
        appendVarintField(2, value: frame.logID, to: &output)
        appendVarintField(3, value: UInt64(Int64(frame.serviceID)), to: &output)
        appendVarintField(4, value: UInt64(Int64(frame.method)), to: &output)
        for header in frame.headers {
            let encodedHeader = encode(header: header)
            appendLengthDelimitedField(5, data: encodedHeader, to: &output)
        }
        appendStringField(6, value: frame.payloadEncoding, to: &output)
        appendStringField(7, value: frame.payloadType, to: &output)
        appendLengthDelimitedField(8, data: frame.payload, to: &output)
        appendStringField(9, value: frame.logIDNew, to: &output)
        return output
    }

    private static func encode(header: FeishuWSHeader) -> Data {
        var output = Data()
        appendStringField(1, value: header.key, to: &output)
        appendStringField(2, value: header.value, to: &output)
        return output
    }

    private static func decodeHeader(_ data: Data) throws -> FeishuWSHeader {
        let bytes = [UInt8](data)
        var index = 0
        var key = ""
        var value = ""

        while index < bytes.count {
            let tag = try readVarint(bytes, &index)
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)

            switch (field, wire) {
            case (1, 2):
                key = try decodeString(bytes, &index)
            case (2, 2):
                value = try decodeString(bytes, &index)
            default:
                try skipField(bytes, &index, wireType: wire)
            }
        }

        return FeishuWSHeader(key: key, value: value)
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var shift = 0
        var result: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                throw FeishuBridgeError.decode("Varint overflow")
            }
        }
        throw FeishuBridgeError.decode("Unexpected EOF")
    }

    private static func readLengthDelimited(_ bytes: [UInt8], _ index: inout Int) throws -> Data {
        let length = Int(try readVarint(bytes, &index))
        guard length >= 0, index + length <= bytes.count else {
            throw FeishuBridgeError.decode("Invalid length")
        }
        defer { index += length }
        return Data(bytes[index..<index + length])
    }

    private static func decodeString(_ bytes: [UInt8], _ index: inout Int) throws -> String {
        let data = try readLengthDelimited(bytes, &index)
        return String(decoding: data, as: UTF8.self)
    }

    private static func skipField(_ bytes: [UInt8], _ index: inout Int, wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint(bytes, &index)
        case 2:
            _ = try readLengthDelimited(bytes, &index)
        default:
            throw FeishuBridgeError.decode("Unsupported wire type \(wireType)")
        }
    }

    private static func appendVarintField(_ field: UInt64, value: UInt64, to data: inout Data) {
        appendVarint((field << 3) | 0, to: &data)
        appendVarint(value, to: &data)
    }

    private static func appendStringField(_ field: UInt64, value: String, to data: inout Data) {
        appendLengthDelimitedField(field, data: Data(value.utf8), to: &data)
    }

    private static func appendLengthDelimitedField(_ field: UInt64, data fieldData: Data, to data: inout Data) {
        appendVarint((field << 3) | 2, to: &data)
        appendVarint(UInt64(fieldData.count), to: &data)
        data.append(fieldData)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while true {
            if value < 0x80 {
                data.append(UInt8(value))
                return
            }
            data.append(UInt8(value & 0x7f | 0x80))
            value >>= 7
        }
    }
}
