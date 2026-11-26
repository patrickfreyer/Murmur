import Foundation

/// Turns a dictation into nicely laid-out text without a language model.
///
/// Uses what the recognizer already gives us: punctuation, capitalization and the timing of every
/// word (pauses are where people start new thoughts). Everything here is deterministic and runs in
/// well under a millisecond.
///
///  - Greetings ("Hi Daniel,") get their own line, followed by a blank line.
///  - Sign-offs ("Best, Patrick") become a closing block.
///  - A long pause after a sentence starts a new paragraph.
///  - Three or more sentences starting "First… Second… Third…" become a numbered list.
///  - Spoken commands: "new line", "new paragraph", "bullet point" / "next point".
///  - In single-line fields everything collapses back to one line.
public enum SmartFormatter {
    public struct Options: Sendable {
        /// Silence after a sentence that starts a new paragraph.
        /// Shortest silence after a sentence that the paragraph model will even consider.
        /// Whether it actually breaks is up to `ParagraphModel`.
        public var paragraphPause: TimeInterval = 0.8
        /// Pause-based paragraphs only in dictations at least this long (short messages stay one block).
        public var minWordsForParagraphs = 40
        /// …and only once the current paragraph already has this many sentences.
        public var minSentencesPerParagraph = 2
        /// The text goes into a field that accepts line breaks.
        public var multiline = true
        /// Treat "new line", "new paragraph", "bullet point" as commands.
        public var spokenCommands = true

        public init(paragraphPause: TimeInterval = 0.8, multiline: Bool = true, spokenCommands: Bool = true) {
            self.paragraphPause = paragraphPause
            self.multiline = multiline
            self.spokenCommands = spokenCommands
        }
    }

    // MARK: - Entry points

    /// Formats from timed words (preferred: pauses are available).
    public static func format(words: [Word], options: Options = Options()) -> String {
        var pieces = tokens(from: words)
        if options.spokenCommands { pieces = applyCommands(pieces) }
        let breaks = ParagraphModel.breakIndices(
            pieces, minWords: options.minWordsForParagraphs, minSentences: options.minSentencesPerParagraph,
            minPause: options.paragraphPause)
        var blocks = assemble(pieces, breaks: breaks)
        blocks = splitGreeting(blocks)
        blocks = splitSignOff(blocks)
        blocks = numberedLists(blocks)
        return render(blocks, multiline: options.multiline)
    }

