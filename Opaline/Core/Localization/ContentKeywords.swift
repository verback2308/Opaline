import Foundation

// MARK: - Content-language keyword tables
//
// Innertube responses carry some information ONLY as localized display text
// ("1.2M views", "3 days ago"). With the content language (`hl`) following
// the user, these strings arrive in the user's language, so classifying and
// parsing them needs per-language keyword hints.
//
// ADDING A CONTENT LANGUAGE = ADDING ITS TABLE to `all` below. A language
// without a table still works — matching runs against every table at once,
// so feeds just keep server order and relative dates fall back to nil
// (sorting treats those as `.distantPast` with a stable tiebreak).

/// Keywords of one language. Substring-matched against lowercased text, so
/// stems are enough ("просмотр" covers "просмотров"/"просмотра").
struct ContentKeywordTable {
    /// Marks a metadata line as a view count ("123 views", "5 watching").
    let viewCount: [String]
    /// Marks a metadata line as a relative published date ("3 days ago").
    let published: [String]
    /// Marks a channel-header line as a subscriber count.
    let subscribers: [String]
    /// Marks a channel-header line as a video count.
    let videos: [String]
    /// Unit stems for relative-date parsing, one field per magnitude.
    let seconds: [String]
    let minutes: [String]
    let hours: [String]
    let days: [String]
    let weeks: [String]
    let months: [String]
    let years: [String]
}

enum ContentKeywords {
    static let english = ContentKeywordTable(
        viewCount: ["view", "watching"],
        published: ["ago", "hour", "day", "week", "month", "year"],
        subscribers: ["subscriber"],
        videos: ["video"],
        seconds: ["sec"],
        minutes: ["min"],
        hours: ["hour"],
        days: ["day"],
        weeks: ["week"],
        months: ["month"],
        years: ["year"]
    )

    static let russian = ContentKeywordTable(
        viewCount: ["просмотр", "смотр"],
        published: ["назад", "час", "нед", "мес", "лет", "дн", "мин", "сек"],
        subscribers: ["подписчик"],
        videos: ["видео"],
        seconds: ["сек"],
        minutes: ["мин"],
        hours: ["час"],
        days: ["дн", "день", "дня"],
        weeks: ["нед"],
        months: ["мес"],
        years: ["лет", "год"]
    )

    /// "годин" not "год": the Russian YEAR stem "год" collides with the
    /// Ukrainian HOUR "година" — the longer stem plus smallest-unit-first
    /// ordering in [[approximateDate]] keeps both languages correct.
    static let ukrainian = ContentKeywordTable(
        viewCount: ["перегляд", "дивл"],
        published: ["тому", "годин", "хв", "тижн", "тижд", "місяц", "рік", "рок"],
        subscribers: ["підписник"],
        videos: ["відео"],
        seconds: ["сек"],
        minutes: ["хв"],
        hours: ["годин"],
        days: ["дн", "день"],
        weeks: ["тижн", "тижд"],
        months: ["місяц"],
        years: ["рік", "рок"]
    )

    static let polish = ContentKeywordTable(
        viewCount: ["wyświetle", "ogląda"],
        published: [
            "temu", "sekund", "minut", "godzin", "dzień", "dni",
            "tydzień", "tygodnie", "tygodni",
            "miesiąc", "miesiące", "miesięcy", "rok", "lata", "lat"
        ],
        subscribers: ["subskrybent"],
        videos: ["filmy"],
        seconds: ["sekund"],
        minutes: ["minut"],
        hours: ["godzin"],
        days: ["dzień", "dni"],
        weeks: ["tydzień", "tygodnie", "tygodni"],
        months: ["miesiąc", "miesiące", "miesięcy"],
        years: ["rok", "lata", "lat"]
    )

    /// "lượt xem" not the bare "xem": on its own the verb means "watch" and
    /// appears in ordinary UI text ("Xem sau"), which would classify any
    /// metadata line as a view count.
    static let vietnamese = ContentKeywordTable(
        viewCount: ["lượt xem", "đang xem"],
        published: ["trước", "giây", "phút", "giờ", "ngày", "tuần", "tháng", "năm"],
        subscribers: ["người đăng ký"],
        videos: ["video"],
        seconds: ["giây"],
        minutes: ["phút"],
        hours: ["giờ"],
        days: ["ngày"],
        weeks: ["tuần"],
        months: ["tháng"],
        years: ["năm"]
    )

    /// Every shipped table — matching is language-agnostic (a Russian UI
    /// still parses cached English strings and vice versa).
    static let all: [ContentKeywordTable] = [english, russian, ukrainian, polish, vietnamese]

    static func isViewCount(_ text: String) -> Bool {
        all.contains { table in
            table.viewCount.contains { text.contains($0) }
        }
    }

    static func isPublished(_ text: String) -> Bool {
        all.contains { table in
            table.published.contains { text.contains($0) }
        }
    }

    static func isSubscriberCount(_ text: String) -> Bool {
        all.contains { table in
            table.subscribers.contains { text.contains($0) }
        }
    }

    static func isVideoCount(_ text: String) -> Bool {
        all.contains { table in
            table.videos.contains { text.contains($0) }
        }
    }

    /// Approximate absolute date for a relative string ("3 days ago"),
    /// checked smallest unit first — mirrors the pre-extraction behavior
    /// of `VideoFormatters.approximateDate`.
    static func approximateDate(fromRelative text: String) -> Date? {
        let lowered = text.lowercased()
        let num = lowered.components(separatedBy: .whitespaces)
            .compactMap(Int.init).first ?? 1
        // Weeks BEFORE days: the Ukrainian week "тиждень" contains the
        // day stem "день" and must win. Otherwise smallest-unit-first.
        let scales: [(KeyPath<ContentKeywordTable, [String]>, Double)] = [
            (\.seconds, 1), (\.minutes, 60), (\.hours, 3_600),
            (\.weeks, 604_800), (\.days, 86_400),
            (\.months, 2_592_000), (\.years, 31_536_000)
        ]
        for (unit, secondsPerUnit) in scales {
            let matched = all.contains { table in
                table[keyPath: unit].contains { lowered.contains($0) }
            }
            if matched {
                return Date() - Double(num) * secondsPerUnit
            }
        }
        return nil
    }
}
