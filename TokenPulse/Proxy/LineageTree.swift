import CryptoKit
import Foundation

/// In-memory lineage tree that tracks the conversation structure of every
/// proxied request whose body carries a messages-style stack (or, for
/// OpenAI Responses, a `previous_response_id`).
///
/// A tree is rooted at a `Conversation` (one per unique cache-identity
/// fingerprint) and grows by appending descendants; nodes are never
/// re-parented. Segments hold a non-branching run of normalized messages
/// so that a 50-turn conversation needs only one segment in memory and
/// one row in SQLite.
///
/// This type is a value-semantic struct that must be owned by an actor
/// (`ProxySessionStore`) so mutations are serialized. It is pure Swift
/// and has no I/O side effects — callers are responsible for mirroring
/// changes to SQLite via `ProxyEventLogger`.
struct LineageTree: Sendable {

    // MARK: - Conversation

    struct ConversationKey: Hashable, Sendable {
        let flavor: ProxyAPIFlavor
        let fingerprintHash: String
    }

    /// A conversation is the tree root. Beyond the routing key, it also owns the
    /// full `LineageFingerprint` so downstream callers (UI rows, SQLite mirror,
    /// future keep-alive replay) never need to carry model/system/tools through
    /// per-request activity state — they ask the conversation instead.
    struct Conversation: Sendable {
        let id: UUID
        let key: ConversationKey
        let fingerprint: LineageFingerprint
        let rootSegmentID: UUID
        var lastActivityAt: Date
    }

    // MARK: - Normalized message

    /// A message after stripping transient markers (cache_control, ephemeral, etc.).
    /// `contentHash` is the canonical SHA256 used for prefix comparison; `rawJSON`
    /// is the normalized JSON kept for payload reconstruction.
    struct NormalizedMessage: Sendable, Equatable {
        let role: String
        let contentHash: String
        let rawJSON: Data
    }

    // MARK: - Segment

    /// A non-branching run of messages. Segments grow in place when a
    /// descendant extends the current leaf; branching creates a new
    /// segment whose parent is the existing segment at `parentSplitIndex`.
    struct Segment: Sendable {
        let id: UUID
        let conversationID: UUID
        let parentSegmentID: UUID?
        /// Index in the parent segment where this segment branches off.
        /// `-1` for the conversation's root segment.
        let parentSplitIndex: Int
        var messages: [NormalizedMessage]
        /// Requests whose tail lands somewhere inside this segment, sorted by `tailIndex`.
        var nodes: [Node]
        var lastActivityAt: Date
        /// Cached canonical JSON serialization of `messages`. Populated lazily by
        /// `cachedMessagesJSON(for:)` and invalidated whenever `messages` mutates
        /// (only `extendOrBranch`'s in-place extension path does that).
        var messagesJSONCache: String?
    }

    // MARK: - Node (one recorded request)

    struct Node: Sendable {
        let requestID: UUID
        /// Inclusive index into the segment's `messages` array — the last message this
        /// request sent. For OpenAI-linked nodes without a messages body this may still
        /// be set from the parent's tail.
        let tailIndex: Int
        /// Anthropic `msg_*` or OpenAI `resp_*` returned by upstream once known.
        var responseID: String?
        /// OpenAI `previous_response_id` from the request body, if any.
        let previousResponseID: String?
        var done: Bool
        let createdAt: Date
        var doneAt: Date?
        var tokenUsage: TokenUsage?
        /// Anthropic-style session ID (e.g. `X-Claude-Code-Session-Id`) or
        /// OpenAI `session_id` header, for UI grouping. Decoupled from the
        /// conversation (which is keyed by fingerprint, not session).
        let sessionID: String
    }

    // MARK: - State

    /// Conversations keyed by their stable conversation key.
    private(set) var conversations: [ConversationKey: Conversation] = [:]
    /// Every segment, indexed by UUID for O(1) lookup.
    private(set) var segments: [UUID: Segment] = [:]
    /// Map from request UUID to its location (segment + index into `Segment.nodes`).
    private(set) var nodeLocations: [UUID: (segmentID: UUID, nodeIndex: Int)] = [:]
    /// Map from upstream response ID (when known) to the owning request UUID.
    /// Enables OpenAI `previous_response_id` linkage.
    private(set) var responseIDIndex: [String: UUID] = [:]