    /// Formats plain text (no timings: no pause-based paragraphs).
    public static func format(text: String, options: Options = Options()) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map {
            Word(text: String($0), start: 0, end: 0, track: .mic)
        }
        return format(words: words, options: options)
    }

    // MARK: - Model

    enum Piece: Equatable {
        case word(String, gapBefore: TimeInterval)
        case lineBreak
        case paragraph
        case bullet
    }

    /// A block is a paragraph, a list item, or a short line (greeting, sign-off name).
    struct Block: Equatable {
        enum Kind: Equatable { case paragraph, bullet, numbered(Int), line }
        var kind: Kind
        var text: String
        /// Keep with the previous block using a single newline (no blank line).
        var tight = false
    }

    static func tokens(from words: [Word]) -> [Piece] {
        var out: [Piece] = []
        var lastEnd: TimeInterval?
        for w in words {
            let gap = lastEnd.map { max(0, w.start - $0) } ?? 0
            out.append(.word(w.text, gapBefore: gap))
            lastEnd = w.end
        }
        return out
    }

    // MARK: - Spoken commands

    static let commands: [([String], Piece)] = [
        (["new", "paragraph"], .paragraph),
        (["next", "paragraph"], .paragraph),
        (["new", "line"], .lineBreak),
        (["next", "line"], .lineBreak),
        (["bullet", "point"], .bullet),
        (["next", "bullet"], .bullet),
        (["next", "point"], .bullet),
        (["neuer", "absatz"], .paragraph),
        (["neue", "zeile"], .lineBreak),
        (["aufzählungspunkt"], .bullet),
    ]

    static func bare(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func applyCommands(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        var i = 0
        outer: while i < pieces.count {
            for (phrase, piece) in commands {
                guard i + phrase.count <= pieces.count else { continue }
                let match = (0..<phrase.count).allSatisfy { k in
                    if case .word(let w, _) = pieces[i + k] { return bare(w) == phrase[k] }
                    return false
                }
                if match {
                    // Drop punctuation the recognizer hung on the word before the command
                    // ("…tomorrow, new line" → "…tomorrow").
                    if let last = out.lastIndex(where: { if case .word = $0 { return true }; return false }),
                        case .word(let w, let g) = out[last], w.last == ","
                    {
                        out[last] = .word(String(w.dropLast()), gapBefore: g)
                    }
                    out.append(piece)
                    i += phrase.count
                    continue outer
                }
            }
            out.append(pieces[i])
            i += 1
        }
        return out
    }

    // MARK: - Paragraphs from pauses

    static func endsSentence(_ w: String) -> Bool {
        guard let c = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)")).last else { return false }
        return ".!?".contains(c)
    }

    static func assemble(_ pieces: [Piece], breaks: Set<Int> = []) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        var previousWord: String?
        var pendingTight = false
        var capitalizeNext = false

        func flush() {
            if var c = current, !c.text.isEmpty {
                c.text = c.text.trimmingCharacters(in: .whitespaces)
                blocks.append(c)
            }
            current = nil
        }

        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .paragraph:
                flush()
                pendingTight = false
                capitalizeNext = true
            case .lineBreak:
                flush()
                pendingTight = true
                capitalizeNext = true
            case .bullet:
                flush()
                // Lists sit directly under their intro line ("Agenda:") and under each other.
                current = Block(kind: .bullet, text: "", tight: !blocks.isEmpty)
                capitalizeNext = true
            case .word(var w, _):
                // The paragraph model decided this word opens a new paragraph.
                if breaks.contains(index), current?.kind == .paragraph { flush() }
                if capitalizeNext || current == nil {
                    w = capitalizedFirst(w)
                    capitalizeNext = false
                }
                if current == nil {
                    current = Block(kind: .paragraph, text: "", tight: pendingTight)
                    pendingTight = false
                }
                current!.text += (current!.text.isEmpty ? "" : " ") + w
                previousWord = w
            }
        }
        flush()
        return blocks.map { b in
            var b = b
            // Spoken bullets rarely end with punctuation the recognizer adds; drop a lone trailing period.
            if b.kind == .bullet, b.text.hasSuffix("."), !b.text.hasSuffix("..") { b.text.removeLast() }
            return b
        }
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter), s[i].isLowercase else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    // MARK: - Greetings and sign-offs

    static let greeting = try! NSRegularExpression(
        pattern: #"^((?:hi|hello|hey|dear|good (?:morning|afternoon|evening)|hallo|hi there|liebe[rs]?|sehr geehrte[rs]?|guten (?:morgen|tag|abend)|moin|servus|bonjour|hola|ciao)(?:\s+[^\s,.!?;:]+){0,4})[,!.:]\s+(.+)$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func splitGreeting(_ blocks: [Block]) -> [Block] {
        guard let first = blocks.first, first.kind == .paragraph else { return blocks }
        let ns = first.text as NSString
        guard let m = greeting.firstMatch(in: first.text, range: NSRange(location: 0, length: ns.length)),
            m.numberOfRanges >= 3
        else { return blocks }
        let salutation = ns.substring(with: m.range(at: 1))
        let rest = ns.substring(with: m.range(at: 2))
        // Only a real letter: the rest must be a full sentence, not "Hi, how are you?".
        guard rest.split(separator: " ").count >= 5 else { return blocks }
        var out = blocks
        out[0] = Block(kind: .line, text: salutation + ",")
        out.insert(Block(kind: .paragraph, text: capitalizedFirst(rest)), at: 1)
        return out
    }

    static let closings = [
        "best regards", "kind regards", "warm regards", "warmest regards", "many thanks", "thanks again",
        "thank you", "all the best", "best wishes", "regards", "best", "thanks", "cheers", "sincerely",
        "talk soon", "see you", "viele grüße", "liebe grüße", "beste grüße", "freundliche grüße",
        "mit freundlichen grüßen", "lg", "vg", "danke",
    ]

    static func splitSignOff(_ blocks: [Block]) -> [Block] {
        guard var last = blocks.last, last.kind == .paragraph else { return blocks }
        let text = last.text
        let lower = text.lowercased()
        // Look for "<closing>, <Name>." or "<closing>." at the very end of the dictation.
        for closing in closings.sorted(by: { $0.count > $1.count }) {
            guard let r = lower.range(of: closing, options: .backwards) else { continue }
            let start = r.lowerBound
            // Must start a sentence (beginning of text or after . ! ?).
            let before = lower[..<start].trimmingCharacters(in: .whitespaces)
            guard before.isEmpty || before.last.map({ ".!?".contains($0) }) == true else { continue }
            let tail = String(text[start...])
            let parts = tail.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).split(
                separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            let closingText = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard closingText.lowercased() == closing else {
                // "Best Patrick" (no comma) — split on the closing itself.
                let after = tail.dropFirst(closing.count).trimmingCharacters(in: CharacterSet(charactersIn: ",. "))
                guard isName(after) else { continue }
                return replaceTail(blocks, keep: String(text[..<start]), closing: String(tail.prefix(closing.count)), name: after)
            }
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ". ")) : ""
            guard name.isEmpty || isName(name) else { continue }
            // A bare closing ("Thanks.") is only a sign-off when the text is clearly a letter.
            if name.isEmpty, blocks.count < 2 && before.isEmpty { return blocks }
            last.text = String(text[..<start])
            let punct = tail.last.map { "!.".contains($0) ? String($0) : "." } ?? "."
            return replaceTail(blocks, keep: last.text, closing: closingText, name: name, closingPunctuation: punct)
        }
        return blocks
    }

    static func isName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        return (1...3).contains(words.count) && words.allSatisfy { $0.first?.isUppercase == true }
    }

    static func replaceTail(
        _ blocks: [Block], keep: String, closing: String, name: String, closingPunctuation: String = "."
    ) -> [Block] {
        var out = Array(blocks.dropLast())
        let body = keep.trimmingCharacters(in: .whitespaces)
        if !body.isEmpty { out.append(Block(kind: .paragraph, text: body)) }
        // "Best,\nPatrick" with a name; a bare closing keeps its own punctuation ("Thanks!").
        out.append(Block(kind: .line, text: capitalizedFirst(closing) + (name.isEmpty ? closingPunctuation : ",")))
        if !name.isEmpty { out.append(Block(kind: .line, text: name, tight: true)) }
        return out
    }

    // MARK: - Numbered lists from "First… Second… Third…"

    static let ordinals: [[String]] = [
        ["first", "firstly", "first of all", "number one", "one", "erstens", "zuerst"],
        ["second", "secondly", "number two", "two", "zweitens"],
        ["third", "thirdly", "number three", "three", "drittens"],
        ["fourth", "fourthly", "number four", "four", "viertens"],
        ["fifth", "fifthly", "number five", "five", "fünftens"],
        ["sixth", "number six", "six", "sechstens"],
    ]
    static let lastOrdinals = ["finally", "lastly", "last", "and finally", "schließlich", "zuletzt"]

    /// Returns the ordinal position (0-based) and the remainder, if the sentence starts with one.
    static func ordinalPrefix(_ sentence: String) -> (Int?, String)? {
        let lower = sentence.lowercased()
        func strip(_ p: String) -> String? {
            guard lower.hasPrefix(p) else { return nil }
            let rest = sentence.dropFirst(p.count)
            guard let c = rest.first, c == "," || c == ":" || c == " " else { return nil }
            return rest.drop(while: { $0 == "," || $0 == ":" || $0 == " " }).description
        }
        for (i, list) in ordinals.enumerated() {
            for p in list.sorted(by: { $0.count > $1.count }) {
                if let r = strip(p) { return (i, r) }
            }
        }
        for p in lastOrdinals.sorted(by: { $0.count > $1.count }) {
            if let r = strip(p) { return (nil, r) }
        }
        return nil
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for w in text.split(separator: " ") {
            current += (current.isEmpty ? "" : " ") + w
            if endsSentence(String(w)) {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func numberedLists(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        for block in blocks {
            guard block.kind == .paragraph else {
                out.append(block)
                continue
            }
            let ss = sentences(block.text)
            // Find a run of sentences that start with consecutive ordinals.
            var runStart: Int?
            var items: [(Int, String)] = []
            var expected = 0
            for (i, s) in ss.enumerated() {
                if let (n, rest) = ordinalPrefix(s), n == expected || (n == nil && expected >= 2) {
                    if runStart == nil { runStart = i }
                    items.append((i, rest))
                    expected += 1
                    if n == nil { break }
                } else if runStart != nil {
                    break
                }
            }
            guard let start = runStart, items.count >= 3 else {
                out.append(block)
                continue
            }
            let end = items.last!.0
            let intro = ss[..<start].joined(separator: " ")
            let outro = ss.count > end + 1 ? ss[(end + 1)...].joined(separator: " ") : ""
            if !intro.isEmpty { out.append(Block(kind: .paragraph, text: intro, tight: block.tight)) }
            for (k, item) in items.enumerated() {
                out.append(Block(kind: .numbered(k + 1), text: capitalizedFirst(item.1), tight: k > 0 || !intro.isEmpty))
            }
            if !outro.isEmpty { out.append(Block(kind: .paragraph, text: outro)) }
        }
        return out
    }

    // MARK: - Rendering

    static func render(_ blocks: [Block], multiline: Bool) -> String {
        guard multiline else {
            return blocks.map { b -> String in
                switch b.kind {
                case .line where b.text.hasSuffix(","): return b.text
                default: return b.text
                }
            }.joined(separator: " ")
        }
        var out = ""
        for (i, b) in blocks.enumerated() {
            let line: String
            switch b.kind {
            case .paragraph, .line: line = b.text
            case .bullet: line = "• " + b.text
            case .numbered(let n): line = "\(n). " + b.text
            }
            if i > 0 {
                let prev = blocks[i - 1].kind
                let listContinues: Bool = {
                    switch (prev, b.kind) {
                    case (.bullet, .bullet), (.numbered, .numbered): return true
                    default: return false
                    }
                }()
                out += (b.tight || listContinues) ? "\n" : "\n\n"
            }
            out += line
        }
        return out
    }
}
