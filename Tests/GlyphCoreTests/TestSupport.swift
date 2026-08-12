//
//  TestSupport.swift — locate & load the real tracked data artifacts
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  Tests parse the REAL data/glyphs_baked.json and data/sayings.json (slice
//  deliverable 4: "parse the real JSON"), not fixtures. The files live at the
//  repo root, a sibling of Sources/ and Tests/. We locate the root from this
//  source file's path (#filePath → …/Tests/GlyphCoreTests/TestSupport.swift →
//  up 3) rather than bundling resources into the SPM target — the artifact
//  under test IS the tracked file, and this avoids SPM resource plumbing.
//

import Foundation

enum TestData {
    /// Repo root = this file's directory, up three (GlyphCoreTests → Tests → root).
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GlyphCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }

    static func glyphsBakedJSON() throws -> Data { try data("data/glyphs_baked.json") }

    static func sayings() throws -> [String] {
        let raw = try data("data/sayings.json")
        return try JSONDecoder().decode([String].self, from: raw)
    }
}
