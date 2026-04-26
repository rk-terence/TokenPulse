import CryptoKit
import Foundation

/// In-memory content tree. Each tree represents the conversation space for a
/// single cache-identity fingerprint (same model / system / tools / thinking).
/// Nodes are content checkpoints — a node stores only the messages it appends
/// to its parent's cumulative prefix. Requests are separate records attached
/// to a node; a node may own multiple requests (retries, repeats, or two
/// sessions arriving at the exact same content state).
///
/// The tree is a value-semantic struct owned by an actor (`ProxySessionStore`)
/// so mutations are serialized. It has no I/O side effects — callers mirror
/// changes to SQLite via `ProxyEventLogger`.
struct ContentTree: Sendable {

    // MARK: - Conversation

    struct ConversationKey: Hashable, Sendable {
        let flavor: ProxyAPIFlavor
        let fingerprintHash: String
    }

    /// A conversation is the tree root. Beyond the routing key, it also owns
    /// the full `LineageFingerprint` so downstream callers (UI rows, SQLite
    /// mirror) can resolve a node back to its model/system/tools without
    /// re-parsing the original request body.
    struct Conversation: Sendable {
        let id: UUID
        let key: ConversationKey
        let fingerprint: LineageFingerprint
        let rootNodeID: UUID
        var lastActivityAt: Date
    }

    // MARK: - Normalized message

    /// One provider-normalized lineage item. Anthropic strips prompt-caching
    /// markers and coalesces equivalent consecutive turns; OpenAI keeps the
    /// full ordered `input` item list while normalizing only documented
    /// shorthands. `role` is a display/debug label (message role or item type).
    /// `contentHash` is the canonical SHA-256 used for prefix folding;
    /// `rawJSON` is the normalized JSON kept for payload reconstruction.
    struct NormalizedMessage: Sendable, Equatable {
        let role: String
        let contentHash: String
        let rawJSON: Data
    }

    // MARK: - Node (content checkpoint)

    /// A point in the conversation's message-prefix space. The root node of
    /// every conversation has an empty `deltaMessages` list; descendant nodes
    /// carry the messages their attach added on top of the parent's cumulative
    /// prefix. `cumulativeHash` is the fold-hash of the full prefix at this
    /// node and is the key under which the node is looked up during attach.
    struct Node: Sendable {
        let id: UUID
        let conversationID: UUID
        let parentNodeID: UUID?
        var deltaMessages: [NormalizedMessage]
        let cumulativeHash: String
        var lastActivityAt: Date
        /// Canonical JSON of `deltaMessages`, populated lazily by
        /// `cachedDeltaMessagesJSON(for:)`. Deltas are immutable after
        /// creation so the cache never needs invalidation.
        var deltaMessagesJSONCache: String?
    }

    // MARK: - Request (one attempt attached to a node)

    /// One proxy request attached to a content node. A node may hold many of
    /// these — retries, two sessions arriving at the same prefix, or the same
    /// client hammering a turn. `finishedAt == nil` means the request is
    /// still in flight; `succeeded` distinguishes successful completion from
    /// an errored / cancelled terminal state.
    struct Request: Sendable {
        let id: UUID
        let nodeID: UUID
        let sessionID: String
        let previousResponseID: String?
        var responseID: String?
        let createdAt: Date
        var finishedAt: Date?
        var succeeded: Bool
        var tokenUsage: TokenUsage?

        var isTerminal: Bool { finishedAt != nil }
    }

    // MARK: - State

    private(set) var conversations: [ConversationKey: Conversation] = [:]
    private(set) var nodes: [UUID: Node] = [:]
    private(set) var requests: [UUID: Request] = [:]
    /// Direct children of a node (parent → child IDs).
    private(set) var childrenByNode: [UUID: [UUID]] = [:]
    /// Requests attached to a node.
    private(set) var requestsByNode: [UUID: [UUID]] = [:]
    /// Per-conversation trim-and-match index: cumulative prefix hash → node.
    private(set) var nodesByHash: [ConversationKey: [String: UUID]] = [:]
    /// Upstream-response-ID → owning node. Used for OpenAI
    /// `previous_response_id` linkage across requests.
    private(set) var responseIDIndex: [String: UUID] = [:]

