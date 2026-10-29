import AtlasCore
import AtlasSpaces
import Foundation

/// A place found by name (Open-Meteo geocoding).
public struct WeatherPlace: Codable, Hashable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// "Massachusetts, United States".
    public var region: String

    public init(name: String, latitude: Double, longitude: Double, region: String = "") {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.region = region
    }
}

/// The weather at a place, as last fetched.
public struct WeatherReading: Codable, Hashable, Sendable {
    /// WMO weather code.
    public var code: Int
    public var temperature: Double
    public var unit: String
    public var sunrise: Date?
    public var sunset: Date?
    public var fetchedAt: Date

    public init(code: Int, temperature: Double, unit: String = "°", sunrise: Date? = nil, sunset: Date? = nil, fetchedAt: Date) {
        self.code = code
        self.temperature = temperature
        self.unit = unit
        self.sunrise = sunrise
        self.sunset = sunset
        self.fetchedAt = fetchedAt
    }
}

/// Fetches a URL; replaced in tests.
public protocol WeatherFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionWeatherFetcher: WeatherFetching {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("ATLAS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Pure mappings: WMO codes to the window's weather, and the time of day
/// to its sky.
public enum WeatherMapping {
    typealias Weather = StudyRoomState.WindowView.Weather
    typealias Sky = StudyRoomState.WindowView.Sky

    public static func weather(code: Int) -> StudyRoomState.WindowView.Weather {
        switch code {
        case 0, 1: return .clear
        case 2, 3: return .clouds
        case 45, 48: return .fog
        case 51...67, 80...82, 95...99: return .rain
        case 71...77, 85, 86: return .snow
        default: return .clouds
        }
    }

    public static func describe(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 80: return "Light rain"
        case 63, 81: return "Rain"
        case 65, 82: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 85: return "Light snow"
        case 73, 75, 86: return "Snow"
        case 77: return "Snow grains"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }

    /// Dawn around sunrise, day, golden hour before sunset, blue hour
    /// after it, then night. Without sun times (never fetched), a typical
    /// 6:45 sunrise and 18:15 sunset.
    public static func sky(at date: Date, sunrise: Date?, sunset: Date?, calendar: Calendar = .current) -> StudyRoomState.WindowView.Sky {
        // Sun times from another day (an old cache) keep their time of day.
        func today(_ time: Date?, fallback: (Int, Int)) -> Date {
            let parts = time.map { calendar.dateComponents([.hour, .minute], from: $0) }
            return calendar.date(bySettingHour: parts?.hour ?? fallback.0, minute: parts?.minute ?? fallback.1, second: 0, of: date) ?? date
        }
        let rise = today(sunrise, fallback: (6, 45)), set = today(sunset, fallback: (18, 15))
        let minute: TimeInterval = 60
        switch date {
        case rise.addingTimeInterval(-40 * minute)..<rise.addingTimeInterval(40 * minute): return .dawn
        case rise.addingTimeInterval(40 * minute)..<set.addingTimeInterval(-90 * minute): return .day
        case set.addingTimeInterval(-90 * minute)..<set: return .golden
        case set..<set.addingTimeInterval(50 * minute): return .blueHour
        default: return .night
        }
    }

    static func skyName(_ sky: StudyRoomState.WindowView.Sky) -> String {
        switch sky {
        case .dawn: return "Dawn"
        case .day: return "Daytime"
        case .golden: return "Golden hour"
        case .blueHour: return "Blue hour"
        case .night: return "Night"
        }
    }
}

/// Real weather for the Study Library's window, from Open-Meteo (free, no
/// key, no location permission: you type a city). Fetched at most every
/// 30 minutes and cached, so the room never waits on the network; with no
/// city, or offline for a while, the window shows just the time of day.
public final class WeatherService: @unchecked Sendable {
    struct Cache: Codable, Equatable {
        var city: String
        var place: WeatherPlace
        var reading: WeatherReading?
    }

    static let cacheKey = "study.weather.cache"
    /// How often to fetch.
    public static let refreshInterval: TimeInterval = 30 * 60
    /// Older than this, the weather is shown as unknown (time of day only).
    public static let staleAfter: TimeInterval = 3 * 3600

    let store: AtlasStore
    let fetcher: WeatherFetching
    var now: @Sendable () -> Date
    private let lock = NSLock()
    private var inFlight = false

    init(store: AtlasStore, fetcher: WeatherFetching = URLSessionWeatherFetcher(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.fetcher = fetcher
        self.now = now
    }

    var cache: Cache? {
        get { try? store.preference(Self.cacheKey, as: Cache.self) }
        set { try? store.setPreference(newValue, for: Self.cacheKey) }
    }

    /// The place last found for `city`, if any.
    public func place(for city: String) -> WeatherPlace? {
        guard let cache, Self.same(cache.city, city) else { return nil }
        return cache.place
    }

    /// Fetches the weather if it's due (or `force`). True if it changed.
    /// Failures keep the last reading; the window falls back on its own.
    @discardableResult
    public func refresh(city: String, force: Bool = false) async -> Bool {
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty else { return false }
        let current = cache
        if !force, let current, Self.same(current.city, city), let reading = current.reading,
           now().timeIntervalSince(reading.fetchedAt) < Self.refreshInterval {
            return false
        }
        let busy = lock.withLock { () -> Bool in
            defer { inFlight = true }
            return inFlight
        }
        guard !busy else { return false }
        defer { lock.withLock { inFlight = false } }
        do {
            let place: WeatherPlace
            if let current, Self.same(current.city, city) {
                place = current.place
            } else {
                place = try await geocode(city)
                cache = Cache(city: city, place: place, reading: nil)
            }
            let reading = try await forecast(place)
            cache = Cache(city: city, place: place, reading: reading)
            return true
        } catch {
            AtlasLog.engine.info("Weather for \(city, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What the window shows now.
    public func view(city: String) -> StudyRoomState.WindowView {
        let date = now()
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = cache.flatMap { Self.same($0.city, city) ? $0 : nil }
        let reading = cached?.reading
        let sky = WeatherMapping.sky(at: date, sunrise: reading?.sunrise, sunset: reading?.sunset)
        let skyName = WeatherMapping.skyName(sky)
        guard !city.isEmpty else {
            return .init(sky: sky, weather: .clear, detail: "\(skyName) · set a weather city in Study Settings for real weather")
        }
        guard let cached, let reading else {
            return .init(sky: sky, weather: .clear, detail: "\(skyName) · looking up the weather for \(city)…")
        }
        let age = date.timeIntervalSince(reading.fetchedAt)
        guard age < Self.staleAfter else {
            let ago = age < 86_400 ? "\(Int(age / 3600)) h ago" : "a while ago"
            return .init(sky: sky, weather: .clear, detail: "\(skyName) · \(cached.place.name) · offline (last update \(ago))")
        }
        let temperature = "\(Int(reading.temperature.rounded()))\(reading.unit)"
        return .init(sky: sky, weather: WeatherMapping.weather(code: reading.code),
                     detail: "\(WeatherMapping.describe(code: reading.code)) · \(temperature) · \(cached.place.name)")
    }

    // MARK: - Open-Meteo

    func geocode(_ city: String) async throws -> WeatherPlace {
        // "Boston, MA": search the name, prefer a result in the region named after the comma.
        let parts = city.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: parts[0]), .init(name: "count", value: "10"),
                                 .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let country: String?
                let country_code: String?
                let admin1: String?
            }
            let results: [Result]?
        }
        let response = try JSONDecoder().decode(Response.self, from: try await fetcher.data(from: components.url!))
        let results = response.results ?? []
        let hint = parts.count > 1 ? parts[1].lowercased() : nil
        let chosen = hint.flatMap { hint in
            results.first { result in
                [result.admin1, result.country, result.country_code].compactMap { $0?.lowercased() }
                    .contains { $0 == hint || $0.hasPrefix(hint) || Self.stateAbbreviations[hint] == $0 }
            }
        } ?? results.first
        guard let chosen else { throw WeatherError.placeNotFound(city) }
        return WeatherPlace(name: chosen.name, latitude: chosen.latitude, longitude: chosen.longitude,
                            region: [chosen.admin1, chosen.country].compactMap { $0 }.joined(separator: ", "))
    }

    func forecast(_ place: WeatherPlace) async throws -> WeatherReading {
        let fahrenheit = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(place.latitude)), .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "weather_code,temperature_2m"), .init(name: "daily", value: "sunrise,sunset"),
            .init(name: "timezone", value: "auto"), .init(name: "timeformat", value: "unixtime"), .init(name: "forecast_days", value: "1"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable {
                let weather_code: Int
                let temperature_2m: Double
            }
            struct Daily: Decodable {
                let sunrise: [Double]?
                let sunset: [Double]?
            }
            let current: Current
            let daily: Daily?
        }
        let response = try JSONDecoder().decode(Response.self, from: try await fetcher.data(from: components.url!))
        return WeatherReading(code: response.current.weather_code, temperature: response.current.temperature_2m,
                              unit: fahrenheit ? "°F" : "°C",
                              sunrise: response.daily?.sunrise?.first.map { Date(timeIntervalSince1970: $0) },
                              sunset: response.daily?.sunset?.first.map { Date(timeIntervalSince1970: $0) },
                              fetchedAt: now())
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// "MA" → "massachusetts", for "Boston, MA".
    static let stateAbbreviations: [String: String] = [
        "al": "alabama", "ak": "alaska", "az": "arizona", "ar": "arkansas", "ca": "california", "co": "colorado", "ct": "connecticut",
        "de": "delaware", "dc": "district of columbia", "fl": "florida", "ga": "georgia", "hi": "hawaii", "id": "idaho", "il": "illinois",
        "in": "indiana", "ia": "iowa", "ks": "kansas", "ky": "kentucky", "la": "louisiana", "me": "maine", "md": "maryland",
        "ma": "massachusetts", "mi": "michigan", "mn": "minnesota", "ms": "mississippi", "mo": "missouri", "mt": "montana",
        "ne": "nebraska", "nv": "nevada", "nh": "new hampshire", "nj": "new jersey", "nm": "new mexico", "ny": "new york",
        "nc": "north carolina", "nd": "north dakota", "oh": "ohio", "ok": "oklahoma", "or": "oregon", "pa": "pennsylvania",
        "ri": "rhode island", "sc": "south carolina", "sd": "south dakota", "tn": "tennessee", "tx": "texas", "ut": "utah",
        "vt": "vermont", "va": "virginia", "wa": "washington", "wv": "west virginia", "wi": "wisconsin", "wy": "wyoming",
    ]
}

public enum WeatherError: Error, LocalizedError, Equatable {
    case placeNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .placeNotFound(let city): return "Couldn't find a place called “\(city)”."
        }
    }
}
