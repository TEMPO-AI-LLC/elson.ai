import Foundation
import SwiftUI

import MarkdownUI

struct MarkdownMessageView: View {
    private let markdownSource: String

    init(_ text: String) {
        self.markdownSource = MarkdownMessageView.linkifyPlainTextURLs(text)
    }

    var body: some View {
        Markdown(markdownSource)
            .font(.body)
            .foregroundStyle(.primary)
            .tint(.accentColor)
            .textSelection(.enabled)
    }

    private struct ProtectedRanges {
        let fencedCodeBlocks: [Range<String.Index>]
        let inlineCode: [Range<String.Index>]

        func contains(_ index: String.Index) -> Bool {
            fencedCodeBlocks.contains(where: { $0.contains(index) }) || inlineCode.contains(where: { $0.contains(index) })
        }
    }

    private static func linkifyPlainTextURLs(_ text: String) -> String {
        let protected = ProtectedRanges(
            fencedCodeBlocks: fencedCodeBlockRanges(in: text),
            inlineCode: inlineCodeRanges(in: text)
        )

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        guard let detector else { return text }

        let ns = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count + matches.count * 8)

        var cursor = 0

        for match in matches {
            guard let url = match.url else { continue }
            let r = match.range
            guard r.location >= 0, r.length > 0 else { continue }

            if r.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }

            let linkText = ns.substring(with: r)
            let matchStart = text.index(text.startIndex, offsetBy: r.location)
            if protected.contains(matchStart) || isAlreadyMarkdownLinked(text, matchRange: r) {
                result += linkText
            } else {
                let destination = url.absoluteString
                if url.scheme?.lowercased() == "mailto" {
                    result += "[\(linkText)](\(destination))"
                } else {
                    result += "[\(linkText)](<\(destination)>)"
                }
            }

            cursor = r.location + r.length
        }

        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }

        return result
    }

    private static func isAlreadyMarkdownLinked(_ text: String, matchRange: NSRange) -> Bool {
        guard matchRange.location >= 2 else { return false }

        let start = text.index(text.startIndex, offsetBy: matchRange.location)
        let prev1 = text.index(before: start)
        let prev2 = text.index(before: prev1)

        if text[prev1] == "<" { return true }
        if text[prev2] == "]" && text[prev1] == "(" { return true }

        return false
    }

    private static func fencedCodeBlockRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        var fenceStart: String.Index? = nil

        while searchStart < text.endIndex, let fence = text.range(of: "```", range: searchStart..<text.endIndex) {
            if let start = fenceStart {
                let end = fence.upperBound
                ranges.append(start..<end)
                fenceStart = nil
                searchStart = end
            } else {
                fenceStart = fence.lowerBound
                searchStart = fence.upperBound
            }
        }

        if let start = fenceStart {
            ranges.append(start..<text.endIndex)
        }

        return ranges
    }

    private static func inlineCodeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        var start: String.Index? = nil

        while index < text.endIndex {
            if text[index] == "`" {
                if let s = start {
                    let end = text.index(after: index)
                    ranges.append(s..<end)
                    start = nil
                } else {
                    start = index
                }
            }
            index = text.index(after: index)
        }

        if let start {
            ranges.append(start..<text.endIndex)
        }

        return ranges
    }
}