    // MARK: - Attach

    struct AttachResult: Sendable {
        let conversationID: UUID
        let nodeID: UUID
        let createdConversation: Bool
        let createdNode: Bool
    }

    struct AttachPreview: Sendable {
        enum MatchKind: String, Sendable {
            case root = "root"
            case existingNode = "existing_node"
            case newChild = "new_child"
            case previousResponseLink = "previous_response_link"
        }

        let matchKind: MatchKind
        let matchedPrefixCount: Int
        let deltaMessages: [NormalizedMessage]
        let fullMessages: [NormalizedMessage]
        let previousResponseID: String?
        let fingerprintHash: String
        fileprivate let matchedNodeID: UUID?
        fileprivate let cumulativeHash: String
    }

    func previewAttach(
        fingerprint: LineageFingerprint,
        messages: [NormalizedMessage],
        previousResponseID: String?
    ) -> AttachPreview {
        let key = fingerprint.conversationKey

        if messages.isEmpty,
           let previousResponseID,
           let ownerNodeID = responseIDIndex[previousResponseID] {
            return AttachPreview(
                matchKind: .previousResponseLink,
                matchedPrefixCount: 0,
                deltaMessages: [],
                fullMessages: messages,
                previousResponseID: previousResponseID,
                fingerprintHash: key.fingerprintHash,
                matchedNodeID: ownerNodeID,
                cumulativeHash: Self.emptyPrefixHash()
            )
        }

        if messages.isEmpty {
            return AttachPreview(
                matchKind: .root,
                matchedPrefixCount: 0,
                deltaMessages: [],
                fullMessages: messages,
                previousResponseID: previousResponseID,
                fingerprintHash: key.fingerprintHash,
                matchedNodeID: conversations[key]?.rootNodeID,
                cumulativeHash: Self.emptyPrefixHash()
            )
        }

        let prefixHashes = Self.computePrefixHashes(messages: messages)
        let conversation = conversations[key]
        let conversationHashes = nodesByHash[key] ?? [:]
        var matchedPrefixCount = 0
        var matchedNodeID = conversation?.rootNodeID

        for index in stride(from: messages.count, through: 0, by: -1) {
            if let nodeID = conversationHashes[prefixHashes[index]] {
                matchedPrefixCount = index
                matchedNodeID = nodeID
                break
            }
        }

        let matchKind: AttachPreview.MatchKind = matchedPrefixCount == messages.count ? .existingNode : .newChild
        let deltaMessages = matchedPrefixCount == messages.count ? [] : Array(messages[matchedPrefixCount...])
        return AttachPreview(
            matchKind: matchKind,
            matchedPrefixCount: matchedPrefixCount,
            deltaMessages: deltaMessages,
            fullMessages: messages,
            previousResponseID: previousResponseID,
            fingerprintHash: key.fingerprintHash,
            matchedNodeID: matchedNodeID,
            cumulativeHash: prefixHashes[messages.count]
        )
    }

