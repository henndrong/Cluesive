//
//  RoomPlanCore.swift
//  Cluesive
//
//  Shared types, signature stubs, and map persistence helpers.
//

import SwiftUI
import Combine
import ARKit
import SceneKit

enum LocalizationState: String {
    case unknown
    case relocalizing
    case localized

    var displayText: String {
        rawValue.capitalized
    }
}

enum AnchorType: String, Codable, CaseIterable, Identifiable {
    case door
    case roomEntrance
    case corner
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .door: return "Door"
        case .roomEntrance: return "Room Entrance"
        case .corner: return "Corner"
        case .custom: return "Custom"
        }
    }

    var defaultNamePrefix: String {
        switch self {
        case .door: return "Door"
        case .roomEntrance: return "Room Entrance"
        case .corner: return "Corner"
        case .custom: return "Anchor"
        }
    }
}

enum AnchorPlacementMode: String, Codable, CaseIterable, Identifiable {
    case aimedRaycast
    case currentPose

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .aimedRaycast: return "Aim"
        case .currentPose: return "Here"
        }
    }

    var addButtonLabel: String {
        switch self {
        case .aimedRaycast: return "Add Aimed Anchor"
        case .currentPose: return "Add Here Anchor"
        }
    }
}

struct AnchorTargetPreview {
    let isTargetValid: Bool
    let worldPosition: SIMD3<Float>?
    let reason: String?
    let surfaceKind: String?
}

struct SavedSemanticAnchor: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let type: AnchorType
    let createdAt: Date
    let transform: [Float] // 16 floats, column-major order matching simd_float4x4 storage
    let placementMode: AnchorPlacementMode?
    let sourceNote: String?

    init(
        id: UUID,
        name: String,
        type: AnchorType,
        createdAt: Date,
        transform: [Float],
        placementMode: AnchorPlacementMode? = nil,
        sourceNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.transform = transform
        self.placementMode = placementMode
        self.sourceNote = sourceNote
    }
}

struct AnchorPingResult {
    let anchorID: UUID
    let anchorName: String
    let distanceMeters: Float
    let bearingDegrees: Float // signed delta: negative = left, positive = right
    let absoluteHeadingDegrees: Float
    let isReachable: Bool
}

struct ScanReadinessSnapshot {
    let mappingMappedRatio: Float
    let featurePointMedian: Int
    let yawCoverageDegrees: Float
    let translationDistanceMeters: Float
    let trackingNormalRatio: Float
    let qualityScore: Float
    let warnings: [String]
}

enum RelocalizationAttemptMode: String {
    case stationary360
    case microMovementFallback

    var displayName: String {
        switch self {
        case .stationary360: return "Stationary 360"
        case .microMovementFallback: return "Micro-movement"
        }
    }
}

struct RelocalizationAttemptState {
    var mode: RelocalizationAttemptMode
    var startedAt: Date
    var rotationAccumulatedDegrees: Float
    var featurePointMedianRecent: Int
    var sawRelocalizingTracking: Bool
    var stableNormalFrames: Int
    var timeoutSeconds: TimeInterval
}

struct RelocalizationGuidanceSnapshot {
    let attemptMode: RelocalizationAttemptMode
    let attemptProgressText: String
    let recommendedActionText: String
    let stationaryAttemptReadyToEscalate: Bool
    let relocalizationQualityScore: Float
}

enum FallbackRelocalizationMode: String, Codable {
    case none
    case roomPlanSignature
    case meshAlignment

    var displayName: String {
        switch self {
        case .none: return "None"
        case .roomPlanSignature: return "Room Signature"
        case .meshAlignment: return "Mesh Alignment"
        }
    }
}

struct LineSegment2D: Codable {
    let x1: Float
    let y1: Float
    let x2: Float
    let y2: Float
}

struct ObjectFootprint2D: Codable {
    let category: String
    let x: Float
    let y: Float
    let width: Float
    let depth: Float
}

