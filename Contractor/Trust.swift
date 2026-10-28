import Foundation

struct FeeSchedule: Codable, Equatable {
    /// Flat platform fee. The contractor receives the rest, before any separately disclosed processing cost.
    var percent: Int = 5

    static let launch = FeeSchedule()

    var standardPercent: Int { percent }
    var repeatPercent: Int { percent }
    var minimumCents: Int { 0 }

    var processingNote: String {
        "Card processing is $0 in this demo. A live Stripe charge shows any processing cost before you confirm. The 5% platform fee is separate."
    }

    private enum CodingKeys: String, CodingKey {
        case percent
        case standardPercent
    }

    init(percent: Int = 5) {
        self.percent = percent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let percent = try container.decodeIfPresent(Int.self, forKey: .percent) {
            self.percent = percent
        } else {
            self.percent = 5
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(percent, forKey: .percent)
    }
}

struct PlatformCharge: Codable, Equatable {
    /// The customer pays the quote price in the app.
    var amountCents: Int
    /// Kept by the platform before the pro is paid.
    var applicationFeeCents: Int
    var proPayoutCents: Int
    var currency: String
    /// `authorized`, `captured`, `failed`, `refunded`, or `canceled`. The demo records `authorized` and does not capture.
    var status: String
    /// The pro's Stripe Connect account. Empty until Stripe onboarding is live.
    var connectedAccountID: String
    /// Separately disclosed card-processing cost. Zero until Stripe reports one.
    var processingCents: Int = 0
}

enum ContactFilter {
    static let replacement = "[hidden until booking]"
    static let notice = "Phone numbers, emails, and links stay hidden until this job is booked and the payment is authorized in the app."

    static func display(_ text: String, unlocked: Bool) -> (text: String, masked: Bool) {
        if unlocked { return (text, false) }
        let ranges = matches(in: text)
        guard !ranges.isEmpty else { return (text, false) }
        return (replacing(ranges, in: text), true)
    }

    static func matches(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        let patterns = [
            #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            #"(https?://|www\.)\S+"#,
            #"\b[a-z0-9\-]+\.(com|net|org|io|co|me|app)\b\S*"#,
            #"(?:\+?1[\s.\-]?)?(?:\(?\d{3}\)?[\s.\-]?)\d{3}[\s.\-]?\d{4}"#,
            #"(?<![A-Za-z0-9])@[A-Za-z0-9_.]{3,}"#,
            #"\b(text me|call me|email me|e-mail me|my number|reach me|hit me up|dm me|whatsapp|telegram|venmo|cash ?app|paypal|signal me|off[- ]app|off the app|pay me direct|facebook|instagram|snapchat|tiktok)\b"#,
        ]
        for pattern in patterns {
            found.append(contentsOf: regexRanges(pattern, in: text))
        }
        found.append(contentsOf: regexRanges(spelledDigits, in: text))
        return merge(found)
    }

    private static let spelledDigits = #"(?i)\b(?:(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|niner)(?:-|\s+|\s+(?:and|dash|hyphen)\s+)){2,}(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|niner)\b"#

    private static func regexRanges(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Range(match.range, in: text)
        }
    }

    private static func merge(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                let end = max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = last.lowerBound..<end
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func replacing(_ ranges: [Range<String.Index>], in text: String) -> String {
        var result = text
        for range in ranges.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

enum Terms {
    static let title = "Terms"
    static let body = """
    Contractor Pros is for jobs booked in the app. If you meet a customer or a contractor here, you agree not to take that work off the app to avoid the platform fee.

    The customer sets an offered price. A contractor may accept that price or send a counter-offer. Only one contractor is assigned unless the customer allows more than one. The platform fee is \(FeeSchedule.launch.percent)% of the agreed price. The contractor receives the rest, minus any card-processing cost shown before confirmation. This demo authorizes that amount and does not capture a card.

    The street address is shown to the assigned contractor only after that authorization. Reviews apply only to jobs booked in the app. Phone numbers, emails, and links in chat stay hidden until then.

    A later review window (planned at 72 hours after the contractor submits completion) will be disclosed before it can approve a payout. This build does not auto-approve work or send a payout.
    """
}

enum Guarantee {
    static let title = "Contractor Guarantee"
    static let detail = "Shown after a job is booked and the payment is authorized in the app."
}
