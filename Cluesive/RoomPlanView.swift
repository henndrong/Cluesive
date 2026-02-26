//
//  RoomPlanView.swift
//  Cluesive
//
//  Phase 1 MVP: ARKit LiDAR scanning + ARWorldMap persistence/relocalization.
//

import SwiftUI
import Combine
import ARKit
import SceneKit

private enum LocalizationState: String {
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

private protocol RoomSignatureProvider {
    func captureCurrentSignature(mapName: String, anchors: [SavedSemanticAnchor]) -> RoomSignatureArtifact?
    func buildLiveSignatureSnapshot(currentYaw: Float, featurePointCount: Int) -> RoomSignatureArtifact?
    func match(live: RoomSignatureArtifact, saved: RoomSignatureArtifact) -> RoomSignatureMatchResult?
}

private struct StubRoomSignatureProvider: RoomSignatureProvider {
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

private enum Phase1MapStore {
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

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
final class RoomPlanModel: NSObject, ObservableObject {
    private let anchorConfidenceThreshold: Float = 0.70

    @Published var isSessionRunning = false
    @Published var trackingStateText = "Not started"
    @Published var mappingStatusText = "n/a"
    @Published var guidanceText = "Start a scan and slowly move around walls/furniture."
    @Published var relocalizationText = "No map loaded"
    @Published var localizationStateText = "Unknown"
    @Published var poseText = "x 0.00  y 0.00  z 0.00  yaw 0°"
    @Published var poseDebugText = "Position: (0.00, 0.00, 0.00) | Heading: 0° | Confidence: 0%"
    @Published var poseStabilityText = "Pose stability: unknown"
    @Published var headingJitterText = "Heading jitter: n/a"
    @Published var localizationConfidenceText = "Localization confidence: 0%"
    @Published var meshAnchorCount = 0
    @Published var planeAnchorCount = 0
    @Published var featurePointCount = 0
    @Published var hasSavedMap = false
    @Published var lastSavedText = "No saved map"
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var anchors: [SavedSemanticAnchor] = []
    @Published var selectedAnchorType: AnchorType = .door
    @Published var anchorDraftName = ""
    @Published var anchorPingText: String?
    @Published var anchorOperationMessage: String?
    @Published var anchorPlacementAllowed = false
    @Published var anchorPlacementBlockReason: String?
    @Published var isAnchorModePresented = false
    @Published var anchorPlacementMode: AnchorPlacementMode = .aimedRaycast
    @Published var anchorTargetPreviewText: String?
    @Published var anchorTargetingReady = false
    @Published var anchorModeStatusText = "Relocalize and aim at a landmark"
    @Published var showDebugOverlay = true
    @Published var mapReadinessText = "Map Readiness: n/a"
    @Published var mapReadinessScoreText = "Readiness score: 0%"
    @Published var mapReadinessWarningsText: String?
    @Published var saveMapWarningText: String?
    @Published var relocalizationAttemptModeText = "Reloc Attempt: n/a"
    @Published var relocalizationAttemptProgressText = "Rotation progress: 0° / 360°"
    @Published var relocalizationFallbackPromptText: String?
    @Published var showAdvancedRelocDebug = false
    @Published var fallbackRelocalizationText = "Fallback Reloc: Inactive"
    @Published var fallbackRelocalizationActive = false
    @Published var fallbackRelocalizationModeText = "Fallback Mode: None"
    @Published var fallbackRelocalizationPromptText: String?
    @Published var fallbackRelocalizationConfidenceText = "Fallback confidence: 0%"
    @Published var hasRoomSignatureArtifact = false
    @Published var roomSignatureStatusText = "Room Signature: Not captured"
    @Published var roomSignatureCaptureWarningText: String?
    @Published var meshFallbackText = "Mesh Fallback: Inactive"
    @Published var meshFallbackPhaseText = "Mesh Fallback Phase: idle"
    @Published var meshFallbackConfidenceText = "Mesh Fallback Confidence: 0%"
    @Published var meshFallbackPromptText: String?
    @Published var meshArtifactStatusText = "Mesh Artifact: Not captured"
    @Published var meshArtifactCaptureWarningText: String?
    @Published var meshPoseSeedText = "Mesh Pose Seed: n/a"
    @Published var appLocalizationStateText = "App Localization: Searching"
    @Published var appLocalizationSourceText = "Localization Source: None"
    @Published var appLocalizationPromptText = "App localization not ready"
    @Published var appLocalizationConfidenceText = "App localization confidence: 0%"
    @Published var meshOverrideAppliedText = "World Origin Shift: No"
    @Published var arkitVsAppStateText = "ARKit vs App: No map alignment yet"
    @Published var localizationConflictText: String?
    @Published var meshOverrideStatusText = "Mesh Override: Awaiting stable mesh alignment"
    @Published var worldOriginShiftDebugText = "World Origin Shift Debug: n/a"

    fileprivate weak var sceneView: ARSCNView?

    private var awaitingRelocalization = false
    private var sawRelocalizingState = false
    private var stableNormalFramesAfterLoad = 0
    private var loadRequestedAt: Date?
    private var localizationState: LocalizationState = .unknown {
        didSet {
            localizationStateText = localizationState.displayText
        }
    }

    private var lastTransform: simd_float4x4?
    private var lastMovementAt = Date()
    private var yawSweepWindowStart = Date()
    private var yawSweepAccumulated: Float = 0
    private var lastYaw: Float?
    private var yawJitterSamples: [(time: Date, yaw: Float)] = []
    private var currentPoseTransform: simd_float4x4?
    private var latestLocalizationConfidence: Float = 0
    private var isPoseStableForAnchorActions = false
    private var latestAnchorTargetPreview = AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: "No target", surfaceKind: nil)
    private var consecutiveValidRaycastFrames = 0
    private var recentMappingSamples: [ARFrame.WorldMappingStatus] = []
    private var recentFeaturePointSamples: [Int] = []
    private var recentTrackingNormalSamples: [Bool] = []
    private var sessionYawCoverageAccumulated: Float = 0
    private var sessionTranslationAccumulated: Float = 0
    private var relocalizationAttemptState: RelocalizationAttemptState?
    private var relocalizationAttemptLastYaw: Float?
    private var fallbackRelocalizationState = FallbackRelocalizationState(
        isActive: false,
        mode: .none,
        startedAt: Date(),
        scanProgressText: "Idle",
        matchResult: nil,
        failureReason: nil,
        rotationAccumulatedDegrees: 0,
        lastYaw: nil
    )
    private let roomSignatureProvider: RoomSignatureProvider = StubRoomSignatureProvider()
    private var savedRoomSignatureArtifact: RoomSignatureArtifact?
    private var savedMeshArtifact: MeshMapArtifact?
    private var meshFallbackState = MeshFallbackState(
        active: false,
        phase: .idle,
        startedAt: Date(),
        progressText: "Idle",
        result: nil
    )
    private var appLocalizationState: AppLocalizationState = .searching
    private var appLocalizationSource: AppLocalizationSource = .none
    private var acceptedMeshAlignment: MeshAlignmentAcceptance?
    private var hasAppliedWorldOriginShiftForCurrentAttempt = false
    private var meshAlignmentCandidateBuffer: [MeshRelocalizationResult] = []
    private var preShiftSessionPoseSnapshot: simd_float4x4?
    private var postShiftValidationFrames = 0
    private var lastConflictSnapshot: LocalizationConflictSnapshot?
    private var conflictDisagreementFrames = 0

    override init() {
        super.init()
        resetAppLocalizationStateForNewAttempt()
        refreshSavedMapState()
        loadAnchorsFromDisk()
        refreshRoomSignatureStatus()
        refreshMeshArtifactStatus()
        refreshAnchorActionAvailability()
    }

    func attachSceneView(_ view: ARSCNView) {
        sceneView = view
        view.session.delegate = self
        view.delegate = self
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.debugOptions = [.showFeaturePoints]
        refreshSavedMapState()
        refreshRoomSignatureStatus()
        refreshMeshArtifactStatus()
    }

    func startFreshScan() {
        guard ARWorldTrackingConfiguration.isSupported else {
            errorMessage = "ARWorldTracking is not supported on this device."
            return
        }
        runSession(initialWorldMap: nil)
        relocalizationText = "Fresh scan session"
        localizationState = .unknown
        statusMessage = "Scanning started"
        errorMessage = nil
        awaitingRelocalization = false
        loadRequestedAt = nil
        resetAppLocalizationStateForNewAttempt()
    }

    func stopScan() {
        sceneView?.session.pause()
        isSessionRunning = false
        statusMessage = "Session paused"
    }

    func saveCurrentMap() {
        guard let session = sceneView?.session else {
            errorMessage = "AR session not ready."
            return
        }
        let frameForMeshCapture = session.currentFrame
        saveMapWarningText = saveReadinessWarningIfNeeded()
        statusMessage = "Saving map..."
        errorMessage = nil
        session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self else { return }
            Task { @MainActor [self] in
                if let error {
                    self.errorMessage = "Save failed: \(error.localizedDescription)"
                    self.statusMessage = nil
                    return
                }
                guard let worldMap else {
                    self.errorMessage = "Save failed: ARWorldMap was nil."
                    self.statusMessage = nil
                    return
                }
                do {
                    let metadata = try Phase1MapStore.save(worldMap: worldMap)
                    self.captureRoomSignatureIfAvailable()
                    self.captureMeshArtifactIfAvailable(from: frameForMeshCapture)
                    self.hasSavedMap = true
                    self.lastSavedText = "Saved \(metadata.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                    self.loadAnchorsFromDisk()
                    self.refreshRoomSignatureStatus()
                    self.refreshMeshArtifactStatus()
                    if let warning = self.saveMapWarningText {
                        self.statusMessage = "Map saved (warning: weaker relocalization readiness)"
                        self.anchorOperationMessage = warning
                    } else {
                        self.statusMessage = "Map saved on device"
                    }
                } catch {
                    self.errorMessage = "Save failed: \(error.localizedDescription)"
                    self.statusMessage = nil
                }
            }
        }
    }

