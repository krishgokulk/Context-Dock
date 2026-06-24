// WeatherService.swift
// Keyless weather for General Chat. Resolves approximate location via IP geolocation
// (no Location permission / WeatherKit entitlement needed — only network.client) and
// fetches current conditions from Open-Meteo. Returns a short human-readable summary,
// or nil on any failure (the chat just omits weather context).

import Foundation

enum WeatherService {
    private struct IPLocation: Decodable {
        let latitude: Double
        let longitude: Double
        let city: String?
        let region: String?
    }

    private struct OpenMeteo: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let weather_code: Int?
            let wind_speed_10m: Double?
            let relative_humidity_2m: Double?
        }
        let current: Current?
    }

    private struct GeoResult: Decodable {
        struct Hit: Decodable {
            let latitude: Double
            let longitude: Double
            let name: String?
            let admin1: String?
            let country: String?
        }
        let results: [Hit]?
    }

    /// One-line current-weather summary. If `place` is given, geocodes that city; otherwise
    /// uses the device's approximate IP location. Returns nil on any failure.
    static func currentSummary(place: String? = nil) async -> String? {
        let lat: Double
        let lon: Double
        let placeName: String

        if let place, !place.trimmingCharacters(in: .whitespaces).isEmpty,
            let hit = await geocode(place)
        {
            lat = hit.latitude
            lon = hit.longitude
            placeName = [hit.name, hit.admin1, hit.country].compactMap { $0 }.first ?? place
        } else if let loc = await ipLocation() {
            lat = loc.latitude
            lon = loc.longitude
            placeName = [loc.city, loc.region].compactMap { $0 }.first ?? "your location"
        } else {
            return nil
        }

        guard let weather = await openMeteo(lat: lat, lon: lon),
            let current = weather.current
        else { return nil }

        let place = placeName
        var parts: [String] = []
        if let t = current.temperature_2m {
            parts.append("\(Int(t.rounded()))°C")
        }
        if let feels = current.apparent_temperature {
            parts.append("feels like \(Int(feels.rounded()))°C")
        }
        if let code = current.weather_code {
            parts.append(condition(for: code))
        }
        if let h = current.relative_humidity_2m {
            parts.append("humidity \(Int(h.rounded()))%")
        }
        if let w = current.wind_speed_10m {
            parts.append("wind \(Int(w.rounded())) km/h")
        }
        guard !parts.isEmpty else { return nil }
        return "Current weather in \(place): " + parts.joined(separator: ", ") + "."
    }

    private static func geocode(_ place: String) async -> GeoResult.Hit? {
        let name =
            place.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place
        guard let url = URL(
            string:
                "https://geocoding-api.open-meteo.com/v1/search?name=\(name)&count=1&language=en")
        else { return nil }
        guard let data = try? await fetch(url) else { return nil }
        return (try? JSONDecoder().decode(GeoResult.self, from: data))?.results?.first
    }

    private static func ipLocation() async -> IPLocation? {
        guard let url = URL(string: "https://ipapi.co/json/") else { return nil }
        guard let data = try? await fetch(url) else { return nil }
        return try? JSONDecoder().decode(IPLocation.self, from: data)
    }

    private static func openMeteo(lat: Double, lon: Double) async -> OpenMeteo? {
        let urlString =
            "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m"
        guard let url = URL(string: urlString) else { return nil }
        guard let data = try? await fetch(url) else { return nil }
        return try? JSONDecoder().decode(OpenMeteo.self, from: data)
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// WMO weather interpretation codes → short label.
    private static func condition(for code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 65, 66, 67: return "rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorm"
        default: return "mixed conditions"
        }
    }
}