struct RoomSignatureArtifact: Codable {
    let mapName: String
    let capturedAt: Date
    let roomBounds2D: [SIMD2<Float>]
    let wallSegments: [LineSegment2D]
    let openings: [LineSegment2D]
    let objectFootprints: [ObjectFootprint2D]
    let signatureVersion: Int
    let source: String
}

struct RoomSignatureMatchResult {
    let confidence: Float
    let likelyAreaLabel: String?
    let orientationHintDegrees: Float?
    let referenceFeatureDescription: String
    let recommendedPrompt: String
    let matchReasonDebug: String?
}

struct FallbackRelocalizationState {
    var isActive: Bool
    var mode: FallbackRelocalizationMode
    var startedAt: Date
    var scanProgressText: String
    var matchResult: RoomSignatureMatchResult?
    var failureReason: String?
    var rotationAccumulatedDegrees: Float
    var lastYaw: Float?
}

struct MeshSignatureDescriptor: Codable {
    let dominantYawBins: [Float]      // coarse horizontal normal bins
    let heightHistogram: [Float]
    let occupancyHash: [UInt64]
    let boundsMinXZ: SIMD2<Float>
    let boundsMaxXZ: SIMD2<Float>
    let pointCount: Int
}

struct MeshAnchorRecord: Codable {
    let id: UUID
    let transform: [Float]
    let vertices: [Float]             // flat xyz xyz ...
    let normals: [Float]?             // flat xyz xyz ...
    let faces: [UInt32]               // triangle indices
    let capturedAt: Date
    let classificationSummary: String?
}

struct MeshMapArtifact: Codable {
    let mapName: String
    let capturedAt: Date
    let meshAnchors: [MeshAnchorRecord]
    let descriptor: MeshSignatureDescriptor
    let version: Int
}

struct MeshRelocalizationHypothesis: Codable {
    let yawDegrees: Float
    let translationXZ: SIMD2<Float>
    let coarseConfidence: Float
    let source: String
}

struct MeshRelocalizationResult {
    let coarsePoseSeed: MeshRelocalizationHypothesis?
    let refinedPoseSeed: MeshRelocalizationHypothesis?
    let orientationHintDegrees: Float?
    let areaHint: String?
    let confidence: Float
    let residualErrorMeters: Float
    let overlapRatio: Float
    let yawConfidenceDegrees: Float
    let supportingPointCount: Int
    let isStableAcrossFrames: Bool
    let debugReason: String
}

enum MeshFallbackPhase: String {
    case idle
    case coarseMatching
    case refiningICP
    case matched
    case inconclusive
}

struct MeshFallbackState {
    var active: Bool
    var phase: MeshFallbackPhase
    var startedAt: Date
    var progressText: String
    var result: MeshRelocalizationResult?
}

enum AppLocalizationState: String {
    case searching
    case meshAligning
    case meshAlignedOverride
    case arkitConfirmed
    case conflict
    case degraded

    var displayLabel: String {
        switch self {
        case .searching: return "Searching"
        case .meshAligning: return "Mesh Aligning"
        case .meshAlignedOverride: return "Mesh-Aligned Override"
        case .arkitConfirmed: return "ARKit Confirmed"
        case .conflict: return "Conflict"
        case .degraded: return "Degraded"
        }
    }

    var isUsableForNavigation: Bool {
        self == .meshAlignedOverride || self == .arkitConfirmed
    }

    var isUsableForAnchors: Bool {
        isUsableForNavigation
    }

    var requiresCautionPrompt: Bool {
        self == .meshAlignedOverride || self == .degraded
    }
}

enum AppLocalizationSource: String {
    case none
    case meshICP
    case arkitWorldMap
    case arkitAndMeshConsistent

    var displayLabel: String {
        switch self {
        case .none: return "None"
        case .meshICP: return "Mesh ICP"
        case .arkitWorldMap: return "ARKit WorldMap"
        case .arkitAndMeshConsistent: return "ARKit + Mesh Consistent"
        }
    }
}

struct MeshAlignmentAcceptance {
    let mapFromSessionTransform: simd_float4x4
    let confidence: Float
    let residualErrorMeters: Float
    let overlapRatio: Float
    let yawConfidenceDegrees: Float
    let acceptedAt: Date
    let supportingFrames: Int
}