    /// Attach a newly-parsed proxy request to the tree. The request starts in
    /// the in-flight state; callers must call `finishRequest` on completion.
    ///
    /// - Parameters:
    ///   - requestID: Unique ID for this request.
    ///   - sessionID: UI grouping key; does not affect tree shape.
    ///   - fingerprint: Cache-identity fingerprint; persisted on the
    ///     conversation the first time it is seen.
    ///   - messages: Normalized messages carried by the request body. Empty
    ///     when the provider used `previous_response_id` alone (OpenAI).
    ///   - previousResponseID: OpenAI `previous_response_id`, if any.
    @discardableResult
    mutating func attach(
        requestID: UUID,
        sessionID: String,
        fingerprint: LineageFingerprint,
        messages: [NormalizedMessage],
        previousResponseID: String?,
        now: Date = Date()
    ) -> AttachResult {
        let preview = previewAttach(
            fingerprint: fingerprint,
            messages: messages,
            previousResponseID: previousResponseID
        )
        let key = fingerprint.conversationKey

        // 1) OpenAI previous_response_id with no body messages: force-link to
        //    the node that produced the referenced upstream response.
        if preview.matchKind == .previousResponseLink,
           let ownerNodeID = preview.matchedNodeID,
           let ownerNode = nodes[ownerNodeID] {
            recordRequest(
                id: requestID,
                nodeID: ownerNode.id,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
            touch(nodeID: ownerNode.id, now: now)
            touch(conversationID: ownerNode.conversationID, at: now)
            return AttachResult(
                conversationID: ownerNode.conversationID,
                nodeID: ownerNode.id,
                createdConversation: false,
                createdNode: false
            )
        }

        // 2) Resolve / create the conversation.
        let (conversation, createdConversation) = resolveOrCreateConversation(
            key: key,
            fingerprint: fingerprint,
            now: now
        )

        // 3) Brand-new conversation with no messages and no resolvable
        //    previous_response_id: attach to the root node (empty prefix) and
        //    return. Descendants cannot match against this request unless a
        //    later one produces a responseID linkage.
        if preview.matchKind == .root {
            recordRequest(
                id: requestID,
                nodeID: conversation.rootNodeID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
            touch(nodeID: conversation.rootNodeID, now: now)
            touch(conversationID: conversation.id, at: now)
            return AttachResult(
                conversationID: conversation.id,
                nodeID: conversation.rootNodeID,
                createdConversation: createdConversation,
                createdNode: false
            )
        }

        // 4) Precompute prefix hashes once (O(N)) and trim-and-match against
        //    `nodesByHash[key]` from k=N down to k=0. The root node is always
        //    registered at k=0 so the loop always terminates.
        // 5) Full prefix already exists — attach to the matched node.
        if preview.matchKind == .existingNode,
           let matchedNodeID = preview.matchedNodeID {
            recordRequest(
                id: requestID,
                nodeID: matchedNodeID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
            touch(nodeID: matchedNodeID, now: now)
            touch(conversationID: conversation.id, at: now)
            return AttachResult(
                conversationID: conversation.id,
                nodeID: matchedNodeID,
                createdConversation: createdConversation,
                createdNode: false
            )
        }

        // 6) Partial match — create a new child node with the trimmed-off
        //    suffix as its delta.
        let newNodeID = UUID()
        let newNode = Node(
            id: newNodeID,
            conversationID: conversation.id,
            parentNodeID: preview.matchedNodeID ?? conversation.rootNodeID,
            deltaMessages: preview.deltaMessages,
            cumulativeHash: preview.cumulativeHash,
            lastActivityAt: now,
            deltaMessagesJSONCache: nil
        )
        nodes[newNodeID] = newNode
        childrenByNode[preview.matchedNodeID ?? conversation.rootNodeID, default: []].append(newNodeID)
        nodesByHash[key, default: [:]][newNode.cumulativeHash] = newNodeID
        recordRequest(
            id: requestID,
            nodeID: newNodeID,
            sessionID: sessionID,
            previousResponseID: previousResponseID,
            now: now
        )
        touch(conversationID: conversation.id, at: now)
        return AttachResult(
            conversationID: conversation.id,
            nodeID: newNodeID,
            createdConversation: createdConversation,
            createdNode: true
        )
    }

    // MARK: - Request transitions

    /// Mark a request as terminal. `succeeded == true` indicates the stream
    /// completed cleanly; `false` covers upstream errors, client disconnects,
    /// and incomplete streams alike.
    mutating func finishRequest(
        requestID: UUID,
        succeeded: Bool,
        tokenUsage: TokenUsage?,
        responseID: String?,
        now: Date = Date()
    ) {
        guard var request = requests[requestID] else { return }
        request.finishedAt = now
        request.succeeded = succeeded
        request.tokenUsage = tokenUsage
        if let responseID {
            request.responseID = responseID
            // Only index successful responses as `previous_response_id`
            // parents. A partial / errored turn (Anthropic or OpenAI
            // `response.incomplete`) can still surface a response ID, but we
            // must not let follow-up requests force-link onto an unresolved
            // content state — those fall back to cumulative-hash matching.
            if succeeded {
                responseIDIndex[responseID] = request.nodeID
            }
        }
        requests[requestID] = request
        touch(nodeID: request.nodeID, now: now)
        if let node = nodes[request.nodeID] {
            touch(conversationID: node.conversationID, at: now)
        }
    }

    // MARK: - Displayable requests

    /// A successful request the UI should render in the popover's Done section.
    /// `isPendingReplacement` is true iff the owning node has at least one
    /// descendant node with an in-flight request (so the row should be dimmed
    /// until that descendant either succeeds — at which point this row stops
    /// being displayable — or fails — at which point the flag clears).
    struct DisplayableRequest: Sendable {
        let conversationID: UUID
        let nodeID: UUID
        let requestID: UUID
        let isPendingReplacement: Bool
    }

    /// Every successful request whose node has no descendant node carrying a
    /// successful request. Descendants with only in-flight requests leave the
    /// owner flagged as pending replacement.
    func displayableRequests() -> [DisplayableRequest] {
        var result: [DisplayableRequest] = []
        for (nodeID, node) in nodes {
            let doneRequests = (requestsByNode[nodeID] ?? [])
                .compactMap { requests[$0] }
                .filter { $0.succeeded }
            guard !doneRequests.isEmpty else { continue }
            if subtreeContainsSuccessfulRequest(startingAtChildrenOf: nodeID) {
                continue
            }
            let pending = subtreeContainsInFlightRequest(startingAtChildrenOf: nodeID)
            for req in doneRequests {
                result.append(DisplayableRequest(
                    conversationID: node.conversationID,
                    nodeID: nodeID,
                    requestID: req.id,
                    isPendingReplacement: pending
                ))
            }
        }
        return result
    }

    private func subtreeContainsSuccessfulRequest(startingAtChildrenOf nodeID: UUID) -> Bool {
        var stack = childrenByNode[nodeID] ?? []
        while let current = stack.popLast() {
            let nodeRequests = (requestsByNode[current] ?? []).compactMap { requests[$0] }
            if nodeRequests.contains(where: { $0.succeeded }) { return true }
            stack.append(contentsOf: childrenByNode[current] ?? [])
        }
        return false
    }

    private func subtreeContainsInFlightRequest(startingAtChildrenOf nodeID: UUID) -> Bool {
        var stack = childrenByNode[nodeID] ?? []
        while let current = stack.popLast() {
            let nodeRequests = (requestsByNode[current] ?? []).compactMap { requests[$0] }
            if nodeRequests.contains(where: { $0.finishedAt == nil }) { return true }
            stack.append(contentsOf: childrenByNode[current] ?? [])
        }
        return false
    }

    // MARK: - Lookup helpers

    func conversation(withID id: UUID) -> Conversation? {
        conversations.values.first(where: { $0.id == id })
    }

    /// Walk from root to `nodeID`, returning nodes in root → target order.
    func ancestorChain(for nodeID: UUID) -> [Node] {
        var chain: [Node] = []
        var cursor: UUID? = nodeID
        while let id = cursor, let node = nodes[id] {
            chain.append(node)
            cursor = node.parentNodeID
        }
        return chain.reversed()
    }

    /// Reconstruct the full messages list at a node by walking root → target
    /// and concatenating per-node deltas.
    func reconstructMessages(nodeID: UUID) -> [NormalizedMessage] {
        var result: [NormalizedMessage] = []
        for node in ancestorChain(for: nodeID) {
            result.append(contentsOf: node.deltaMessages)
        }
        return result
    }

    // MARK: - Cached delta JSON

    /// Canonical JSON serialization of a node's `deltaMessages`. Cached on
    /// the node so repeated mirror writes don't re-encode. Returns "[]" for
    /// unknown IDs or empty deltas.
    mutating func cachedDeltaMessagesJSON(for nodeID: UUID) -> String {
        guard var node = nodes[nodeID] else { return "[]" }
        if let cached = node.deltaMessagesJSONCache { return cached }
        let encoded = Self.encodeDeltaMessagesJSON(node.deltaMessages)
        node.deltaMessagesJSONCache = encoded
        nodes[nodeID] = node
        return encoded
    }

    // MARK: - Pruning

    struct PruneResult: Sendable {
        var removedConversationIDs: Set<UUID>
        var removedNodeIDs: Set<UUID>
        var removedRequestIDs: Set<UUID>
    }

    /// Drop terminal requests older than `retention`, then remove whole
    /// conversation trees whose last activity predates the cutoff. Content
    /// nodes are retained while their conversation is active so prefix
    /// matching and `previous_response_id` lineage stay stable even after
    /// individual request rows age out. In-flight requests are never pruned
    /// regardless of age — they finalize on their own schedule via
    /// `finishRequest`.
    mutating func prune(retention: TimeInterval, now: Date = Date()) -> PruneResult {
        var result = PruneResult(removedConversationIDs: [], removedNodeIDs: [], removedRequestIDs: [])
        let cutoff = now.addingTimeInterval(-retention)

        let expiredRequestIDs = requests.compactMap { id, request -> UUID? in
            guard let finishedAt = request.finishedAt, finishedAt < cutoff else { return nil }
            return id
        }

        for id in expiredRequestIDs {
            guard let request = requests.removeValue(forKey: id) else { continue }
            if var list = requestsByNode[request.nodeID] {
                list.removeAll(where: { $0 == id })
                if list.isEmpty {
                    requestsByNode.removeValue(forKey: request.nodeID)
                } else {
                    requestsByNode[request.nodeID] = list
                }
            }
            result.removedRequestIDs.insert(id)
        }

        for (key, conversation) in Array(conversations) {
            guard let root = nodes[conversation.rootNodeID] else {
                conversations.removeValue(forKey: key)
                nodesByHash.removeValue(forKey: key)
                result.removedConversationIDs.insert(conversation.id)
                continue
            }
            guard conversation.lastActivityAt < cutoff else { continue }

            let nodeIDs = subtreeNodeIDs(rootedAt: root.id)
            guard !subtreeContainsInFlightRequest(nodeIDs: nodeIDs) else { continue }

            removeConversationTree(
                key: key,
                conversationID: conversation.id,
                nodeIDs: nodeIDs,
                result: &result
            )
        }

        return result
    }

    // MARK: - Prefix hashing (single-pass, no redundant work)

    /// Hash of the empty prefix (H_0). Serves as the root node's cumulative hash.
    static func emptyPrefixHash() -> String {
        LineageHash.sha256Hex("")
    }

    /// Fold one more message's content hash into the running prefix hash.
    /// H_k = SHA256(H_{k-1} + ":" + msg_k.contentHash).
    static func foldPrefixHash(previous: String, messageContentHash: String) -> String {
        LineageHash.sha256Hex(previous + ":" + messageContentHash)
    }

    /// Compute H_0..H_N for `messages` in one O(N) pass. Each message's
    /// `contentHash` is folded exactly once, so repeated trim-and-match
    /// lookups reuse the array without re-hashing anything.
    static func computePrefixHashes(messages: [NormalizedMessage]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(messages.count + 1)
        var running = emptyPrefixHash()
        result.append(running)
        for message in messages {
            running = foldPrefixHash(previous: running, messageContentHash: message.contentHash)
            result.append(running)
        }
        return result
    }

    // MARK: - Private helpers

    private mutating func resolveOrCreateConversation(
        key: ConversationKey,
        fingerprint: LineageFingerprint,
        now: Date
    ) -> (Conversation, Bool) {
        if let existing = conversations[key] {
            return (existing, false)
        }
        let rootHash = Self.emptyPrefixHash()
        let rootID = UUID()
        let conversationID = UUID()
        let rootNode = Node(
            id: rootID,
            conversationID: conversationID,
            parentNodeID: nil,
            deltaMessages: [],
            cumulativeHash: rootHash,
            lastActivityAt: now,
            deltaMessagesJSONCache: "[]"
        )
        let conversation = Conversation(
            id: conversationID,
            key: key,
            fingerprint: fingerprint,
            rootNodeID: rootID,
            lastActivityAt: now
        )
        nodes[rootID] = rootNode
        conversations[key] = conversation
        nodesByHash[key, default: [:]][rootHash] = rootID
        return (conversation, true)
    }

    private mutating func recordRequest(
        id: UUID,
        nodeID: UUID,
        sessionID: String,
        previousResponseID: String?,
        now: Date
    ) {
        let request = Request(
            id: id,
            nodeID: nodeID,
            sessionID: sessionID,
            previousResponseID: previousResponseID,
            responseID: nil,
            createdAt: now,
            finishedAt: nil,
            succeeded: false,
            tokenUsage: nil
        )
        requests[id] = request
        requestsByNode[nodeID, default: []].append(id)
    }

    private mutating func touch(nodeID: UUID, now: Date) {
        guard var node = nodes[nodeID] else { return }
        node.lastActivityAt = now
        nodes[nodeID] = node
    }

    private mutating func touch(conversationID: UUID, at now: Date) {
        for (key, conversation) in conversations where conversation.id == conversationID {
            var updated = conversation
            updated.lastActivityAt = now
            conversations[key] = updated
            return
        }
    }

    private func subtreeNodeIDs(rootedAt rootID: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var stack = [rootID]
        while let current = stack.popLast() {
            guard result.insert(current).inserted else { continue }
            stack.append(contentsOf: childrenByNode[current] ?? [])
        }
        return result
    }

    private func subtreeContainsInFlightRequest(nodeIDs: Set<UUID>) -> Bool {
        for nodeID in nodeIDs {
            for requestID in requestsByNode[nodeID] ?? [] {
                guard let request = requests[requestID] else { continue }
                if request.finishedAt == nil {
                    return true
                }
            }
        }
        return false
    }

    private mutating func removeConversationTree(
        key: ConversationKey,
        conversationID: UUID,
        nodeIDs: Set<UUID>,
        result: inout PruneResult
    ) {
        for nodeID in nodeIDs {
            for requestID in requestsByNode[nodeID] ?? [] {
                requests.removeValue(forKey: requestID)
                result.removedRequestIDs.insert(requestID)
            }
            requestsByNode.removeValue(forKey: nodeID)
            childrenByNode.removeValue(forKey: nodeID)
            if nodes.removeValue(forKey: nodeID) != nil {
                result.removedNodeIDs.insert(nodeID)
            }
        }

        responseIDIndex = responseIDIndex.filter { !nodeIDs.contains($0.value) }
        nodesByHash.removeValue(forKey: key)
        conversations.removeValue(forKey: key)
        result.removedConversationIDs.insert(conversationID)
    }

    private static func encodeDeltaMessagesJSON(_ messages: [NormalizedMessage]) -> String {
        let array = messages.compactMap { message -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: message.rawJSON) as? [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "[]"
    }
}

// MARK: - Hash helpers

enum LineageHash {
    /// Stable SHA-256 hex of a string. Used as the fingerprint hash inside
    /// `ConversationKey` and as the per-message `contentHash`.
    static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ input: Data) -> String {
        let digest = SHA256.hash(data: input)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
