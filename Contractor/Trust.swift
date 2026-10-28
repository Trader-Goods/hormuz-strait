import Foundation

struct FeeSchedule: Codable, Equatable {
    var standardPercent = 8
    var repeatPercent = 5
    var minimumCents = 500

    static let launch = FeeSchedule()
}

struct PlatformCharge: Codable, Equatable {
    /// The customer pays the quote price in the app.
    var amountCents: Int
    /// Kept by the platform before the pro is paid.
    var applicationFeeCents: Int
    var proPayoutCents: Int
    var currency: String
    /// `stubbed` until a Stripe Connect charge is live.
    var status: String
    /// The pro's Stripe Connect account. Empty in the demo.
    var connectedAccountID: String
}

enum ContactFilter {
    static let replacement = "[hidden until booking]"
    static let notice = "Phone numbers, emails, and links stay hidden until this job is booked and paid in the app."

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
    Contractor is for jobs booked and paid in the app. If you meet a customer or a pro here, you agree not to take that work off the app to avoid the booking fee.

    Quotes are free. The customer pays the quoted price in the app. Contractor keeps a platform fee before the pro is paid. The first booking fee is \(FeeSchedule.launch.standardPercent)%. Booking the same pro again, including recurring lawn service, is \(FeeSchedule.launch.repeatPercent)%.

    Reviews and the Contractor Guarantee apply only to jobs booked and paid in the app. Phone numbers, emails, and links in chat stay hidden until then.
    """
}

enum Guarantee {
    static let title = "Contractor Guarantee"
    static let detail = "Shown only after a job is booked and paid in the app."
}
