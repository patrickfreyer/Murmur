import Testing
@testable import MurmurCore

@Suite struct SmartFormatterTests {
    /// Builds timed words from text; "|" marks a pause of `pause` seconds before the next word.
    func timed(_ s: String, pause: Double = 2.0) -> [Word] {
        var t = 0.0
        var out: [Word] = []
        for raw in s.split(separator: " ") {
            if raw == "|" { t += pause; continue }
            out.append(Word(text: String(raw), start: t, end: t + 0.3, track: .mic))
            t += 0.35
        }
        return out
    }

    @Test func emailGreetingAndSignOff() {
        let f = SmartFormatter.format(words: timed(
            "Hi Daniel, the migration finished last night. Could you send the invitations tomorrow? Best, Patrick."))
        #expect(f == "Hi Daniel,\n\nThe migration finished last night. Could you send the invitations tomorrow?\n\nBest,\nPatrick")
    }

    @Test func germanGreeting() {
        let f = SmartFormatter.format(text: "Hallo Anna, danke für die schnelle Antwort. Viele Grüße, Patrick.")
        #expect(f == "Hallo Anna,\n\nDanke für die schnelle Antwort.\n\nViele Grüße,\nPatrick")
    }

    @Test func casualGreetingStaysInline() {
        #expect(SmartFormatter.format(text: "Hi, how are you?") == "Hi, how are you?")
        #expect(SmartFormatter.format(text: "Hey Sam, sounds good!") == "Hey Sam, sounds good!")
    }

    @Test func pauseAfterSentenceStartsParagraph() {
        let f = SmartFormatter.format(words: timed("The beta is ready. We ship Thursday. | Separately, the icons are done."))
        #expect(f == "The beta is ready. We ship Thursday.\n\nSeparately, the icons are done.")
    }

    @Test func pauseMidSentenceDoesNotBreak() {
        let f = SmartFormatter.format(words: timed("I think we should | probably wait until Monday."))
        #expect(f == "I think we should probably wait until Monday.")
    }

    @Test func ordinalsBecomeNumberedList() {
        let f = SmartFormatter.format(text:
            "Three things for the launch. First, finish the icons. Second, send the invites. Third, update the website. Thanks!")
        #expect(f == "Three things for the launch.\n1. Finish the icons.\n2. Send the invites.\n3. Update the website.\n\nThanks!")
    }

    @Test func twoOrdinalsAreNotAList() {
        let s = "First, we tested it. Second, it worked."
        #expect(SmartFormatter.format(text: s) == s)
    }

    @Test func spokenCommands() {
        let f = SmartFormatter.format(text: "Shopping list bullet point milk bullet point eggs, bullet point bread.")
        #expect(f == "Shopping list\n• Milk\n• Eggs\n• Bread")
        let g = SmartFormatter.format(text: "Dear team, new paragraph the release is out. New line Patrick")
        #expect(g.contains("\n\nThe release is out.\nPatrick"))
    }

    @Test func singleLineFieldsCollapse() {
        let f = SmartFormatter.format(
            words: timed("Hi Daniel, the build is ready for testing. | Best, Patrick."),
            options: .init(multiline: false))
        #expect(!f.contains("\n"))
        #expect(f.hasPrefix("Hi Daniel, The build"))
    }

    @Test func plainSentenceUnchanged() {
        let s = "Can you send me the updated deck before the call tomorrow?"
        #expect(SmartFormatter.format(text: s) == s)
    }
}