    // MARK: - Attach

    /// Result of attaching a request to the tree.
    struct AttachResult: Sendable {
        let conversationID: UUID
        let segmentID: UUID
        let tailIndex: Int
        /// Whether this attach created a new conversation root.
        let createdConversation: Bool
        /// Whether this attach created a new segment (branch or first segment in a conversation).
        let createdSegment: Bool
        /// Messages that were appended to the segment as part of this attach (could be empty
        /// when a duplicate prefix matches an existing segment tail exactly).
        let appendedMessages: [NormalizedMessage]
    }

    /// Record a new request in the tree. Called the moment upstream returns 2xx.
    ///
    /// - Parameters:
    ///   - requestID: Unique identifier for the request.
    ///   - sessionID: UI grouping key (session header prefix); does not affect tree shape.
    ///   - fingerprint: Full cache-identity fingerprint. Persisted on the conversation the
    ///     first time it is seen; reused as the routing key (`fingerprint.conversationKey`).
    ///   - messages: Normalized messages carried by the request body. Empty when the
    ///     provider used `previous_response_id` alone (OpenAI path).
    ///   - previousResponseID: OpenAI `previous_response_id`, if any.
    ///   - now: Timestamp injected for deterministic testing.
    mutating func attach(
        requestID: UUID,
        sessionID: String,
        fingerprint: LineageFingerprint,
        messages: [NormalizedMessage],
        previousResponseID: String?,
        now: Date = Date()
    ) -> AttachResult {
        let key = fingerprint.conversationKey
        // 1) OpenAI `previous_response_id` path — forced parent linkage.
        if messages.isEmpty,
           let previousResponseID,
           let ownerRequestID = responseIDIndex[previousResponseID],
           let ownerLocation = nodeLocations[ownerRequestID],
           let ownerSegment = segments[ownerLocation.segmentID] {
            let ownerNode = ownerSegment.nodes[ownerLocation.nodeIndex]
            let result = extendOrBranch(
                conversationID: ownerSegment.conversationID,
                parentSegmentID: ownerSegment.id,
                parentTailIndex: ownerNode.tailIndex,
                newMessages: [],
                requestID: requestID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
            touchConversation(id: ownerSegment.conversationID, at: now)
            return AttachResult(
                conversationID: ownerSegment.conversationID,
                segmentID: result.segmentID,
                tailIndex: result.tailIndex,
                createdConversation: false,
                createdSegment: result.createdSegment,
                appendedMessages: result.appendedMessages
            )
        }

        // 2) Resolve (or create) the conversation.
        if let existing = conversations[key] {
            let result = attachToConversation(
                conversation: existing,
                messages: messages,
                requestID: requestID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
            touchConversation(id: existing.id, at: now)
            return AttachResult(
                conversationID: existing.id,
                segmentID: result.segmentID,
                tailIndex: result.tailIndex,
                createdConversation: false,
                createdSegment: result.createdSegment,
                appendedMessages: result.appendedMessages
            )
        }

        // 3) Brand-new conversation — create root segment seeded with the full messages list.
        //    When `messages` is empty (OpenAI `previous_response_id` path where the
        //    pointed-at response is no longer resolvable in memory, e.g. after a
        //    restart or prune), we still need the request to become a tracked node
        //    so completion and mirror logging work. The node sits at tailIndex=-1
        //    (pre-first-message) so `reconstructMessages` returns [].
        let conversationID = UUID()
        let rootSegmentID = UUID()
        let rootTailIndex = messages.isEmpty ? -1 : messages.count - 1
        let rootNode = Node(
            requestID: requestID,
            tailIndex: rootTailIndex,
            responseID: nil,
            previousResponseID: previousResponseID,
            done: false,
            createdAt: now,
            doneAt: nil,
            tokenUsage: nil,
            sessionID: sessionID
        )
        let rootSegment = Segment(
            id: rootSegmentID,
            conversationID: conversationID,
            parentSegmentID: nil,
            parentSplitIndex: -1,
            messages: messages,
            nodes: [rootNode],
            lastActivityAt: now,
            messagesJSONCache: nil
        )
        segments[rootSegmentID] = rootSegment
        nodeLocations[requestID] = (rootSegmentID, 0)
        conversations[key] = Conversation(
            id: conversationID,
            key: key,
            fingerprint: fingerprint,
            rootSegmentID: rootSegmentID,
            lastActivityAt: now
        )
        return AttachResult(
            conversationID: conversationID,
            segmentID: rootSegmentID,
            tailIndex: rootTailIndex,
            createdConversation: true,
            createdSegment: true,
            appendedMessages: messages
        )
    }

    // MARK: - Done transition

    /// Mark a node as done (response fully received). Subsequent descendants may attach to it.
    mutating func markDone(
        requestID: UUID,
        tokenUsage: TokenUsage?,
        responseID: String?,
        now: Date = Date()
    ) {
        guard let location = nodeLocations[requestID] else { return }
        guard var segment = segments[location.segmentID] else { return }
        var node = segment.nodes[location.nodeIndex]
        node.done = true
        node.doneAt = now
        node.tokenUsage = tokenUsage
        if let responseID {
            node.responseID = responseID
            responseIDIndex[responseID] = requestID
        }
        segment.nodes[location.nodeIndex] = node
        segment.lastActivityAt = now
        segments[location.segmentID] = segment
        touchConversation(id: segment.conversationID, at: now)
    }

    // MARK: - Leaf query

    /// Look up a conversation by its UUID. Used by the UI and SQLite mirror to
    /// resolve a node back to its `LineageFingerprint` (model / system / tools).
    func conversation(withID id: UUID) -> Conversation? {
        for conversation in conversations.values where conversation.id == id {
            return conversation
        }
        return nil
    }

    /// A done-true node considered *displayable* in the popup.
    ///
    /// - `isPendingReplacement == false`: the node is a true leaf — no descendant
    ///   exists at all. It represents the current state of the conversation.
    /// - `isPendingReplacement == true`: the node has at least one `done == false`
    ///   descendant (a new active request extended from it) but no `done == true`
    ///   descendant yet. We still show the node — the new active request hasn't
    ///   produced a result — but the UI dims it to signal "about to be replaced".
    struct DisplayableLeaf: Sendable {
        let conversationID: UUID
        let requestID: UUID
        let isPendingReplacement: Bool
    }

    /// Return every done-true node that has no done-true descendant anywhere
    /// below it. Nodes with `done=false` descendants are flagged as pending.
    /// Callers drive popup rendering from this result.
    func displayableDoneLeaves() -> [DisplayableLeaf] {
        var result: [DisplayableLeaf] = []
        for segment in segments.values {
            for (index, node) in segment.nodes.enumerated() where node.done {
                if hasDoneTrueDescendant(of: node, atIndex: index, inSegment: segment) {
                    continue
                }
                let pending = hasAnyDescendant(of: node, atIndex: index, inSegment: segment)
                result.append(
                    DisplayableLeaf(
                        conversationID: segment.conversationID,
                        requestID: node.requestID,
                        isPendingReplacement: pending
                    )
                )
            }
        }
        return result
    }

    /// Legacy accessor retained for pruning: only true leaves with no descendants.
    /// Pruning still targets these (pending nodes are kept alive because their
    /// `done=false` descendant is by invariant itself a leaf that holds activity).
    private func isStrictLeaf(
        node: Node,
        atIndex index: Int,
        inSegment segment: Segment
    ) -> Bool {
        if index < segment.nodes.count - 1 {
            return false
        }
        for candidate in segments.values where candidate.parentSegmentID == segment.id {
            if candidate.parentSplitIndex >= node.tailIndex {
                return false
            }
        }
        return true
    }

    /// Any done-true node that descends from `node` (either further along the
    /// same segment or in any child segment branching at or after `node.tailIndex`).
    private func hasDoneTrueDescendant(
        of node: Node,
        atIndex index: Int,
        inSegment segment: Segment
    ) -> Bool {
        var nextIndex = index + 1
        while nextIndex < segment.nodes.count {
            if segment.nodes[nextIndex].done { return true }
            nextIndex += 1
        }
        for child in segments.values
        where child.parentSegmentID == segment.id && child.parentSplitIndex >= node.tailIndex {
            if subtreeContainsDoneTrueNode(child.id) {
                return true
            }
        }
        return false
    }

    private func subtreeContainsDoneTrueNode(_ segmentID: UUID) -> Bool {
        guard let segment = segments[segmentID] else { return false }
        for node in segment.nodes where node.done {
            return true
        }
        for child in segments.values where child.parentSegmentID == segmentID {
            if subtreeContainsDoneTrueNode(child.id) { return true }
        }
        return false
    }

    /// Whether any descendant node exists below `node` (regardless of done state).
    private func hasAnyDescendant(
        of node: Node,
        atIndex index: Int,
        inSegment segment: Segment
    ) -> Bool {
        if index < segment.nodes.count - 1 { return true }
        for child in segments.values
        where child.parentSegmentID == segment.id && child.parentSplitIndex >= node.tailIndex {
            return true
        }
        return false
    }

    // MARK: - Pruning

    /// Result of a prune pass: IDs of segments and conversations removed,
    /// plus the request IDs whose nodes were deleted. Callers use this to mirror deletions to SQLite.
    struct PruneResult: Sendable {
        var removedSegmentIDs: Set<UUID>
        var removedConversationIDs: Set<UUID>
        var removedRequestIDs: Set<UUID>
    }

    /// Prune leaves whose most recent activity is older than `retention` seconds,
    /// cascading upward through now-empty segments and then conversations.
    mutating func prune(retention: TimeInterval, now: Date = Date()) -> PruneResult {
        var result = PruneResult(
            removedSegmentIDs: [],
            removedConversationIDs: [],
            removedRequestIDs: []
        )
        let cutoff = now.addingTimeInterval(-retention)

        // Repeatedly walk leaves and prune until a fixed point is reached.
        // Branching is rare; typical fixed point is reached in 1–2 passes.
        var changed = true
        while changed {
            changed = false

            // 1) Prune leaf nodes that are older than the cutoff.
            for (segmentID, segment) in segments {
                var survivingNodes: [Node] = []
                survivingNodes.reserveCapacity(segment.nodes.count)
                for (index, node) in segment.nodes.enumerated() {
                    let isTerminal = isStrictLeaf(node: node, atIndex: index, inSegment: segment)
                    let referenceTime = node.doneAt ?? node.createdAt
                    if isTerminal && referenceTime < cutoff {
                        nodeLocations.removeValue(forKey: node.requestID)
                        if let responseID = node.responseID {
                            responseIDIndex.removeValue(forKey: responseID)
                        }
                        result.removedRequestIDs.insert(node.requestID)
                        changed = true
                    } else {
                        survivingNodes.append(node)
                    }
                }
                if survivingNodes.count != segment.nodes.count {
                    var updated = segment
                    updated.nodes = survivingNodes
                    segments[segmentID] = updated
                }
            }

            // 2) Drop non-root segments that have no nodes AND no child segments.
            let segmentIDsWithChildren: Set<UUID> = Set(segments.values.compactMap { $0.parentSegmentID })
            let rootSegmentIDs: Set<UUID> = Set(conversations.values.map { $0.rootSegmentID })
            for (segmentID, segment) in segments where segment.nodes.isEmpty && !segmentIDsWithChildren.contains(segmentID) {
                guard !rootSegmentIDs.contains(segmentID) else { continue }
                segments.removeValue(forKey: segmentID)
                result.removedSegmentIDs.insert(segmentID)
                changed = true
            }

            // 3) Drop conversations whose root segment is empty AND has no live children.
            for (key, conversation) in conversations {
                guard let root = segments[conversation.rootSegmentID] else {
                    conversations.removeValue(forKey: key)
                    result.removedConversationIDs.insert(conversation.id)
                    changed = true
                    continue
                }
                let hasChildren = segments.values.contains(where: { $0.parentSegmentID == root.id })
                if root.nodes.isEmpty && !hasChildren {
                    segments.removeValue(forKey: root.id)
                    result.removedSegmentIDs.insert(root.id)
                    conversations.removeValue(forKey: key)
                    result.removedConversationIDs.insert(conversation.id)
                    changed = true
                }
            }
        }

        return result
    }

    // MARK: - Cached messages JSON

    /// Canonical JSON serialization of the segment's messages array, cached on
    /// the segment to amortize repeated mirror writes. First call after any
    /// mutation (or initial population) serializes once; subsequent calls hit
    /// the cache. Returns "[]" for unknown segment IDs.
    mutating func cachedMessagesJSON(for segmentID: UUID) -> String {
        guard var segment = segments[segmentID] else { return "[]" }
        if let cached = segment.messagesJSONCache {
            return cached
        }
        let encoded = Self.encodeMessagesJSON(segment.messages)
        segment.messagesJSONCache = encoded
        segments[segmentID] = segment
        return encoded
    }

    private static func encodeMessagesJSON(_ messages: [NormalizedMessage]) -> String {
        let array = messages.compactMap { message -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: message.rawJSON) as? [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "[]"
    }

    // MARK: - Path reconstruction (for SQLite reads / diagnostics)

    /// Walk the parent chain of `segmentID` and concatenate the prefix up to `tailIndex`,
    /// returning the full messages list for that node.
    func reconstructMessages(segmentID: UUID, tailIndex: Int) -> [NormalizedMessage]? {
        guard let segment = segments[segmentID] else { return nil }
        var result: [NormalizedMessage] = []
        if let parentID = segment.parentSegmentID {
            let parentMessages = reconstructMessages(
                segmentID: parentID,
                tailIndex: segment.parentSplitIndex
            )
            if let parentMessages {
                result = parentMessages
            }
        }
        let safeTail = min(max(-1, tailIndex), segment.messages.count - 1)
        if safeTail >= 0 {
            result.append(contentsOf: segment.messages[0...safeTail])
        }
        return result
    }

    // MARK: - Private helpers

    private mutating func touchConversation(id: UUID, at now: Date) {
        for (key, conversation) in conversations where conversation.id == id {
            var updated = conversation
            updated.lastActivityAt = now
            conversations[key] = updated
            return
        }
    }

    private func conversationRootSegmentID(for conversationID: UUID) -> UUID? {
        for conversation in conversations.values where conversation.id == conversationID {
            return conversation.rootSegmentID
        }
        return nil
    }

    private struct ExtendResult {
        let segmentID: UUID
        let tailIndex: Int
        let createdSegment: Bool
        let appendedMessages: [NormalizedMessage]
    }

    private mutating func attachToConversation(
        conversation: Conversation,
        messages: [NormalizedMessage],
        requestID: UUID,
        sessionID: String,
        previousResponseID: String?,
        now: Date
    ) -> ExtendResult {
        guard !messages.isEmpty else {
            // Empty messages and no resolvable previous_response_id — degenerate attach.
            // Treat as a zero-length node at the root tail.
            guard let root = segments[conversation.rootSegmentID] else {
                // Shouldn't happen; fabricate a fresh root.
                return seedConversationRoot(
                    conversationID: conversation.id,
                    messages: [],
                    requestID: requestID,
                    sessionID: sessionID,
                    previousResponseID: previousResponseID,
                    now: now
                )
            }
            return appendNodeToSegment(
                segmentID: root.id,
                tailIndex: max(-1, root.messages.count - 1),
                requestID: requestID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
        }

        // Find the closest done-true ancestor whose messages form a proper prefix.
        if let best = findClosestDoneAncestor(conversationID: conversation.id, messages: messages) {
            return extendOrBranch(
                conversationID: conversation.id,
                parentSegmentID: best.segmentID,
                parentTailIndex: best.tailIndex,
                newMessages: Array(messages[(best.tailIndex + 1)...]),
                requestID: requestID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
        }

        // No ancestor — attach at root or branch from root's split index -1.
        return extendOrBranch(
            conversationID: conversation.id,
            parentSegmentID: conversation.rootSegmentID,
            parentTailIndex: -1,
            newMessages: messages,
            requestID: requestID,
            sessionID: sessionID,
            previousResponseID: previousResponseID,
            now: now
        )
    }

    private mutating func seedConversationRoot(
        conversationID: UUID,
        messages: [NormalizedMessage],
        requestID: UUID,
        sessionID: String,
        previousResponseID: String?,
        now: Date
    ) -> ExtendResult {
        let rootID = UUID()
        let segment = Segment(
            id: rootID,
            conversationID: conversationID,
            parentSegmentID: nil,
            parentSplitIndex: -1,
            messages: messages,
            nodes: [],
            lastActivityAt: now,
            messagesJSONCache: nil
        )
        segments[rootID] = segment
        return appendNodeToSegment(
            segmentID: rootID,
            tailIndex: max(-1, messages.count - 1),
            requestID: requestID,
            sessionID: sessionID,
            previousResponseID: previousResponseID,
            now: now
        )
    }

    /// Extend an existing segment in place, or create a new child segment for a branch.
    private mutating func extendOrBranch(
        conversationID: UUID,
        parentSegmentID: UUID,
        parentTailIndex: Int,
        newMessages: [NormalizedMessage],
        requestID: UUID,
        sessionID: String,
        previousResponseID: String?,
        now: Date
    ) -> ExtendResult {
        guard var parent = segments[parentSegmentID] else {
            // Parent vanished — fabricate a new root under conversation.
            return seedConversationRoot(
                conversationID: conversationID,
                messages: newMessages,
                requestID: requestID,
                sessionID: sessionID,
                previousResponseID: previousResponseID,
                now: now
            )
        }

        let extensionStart = parentTailIndex + 1
        let canExtendInPlace =
            extensionStart == parent.messages.count &&
            !hasChildSegment(ofParent: parentSegmentID, atOrAfter: extensionStart) &&
            !hasNode(inSegment: parent, afterIndex: parentTailIndex)

        if canExtendInPlace {
            // Extend the segment's messages (if any) and append a new node at the new tail.
            parent.messages.append(contentsOf: newMessages)
            if !newMessages.isEmpty {
                parent.messagesJSONCache = nil
            }
            parent.lastActivityAt = now
            segments[parentSegmentID] = parent
            let newTailIndex = parent.messages.count - 1
            let finalTailIndex = newMessages.isEmpty ? parentTailIndex : newTailIndex
            let node = Node(
                requestID: requestID,
                tailIndex: finalTailIndex,
                responseID: nil,
                previousResponseID: previousResponseID,
                done: false,
                createdAt: now,
                doneAt: nil,
                tokenUsage: nil,
                sessionID: sessionID
            )
            parent.nodes.append(node)
            parent.lastActivityAt = now
            segments[parentSegmentID] = parent
            nodeLocations[requestID] = (parentSegmentID, parent.nodes.count - 1)
            return ExtendResult(
                segmentID: parentSegmentID,
                tailIndex: finalTailIndex,
                createdSegment: false,
                appendedMessages: newMessages
            )
        }

        // Branch: create a new child segment.
        let childID = UUID()
        let childTailIndex = max(-1, newMessages.count - 1)
        let childNode = Node(
            requestID: requestID,
            tailIndex: childTailIndex,
            responseID: nil,
            previousResponseID: previousResponseID,
            done: false,
            createdAt: now,
            doneAt: nil,
            tokenUsage: nil,
            sessionID: sessionID
        )
        let child = Segment(
            id: childID,
            conversationID: conversationID,
            parentSegmentID: parentSegmentID,
            parentSplitIndex: parentTailIndex,
            messages: newMessages,
            nodes: [childNode],
            lastActivityAt: now,
            messagesJSONCache: nil
        )
        segments[childID] = child
        nodeLocations[requestID] = (childID, 0)
        return ExtendResult(
            segmentID: childID,
            tailIndex: childNode.tailIndex,
            createdSegment: true,
            appendedMessages: newMessages
        )
    }

    private mutating func appendNodeToSegment(
        segmentID: UUID,
        tailIndex: Int,
        requestID: UUID,
        sessionID: String,
        previousResponseID: String?,
        now: Date
    ) -> ExtendResult {
        guard var segment = segments[segmentID] else {
            return ExtendResult(segmentID: segmentID, tailIndex: tailIndex, createdSegment: false, appendedMessages: [])
        }
        let node = Node(
            requestID: requestID,
            tailIndex: tailIndex,
            responseID: nil,
            previousResponseID: previousResponseID,
            done: false,
            createdAt: now,
            doneAt: nil,
            tokenUsage: nil,
            sessionID: sessionID
        )
        segment.nodes.append(node)
        segment.lastActivityAt = now
        segments[segmentID] = segment
        nodeLocations[requestID] = (segmentID, segment.nodes.count - 1)
        return ExtendResult(segmentID: segmentID, tailIndex: tailIndex, createdSegment: false, appendedMessages: [])
    }

    private func hasChildSegment(ofParent parentID: UUID, atOrAfter index: Int) -> Bool {
        for segment in segments.values
        where segment.parentSegmentID == parentID && segment.parentSplitIndex >= index {
            return true
        }
        return false
    }

    private func hasNode(inSegment segment: Segment, afterIndex index: Int) -> Bool {
        segment.nodes.contains(where: { $0.tailIndex > index })
    }

    /// Ancestor search: walk the tree for the done-true node whose `tailIndex` corresponds
    /// to the longest prefix of `messages` matching a path through the tree.
    private func findClosestDoneAncestor(
        conversationID: UUID,
        messages: [NormalizedMessage]
    ) -> (segmentID: UUID, tailIndex: Int)? {
        guard let rootSegmentID = conversationRootSegmentID(for: conversationID),
              let root = segments[rootSegmentID] else {
            return nil
        }
        return bestAncestor(
            inSegment: root,
            prefixLength: 0,
            messages: messages
        )
    }

    /// Recursive descent: given the current segment and how many messages of the incoming
    /// request have already been matched in ancestor segments, find the deepest done-true
    /// node whose tail aligns with a prefix of the incoming messages.
    private func bestAncestor(
        inSegment segment: Segment,
        prefixLength: Int,
        messages: [NormalizedMessage]
    ) -> (segmentID: UUID, tailIndex: Int)? {
        // How far can incoming messages match this segment's messages starting at index 0?
        var matchLen = 0
        while matchLen < segment.messages.count
              && prefixLength + matchLen < messages.count
              && segment.messages[matchLen].contentHash == messages[prefixLength + matchLen].contentHash {
            matchLen += 1
        }

        // Find the deepest done-true node in this segment that lies within the matched prefix
        // AND whose next message is still to come in `messages` (i.e., tailIndex < messages.count-1-prefixLength).
        var best: (segmentID: UUID, tailIndex: Int)?
        for node in segment.nodes where node.done {
            // The node's tail must be within the match AND the incoming request must have
            // at least one more message beyond it (strict prefix).
            if node.tailIndex < matchLen && prefixLength + node.tailIndex + 1 <= messages.count {
                // Deeper = better; matchLen inside same segment strictly increases with tailIndex.
                best = (segment.id, node.tailIndex)
            }
        }

        // Recurse into child segments whose split point is within the matched prefix.
        for child in segments.values
        where child.parentSegmentID == segment.id && child.parentSplitIndex < matchLen {
            // A child segment that branches at index `parentSplitIndex` continues with the
            // incoming messages starting at `prefixLength + parentSplitIndex + 1`.
            let childPrefixLength = prefixLength + child.parentSplitIndex + 1
            if childPrefixLength > messages.count { continue }
            if let candidate = bestAncestor(
                inSegment: child,
                prefixLength: childPrefixLength,
                messages: messages
            ) {
                if let current = best {
                    // Prefer the candidate whose absolute match depth is greater.
                    let candidateDepth = depthOf(segmentID: candidate.segmentID, tailIndex: candidate.tailIndex)
                    let currentDepth = depthOf(segmentID: current.segmentID, tailIndex: current.tailIndex)
                    if candidateDepth > currentDepth {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }
        }

        return best
    }

    /// Absolute depth (messages-from-root) of a given node position.
    private func depthOf(segmentID: UUID, tailIndex: Int) -> Int {
        guard let segment = segments[segmentID] else { return 0 }
        var depth = tailIndex + 1
        var cursorParentID = segment.parentSegmentID
        var cursorSplitIndex = segment.parentSplitIndex
        while let parentID = cursorParentID, let parent = segments[parentID] {
            depth += cursorSplitIndex + 1
            cursorParentID = parent.parentSegmentID
            cursorSplitIndex = parent.parentSplitIndex
        }
        return depth
    }
}

// MARK: - Hash helpers

enum LineageHash {
    /// Stable SHA256 hex of a string. Used as the fingerprint hash inside `ConversationKey`.
    static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Stable SHA256 hex of raw bytes.
    static func sha256Hex(_ input: Data) -> String {
        let digest = SHA256.hash(data: input)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