struct LocalizationConflictSnapshot {
    let positionDeltaMeters: Float
    let yawDeltaDegrees: Float
    let arkitStateAtConflict: String
    let meshConfidenceAtConflict: Float
    let detectedAt: Date
}

protocol RoomSignatureProvider {
    func captureCurrentSignature(mapName: String, anchors: [SavedSemanticAnchor]) -> RoomSignatureArtifact?
    func buildLiveSignatureSnapshot(currentYaw: Float, featurePointCount: Int) -> RoomSignatureArtifact?
    func match(live: RoomSignatureArtifact, saved: RoomSignatureArtifact) -> RoomSignatureMatchResult?
}

struct StubRoomSignatureProvider: RoomSignatureProvider {
    func captureCurrentSignature(mapName: String, anchors: [SavedSemanticAnchor]) -> RoomSignatureArtifact? {
        guard anchors.count >= 2 else { return nil }
        let points = anchors.compactMap { anchor -> SIMD2<Float>? in
            guard let t = simd_float4x4(flatArray: anchor.transform) else { return nil }
            return SIMD2(t.translation.x, t.translation.z)
        }
        guard points.count >= 2 else { return nil }
        let walls = zip(points, points.dropFirst()).map { p0, p1 in
            LineSegment2D(x1: p0.x, y1: p0.y, x2: p1.x, y2: p1.y)
        }
        let footprints = zip(anchors, points).map { anchor, p in
            ObjectFootprint2D(category: anchor.type.displayName.lowercased(), x: p.x, y: p.y, width: 0.4, depth: 0.4)
        }
        return RoomSignatureArtifact(
            mapName: mapName,
            capturedAt: Date(),
            roomBounds2D: points,
            wallSegments: walls,
            openings: [],
            objectFootprints: footprints,
            signatureVersion: 1,
            source: "stub_anchors"
        )
    }

    func buildLiveSignatureSnapshot(currentYaw: Float, featurePointCount: Int) -> RoomSignatureArtifact? {
        let radius = max(0.5, min(Float(featurePointCount) / 400, 2.0))
        let p0 = SIMD2<Float>(radius, 0)
        let p1 = SIMD2<Float>(0, radius)
        let p2 = SIMD2<Float>(-radius, 0)
        let p3 = SIMD2<Float>(0, -radius)
        let angle = currentYaw
        let rot = simd_float2x2(rows: [
            SIMD2(cos(angle), -sin(angle)),
            SIMD2(sin(angle), cos(angle))
        ])
        let pts = [p0, p1, p2, p3].map { rot * $0 }
        return RoomSignatureArtifact(
            mapName: "live",
            capturedAt: Date(),
            roomBounds2D: pts,
            wallSegments: [LineSegment2D(x1: pts[0].x, y1: pts[0].y, x2: pts[2].x, y2: pts[2].y)],
            openings: [],
            objectFootprints: [],
            signatureVersion: 1,
            source: "stub_live"
        )
    }

    func match(live: RoomSignatureArtifact, saved: RoomSignatureArtifact) -> RoomSignatureMatchResult? {
        guard !saved.objectFootprints.isEmpty || saved.wallSegments.count >= 1 else { return nil }
        let scoreBase = min(Float(saved.objectFootprints.count) / 4.0, 1.0) * 0.5 + min(Float(saved.wallSegments.count) / 4.0, 1.0) * 0.3
        let liveRichness = min(Float(live.roomBounds2D.count) / 4.0, 1.0) * 0.2
        let confidence = min(max(scoreBase + liveRichness, 0.1), 0.9)
        let featureDescription = saved.objectFootprints.first?.category ?? "long wall"
        return RoomSignatureMatchResult(
            confidence: confidence,
            likelyAreaLabel: "Saved room map area",
            orientationHintDegrees: 90,
            referenceFeatureDescription: featureDescription,
            recommendedPrompt: "Likely in the saved room area. Turn right about 90° to face the \(featureDescription) side, then hold steady for ARKit relocalization.",
            matchReasonDebug: "Stub signature match using anchors/structure count"
        )
    }
}