    func loadSavedMapAndRelocalize() {
        do {
            let worldMap = try Phase1MapStore.loadWorldMap()
            loadAnchorsFromDisk()
            savedRoomSignatureArtifact = try Phase1MapStore.loadRoomSignature()
            savedMeshArtifact = try Phase1MapStore.loadMeshArtifact()
            refreshRoomSignatureStatus()
            refreshMeshArtifactStatus()
            awaitingRelocalization = true
            sawRelocalizingState = false
            stableNormalFramesAfterLoad = 0
            loadRequestedAt = Date()
            localizationState = .relocalizing
            relocalizationText = "Loaded map. Walk to the same area to relocalize..."
            statusMessage = "Map loaded, relocalization running"
            errorMessage = nil
            resetAppLocalizationStateForNewAttempt()
            runSession(initialWorldMap: worldMap)
            beginRelocalizationAttempt()
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    func captureRoomSignatureIfAvailable() {
        guard let artifact = roomSignatureProvider.captureCurrentSignature(mapName: Phase1MapStore.mapName, anchors: anchors) else {
            roomSignatureCaptureWarningText = "Room signature not captured (fallback unavailable). Add anchors or integrate RoomPlan capture later."
            return
        }
        saveRoomSignatureArtifact(artifact)
    }

    func buildRoomSignatureArtifact() -> RoomSignatureArtifact? {
        roomSignatureProvider.captureCurrentSignature(mapName: Phase1MapStore.mapName, anchors: anchors)
    }

    func saveRoomSignatureArtifact(_ artifact: RoomSignatureArtifact) {
        do {
            try Phase1MapStore.saveRoomSignature(artifact)
            savedRoomSignatureArtifact = artifact
            roomSignatureCaptureWarningText = nil
            roomSignatureStatusText = "Room Signature: Available (\(artifact.source))"
            hasRoomSignatureArtifact = true
        } catch {
            roomSignatureCaptureWarningText = "Room signature save failed: \(error.localizedDescription)"
        }
    }

    func refreshRoomSignatureStatus() {
        do {
            savedRoomSignatureArtifact = try Phase1MapStore.loadRoomSignature()
            hasRoomSignatureArtifact = savedRoomSignatureArtifact != nil
            if let artifact = savedRoomSignatureArtifact {
                roomSignatureStatusText = "Room Signature: Available (\(artifact.source))"
            } else {
                roomSignatureStatusText = "Room Signature: Not captured"
            }
        } catch {
            hasRoomSignatureArtifact = false
            roomSignatureStatusText = "Room Signature: Unreadable"
            roomSignatureCaptureWarningText = "Room signature load failed: \(error.localizedDescription)"
        }
    }

    func captureMeshArtifactIfAvailable(from frame: ARFrame?) {
        guard let frame else {
            meshArtifactCaptureWarningText = "Mesh artifact not captured (no current AR frame)"
            return
        }
        guard let artifact = buildMeshMapArtifact(from: frame) else {
            meshArtifactCaptureWarningText = "Mesh artifact not captured (no mesh anchors / extraction failed)"
            return
        }
        saveMeshArtifact(artifact)
    }

    func saveMeshArtifact(_ artifact: MeshMapArtifact) {
        do {
            try Phase1MapStore.saveMeshArtifact(artifact)
            savedMeshArtifact = artifact
            meshArtifactCaptureWarningText = nil
            meshArtifactStatusText = "Mesh Artifact: Available (\(artifact.meshAnchors.count) anchors)"
        } catch {
            meshArtifactCaptureWarningText = "Mesh artifact save failed: \(error.localizedDescription)"
            meshArtifactStatusText = "Mesh Artifact: Save failed"
        }
    }

    func refreshMeshArtifactStatus() {
        do {
            savedMeshArtifact = try Phase1MapStore.loadMeshArtifact()
            if let artifact = savedMeshArtifact {
                meshArtifactStatusText = "Mesh Artifact: Available (\(artifact.meshAnchors.count) anchors)"
            } else {
                meshArtifactStatusText = "Mesh Artifact: Not captured"
            }
        } catch {
            meshArtifactStatusText = "Mesh Artifact: Unreadable"
            meshArtifactCaptureWarningText = "Mesh artifact load failed: \(error.localizedDescription)"
        }
    }

    func resetAppLocalizationStateForNewAttempt() {
        appLocalizationState = .searching
        appLocalizationSource = .none
        acceptedMeshAlignment = nil
        hasAppliedWorldOriginShiftForCurrentAttempt = false
        meshAlignmentCandidateBuffer.removeAll()
        preShiftSessionPoseSnapshot = nil
        postShiftValidationFrames = 0
        lastConflictSnapshot = nil
        conflictDisagreementFrames = 0
        localizationConflictText = nil
        meshOverrideStatusText = "Mesh Override: Awaiting stable mesh alignment"
        meshOverrideAppliedText = "World Origin Shift: No"
        worldOriginShiftDebugText = "World Origin Shift Debug: n/a"
        refreshAppLocalizationUI()
    }

    func refreshAppLocalizationUI() {
        appLocalizationStateText = "App Localization: \(appLocalizationState.displayLabel)"
        appLocalizationSourceText = "Localization Source: \(appLocalizationSource.displayLabel)"
        let confidence: Float
        switch appLocalizationState {
        case .meshAlignedOverride:
            confidence = acceptedMeshAlignment?.confidence ?? (meshFallbackState.result?.confidence ?? latestLocalizationConfidence)
        case .arkitConfirmed:
            confidence = max(latestLocalizationConfidence, acceptedMeshAlignment?.confidence ?? 0)
        case .meshAligning:
            confidence = meshFallbackState.result?.confidence ?? 0
        default:
            confidence = latestLocalizationConfidence
        }
        appLocalizationConfidenceText = "App localization confidence: \(Int((max(0, min(1, confidence)) * 100).rounded()))%"

        switch appLocalizationState {
        case .searching:
            appLocalizationPromptText = "Searching for usable alignment. Scan walls/corners slowly."
        case .meshAligning:
            appLocalizationPromptText = "Mesh aligning in progress. Hold position if safe and rotate slowly."
        case .meshAlignedOverride:
            appLocalizationPromptText = "Aligned (provisional via mesh). Move slowly; ARKit still confirming."
        case .arkitConfirmed:
            appLocalizationPromptText = "Aligned. You can proceed."
        case .conflict:
            appLocalizationPromptText = "Alignment conflict detected. Stop and scan walls/corners."
        case .degraded:
            appLocalizationPromptText = "Alignment degraded. Move slowly and rescan strong geometry."
        }

        let arkitState = localizationState.displayText
        arkitVsAppStateText = "ARKit: \(arkitState) | App: \(appLocalizationState.displayLabel)"
        meshOverrideAppliedText = "World Origin Shift: \(hasAppliedWorldOriginShiftForCurrentAttempt ? "Yes" : "No")"
    }

    func updateScanReadinessMetrics(with frame: ARFrame, currentTransform: simd_float4x4, currentYaw: Float) {
        recentMappingSamples.append(frame.worldMappingStatus)
        recentFeaturePointSamples.append(frame.rawFeaturePoints?.points.count ?? 0)
        let trackingNormal = {
            if case .normal = frame.camera.trackingState { return true }
            return false
        }()
        recentTrackingNormalSamples.append(trackingNormal)

        let maxSamples = 180
        if recentMappingSamples.count > maxSamples { recentMappingSamples.removeFirst(recentMappingSamples.count - maxSamples) }
        if recentFeaturePointSamples.count > maxSamples { recentFeaturePointSamples.removeFirst(recentFeaturePointSamples.count - maxSamples) }
        if recentTrackingNormalSamples.count > maxSamples { recentTrackingNormalSamples.removeFirst(recentTrackingNormalSamples.count - maxSamples) }

        let _ = currentTransform
        let _ = currentYaw
        refreshMapReadinessUI()
    }

    func computeScanReadinessSnapshot() -> ScanReadinessSnapshot {
        let mappedCount = recentMappingSamples.filter { $0 == .mapped }.count
        let mappingMappedRatio = recentMappingSamples.isEmpty ? 0 : Float(mappedCount) / Float(recentMappingSamples.count)
        let trackingNormalCount = recentTrackingNormalSamples.filter { $0 }.count
        let trackingNormalRatio = recentTrackingNormalSamples.isEmpty ? 0 : Float(trackingNormalCount) / Float(recentTrackingNormalSamples.count)
        let medianFeature = median(recentFeaturePointSamples)
        let yawCoverageDegrees = min(sessionYawCoverageAccumulated * 180 / .pi, 1080)
        let translationDistanceMeters = sessionTranslationAccumulated

        var score: Float = 0
        score += min(mappingMappedRatio / 0.7, 1) * 0.30
        score += min(trackingNormalRatio / 0.8, 1) * 0.20
        score += min(Float(medianFeature) / 350, 1) * 0.20
        score += min(yawCoverageDegrees / 540, 1) * 0.15
        score += min(translationDistanceMeters / 4.0, 1) * 0.15

        var warnings: [String] = []
        if mappingMappedRatio < 0.45 { warnings.append("Mapping stability low (mapped frames inconsistent)") }
        if medianFeature < 180 { warnings.append("Low feature richness; scan textured edges/furniture") }
        if yawCoverageDegrees < 300 { warnings.append("Limited rotational coverage; rotate in place more") }
        if translationDistanceMeters < 1.5 { warnings.append("Not enough viewpoint movement for robust relocalization") }
        if trackingNormalRatio < 0.6 { warnings.append("Tracking frequently limited; slow down and revisit") }

        return ScanReadinessSnapshot(
            mappingMappedRatio: mappingMappedRatio,
            featurePointMedian: medianFeature,
            yawCoverageDegrees: yawCoverageDegrees,
            translationDistanceMeters: translationDistanceMeters,
            trackingNormalRatio: trackingNormalRatio,
            qualityScore: min(max(score, 0), 1),
            warnings: warnings
        )
    }

    func refreshMapReadinessUI() {
        let snapshot = computeScanReadinessSnapshot()
        let pct = Int((snapshot.qualityScore * 100).rounded())
        let label: String
        switch snapshot.qualityScore {
        case ..<0.45: label = "Weak"
        case ..<0.65: label = "Fair"
        case ..<0.82: label = "Good"
        default: label = "Strong"
        }
        mapReadinessText = "Map Readiness: \(pct)% (\(label))"
        mapReadinessScoreText = String(
            format: "Readiness details: mapped %.0f%%, features %d, rotation %.0f°, move %.1fm",
            snapshot.mappingMappedRatio * 100,
            snapshot.featurePointMedian,
            snapshot.yawCoverageDegrees,
            snapshot.translationDistanceMeters
        )
        mapReadinessWarningsText = snapshot.warnings.prefix(2).joined(separator: " | ")
        saveMapWarningText = snapshot.qualityScore < 0.65
            ? "This map may relocalize poorly from random starts. Scan more viewpoints and rotate 360° in key areas before saving."
            : nil
    }

    func saveReadinessWarningIfNeeded() -> String? {
        let snapshot = computeScanReadinessSnapshot()
        guard snapshot.qualityScore < 0.65 else { return nil }
        return "This map may relocalize poorly from random starts. Scan more viewpoints and rotate 360° in key areas before saving."
    }

    func beginRelocalizationAttempt() {
        relocalizationAttemptState = RelocalizationAttemptState(
            mode: .stationary360,
            startedAt: Date(),
            rotationAccumulatedDegrees: 0,
            featurePointMedianRecent: 0,
            sawRelocalizingTracking: false,
            stableNormalFrames: 0,
            timeoutSeconds: 10
        )
        relocalizationAttemptLastYaw = nil
        relocalizationFallbackPromptText = nil
        refreshRelocalizationGuidanceUI()
    }

    func resetRelocalizationAttemptState() {
        relocalizationAttemptState = nil
        relocalizationAttemptLastYaw = nil
        relocalizationAttemptModeText = "Reloc Attempt: n/a"
        relocalizationAttemptProgressText = "Rotation progress: 0° / 360°"
        relocalizationFallbackPromptText = nil
        resetMeshFallbackState()
        resetFallbackRelocalizationState()
    }

    func updateRelocalizationAttemptMetrics(with frame: ARFrame, currentTransform: simd_float4x4, currentYaw: Float) {
        guard awaitingRelocalization || localizationState == .relocalizing else { return }
        guard var state = relocalizationAttemptState else { return }
        let _ = currentTransform

        if let last = relocalizationAttemptLastYaw {
            let delta = abs(normalizedAngle(currentYaw - last)) * 180 / .pi
            state.rotationAccumulatedDegrees += delta
        }
        relocalizationAttemptLastYaw = currentYaw

        if case .limited(.relocalizing) = frame.camera.trackingState {
            state.sawRelocalizingTracking = true
        }
        if case .normal = frame.camera.trackingState {
            state.stableNormalFrames += 1
        } else {
            state.stableNormalFrames = 0
        }
        let recent = recentFeaturePointSamples.suffix(60)
        state.featurePointMedianRecent = median(Array(recent))

        relocalizationAttemptState = state
        if shouldEscalateFromStationaryToMicroMovement() {
            escalateRelocalizationAttemptToMicroMovement()
        }
        if shouldTriggerMeshFallback() {
            beginMeshFallbackRelocalization()
        }
        if meshFallbackState.active {
            updateMeshFallbackProgress(with: frame, currentYaw: currentYaw)
        } else {
            if shouldTriggerRoomSignatureFallback() {
                beginFallbackRelocalizationIfNeeded()
            }
            if fallbackRelocalizationState.isActive {
                updateFallbackRelocalizationProgress(currentYaw: currentYaw)
            }
        }
        refreshRelocalizationGuidanceUI()
    }

    func refreshRelocalizationGuidanceUI() {
        guard let snapshot = currentRelocalizationGuidanceSnapshot() else {
            if !awaitingRelocalization {
                relocalizationAttemptModeText = "Reloc Attempt: n/a"
                relocalizationAttemptProgressText = "Rotation progress: 0° / 360°"
                relocalizationFallbackPromptText = nil
            }
            return
        }
        relocalizationAttemptModeText = "Reloc Attempt: \(snapshot.attemptMode.displayName)"
        relocalizationAttemptProgressText = snapshot.attemptProgressText
        relocalizationFallbackPromptText = snapshot.attemptMode == .microMovementFallback ? snapshot.recommendedActionText : nil

        if awaitingRelocalization || localizationState == .relocalizing {
            if meshFallbackState.active {
                guidanceText = meshFallbackPromptText ?? snapshot.recommendedActionText
                relocalizationText = meshFallbackText
            } else if fallbackRelocalizationState.isActive {
                guidanceText = fallbackRelocalizationPromptText ?? snapshot.recommendedActionText
                relocalizationText = fallbackRelocalizationText
            } else {
                guidanceText = snapshot.recommendedActionText
                relocalizationText = snapshot.stationaryAttemptReadyToEscalate
                    ? "Reloc: Fallback movement recommended"
                    : "Reloc: Searching"
            }
        }
    }

    func shouldEscalateFromStationaryToMicroMovement() -> Bool {
        guard let state = relocalizationAttemptState, state.mode == .stationary360 else { return false }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        return state.rotationAccumulatedDegrees >= 330 &&
            elapsed >= state.timeoutSeconds &&
            state.featurePointMedianRecent >= 120 &&
            localizationState != .localized
    }

    func escalateRelocalizationAttemptToMicroMovement() {
        guard var state = relocalizationAttemptState, state.mode == .stationary360 else { return }
        state.mode = .microMovementFallback
        state.startedAt = Date()
        state.timeoutSeconds = 14
        relocalizationAttemptState = state
        relocalizationFallbackPromptText = microMovementRelocPrompt()
    }

    func stationaryRelocPrompt(rotationDegrees: Float, featureMedian: Int) -> String {
        if rotationDegrees < 90 {
            return "Relocalizing (Stationary): hold position and rotate slowly. Aim at walls, corners, and furniture edges."
        }
        if featureMedian < 150 {
            return "Keep rotating, and point at textured surfaces and furniture edges to improve matching."
        }
        if rotationDegrees < 300 {
            return "Good coverage so far. Continue rotating slowly to complete a full sweep."
        }
        return "Nearly done. Finish the 360° sweep and pause briefly for a match."
    }

    func microMovementRelocPrompt() -> String {
        "Take 1-2 small steps, pause, then rotate left/right slowly about 90°. Point at large previously scanned surfaces."
    }

    func shouldTriggerMeshFallback() -> Bool {
        guard savedMeshArtifact != nil else { return false }
        guard let state = relocalizationAttemptState else { return false }
        guard state.mode == .microMovementFallback else { return false }
        guard !meshFallbackState.active else { return false }
        guard localizationState != .localized else { return false }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        return elapsed >= state.timeoutSeconds || (elapsed >= 8 && state.featurePointMedianRecent >= 180)
    }

    func beginMeshFallbackRelocalization() {
        guard savedMeshArtifact != nil else {
            meshFallbackText = "Mesh Fallback: Unavailable"
            meshFallbackPhaseText = "Mesh Fallback Phase: idle"
            meshFallbackPromptText = "No saved mesh artifact available."
            return
        }
        meshFallbackState = MeshFallbackState(
            active: true,
            phase: .coarseMatching,
            startedAt: Date(),
            progressText: "Starting coarse mesh match",
            result: nil
        )
        meshFallbackText = "Mesh Fallback: Active"
        meshFallbackPhaseText = "Mesh Fallback Phase: coarseMatching"
        meshFallbackConfidenceText = "Mesh Fallback Confidence: 0%"
        meshFallbackPromptText = "Mesh fallback active: hold position if safe and rotate slowly to expose walls and furniture geometry."
        meshPoseSeedText = "Mesh Pose Seed: n/a"
        if appLocalizationState == .searching {
            appLocalizationState = .meshAligning
            refreshAppLocalizationUI()
        }
    }

    func updateMeshFallbackProgress(with frame: ARFrame, currentYaw: Float) {
        guard meshFallbackState.active else { return }
        let elapsed = Date().timeIntervalSince(meshFallbackState.startedAt)

        switch meshFallbackState.phase {
        case .coarseMatching:
            meshFallbackState.progressText = String(format: "Coarse matching (%.1fs)", elapsed)
            meshFallbackPhaseText = "Mesh Fallback Phase: coarseMatching"
            let hypotheses = runCoarseMeshSignatureMatch(from: frame)
            if hypotheses.isEmpty {
                if elapsed > 2.0 {
                    meshFallbackState.phase = .inconclusive
                    meshFallbackText = "Mesh Fallback: Inconclusive"
                    meshFallbackPromptText = "Mesh fallback could not find a reliable geometry match. Move toward a wall/corner and retry."
                }
                return
            }
            meshFallbackState.phase = .refiningICP
            meshFallbackPhaseText = "Mesh Fallback Phase: refiningICP"
            if let result = runICPLiteRefinement(hypotheses: hypotheses, frame: frame, currentYaw: currentYaw) {
                applyMeshFallbackGuidance(result)
            } else {
                meshFallbackState.phase = .inconclusive
                meshFallbackText = "Mesh Fallback: Inconclusive"
                meshFallbackPromptText = "Mesh refinement was inconclusive. Try a slower sweep near a wall or large furniture."
            }
        case .refiningICP, .matched, .inconclusive, .idle:
            break
        }
    }

    func runCoarseMeshSignatureMatch(from frame: ARFrame) -> [MeshRelocalizationHypothesis] {
        guard let saved = savedMeshArtifact else { return [] }
        guard let live = extractLiveMeshSnapshot(from: frame) else { return [] }

        let s = saved.descriptor
        let l = live.descriptor
        guard !s.dominantYawBins.isEmpty, !l.dominantYawBins.isEmpty else { return [] }
        let count = min(s.dominantYawBins.count, l.dominantYawBins.count)

        var hypotheses: [MeshRelocalizationHypothesis] = []
        for shift in 0..<count {
            var corr: Float = 0
            for i in 0..<count {
                corr += s.dominantYawBins[i] * l.dominantYawBins[(i + shift) % count]
            }
            let yawStep = 360.0 / Float(count)
            let yaw = Float(shift) * yawStep
            let sCenter = (s.boundsMinXZ + s.boundsMaxXZ) * 0.5
            let lCenter = (l.boundsMinXZ + l.boundsMaxXZ) * 0.5
            let t = sCenter - lCenter
            let occBonus: Float = (s.occupancyHash.first == l.occupancyHash.first) ? 0.1 : 0.0
            hypotheses.append(
                MeshRelocalizationHypothesis(
                    yawDegrees: yaw,
                    translationXZ: t,
                    coarseConfidence: min(max(corr + occBonus, 0), 1),
                    source: "signature"
                )
            )
        }
        return hypotheses.sorted { $0.coarseConfidence > $1.coarseConfidence }.prefix(3).map { $0 }
    }

    func runICPLiteRefinement(hypotheses: [MeshRelocalizationHypothesis], frame: ARFrame, currentYaw: Float) -> MeshRelocalizationResult? {
        guard let liveArtifact = extractLiveMeshSnapshot(from: frame), let saved = savedMeshArtifact else { return nil }
        let livePoints = downsamplePointCloud(flatPointsToSIMD(liveArtifact.meshAnchors.flatMap(\.vertices)), maxPoints: 1200)
        let savedPoints = downsamplePointCloud(flatPointsToSIMD(saved.meshAnchors.flatMap(\.vertices)), maxPoints: 1200)
        guard !livePoints.isEmpty, !savedPoints.isEmpty else { return nil }

        let savedCentroid = centroidXZ(savedPoints)
        let liveCentroid = centroidXZ(livePoints)

        var best: MeshRelocalizationHypothesis?
        var bestScore: Float = -Float.infinity
        for h in hypotheses {
            let yawDelta = angleDistanceDegrees(currentYaw * 180 / .pi, h.yawDegrees)
            let centroidT = savedCentroid - liveCentroid
            let combinedT = (h.translationXZ + centroidT) * 0.5
            let extentPenalty = min(simd_length((saved.descriptor.boundsMaxXZ - saved.descriptor.boundsMinXZ) - (liveArtifact.descriptor.boundsMaxXZ - liveArtifact.descriptor.boundsMinXZ)), 3)
            let score = h.coarseConfidence - (abs(yawDelta) / 180) * 0.25 - extentPenalty * 0.05
            if score > bestScore {
                bestScore = score
                best = MeshRelocalizationHypothesis(
                    yawDegrees: h.yawDegrees,
                    translationXZ: combinedT,
                    coarseConfidence: min(max(score, 0), 1),
                    source: "icp_refined"
                )
            }
        }

        guard let refined = best else { return nil }
        let coarse = hypotheses.first
        let confidence = min(max((coarse?.coarseConfidence ?? 0) * 0.4 + refined.coarseConfidence * 0.6, 0), 1)
        let orientationHint = normalizedDegrees(refined.yawDegrees - currentYaw * 180 / .pi)
        let areaHint = simd_length(refined.translationXZ) > 1.5 ? "room edge side" : "room center side"
        let supportCount = min(livePoints.count, savedPoints.count)
        let residual = min(max(1 - refined.coarseConfidence, 0), 1) * 0.35 + 0.03
        let overlap = min(max(refined.coarseConfidence * 0.75 + 0.15, 0), 1)
        let yawConfidence = max(6, 25 - confidence * 18)
        return MeshRelocalizationResult(
            coarsePoseSeed: coarse,
            refinedPoseSeed: refined,
            orientationHintDegrees: orientationHint,
            areaHint: areaHint,
            confidence: confidence,
            residualErrorMeters: residual,
            overlapRatio: overlap,
            yawConfidenceDegrees: yawConfidence,
            supportingPointCount: supportCount,
            isStableAcrossFrames: false,
            debugReason: "Coarse descriptor hypotheses + centroid/extent bounded refinement"
        )
    }

    func applyMeshFallbackGuidance(_ result: MeshRelocalizationResult) {
        meshFallbackState.result = result
        meshFallbackState.phase = result.confidence >= 0.55 ? .matched : .inconclusive
        meshFallbackText = result.confidence >= 0.55 ? "Mesh Fallback: Matched" : "Mesh Fallback: Low-confidence"
        meshFallbackPhaseText = "Mesh Fallback Phase: \(meshFallbackState.phase.rawValue)"
        meshFallbackConfidenceText = "Mesh Fallback Confidence: \(Int((result.confidence * 100).rounded()))%"
        meshOverrideStatusText = String(
            format: "Mesh Override: candidate conf %.0f%% residual %.2fm overlap %.0f%% yaw±%.0f° pts %d",
            result.confidence * 100,
            result.residualErrorMeters,
            result.overlapRatio * 100,
            result.yawConfidenceDegrees,
            result.supportingPointCount
        )
        if let seed = result.refinedPoseSeed {
            meshPoseSeedText = String(
                format: "Mesh Pose Seed: yaw %.0f°, offset (%.2f, %.2f)m",
                seed.yawDegrees,
                seed.translationXZ.x,
                seed.translationXZ.y
            )
        } else {
            meshPoseSeedText = "Mesh Pose Seed: n/a"
        }

        let orient = Int((result.orientationHintDegrees ?? 0).rounded())
        let direction = orient < 0 ? "left" : "right"
        let angle = abs(orient)
        if result.confidence >= 0.55 {
            meshFallbackPromptText = "Mesh geometry suggests you are near the \(result.areaHint ?? "saved room area"). Turn \(direction) about \(angle)° and hold steady to help ARKit relocalize."
        } else {
            meshFallbackPromptText = "Mesh geometry hint is weak. Move closer to a wall/corner and do a slow sweep, then retry relocalization."
        }
        guidanceText = meshFallbackPromptText ?? guidanceText
    }

    func resetMeshFallbackState() {
        meshFallbackState = MeshFallbackState(
            active: false,
            phase: .idle,
            startedAt: Date(),
            progressText: "Idle",
            result: nil
        )
        meshFallbackText = "Mesh Fallback: Inactive"
        meshFallbackPhaseText = "Mesh Fallback Phase: idle"
        meshFallbackConfidenceText = "Mesh Fallback Confidence: 0%"
        meshFallbackPromptText = nil
        meshPoseSeedText = "Mesh Pose Seed: n/a"
        meshAlignmentCandidateBuffer.removeAll()
    }

    func updateAppLocalizationState(with frame: ARFrame, currentYaw: Float) {
        if localizationState == .localized, loadRequestedAt != nil {
            if appLocalizationState == .meshAlignedOverride {
                reconcileARKitRelocalizationAgainstMeshOverride(with: frame)
            } else if appLocalizationState != .conflict {
                promoteToARKitConfirmed()
            }
        } else if meshFallbackState.active, appLocalizationState == .searching {
            appLocalizationState = .meshAligning
        }

        if let result = meshFallbackState.result,
           appLocalizationState != .arkitConfirmed,
           appLocalizationState != .conflict,
           !hasAppliedWorldOriginShiftForCurrentAttempt
        {
            if let acceptance = stabilizeMeshAlignmentCandidate(result) {
                meshOverrideStatusText = String(
                    format: "Mesh Override: Accepted (conf %.0f%%, residual %.2fm, overlap %.0f%%)",
                    acceptance.confidence * 100,
                    acceptance.residualErrorMeters,
                    acceptance.overlapRatio * 100
                )
                promoteToMeshAlignedOverride(using: acceptance)
            }
        }

        if appLocalizationState == .meshAlignedOverride {
            validatePostShiftAlignment(with: frame)
            if localizationState == .localized {
                reconcileARKitRelocalizationAgainstMeshOverride(with: frame)
            }
        }

        if appLocalizationState == .meshAlignedOverride && !isPoseStableForAnchorActions && latestLocalizationConfidence < 0.35 {
            degradeAppLocalization(reason: "Pose stability and confidence dropped after mesh alignment")
        }

        if appLocalizationState == .meshAligning && meshFallbackState.phase == .inconclusive {
            appLocalizationState = .searching
            meshOverrideStatusText = "Mesh Override: Rejected (inconclusive)"
        }

        let _ = currentYaw
        refreshAppLocalizationUI()
    }

    func promoteToMeshAlignedOverride(using acceptance: MeshAlignmentAcceptance) {
        acceptedMeshAlignment = acceptance
        appLocalizationSource = .meshICP
        applyWorldOriginShiftIfNeeded(using: acceptance)
        appLocalizationState = .meshAlignedOverride
        let confidencePercent = Int((acceptance.confidence * 100).rounded())
        meshFallbackPromptText = "Aligned via mesh override (\(confidencePercent)%). Move slowly while ARKit continues confirming."
        guidanceText = meshFallbackPromptText ?? guidanceText
    }

    func promoteToARKitConfirmed() {
        appLocalizationState = .arkitConfirmed
        if acceptedMeshAlignment != nil {
            appLocalizationSource = .arkitAndMeshConsistent
        } else {
            appLocalizationSource = .arkitWorldMap
        }
        localizationConflictText = nil
        lastConflictSnapshot = nil
        conflictDisagreementFrames = 0
        meshOverrideStatusText = hasAppliedWorldOriginShiftForCurrentAttempt
            ? "Mesh Override: Applied; ARKit confirmed alignment"
            : "Mesh Override: Not needed (ARKit confirmed)"
    }

    func degradeAppLocalization(reason: String) {
        guard appLocalizationState != .conflict else { return }
        appLocalizationState = .degraded
        localizationConflictText = nil
        meshOverrideStatusText = "Mesh Override: Degraded"
        guidanceText = "Alignment degraded. \(reason). Face a wall/corner and rotate slowly."
    }

    func enterLocalizationConflict(_ conflict: LocalizationConflictSnapshot) {
        appLocalizationState = .conflict
        lastConflictSnapshot = conflict
        let pos = String(format: "%.2f", conflict.positionDeltaMeters)
        let yaw = String(format: "%.0f", conflict.yawDeltaDegrees)
        localizationConflictText = "ARKit/mesh conflict: Δpos \(pos)m, Δyaw \(yaw)°"
        meshOverrideStatusText = "Mesh Override: Conflict detected"
        guidanceText = "Alignment conflict detected. Stop and scan walls/corners for re-alignment."
    }

    func evaluateMeshAlignmentCandidate(_ result: MeshRelocalizationResult) -> Bool {
        guard result.confidence >= 0.80 else { return false }
        guard result.residualErrorMeters <= 0.20 else { return false }
        guard result.overlapRatio >= 0.35 else { return false }
        guard result.yawConfidenceDegrees <= 12 else { return false }
        guard result.supportingPointCount >= 250 else { return false }
        return true
    }

    func stabilizeMeshAlignmentCandidate(_ result: MeshRelocalizationResult) -> MeshAlignmentAcceptance? {
        meshAlignmentCandidateBuffer.append(result)
        if meshAlignmentCandidateBuffer.count > 5 {
            meshAlignmentCandidateBuffer.removeFirst(meshAlignmentCandidateBuffer.count - 5)
        }
        guard evaluateMeshAlignmentCandidate(result) else {
            meshOverrideStatusText = String(
                format: "Mesh Override: Rejected (conf %.0f%%, residual %.2fm, overlap %.0f%%)",
                result.confidence * 100,
                result.residualErrorMeters,
                result.overlapRatio * 100
            )
            return nil
        }
        guard meshAlignmentCandidateBuffer.count >= 3 else {
            meshOverrideStatusText = "Mesh Override: Candidate good, waiting for stability"
            return nil
        }

        let recent = Array(meshAlignmentCandidateBuffer.suffix(3))
        guard recent.allSatisfy({ evaluateMeshAlignmentCandidate($0) }) else { return nil }
        let seeds = recent.compactMap(\.refinedPoseSeed)
        guard seeds.count == 3, let latestSeed = seeds.last else { return nil }
        let yawStable = seeds.dropLast().allSatisfy { angleDistanceDegrees($0.yawDegrees, latestSeed.yawDegrees) <= 10 }
        let transStable = seeds.dropLast().allSatisfy {
            simd_distance($0.translationXZ, latestSeed.translationXZ) <= 0.45
        }
        guard yawStable, transStable else {
            meshOverrideStatusText = "Mesh Override: Candidate unstable across frames"
            return nil
        }

        let mapFromSession = simd_float4x4(
            yawRadians: latestSeed.yawDegrees * .pi / 180,
            translation: SIMD3<Float>(latestSeed.translationXZ.x, 0, latestSeed.translationXZ.y)
        )
        let conf = recent.map(\.confidence).reduce(0, +) / Float(recent.count)
        let residual = recent.map(\.residualErrorMeters).reduce(0, +) / Float(recent.count)
        let overlap = recent.map(\.overlapRatio).reduce(0, +) / Float(recent.count)
        let yawConf = recent.map(\.yawConfidenceDegrees).reduce(0, +) / Float(recent.count)
        return MeshAlignmentAcceptance(
            mapFromSessionTransform: mapFromSession,
            confidence: conf,
            residualErrorMeters: residual,
            overlapRatio: overlap,
            yawConfidenceDegrees: yawConf,
            acceptedAt: Date(),
            supportingFrames: recent.count
        )
    }

    func applyWorldOriginShiftIfNeeded(using acceptance: MeshAlignmentAcceptance) {
        guard !hasAppliedWorldOriginShiftForCurrentAttempt else { return }
        guard let session = sceneView?.session else { return }
        preShiftSessionPoseSnapshot = currentPoseTransform
        let relative = computeWorldOriginRelativeTransform(from: acceptance.mapFromSessionTransform)
        session.setWorldOrigin(relativeTransform: relative)
        hasAppliedWorldOriginShiftForCurrentAttempt = true
        postShiftValidationFrames = 0
        worldOriginShiftDebugText = String(
            format: "World Origin Shift Debug: applied conf %.0f%% residual %.2fm overlap %.0f%% (using map<-session)",
            acceptance.confidence * 100,
            acceptance.residualErrorMeters,
            acceptance.overlapRatio * 100
        )
        meshOverrideStatusText = "Mesh Override: Applied world-origin shift"
    }

    func computeWorldOriginRelativeTransform(from mapFromSession: simd_float4x4) -> simd_float4x4 {
        mapFromSession
    }

    func validatePostShiftAlignment(with frame: ARFrame) {
        guard hasAppliedWorldOriginShiftForCurrentAttempt else { return }
        postShiftValidationFrames += 1
        if postShiftValidationFrames < 5 { return }
        if meshFallbackState.phase == .inconclusive {
            degradeAppLocalization(reason: "Post-shift mesh validation became inconclusive")
            return
        }
        if case .limited = frame.camera.trackingState, latestLocalizationConfidence < 0.30 {
            degradeAppLocalization(reason: "Tracking remained limited after mesh-aligned override")
        }
    }

    func reconcileARKitRelocalizationAgainstMeshOverride(with frame: ARFrame) {
        guard appLocalizationState == .meshAlignedOverride else {
            if localizationState == .localized, loadRequestedAt != nil {
                promoteToARKitConfirmed()
            }
            return
        }
        guard let conflict = computeARKitMeshDisagreement(frame: frame) else {
            conflictDisagreementFrames = 0
            promoteToARKitConfirmed()
            return
        }
        conflictDisagreementFrames += 1
        if shouldTrustARKitOverMesh(conflict: conflict) {
            conflictDisagreementFrames = 0
            promoteToARKitConfirmed()
            return
        }
        if conflictDisagreementFrames >= 5 {
            enterLocalizationConflict(conflict)
        }
    }

    func computeARKitMeshDisagreement(frame: ARFrame) -> LocalizationConflictSnapshot? {
        guard let acceptance = acceptedMeshAlignment else { return nil }
        let arkitYaw = frame.camera.transform.forwardYawRadians * 180 / .pi
        let meshYaw = acceptance.mapFromSessionTransform.forwardYawRadians * 180 / .pi
        let yawDelta = angleDistanceDegrees(arkitYaw, meshYaw)

        let arkitPos = frame.camera.transform.translation
        let meshPos = acceptance.mapFromSessionTransform.translation
        let posDelta = simd_distance(SIMD2<Float>(arkitPos.x, arkitPos.z), SIMD2<Float>(meshPos.x, meshPos.z))

        guard posDelta > 0.75 || yawDelta > 25 else { return nil }
        return LocalizationConflictSnapshot(
            positionDeltaMeters: posDelta,
            yawDeltaDegrees: yawDelta,
            arkitStateAtConflict: localizationState.displayText,
            meshConfidenceAtConflict: acceptance.confidence,
            detectedAt: Date()
        )
    }

    func shouldTrustARKitOverMesh(conflict: LocalizationConflictSnapshot) -> Bool {
        latestLocalizationConfidence > 0.9 && conflict.meshConfidenceAtConflict < 0.82
    }

    func buildMeshMapArtifact(from frame: ARFrame) -> MeshMapArtifact? {
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return nil }

        var records: [MeshAnchorRecord] = []
        records.reserveCapacity(meshAnchors.count)
        for meshAnchor in meshAnchors {
            guard let record = meshAnchor.toRecord() else { continue }
            records.append(record)
        }
        guard !records.isEmpty else { return nil }
        let descriptor = buildMeshSignatureDescriptor(from: records)
        return MeshMapArtifact(
            mapName: Phase1MapStore.mapName,
            capturedAt: Date(),
            meshAnchors: records,
            descriptor: descriptor,
            version: 1
        )
    }

    func extractLiveMeshSnapshot(from frame: ARFrame) -> MeshMapArtifact? {
        buildMeshMapArtifact(from: frame)
    }

    func buildMeshSignatureDescriptor(from meshAnchors: [MeshAnchorRecord]) -> MeshSignatureDescriptor {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(meshAnchors.reduce(0) { $0 + ($1.vertices.count / 3) })

        for record in meshAnchors {
            points.append(contentsOf: record.vertices.chunked3SIMD)
            if let flatNormals = record.normals {
                normals.append(contentsOf: flatNormals.chunked3SIMD)
            }
        }

        let dsPoints = downsamplePointCloud(points, maxPoints: 5000)
        let wallNormals = estimateWallLikePlanes(points: dsPoints, normals: normals)

        var yawBins = Array(repeating: Float(0), count: 12)
        for n in wallNormals {
            let yaw = atan2(n.z, n.x)
            var idx = Int(((yaw + .pi) / (2 * .pi)) * Float(yawBins.count))
            idx = max(0, min(yawBins.count - 1, idx))
            yawBins[idx] += 1
        }
        let yawSum = max(yawBins.reduce(0, +), 1)
        yawBins = yawBins.map { $0 / yawSum }

        let heights = dsPoints.map(\.y)
        let minY = heights.min() ?? 0
        let maxY = heights.max() ?? 1
        let hRange = max(maxY - minY, 0.001)
        var heightBins = Array(repeating: Float(0), count: 8)
        for y in heights {
            var idx = Int(((y - minY) / hRange) * Float(heightBins.count))
            idx = max(0, min(heightBins.count - 1, idx))
            heightBins[idx] += 1
        }
        let hSum = max(heightBins.reduce(0, +), 1)
        heightBins = heightBins.map { $0 / hSum }

        let xzs = dsPoints.map { SIMD2<Float>($0.x, $0.z) }
        let minX = xzs.map(\.x).min() ?? 0
        let minZ = xzs.map(\.y).min() ?? 0
        let maxX = xzs.map(\.x).max() ?? 0
        let maxZ = xzs.map(\.y).max() ?? 0
        let occupancyHash = coarseOccupancyHash(pointsXZ: xzs, minX: minX, minZ: minZ, maxX: maxX, maxZ: maxZ)

        return MeshSignatureDescriptor(
            dominantYawBins: yawBins,
            heightHistogram: heightBins,
            occupancyHash: occupancyHash,
            boundsMinXZ: SIMD2(minX, minZ),
            boundsMaxXZ: SIMD2(maxX, maxZ),
            pointCount: dsPoints.count
        )
    }

    func downsamplePointCloud(_ points: [SIMD3<Float>], maxPoints: Int) -> [SIMD3<Float>] {
        guard points.count > maxPoints, maxPoints > 0 else { return points }
        let step = max(1, points.count / maxPoints)
        return Swift.stride(from: 0, to: points.count, by: step).map { points[$0] }
    }

    func estimateWallLikePlanes(points: [SIMD3<Float>], normals: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !normals.isEmpty else {
            // Fallback heuristic if normals unavailable: infer no strong wall normals.
            return []
        }
        return normals.filter { abs($0.y) < 0.45 }.map { simd_normalize(SIMD3($0.x, 0, $0.z)) }
    }

    private func coarseOccupancyHash(pointsXZ: [SIMD2<Float>], minX: Float, minZ: Float, maxX: Float, maxZ: Float) -> [UInt64] {
        guard !pointsXZ.isEmpty else { return [0] }
        let nx = 8
        let nz = 8
        let sx = max(maxX - minX, 0.01)
        let sz = max(maxZ - minZ, 0.01)
        var bits = Array(repeating: false, count: nx * nz)
        for p in pointsXZ {
            let ix = max(0, min(nx - 1, Int(((p.x - minX) / sx) * Float(nx))))
            let iz = max(0, min(nz - 1, Int(((p.y - minZ) / sz) * Float(nz))))
            bits[iz * nx + ix] = true
        }
        var word: UInt64 = 0
        for (i, bit) in bits.enumerated() where bit {
            word |= (UInt64(1) << UInt64(i))
        }
        return [word]
    }

    func beginFallbackRelocalizationIfNeeded() {
        guard !fallbackRelocalizationState.isActive else { return }
        guard hasRoomSignatureArtifact, savedRoomSignatureArtifact != nil else {
            fallbackRelocalizationText = "Fallback Reloc: Unavailable (no room signature)"
            fallbackRelocalizationModeText = "Fallback Mode: None"
            fallbackRelocalizationPromptText = "No saved room signature artifact. Continue ARKit relocalization or rescan/save with signature support."
            fallbackRelocalizationConfidenceText = "Fallback confidence: 0%"
            return
        }
        fallbackRelocalizationState = FallbackRelocalizationState(
            isActive: true,
            mode: .roomPlanSignature,
            startedAt: Date(),
            scanProgressText: "Fallback scan started",
            matchResult: nil,
            failureReason: nil,
            rotationAccumulatedDegrees: 0,
            lastYaw: nil
        )
        fallbackRelocalizationActive = true
        fallbackRelocalizationText = "Fallback Reloc: Scanning room layout"
        fallbackRelocalizationModeText = "Fallback Mode: Room Signature"
        fallbackRelocalizationPromptText = "Fallback active: hold position if safe and rotate slowly, aiming at long walls/openings/furniture."
        fallbackRelocalizationConfidenceText = "Fallback confidence: 0%"
    }

    func updateFallbackRelocalizationProgress(currentYaw: Float) {
        guard fallbackRelocalizationState.isActive else { return }
        var state = fallbackRelocalizationState
        if let last = state.lastYaw {
            let delta = abs(normalizedAngle(currentYaw - last)) * 180 / .pi
            state.rotationAccumulatedDegrees += delta
        }
        state.lastYaw = currentYaw
        let progress = Int(min(state.rotationAccumulatedDegrees, 360).rounded())
        state.scanProgressText = "Fallback scan progress: \(progress)° / 360°"

        let elapsed = Date().timeIntervalSince(state.startedAt)
        if state.matchResult == nil, state.rotationAccumulatedDegrees >= 180 || elapsed > 6 {
            runRoomSignatureMatch()
            return
        }
        fallbackRelocalizationState = state
        fallbackRelocalizationText = "Fallback Reloc: Scanning room layout"
        fallbackRelocalizationModeText = "Fallback Mode: \(state.mode.displayName)"
        fallbackRelocalizationPromptText = "Fallback active: rotate slowly 180–360° and aim at long walls, openings, and large furniture."
    }

    func runRoomSignatureMatch() {
        guard fallbackRelocalizationState.isActive else { return }
        let result = matchCurrentScanToRoomSignature()
        if let result {
            applyFallbackRelocalizationGuidance(result)
        } else {
            var state = fallbackRelocalizationState
            state.failureReason = "Inconclusive room-signature match"
            state.matchResult = nil
            fallbackRelocalizationState = state
            fallbackRelocalizationText = "Fallback Reloc: Inconclusive"
            fallbackRelocalizationPromptText = "Fallback layout match was inconclusive. Move toward a wall/corner, repeat a slow sweep, then continue ARKit relocalization."
            fallbackRelocalizationConfidenceText = "Fallback confidence: 0%"
        }
    }

    func matchCurrentScanToRoomSignature() -> RoomSignatureMatchResult? {
        guard let saved = savedRoomSignatureArtifact else { return nil }
        let currentYaw = currentPoseTransform?.forwardYawRadians ?? 0
        let live = roomSignatureProvider.buildLiveSignatureSnapshot(currentYaw: currentYaw, featurePointCount: featurePointCount)
        guard let live else { return nil }
        return roomSignatureProvider.match(live: live, saved: saved)
    }

    func applyFallbackRelocalizationGuidance(_ result: RoomSignatureMatchResult) {
        var state = fallbackRelocalizationState
        state.matchResult = result
        fallbackRelocalizationState = state
        fallbackRelocalizationText = result.confidence >= 0.55 ? "Fallback Reloc: Matched" : "Fallback Reloc: Low-confidence match"
        fallbackRelocalizationModeText = "Fallback Mode: Room Signature"
        fallbackRelocalizationPromptText = result.confidence >= 0.55
            ? result.recommendedPrompt
            : "Low-confidence layout hint: \(result.recommendedPrompt) If unsure, move to a wall/corner and retry."
        fallbackRelocalizationConfidenceText = "Fallback confidence: \(Int((result.confidence * 100).rounded()))%"
        guidanceText = fallbackRelocalizationPromptText ?? guidanceText
    }

    func resetFallbackRelocalizationState() {
        fallbackRelocalizationState = FallbackRelocalizationState(
            isActive: false,
            mode: .none,
            startedAt: Date(),
            scanProgressText: "Idle",
            matchResult: nil,
            failureReason: nil,
            rotationAccumulatedDegrees: 0,
            lastYaw: nil
        )
        fallbackRelocalizationActive = false
        fallbackRelocalizationText = "Fallback Reloc: Inactive"
        fallbackRelocalizationModeText = "Fallback Mode: None"
        fallbackRelocalizationPromptText = nil
        fallbackRelocalizationConfidenceText = "Fallback confidence: 0%"
    }

    func shouldTriggerRoomSignatureFallback() -> Bool {
        guard hasRoomSignatureArtifact else { return false }
        guard let state = relocalizationAttemptState else { return false }
        guard state.mode == .microMovementFallback else { return false }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        if localizationState == .localized { return false }
        if fallbackRelocalizationState.isActive { return false }
        if elapsed >= state.timeoutSeconds { return true }
        if state.featurePointMedianRecent > 180 && elapsed >= 8 { return true }
        return false
    }

    func relocalizationPipelineState() -> String {
        if meshFallbackState.active {
            return "ARKit primary + Mesh fallback"
        }
        if fallbackRelocalizationState.isActive {
            return "ARKit primary + Room Signature fallback"
        }
        return "ARKit primary"
    }

    func refreshSavedMapState() {
        hasSavedMap = Phase1MapStore.savedMapExists()
        guard hasSavedMap else {
            lastSavedText = "No saved map"
            return
        }
        do {
            if let metadata = try Phase1MapStore.loadMetadata() {
                lastSavedText = "Saved \(metadata.updatedAt.formatted(date: .abbreviated, time: .shortened))"
            } else {
                lastSavedText = "Saved map exists"
            }
        } catch {
            lastSavedText = "Saved map exists (metadata unreadable)"
        }
    }

    func loadAnchorsFromDisk() {
        do {
            anchors = try Phase1MapStore.loadAnchors()
            anchorOperationMessage = anchors.isEmpty ? nil : "Loaded \(anchors.count) anchor(s)"
        } catch {
            anchors = []
            errorMessage = "Anchors load failed: \(error.localizedDescription)"
        }
    }

    func enterAnchorMode() {
        isAnchorModePresented = true
        showDebugOverlay = false
        anchorPlacementMode = .aimedRaycast
        refreshAnchorTargetPreview()
        refreshAnchorActionAvailability()
    }

    func exitAnchorMode() {
        isAnchorModePresented = false
        showDebugOverlay = true
        anchorTargetPreviewText = nil
        anchorModeStatusText = "Relocalize and aim at a landmark"
        anchorTargetingReady = false
        consecutiveValidRaycastFrames = 0
        refreshAnchorActionAvailability()
    }

    func addAnchorUsingCurrentPlacementMode(type: AnchorType, name: String) {
        switch anchorPlacementMode {
        case .currentPose:
            addAnchorAtCurrentPose(type: type, name: name)
        case .aimedRaycast:
            addAnchorByRaycast(type: type, name: name)
        }
    }

    func addAnchorAtCurrentPose(type: AnchorType, name: String) {
        guard let transform = currentPoseTransformIfEligibleForAnchor() else {
            let eligibility = validateAnchorPlacementEligibility()
            anchorOperationMessage = eligibility.reason
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? nextDefaultAnchorName(for: type) : trimmedName
        let anchor = SavedSemanticAnchor(
            id: UUID(),
            name: finalName,
            type: type,
            createdAt: Date(),
            transform: transform.flatArray,
            placementMode: .currentPose
        )

        anchors.append(anchor)
        persistAnchorsWithStatus(success: "Added anchor: \(finalName)")
        anchorDraftName = ""
    }

    func addAnchorByRaycast(type: AnchorType, name: String) {
        let eligibility = anchorActionEligibility(for: .aimedRaycast)
        guard eligibility.allowed else {
            anchorOperationMessage = eligibility.reason
            return
        }
        guard let worldPosition = currentRaycastTarget() else {
            anchorOperationMessage = "No target surface in center view"
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? nextDefaultAnchorName(for: type) : trimmedName
        let anchorTransform = simd_float4x4(anchorWorldPosition: worldPosition)
        let anchor = SavedSemanticAnchor(
            id: UUID(),
            name: finalName,
            type: type,
            createdAt: Date(),
            transform: anchorTransform.flatArray,
            placementMode: .aimedRaycast
        )
        anchors.append(anchor)
        persistAnchorsWithStatus(success: "Added aimed anchor: \(finalName)")
        anchorDraftName = ""
    }

    func renameAnchor(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            anchorOperationMessage = "Anchor name cannot be empty"
            return
        }
        guard let idx = anchors.firstIndex(where: { $0.id == id }) else { return }
        anchors[idx].name = trimmed
        persistAnchorsWithStatus(success: "Renamed anchor to \(trimmed)")
    }

    func deleteAnchor(id: UUID) {
        guard let idx = anchors.firstIndex(where: { $0.id == id }) else { return }
        let removed = anchors.remove(at: idx)
        persistAnchorsWithStatus(success: "Deleted anchor: \(removed.name)")
    }

    func pingAnchor(id: UUID) {
        guard let currentTransform = currentPoseTransformIfEligibleForAnchor() else {
            let eligibility = validateAnchorPlacementEligibility()
            anchorPingText = eligibility.reason
            anchorOperationMessage = eligibility.reason
            return
        }
        guard let anchor = anchors.first(where: { $0.id == id }) else { return }
        guard let anchorTransform = simd_float4x4(flatArray: anchor.transform) else {
            anchorPingText = "Anchor data invalid for \(anchor.name)"
            return
        }

        let ping = distanceAndBearing(from: currentTransform, to: anchorTransform, anchorID: anchor.id, anchorName: anchor.name)
        let absBearing = abs(ping.bearingDegrees)
        let turnText: String
        if ping.distanceMeters < 0.4 {
            turnText = "nearby"
        } else if absBearing <= 10 {
            turnText = "ahead"
        } else if ping.bearingDegrees < 0 {
            turnText = "turn left \(Int(absBearing.rounded()))°"
        } else {
            turnText = "turn right \(Int(absBearing.rounded()))°"
        }
        anchorPingText = String(format: "%@: %.2fm, %@", ping.anchorName, ping.distanceMeters, turnText)
        anchorOperationMessage = "Pinged \(ping.anchorName)"
    }

    func refreshAnchorActionAvailability() {
        let eligibility = anchorActionEligibility(for: anchorPlacementMode)
        anchorPlacementAllowed = eligibility.allowed
        anchorPlacementBlockReason = eligibility.reason
        anchorModeStatusText = eligibility.allowed
            ? (anchorPlacementMode == .aimedRaycast ? "Ready to place aimed anchor" : "Ready to place current-position anchor")
            : (eligibility.reason ?? "Anchor placement unavailable")
    }

    func currentPoseTransformIfEligibleForAnchor() -> simd_float4x4? {
        validateAnchorPlacementEligibility().allowed ? currentPoseTransform : nil
    }

    func validateAnchorPlacementEligibility() -> (allowed: Bool, reason: String?) {
        guard currentPoseTransform != nil else {
            return (false, "No current pose yet")
        }
        guard appLocalizationState.isUsableForAnchors else {
            return (false, "Wait for usable alignment (ARKit relocalize or mesh alignment)")
        }
        guard isPoseStableForAnchorActions else {
            return (false, "Anchor placement requires stable heading (hold steady briefly)")
        }
        let effectiveConfidence = acceptedMeshAlignment?.confidence ?? latestLocalizationConfidence
        guard effectiveConfidence >= anchorConfidenceThreshold else {
            return (false, "Anchor placement requires stable alignment (confidence >= 70%)")
        }
        return (true, nil)
    }

    func anchorActionEligibility(for mode: AnchorPlacementMode) -> (allowed: Bool, reason: String?) {
        let base = validateAnchorPlacementEligibility()
        guard base.allowed else { return base }
        if mode == .aimedRaycast {
            guard anchorTargetingReady, latestAnchorTargetPreview.isTargetValid else {
                return (false, latestAnchorTargetPreview.reason ?? "No target surface in center view")
            }
        }
        return (true, nil)
    }

    func currentRaycastTarget() -> SIMD3<Float>? {
        guard latestAnchorTargetPreview.isTargetValid else { return nil }
        guard anchorTargetingReady else { return nil }
        return latestAnchorTargetPreview.worldPosition
    }

    func refreshAnchorTargetPreview() {
        guard isAnchorModePresented else {
            anchorTargetPreviewText = nil
            anchorTargetingReady = false
            consecutiveValidRaycastFrames = 0
            return
        }

        guard anchorPlacementMode == .aimedRaycast else {
            consecutiveValidRaycastFrames = 0
            latestAnchorTargetPreview = AnchorTargetPreview(
                isTargetValid: true,
                worldPosition: currentPoseTransform?.translation,
                reason: nil,
                surfaceKind: "device_pose"
            )
            anchorTargetingReady = validateAnchorPlacementEligibility().allowed
            anchorTargetPreviewText = anchorTargetingReady ? "Here mode: saves current phone position" : validateAnchorPlacementEligibility().reason
            return
        }

        guard let view = sceneView else {
            latestAnchorTargetPreview = AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: "AR view not ready", surfaceKind: nil)
            anchorTargetPreviewText = latestAnchorTargetPreview.reason
            anchorTargetingReady = false
            consecutiveValidRaycastFrames = 0
            return
        }

        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let query = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any) else {
            latestAnchorTargetPreview = AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: "No target surface in center view", surfaceKind: nil)
            anchorTargetPreviewText = latestAnchorTargetPreview.reason
            anchorTargetingReady = false
            consecutiveValidRaycastFrames = 0
            return
        }

