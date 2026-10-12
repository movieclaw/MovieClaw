import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct GalleryPrefsTests {
    @Test func libraryModesAreIndependentAndPersist() {
        let suite = "gallery-prefs-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = GalleryPrefs(defaults: defaults)

        #expect(!prefs.galleryMode(libraryId: 1))
        #expect(!prefs.galleryMode(libraryId: 2))
        prefs.setGalleryMode(true, libraryId: 1)
        #expect(prefs.galleryMode(libraryId: 1))
        #expect(!prefs.galleryMode(libraryId: 2))

        prefs.setGalleryMode(true, libraryId: 2)
        prefs.setGalleryMode(false, libraryId: 1)
        let restored = GalleryPrefs(defaults: defaults)
        #expect(!restored.galleryMode(libraryId: 1))
        #expect(restored.galleryMode(libraryId: 2))
        #expect(!restored.galleryMode(libraryId: 3))
    }

    @Test func legacyCrossLibraryModeDoesNotBecomeLibraryDefault() {
        let suite = "gallery-prefs-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "movieclaw.library.gallery-mode")
        let prefs = GalleryPrefs(defaults: defaults)

        #expect(prefs.galleryMode(libraryId: nil))
        #expect(!prefs.galleryMode(libraryId: 1))
        prefs.setGalleryMode(true, libraryId: 1)
        prefs.setGalleryMode(false, libraryId: nil)
        #expect(prefs.galleryMode(libraryId: 1))
        #expect(!prefs.galleryMode(libraryId: nil))
        #expect(!prefs.galleryMode(libraryId: 2))
    }
}