enum Phase1MapStore {
    struct Metadata: Codable {
        let mapName: String
        let createdAt: Date
        let updatedAt: Date
        let note: String
    }

    static let mapName = "Phase1_DefaultMap"

    private static var mapsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Maps", isDirectory: true)
    }

    private static var bundleDirectory: URL {
        mapsDirectory.appendingPathComponent(mapName, isDirectory: true)
    }

    private static var worldMapURL: URL {
        bundleDirectory.appendingPathComponent("worldMap.arexport")
    }

    private static var metadataURL: URL {
        bundleDirectory.appendingPathComponent("metadata.json")
    }

    private static var anchorsURL: URL {
        bundleDirectory.appendingPathComponent("anchors.json")
    }

    private static var roomSignatureURL: URL {
        bundleDirectory.appendingPathComponent("roomSignature.json")
    }

    private static var meshArtifactURL: URL {
        bundleDirectory.appendingPathComponent("meshArtifact.json")
    }

    static func savedMapExists() -> Bool {
        FileManager.default.fileExists(atPath: worldMapURL.path)
    }

    static func save(worldMap: ARWorldMap) throws -> Metadata {
        let fm = FileManager.default
        try fm.createDirectory(at: bundleDirectory, withIntermediateDirectories: true, attributes: nil)

        let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try data.write(to: worldMapURL, options: .atomic)

        let now = Date()
        let metadata = Metadata(
            mapName: mapName,
            createdAt: (try? loadMetadata()?.createdAt) ?? now,
            updatedAt: now,
            note: "Phase 1 ARWorldMap save"
        )
        let metadataData = try JSONEncoder.pretty.encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)

        if !fm.fileExists(atPath: anchorsURL.path) {
            try Data("[]".utf8).write(to: anchorsURL, options: .atomic)
        }
        return metadata
    }

    static func loadWorldMap() throws -> ARWorldMap {
        let data = try Data(contentsOf: worldMapURL)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw NSError(domain: "Phase1MapStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode ARWorldMap"])
        }
        return map
    }

    static func loadMetadata() throws -> Metadata? {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder.iso8601.decode(Metadata.self, from: data)
    }

    static func loadAnchors() throws -> [SavedSemanticAnchor] {
        guard FileManager.default.fileExists(atPath: anchorsURL.path) else { return [] }
        let data = try Data(contentsOf: anchorsURL)
        if data.isEmpty { return [] }
        return try JSONDecoder.iso8601.decode([SavedSemanticAnchor].self, from: data)
    }

    static func saveAnchors(_ anchors: [SavedSemanticAnchor]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundleDirectory, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder.pretty.encode(anchors)
        try data.write(to: anchorsURL, options: .atomic)
    }

    static func roomSignatureExists() -> Bool {
        FileManager.default.fileExists(atPath: roomSignatureURL.path)
    }

    static func saveRoomSignature(_ artifact: RoomSignatureArtifact) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundleDirectory, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder.pretty.encode(artifact)
        try data.write(to: roomSignatureURL, options: .atomic)
    }

    static func loadRoomSignature() throws -> RoomSignatureArtifact? {
        guard FileManager.default.fileExists(atPath: roomSignatureURL.path) else { return nil }
        let data = try Data(contentsOf: roomSignatureURL)
        return try JSONDecoder.iso8601.decode(RoomSignatureArtifact.self, from: data)
    }

    static func meshArtifactExists() -> Bool {
        FileManager.default.fileExists(atPath: meshArtifactURL.path)
    }

    static func saveMeshArtifact(_ artifact: MeshMapArtifact) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundleDirectory, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder.pretty.encode(artifact)
        try data.write(to: meshArtifactURL, options: .atomic)
    }

    static func loadMeshArtifact() throws -> MeshMapArtifact? {
        guard FileManager.default.fileExists(atPath: meshArtifactURL.path) else { return nil }
        let data = try Data(contentsOf: meshArtifactURL)
        return try JSONDecoder.iso8601.decode(MeshMapArtifact.self, from: data)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