        let results = view.session.raycast(query)
        if let hit = results.first {
            let hitPos = hit.worldTransform.translation
            latestAnchorTargetPreview = AnchorTargetPreview(
                isTargetValid: true,
                worldPosition: hitPos,
                reason: nil,
                surfaceKind: "\(hit.target)"
            )
            consecutiveValidRaycastFrames += 1
            let baseOK = validateAnchorPlacementEligibility().allowed
            anchorTargetingReady = baseOK && consecutiveValidRaycastFrames >= 3
            anchorTargetPreviewText = String(
                format: anchorTargetingReady ? "Target locked %.2fm" : "Hold steady on target %.2fm",
                simd_distance(hitPos, currentPoseTransform?.translation ?? hitPos)
            )
        } else {
            latestAnchorTargetPreview = AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: "No target surface in center view", surfaceKind: nil)
            anchorTargetPreviewText = latestAnchorTargetPreview.reason
            anchorTargetingReady = false
            consecutiveValidRaycastFrames = 0
        }
    }

    func distanceAndBearing(from current: simd_float4x4, to anchorTransform: simd_float4x4, anchorID: UUID, anchorName: String) -> AnchorPingResult {
        let currentPosition = current.translation
        let anchorPosition = anchorTransform.translation
        let dx = anchorPosition.x - currentPosition.x
        let dz = anchorPosition.z - currentPosition.z
        let distance = sqrt(dx * dx + dz * dz)

        let currentHeading = headingFromTransform(current)
        let targetHeading = atan2(dz, dx)
        let delta = normalizedAngle(targetHeading - currentHeading)

        return AnchorPingResult(
            anchorID: anchorID,
            anchorName: anchorName,
            distanceMeters: distance,
            bearingDegrees: delta * 180 / .pi,
            absoluteHeadingDegrees: targetHeading * 180 / .pi,
            isReachable: true
        )
    }

    func headingFromTransform(_ transform: simd_float4x4) -> Float {
        transform.forwardYawRadians
    }

    private func nextDefaultAnchorName(for type: AnchorType) -> String {
        let base = type.defaultNamePrefix
        let sameTypeCount = anchors.filter { $0.type == type }.count
        return "\(base) \(sameTypeCount + 1)"
    }

    private func persistAnchorsWithStatus(success: String) {
        do {
            try Phase1MapStore.saveAnchors(anchors)
            anchorOperationMessage = success
            errorMessage = nil
        } catch {
            errorMessage = "Anchors save failed: \(error.localizedDescription)"
        }
    }

    private func runSession(initialWorldMap: ARWorldMap?) {
        guard let view = sceneView else {
            errorMessage = "AR view not initialized yet."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if let initialWorldMap {
            configuration.initialWorldMap = initialWorldMap
        }

        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true

        meshAnchorCount = 0
        planeAnchorCount = 0
        featurePointCount = 0
        lastTransform = nil
        lastYaw = nil
        currentPoseTransform = nil
        latestLocalizationConfidence = 0
        isPoseStableForAnchorActions = false
        latestAnchorTargetPreview = AnchorTargetPreview(isTargetValid: false, worldPosition: nil, reason: "No target", surfaceKind: nil)
        consecutiveValidRaycastFrames = 0
        anchorTargetingReady = false
        anchorTargetPreviewText = nil
        recentMappingSamples.removeAll()
        recentFeaturePointSamples.removeAll()
        recentTrackingNormalSamples.removeAll()
        sessionYawCoverageAccumulated = 0
        sessionTranslationAccumulated = 0
        resetRelocalizationAttemptState()
        yawJitterSamples.removeAll()
        yawSweepAccumulated = 0
        yawSweepWindowStart = Date()
        lastMovementAt = Date()
        poseStabilityText = "Pose stability: unknown"
        headingJitterText = "Heading jitter: n/a"
        localizationConfidenceText = "Localization confidence: 0%"
        mapReadinessText = "Map Readiness: n/a"
        mapReadinessScoreText = "Readiness score: 0%"
        mapReadinessWarningsText = nil
        saveMapWarningText = nil
        resetAppLocalizationStateForNewAttempt()
        refreshAnchorActionAvailability()
    }

    private func updateRelocalizationState(with frame: ARFrame) {
        let tracking = frame.camera.trackingState
        if case .limited(.relocalizing) = tracking {
            if awaitingRelocalization { sawRelocalizingState = true }
            if relocalizationAttemptState == nil { beginRelocalizationAttempt() }
            stableNormalFramesAfterLoad = 0
            localizationState = .relocalizing
            relocalizationText = "Relocalizing... point camera at previously scanned surfaces"
            refreshAnchorActionAvailability()
            return
        }

        guard awaitingRelocalization else {
            if localizationState != .unknown, case .normal = tracking {
                localizationState = .localized
            } else if localizationState == .localized, case .limited = tracking {
                localizationState = .unknown
            }
            refreshAnchorActionAvailability()
            return
        }

        if case .normal = tracking {
            stableNormalFramesAfterLoad += 1
            let longEnoughSinceLoad = (loadRequestedAt.map { Date().timeIntervalSince($0) > 1.5 } ?? true)
            if stableNormalFramesAfterLoad > 15 && longEnoughSinceLoad {
                awaitingRelocalization = false
                localizationState = .localized
                relocalizationText = sawRelocalizingState
                    ? "Relocalized to saved map (ARKit tracking normal)"
                    : "Tracking normal after map load (likely relocalized)"
                statusMessage = "Localization ready"
                resetRelocalizationAttemptState()
            }
        } else {
            stableNormalFramesAfterLoad = 0
            if case .limited = tracking {
                localizationState = .relocalizing
            }
        }
        refreshAnchorActionAvailability()
    }

    private func updateGuidance(with frame: ARFrame) {
        if appLocalizationState == .conflict || appLocalizationState == .degraded {
            guidanceText = appLocalizationPromptText
            return
        }
        if appLocalizationState == .meshAlignedOverride {
            guidanceText = appLocalizationPromptText
            return
        }
        if awaitingRelocalization || localizationState == .relocalizing {
            if relocalizationAttemptState == nil { beginRelocalizationAttempt() }
            refreshRelocalizationGuidanceUI()
            return
        }

        let tracking = frame.camera.trackingState
        let mapping = frame.worldMappingStatus

        switch tracking {
        case .notAvailable:
            guidanceText = "Tracking unavailable. Move to a brighter area and restart."
            return
        case .limited(let reason):
            switch reason {
            case .initializing:
                guidanceText = "Initializing tracking. Hold steady, then begin scanning slowly."
            case .excessiveMotion:
                guidanceText = "Move slower. Sweep the phone smoothly."
            case .insufficientFeatures:
                guidanceText = "Aim at textured surfaces, edges, and furniture."
            case .relocalizing:
                guidanceText = "Relocalizing. Point at previously scanned walls and large objects."
            @unknown default:
                guidanceText = "Tracking limited. Slow down and scan more of the room."
            }
            return
        case .normal:
            break
        }

        if mapping == .limited || mapping == .notAvailable {
            guidanceText = "Keep scanning walls and furniture. Pan left and right for coverage."
            return
        }

        let now = Date()
        if now.timeIntervalSince(yawSweepWindowStart) > 4 {
            yawSweepWindowStart = now
            yawSweepAccumulated = 0
        }

        let stillForTooLong = now.timeIntervalSince(lastMovementAt) > 2.0
        if stillForTooLong {
            guidanceText = "Move slowly through the room. Scan both sides and corners."
        } else if yawSweepAccumulated < (.pi / 6) {
            guidanceText = "Pan left/right a bit more to improve map coverage."
        } else if mapping == .extending {
            guidanceText = "Good scan. Continue covering unscanned areas."
        } else {
            guidanceText = "Mapping looks good. You can save when coverage is complete."
        }

        if let warnings = mapReadinessWarningsText, !warnings.isEmpty, computeScanReadinessSnapshot().qualityScore < 0.65 {
            guidanceText = "Reloc robustness hint: \(warnings)"
        }
    }

    private func currentRelocalizationGuidanceSnapshot() -> RelocalizationGuidanceSnapshot? {
        guard let state = relocalizationAttemptState else { return nil }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        let relocQuality = relocalizationAttemptQualityScore(state: state)
        switch state.mode {
        case .stationary360:
            let progress = min(Int(state.rotationAccumulatedDegrees.rounded()), 360)
            return RelocalizationGuidanceSnapshot(
                attemptMode: state.mode,
                attemptProgressText: "Rotation progress: \(progress)° / 360°",
                recommendedActionText: stationaryRelocPrompt(
                    rotationDegrees: state.rotationAccumulatedDegrees,
                    featureMedian: state.featurePointMedianRecent
                ),
                stationaryAttemptReadyToEscalate: shouldEscalateFromStationaryToMicroMovement(),
                relocalizationQualityScore: relocQuality
            )
        case .microMovementFallback:
            return RelocalizationGuidanceSnapshot(
                attemptMode: state.mode,
                attemptProgressText: String(
                    format: "Fallback active (%.0fs elapsed). Feature median: %d",
                    elapsed,
                    state.featurePointMedianRecent
                ),
                recommendedActionText: microMovementRelocPrompt(),
                stationaryAttemptReadyToEscalate: false,
                relocalizationQualityScore: relocQuality
            )
        }
    }

    private func relocalizationAttemptQualityScore(state: RelocalizationAttemptState) -> Float {
        var score: Float = 0
        if state.sawRelocalizingTracking { score += 0.20 }
        score += min(Float(state.stableNormalFrames) / 20, 1) * 0.35
        score += min(Float(state.featurePointMedianRecent) / 300, 1) * 0.25
        score += min(state.rotationAccumulatedDegrees / 360, 1) * 0.20
        return min(max(score, 0), 1)
    }

    private func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

extension RoomPlanModel: ARSessionDelegate, ARSCNViewDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let featureCount = frame.rawFeaturePoints?.points.count ?? 0
        let anchors = frame.anchors
        let meshCount = anchors.filter { $0 is ARMeshAnchor }.count
        let planeCount = anchors.filter { $0 is ARPlaneAnchor }.count

        let transform = camera.transform
        let position = transform.translation
        let yaw = transform.forwardYawRadians

        Task { @MainActor in
            self.featurePointCount = featureCount
            self.meshAnchorCount = meshCount
            self.planeAnchorCount = planeCount
            self.currentPoseTransform = transform
            self.trackingStateText = camera.trackingState.displayText
            self.mappingStatusText = frame.worldMappingStatus.displayText
            self.poseText = String(
                format: "x %.2f  y %.2f  z %.2f  yaw %.0f°",
                position.x,
                position.y,
                position.z,
                yaw * 180 / .pi
            )

            self.updateMotionHeuristics(currentTransform: transform, currentYaw: yaw)
            self.updateScanReadinessMetrics(with: frame, currentTransform: transform, currentYaw: yaw)
            self.updateRelocalizationState(with: frame)
            self.updateRelocalizationAttemptMetrics(with: frame, currentTransform: transform, currentYaw: yaw)
            self.updatePoseDiagnostics(with: frame, position: position, yaw: yaw)
            self.updateAppLocalizationState(with: frame, currentYaw: yaw)
            self.updateGuidance(with: frame)
            self.refreshAnchorTargetPreview()
            self.refreshAnchorActionAvailability()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = "AR session failed: \(error.localizedDescription)"
            self.isSessionRunning = false
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.statusMessage = "Session interrupted"
            self.isSessionRunning = false
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.statusMessage = "Interruption ended. Restart scan if needed."
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            self.trackingStateText = camera.trackingState.displayText
        }
    }

    @MainActor
    private func updateMotionHeuristics(currentTransform: simd_float4x4, currentYaw: Float) {
        defer {
            lastTransform = currentTransform
            lastYaw = currentYaw
        }

        if let lastTransform {
            let translationDelta = simd_distance(lastTransform.translation, currentTransform.translation)
            if translationDelta > 0.03 {
                lastMovementAt = Date()
            }
            sessionTranslationAccumulated += translationDelta
        }

        if let lastYaw {
            let deltaYaw = abs(normalizedAngle(currentYaw - lastYaw))
            yawSweepAccumulated += deltaYaw
            sessionYawCoverageAccumulated += deltaYaw
            if deltaYaw > (.pi / 36) {
                lastMovementAt = Date()
            }
        }

        yawJitterSamples.append((Date(), currentYaw))
        let cutoff = Date().addingTimeInterval(-1.5)
        yawJitterSamples.removeAll { $0.time < cutoff }
    }

    @MainActor
    private func normalizedAngle(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }

    @MainActor
    private func updatePoseDiagnostics(with frame: ARFrame, position: SIMD3<Float>, yaw: Float) {
        let headingDegrees = yaw * 180 / .pi
        let jitterDegrees = headingJitterDegrees()
        let stableHeading = jitterDegrees.map { $0 <= 8 } ?? false
        let trackingNormal = {
            if case .normal = frame.camera.trackingState { return true }
            return false
        }()

        let confidence = localizationConfidence(
            cameraTracking: frame.camera.trackingState,
            mapping: frame.worldMappingStatus,
            stableHeading: stableHeading,
            jitterDegrees: jitterDegrees
        )

        let confidencePercent = Int((confidence * 100).rounded())
        latestLocalizationConfidence = confidence
        localizationConfidenceText = "Localization confidence: \(confidencePercent)%"
        headingJitterText = jitterDegrees.map {
            String(format: "Heading jitter (1.5s avg): %.1f°", $0)
        } ?? "Heading jitter: gathering samples..."

        let stabilityLabel: String
        if !trackingNormal {
            stabilityLabel = "unstable (tracking limited)"
            isPoseStableForAnchorActions = false
        } else if stableHeading {
            stabilityLabel = "stable"
            isPoseStableForAnchorActions = true
        } else {
            stabilityLabel = "unstable (heading jitter)"
            isPoseStableForAnchorActions = false
        }
        poseStabilityText = "Pose stability: \(stabilityLabel)"

        poseDebugText = String(
            format: "Position (map frame): x %.2f, y %.2f, z %.2f | Heading: %.0f° | Confidence: %d%%",
            position.x,
            position.y,
            position.z,
            headingDegrees,
            confidencePercent
        )

        if localizationState == .localized && !trackingNormal {
            localizationState = .unknown
        }
        refreshAnchorActionAvailability()
    }

    @MainActor
    private func headingJitterDegrees() -> Float? {
        guard yawJitterSamples.count >= 4 else { return nil }
        let yaws = yawJitterSamples.map(\.yaw)
        guard yaws.count >= 2 else { return nil }

        var sum: Float = 0
        for idx in 1..<yaws.count {
            sum += abs(normalizedAngle(yaws[idx] - yaws[idx - 1]))
        }
        let avgRadians = sum / Float(yaws.count - 1)
        return avgRadians * 180 / .pi
    }

    @MainActor
    private func localizationConfidence(
        cameraTracking: ARCamera.TrackingState,
        mapping: ARFrame.WorldMappingStatus,
        stableHeading: Bool,
        jitterDegrees: Float?
    ) -> Float {
        var score: Float = 0.0

        switch localizationState {
        case .unknown:
            score += 0.10
        case .relocalizing:
            score += 0.35
        case .localized:
            score += 0.55
        }

        switch cameraTracking {
        case .normal:
            score += 0.25
        case .limited(.relocalizing):
            score += 0.10
        case .limited:
            score += 0.05
        case .notAvailable:
            score += 0.0
        }

        switch mapping {
        case .mapped:
            score += 0.15
        case .extending:
            score += 0.10
        case .limited:
            score += 0.05
        case .notAvailable:
            score += 0.0
        @unknown default:
            score += 0.0
        }

        if stableHeading {
            score += 0.05
        } else if let jitterDegrees {
            if jitterDegrees > 15 { score -= 0.10 }
        }

        return min(max(score, 0), 1)
    }
}

