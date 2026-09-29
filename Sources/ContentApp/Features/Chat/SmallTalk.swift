import Foundation

/// Something said TO the assistant, not a description of something to make.
///
/// Abel, 29 Sep 2026, on the video page: "on the text input bar, you will ask
/// the AI something like 'Hi,' and it will ask you."
///
/// It used to. Then "send is generate" (26 Sep) made the video page submit the
/// job on every send -- and a greeting is a perfectly valid prompt to a video
/// model, so "Hi" would have been made into a video, on somebody's credits. A
/// greeting is not a subject. It goes to the agent instead, which answers the
/// way it always did -- "Sure, what should the video be of?" -- and the next
/// message, the actual idea, is the one that is made.
///
/// Deliberately a short list of exact phrases and not a guess. A guess would
/// eventually eat a real prompt ("sunset" is one word and a fine video); a
/// list only ever catches the things it names.
enum SmallTalk {
    private static let phrases: Set<String> = [
        "hi", "hii", "hiii", "hello", "hey", "heyy", "hiya", "hi there", "hello there",
        "hey there", "yo", "sup", "hola", "salam", "selam", "howdy",
        "good morning", "good afternoon", "good evening", "good night",
        "thanks", "thank you", "thx", "ty", "ok", "okay", "cool", "nice", "wow",
        "test", "testing", "help", "hi how are you", "how are you", "what can you do",
        "who are you", "what is this", "start",
    ]

    /// True for a greeting, a thank-you or a poke -- after stripping the
    /// spec the composer appends ("(5 seconds, 9:16)"), punctuation and case.
    static func matches(_ text: String) -> Bool {
        var body = text
        // The composer's habit of appending its choices on a new line.
        if let opening = body.range(of: "\n(", options: .backwards), body.hasSuffix(")") {
            body = String(body[..<opening.lowerBound])
        }
        // Letters kept, everything else a space, so "Hi!!" and "hi." and
        // "Hi  " are all "hi".
        var kept = ""
        for scalar in body.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                kept.unicodeScalars.append(scalar)
            } else {
                kept.append(" ")
            }
        }
        let cleaned = kept.split(separator: " ").joined(separator: " ")
        return phrases.contains(cleaned)
    }
}
