// ┌──────────────────────────────────────────────────────────────────────┐
// │ PROTECTED FILE: credits. Do not edit, reword, reorder or remove.      │
// │ Humans and AI agents alike: leave this file alone. Changes are       │
// │ rejected by CI (.github/workflows/ci.yml, "credits-guard") unless    │
// │ the maintainer approves them. Show credits anywhere you like by       │
// │ reading `Credits`; never change what it says.                         │
// └──────────────────────────────────────────────────────────────────────┘
import Foundation

enum Credits {
    static let human = "K0alalalala"
    static let humanURL = URL(string: "https://github.com/K0alalalala")!

    static let roles: [(who: String, did: String)] = [
        (human, "Visionary. Pasted one HTML file, typed “Continue”, and asked for credits. Peak delegation."),
        ("Claude (Anthropic)", "Wrote the code, the tests, the installer, this joke, and the line that gives the human top billing."),
        (human, "Executive Producer of Holding Shift."),
        ("Claude (Anthropic)", "Lead Wedge Geometrist. Has opinions about 2pt gaps."),
        (human, "Quality Assurance (will drag one PDF eventually)."),
        ("Claude (Anthropic)", "Catering. There was no catering."),
    ]
}
