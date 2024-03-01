// This is free software: you can redistribute and/or modify it
// under the terms of the GNU Lesser General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import Foundation
import OSLog
import Observation
import SkipSQL
let logger: Logger = Logger(subsystem: "app.libary", category: "NetSkipModel")

/// A type representing an app.
public struct ManagedApp : Identifiable, Sendable, Encodable {
    //public typealias Language = Locale.Language
    public typealias Language = String

    /// The stable identity of the entity associated with this instance.
    public let id: String

    /// The localized name of the app.
    public let name: String

    /// The localized subtitle of the app.
    public let subtitle: String?

    /// The description of the app
    public var description: String? {
        // note: this can't be the stored property because it conflicts on the Kotlin side
        appDescription
    }

    private let appDescription: String?

    /// The platform of the app
    public let platform: Platform

    /// The operating system compatibility requirements for the app
    public let requirements: String?

    /// The languages supported by the app
    public let languages: [Language]

    /// The language of app metadata
    public let metadataLanguage: Language?

    /// The URL of app developer’s website
    public let developerWebsite: URL?

    /// The genres of the app
    public let genres: [String]

    /// The age rating for the content of the app
    public let contentRating: String?

    /// The URL of app’s privacy policy
    public let privacyPolicy: URL?

    /// The copyright of the app
    public let copyright: String?

    /// The URL of app’s license agreement
    public var licenseAgreement: URL?

    /// The version of the app
    public let version: String?

    /// The localized developer release notes version of the app.
    public let releaseNotes: String?

    /// The release date version of the app
    public let releaseDate: Date?

    /// The size of the app in bytes
    public let fileSize: UInt64?

    /// A URL for the icon of the app. The icon will scale to fit the given size.
    public func iconURL(fitting: CGSize) -> URL? {
        fatalError("TODO")
    }

    /// An Array of URLs for the screenshots of the app. The screenshots will scale to fit the given size.
    public func screenshotURLs(fitting: CGSize) -> [URL] {
        fatalError("TODO")
    }

    public init(id: String, name: String, subtitle: String? = nil, description: String? = nil, platform: Platform, requirements: String? = nil, languages: [Language] = [], metadataLanguage: Language? = nil, developerWebsite: URL? = nil, genres: [String] = [], contentRating: String? = nil, privacyPolicy: URL? = nil, copyright: String? = nil, licenseAgreement: URL? = nil, version: String? = nil, releaseNotes: String? = nil, releaseDate: Date? = nil, fileSize: UInt64? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.appDescription = description
        self.platform = platform
        self.requirements = requirements
        self.languages = languages
        self.metadataLanguage = metadataLanguage
        self.developerWebsite = developerWebsite
        self.genres = genres
        self.contentRating = contentRating
        self.privacyPolicy = privacyPolicy
        self.copyright = copyright
        self.licenseAgreement = licenseAgreement
        self.version = version
        self.releaseNotes = releaseNotes
        self.releaseDate = releaseDate
        self.fileSize = fileSize
    }

//    public enum CodingKeys : String, CodingKey, CaseIterable {
//        case id
//        case name // Conflicting declarations: enum entry name, public final val name: String
//        case subtitle
//        case description // Conflicting declarations: public open val description: String, enum entry description
//        case platform
//        case requirements
//        case languages
//        case metadataLanguage
//        case developerWebsite
//        case genres
//        case contentRating
//        case privacyPolicy
//        case copyright
//        case licenseAgreement
//        case version
//        case releaseNotes
//        case releaseDate
//        case fileSize
//    }

}

/// A value representing the platform for a ManagedApp
public struct Platform : Hashable, Sendable, Codable {
    public let identifier: String

    /// The Platform representing iOS
    public static let iOS: Platform = Platform(identifier: "ios")

    /// The Platform representing macOS
    public static var macOS: Platform = Platform(identifier: "macos")

    /// A textual representation of this instance.
    public var description: String { identifier }
}