struct RoomCaptureContainerView: UIViewRepresentable {
    @ObservedObject var model: RoomPlanModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        model.attachSceneView(view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct RoomPlanView: View {
    @StateObject private var model = RoomPlanModel()
    @State private var renamingAnchorID: UUID?
    @State private var renameDraft = ""
    @State private var showAnchorModeAdvancedStatus = false
    @State private var showRelocalizationDetails = false
    @State private var showReadinessDetails = false
    @State private var showRawDebugDetails = false
    @State private var showScanFallbackStorageDetails = false

    var body: some View {
        ZStack {
            RoomCaptureContainerView(model: model)
                .ignoresSafeArea()

            if model.isAnchorModePresented {
                anchorReticleOverlay
                    .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                topStatusPanel
                Spacer()
                bottomControlPanel
            }
            .padding()
        }
        .onAppear {
            model.refreshSavedMapState()
            model.loadAnchorsFromDisk()
            model.refreshRoomSignatureStatus()
            model.refreshMeshArtifactStatus()
            if !model.isSessionRunning {
                model.startFreshScan()
            }
        }
        .onDisappear {
            model.stopScan()
        }
        .onChange(of: model.anchorPlacementMode) { _, _ in
            model.refreshAnchorTargetPreview()
            model.refreshAnchorActionAvailability()
        }
    }

    private var topStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            } else if let status = model.statusMessage {
                Text(status)
                    .foregroundStyle(.green)
            }

            if model.isAnchorModePresented {
                Text("Anchor Mode")
                    .font(.caption.weight(.semibold))
                Text("Localization State: \(model.localizationStateText)")
                Text(model.appLocalizationStateText)
                Text(model.appLocalizationSourceText)
                Text(model.meshOverrideAppliedText)
                Text("Reloc: \(model.relocalizationText)")
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.appLocalizationConfidenceText)
                Text(model.appLocalizationPromptText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.localizationConfidenceText)
                Text(model.poseStabilityText)
                Text("Target: \(model.anchorTargetPreviewText ?? "n/a")")
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = model.anchorPlacementBlockReason, !model.anchorPlacementAllowed {
                    Text(reason)
                        .foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ping = model.anchorPingText {
                    Text("Ping: \(ping)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let anchorOp = model.anchorOperationMessage {
                    Text("Anchors: \(anchorOp)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let conflict = model.localizationConflictText {
                    Text(conflict)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Advanced Relocalization / Fallback", isExpanded: $showAnchorModeAdvancedStatus) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.arkitVsAppStateText)
                        Text(model.meshOverrideStatusText)
                        Text(model.worldOriginShiftDebugText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.relocalizationAttemptModeText)
                        Text(model.relocalizationAttemptProgressText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.meshFallbackText)
                        Text(model.meshFallbackPhaseText)
                        Text(model.meshFallbackConfidenceText)
                        Text(model.meshPoseSeedText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let meshPrompt = model.meshFallbackPromptText {
                            Text("Mesh fallback: \(meshPrompt)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.fallbackRelocalizationText)
                        Text(model.fallbackRelocalizationModeText)
                        Text(model.fallbackRelocalizationConfidenceText)
                        if let fallbackPrompt = model.fallbackRelocalizationPromptText {
                            Text("Fallback prompt: \(fallbackPrompt)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let fallback = model.relocalizationFallbackPromptText {
                            Text("Fallback: \(fallback)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("Tracking: \(model.trackingStateText)")
                Text("Mapping: \(model.mappingStatusText)")
                Text("Localization State: \(model.localizationStateText)")
                Text(model.appLocalizationStateText)
                Text(model.appLocalizationSourceText)
                Text(model.meshOverrideAppliedText)
                Text("Reloc: \(model.relocalizationText)")
                Text(model.appLocalizationConfidenceText)
                Text(model.appLocalizationPromptText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Guidance: \(model.guidanceText)")
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.mapReadinessText)
                Text(model.mapReadinessScoreText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.localizationConfidenceText)
                Text(model.poseStabilityText)
                if let anchorOp = model.anchorOperationMessage {
                    Text("Anchors: \(anchorOp)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ping = model.anchorPingText {
                    Text("Ping: \(ping)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let conflict = model.localizationConflictText {
                    Text(conflict)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Relocalization & Fallback Details", isExpanded: $showRelocalizationDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.arkitVsAppStateText)
                        Text(model.meshOverrideStatusText)
                        Text(model.worldOriginShiftDebugText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.relocalizationAttemptModeText)
                        Text(model.relocalizationAttemptProgressText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.meshFallbackText)
                        Text(model.meshFallbackPhaseText)
                        Text(model.meshFallbackConfidenceText)
                        Text(model.meshPoseSeedText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let meshPrompt = model.meshFallbackPromptText {
                            Text("Mesh fallback: \(meshPrompt)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.fallbackRelocalizationText)
                        Text(model.fallbackRelocalizationModeText)
                        Text(model.fallbackRelocalizationConfidenceText)
                        Text("Pipeline: \(model.relocalizationPipelineState())")
                        if let fallbackPrompt = model.fallbackRelocalizationPromptText {
                            Text("Fallback prompt: \(fallbackPrompt)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let fallback = model.relocalizationFallbackPromptText {
                            Text("Fallback: \(fallback)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }

                DisclosureGroup("Map Readiness / Saved Artifacts", isExpanded: $showReadinessDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.meshArtifactStatusText)
                        if let meshWarn = model.meshArtifactCaptureWarningText {
                            Text("Mesh warning: \(meshWarn)")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.roomSignatureStatusText)
                        Text("Fallback aid: \(model.hasRoomSignatureArtifact ? "Ready" : "Unavailable")")
                        if let sigWarn = model.roomSignatureCaptureWarningText {
                            Text("Signature warning: \(sigWarn)")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let warnings = model.mapReadinessWarningsText, !warnings.isEmpty {
                            Text("Readiness warnings: \(warnings)")
                                .foregroundStyle(.yellow)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let saveWarning = model.saveMapWarningText {
                            Text("Save warning: \(saveWarning)")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.lastSavedText)
                    }
                    .padding(.top, 4)
                }

                DisclosureGroup("Raw Debug Metrics", isExpanded: $showRawDebugDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mesh anchors: \(model.meshAnchorCount)  Planes: \(model.planeAnchorCount)  Features: \(model.featurePointCount)")
                        Text(model.poseText)
                        Text(model.poseDebugText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.headingJitterText)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomControlPanel: some View {
        VStack(spacing: 10) {
            if model.isAnchorModePresented {
                anchorModePanel
            } else {
                scanControlsPanel
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var scanControlsPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(model.isSessionRunning ? "Pause" : "Start Scan") {
                    if model.isSessionRunning {
                        model.stopScan()
                    } else {
                        model.startFreshScan()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("New Scan") {
                    model.startFreshScan()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button("Save Map") {
                    model.saveCurrentMap()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isSessionRunning)

                Button("Load Map") {
                    model.loadSavedMapAndRelocalize()
                }
                .buttonStyle(.bordered)
                .disabled(!model.hasSavedMap)

                Button("Anchors") {
                    model.enterAnchorMode()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasSavedMap)
            }

            DisclosureGroup("Saved Artifacts / Fallback Aids", isExpanded: $showScanFallbackStorageDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    if let saveWarning = model.saveMapWarningText {
                        Text(saveWarning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(model.roomSignatureStatusText)
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Fallback aid: \(model.hasRoomSignatureArtifact ? "Ready" : "Unavailable")")
                        .font(.caption2)
                        .foregroundStyle(model.hasRoomSignatureArtifact ? .green : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let sigWarn = model.roomSignatureCaptureWarningText {
                        Text(sigWarn)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(model.meshArtifactStatusText)
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let meshWarn = model.meshArtifactCaptureWarningText {
                        Text(meshWarn)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var anchorModePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Anchor Tools")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Close") {
                    if renamingAnchorID != nil {
                        renamingAnchorID = nil
                        renameDraft = ""
                    }
                    model.exitAnchorMode()
                }
                .buttonStyle(.bordered)
            }

            Picker("Placement", selection: $model.anchorPlacementMode) {
                ForEach(AnchorPlacementMode.allCases) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            anchorControls

            anchorList
        }
    }

    private var anchorControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Anchor Type", selection: $model.selectedAnchorType) {
                    ForEach(AnchorType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                TextField("Anchor name (optional)", text: $model.anchorDraftName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button(model.anchorPlacementMode.addButtonLabel) {
                    model.addAnchorUsingCurrentPlacementMode(type: model.selectedAnchorType, name: model.anchorDraftName)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.anchorPlacementAllowed)

                Text("\(model.anchors.count) saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if let reason = model.anchorPlacementBlockReason, !model.anchorPlacementAllowed {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let target = model.anchorTargetPreviewText {
                Text(target)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var anchorList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if model.anchors.isEmpty {
                    Text("No anchors yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.anchors) { anchor in
                        anchorRow(anchor)
                    }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func anchorRow(_ anchor: SavedSemanticAnchor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(anchor.name)
                        .font(.caption.weight(.semibold))
                    Text(anchor.type.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if renamingAnchorID == anchor.id {
                HStack(spacing: 8) {
                    TextField("New name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        model.renameAnchor(id: anchor.id, newName: renameDraft)
                        renamingAnchorID = nil
                        renameDraft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") {
                        renamingAnchorID = nil
                        renameDraft = ""
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Ping") {
                        model.pingAnchor(id: anchor.id)
                    }
                    .buttonStyle(.bordered)

                    Button("Rename") {
                        renamingAnchorID = anchor.id
                        renameDraft = anchor.name
                    }
                    .buttonStyle(.bordered)

                    Button("Delete", role: .destructive) {
                        if renamingAnchorID == anchor.id {
                            renamingAnchorID = nil
                            renameDraft = ""
                        }
                        model.deleteAnchor(id: anchor.id)
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var anchorReticleOverlay: some View {
        VStack {
            Spacer()
        }
        .overlay {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(reticleColor, lineWidth: 2)
                        .frame(width: 34, height: 34)
                    Circle()
                        .fill(reticleColor)
                        .frame(width: 5, height: 5)
                }
                Text(reticleLabel)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var reticleColor: Color {
        if !model.isAnchorModePresented { return .clear }
        if model.anchorPlacementAllowed { return .green }
        if model.anchorPlacementMode == .aimedRaycast,
           model.anchorTargetPreviewText?.localizedCaseInsensitiveContains("No target") == true {
            return .yellow
        }
        return .red
    }

    private var reticleLabel: String {
        if model.anchorPlacementAllowed { return "Ready" }
        if model.anchorPlacementMode == .aimedRaycast,
           model.anchorTargetPreviewText?.localizedCaseInsensitiveContains("No target") == true {
            return "No Surface"
        }
        return "Relocalize"
    }
}

private extension simd_float4x4 {
    init(anchorWorldPosition position: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(position.x, position.y, position.z, 1)
    }

    init(yawRadians: Float, translation: SIMD3<Float>) {
        let c = cos(yawRadians)
        let s = sin(yawRadians)
        self = simd_float4x4(
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(translation.x, translation.y, translation.z, 1)
        )
    }

    init?(flatArray values: [Float]) {
        guard values.count == 16 else { return nil }
        self = simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }

    var flatArray: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
    }

    nonisolated var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    nonisolated var forwardYawRadians: Float {
        let forward = SIMD3(-columns.2.x, 0, -columns.2.z)
        let mag = simd_length(forward)
        guard mag > 0.0001 else { return 0 }
        let norm = forward / mag
        return atan2(norm.z, norm.x)
    }
}

private extension Array where Element == Float {
    var chunked3SIMD: [SIMD3<Float>] {
        guard count >= 3 else { return [] }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count / 3)
        var i = 0
        while i + 2 < count {
            out.append(SIMD3(self[i], self[i + 1], self[i + 2]))
            i += 3
        }
        return out
    }
}

private func flatPointsToSIMD(_ flat: [Float]) -> [SIMD3<Float>] {
    flat.chunked3SIMD
}

private func centroidXZ(_ points: [SIMD3<Float>]) -> SIMD2<Float> {
    guard !points.isEmpty else { return .zero }
    let sum = points.reduce(SIMD2<Float>.zero) { partial, p in
        partial + SIMD2<Float>(p.x, p.z)
    }
    return sum / Float(points.count)
}

private func normalizedDegrees(_ degrees: Float) -> Float {
    var d = degrees
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
}

private func angleDistanceDegrees(_ a: Float, _ b: Float) -> Float {
    abs(normalizedDegrees(a - b))
}

private extension ARMeshAnchor {
    func toRecord() -> MeshAnchorRecord? {
        let geometry = self.geometry
        let vertices = geometry.extractVertices()
        guard !vertices.isEmpty else { return nil }
        let normals = geometry.extractNormals()
        let faces = geometry.extractTriangleIndices(vertexCount: vertices.count)
        return MeshAnchorRecord(
            id: identifier,
            transform: transform.flatArray,
            vertices: vertices.flatMap { [$0.x, $0.y, $0.z] },
            normals: normals.isEmpty ? nil : normals.flatMap { [$0.x, $0.y, $0.z] },
            faces: faces,
            capturedAt: Date(),
            classificationSummary: nil
        )
    }
}

private extension ARMeshGeometry {
    func extractVertices() -> [SIMD3<Float>] {
        let src = vertices
        let ptr = src.buffer.contents()
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(src.count)
        for i in 0..<src.count {
            let offset = src.offset + src.stride * i
            let p = ptr.advanced(by: offset).assumingMemoryBound(to: SIMD3<Float>.self)
            result.append(p.pointee)
        }
        return result
    }

    func extractNormals() -> [SIMD3<Float>] {
        let src = normals
        let ptr = src.buffer.contents()
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(src.count)
        for i in 0..<src.count {
            let offset = src.offset + src.stride * i
            let p = ptr.advanced(by: offset).assumingMemoryBound(to: SIMD3<Float>.self)
            result.append(p.pointee)
        }
        return result
    }

    func extractTriangleIndices(vertexCount: Int) -> [UInt32] {
        let el = faces
        let ptr = el.buffer.contents()
        let primitiveCount = el.count
        let indicesPerPrimitive = 3
        let total = primitiveCount * indicesPerPrimitive
        var result: [UInt32] = []
        result.reserveCapacity(total)

        for i in 0..<total {
            let byteOffset = i * el.bytesPerIndex
            let idxPtr = ptr.advanced(by: byteOffset)
            let value: UInt32
            switch el.bytesPerIndex {
            case 2:
                value = UInt32(idxPtr.assumingMemoryBound(to: UInt16.self).pointee)
            case 4:
                value = idxPtr.assumingMemoryBound(to: UInt32.self).pointee
            default:
                value = 0
            }
            if Int(value) < vertexCount {
                result.append(value)
            } else {
                result.append(0)
            }
        }
        return result
    }
}

private extension ARCamera.TrackingState {
    nonisolated var displayText: String {
        switch self {
        case .normal:
            return "Normal"
        case .notAvailable:
            return "Not available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Limited: initializing"
            case .excessiveMotion: return "Limited: excessive motion"
            case .insufficientFeatures: return "Limited: insufficient features"
            case .relocalizing: return "Limited: relocalizing"
            @unknown default: return "Limited: unknown"
            }
        }
    }
}

private extension ARFrame.WorldMappingStatus {
    nonisolated var displayText: String {
        switch self {
        case .notAvailable: return "Not available"
        case .limited: return "Limited"
        case .extending: return "Extending"
        case .mapped: return "Mapped"
        @unknown default: return "Unknown"
        }
    }
}

#Preview {
    RoomPlanView()
}
