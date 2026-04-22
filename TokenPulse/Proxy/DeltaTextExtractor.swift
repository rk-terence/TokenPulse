import Foundation

/// Extracts user-authored text from delta messages produced by `ContentTree.previewAttach`.
///
/// Handles both Anthropic Messages and OpenAI Responses JSON shapes without
/// requiring callers to plumb `ProxyAPIFlavor` — the shapes are distinguishable
/// by their keys.
///
/// Only user-role content and tool-result equivalents are scanned. Assistant turns
/// and reasoning items are skipped. Images and non-text blocks are also skipped.
enum DeltaTextExtractor {

    /// Concatenate all user-authored and tool-result text from `messages`.
    /// Returns an empty string if no scannable content is present.
    static func scannableText(from messages: [ContentTree.NormalizedMessage]) -> String {
        var parts: [String] = []
        for message in messages {
            guard let object = try? JSONSerialization.jsonObject(with: message.rawJSON) as? [String: Any] else {
                continue
            }
            extractText(from: object, into: &parts)
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Private

    private static func extractText(from object: [String: Any], into parts: inout [String]) {
        // Determine the shape of this item.
        // Anthropic: {"role": "user"|"assistant", "content": [...]}
        // OpenAI input item: {"type": "message", "role": "user", ...} or
        //                    {"type": "function_call_output", "output": "..."}

        let role = object["role"] as? String
        let itemType = object["type"] as? String

        // --- OpenAI function_call_output item ---
        // {"type": "function_call_output", "output": "..."}
        if itemType == "function_call_output" {
            if let output = object["output"] as? String {
                parts.append(output)
            }
            return
        }

        // --- Skip non-user roles ---
        // For Anthropic messages role == "assistant" should be ignored.
        // For OpenAI input items, skip assistant/reasoning types.
        if let role, role != "user" {
            return
        }
        if let itemType, itemType != "message" {
            // OpenAI items that are not "message" or "function_call_output" — skip.
            return
        }

        // --- Process content array ---
        guard let contentValue = object["content"] else { return }

        if let contentArray = contentValue as? [[String: Any]] {
            for block in contentArray {
                extractBlockText(from: block, into: &parts)
            }
        } else if let contentString = contentValue as? String {
            // Shorthand string content (rare but legal in some API variants)
            parts.append(contentString)
        }
    }

    private static func extractBlockText(from block: [String: Any], into parts: inout [String]) {
        let blockType = block["type"] as? String

        // Anthropic text block: {"type": "text", "text": "..."}
        if blockType == "text" {
            if let text = block["text"] as? String {
                parts.append(text)
            }
            return
        }

        // Anthropic tool_result block: {"type": "tool_result", "content": string | [...]}
        if blockType == "tool_result" {
            if let innerString = block["content"] as? String {
                parts.append(innerString)
            } else if let innerArray = block["content"] as? [[String: Any]] {
                for inner in innerArray {
                    if inner["type"] as? String == "text", let text = inner["text"] as? String {
                        parts.append(text)
                    }
                }
            }
            return
        }

        // OpenAI input_text block: {"type": "input_text", "text": "..."}
        if blockType == "input_text" {
            if let text = block["text"] as? String {
                parts.append(text)
            }
            return
        }

        // All other block types (images, audio, etc.) — skip.
    }
}
