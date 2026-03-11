//
//  RoomPlanModel.swift
//  Cluesive
//
//  AR session orchestration, relocalization, mesh fallback, and anchor workflows.
//

import SwiftUI
import Combine
import ARKit
import SceneKit
import UIKit

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
    @Published var fallbackModeText = "Fallback mode: Hybrid Geometry + Vision"
    @Published var fallbackConfidenceBandText = "Fallback confidence band: Low"
    @Published var fallbackNeedsConfirmation = false
    @Published var fallbackConfirmationPromptText: String?
    @Published var fallbackLatencyMsText = "Fallback latency: n/a"
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
    @Published var localizationEventCountText = "Localization Events: 0"
    @Published var localizationLastEventText = "Last Localization Event: n/a"
    @Published var meshOnlyTestModeEnabled = false {
        didSet {
            if meshOnlyTestModeEnabled {
                resetAppLocalizationStateForNewAttempt()
                resetMeshFallbackState()
                if relocalizationAttemptState == nil {
                    beginRelocalizationAttempt()
                }
                relocalizationText = "Mesh-only test mode active: ARKit relocalization is ignored for app localization."
                statusMessage = "Mesh-only test mode ON (fallback isolation active)"
            } else {
                statusMessage = "Mesh-only test mode OFF"
            }
            refreshAppLocalizationUI()
        }
    }

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
    private var savedStructureSignatureArtifact: StructureSignatureArtifact?
    private var savedVisionIndexArtifact: VisionIndexArtifact?
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
    private var localizationEvents: [LocalizationEventRecord] = []
    private var lastLocalizationEventPresentationUpdateAt: Date = .distantPast
    private var meshFallbackLastEvaluationAt: Date = .distantPast
    private var meshFallbackEvaluationIntervalSeconds: TimeInterval = 0.75
    private var visionCandidateEvaluationIntervalSeconds: TimeInterval = 2.0
    private var lastVisionCandidateEvaluationAt: Date = .distantPast
    private var runtimeVisionKeyframeBuffer: [VisionFeatureRecord] = []
    private var lastRuntimeVisionKeyframeCaptureAt: Date = .distantPast
    private var memoryPressureRelaxedUntil: Date = .distantPast
    private var meshFallbackSoftTimeoutLogged = false
    private var fallbackLocalizationMode: FallbackLocalizationMode = .hybridGeometryVision
    private var pendingFallbackAcceptance: MeshAlignmentAcceptance?
    private var hasUserConfirmedMediumFallback = false
    private var cachedSavedMeshPoints: [SIMD3<Float>] = []
    private var memoryWarningObserver: NSObjectProtocol?

    override init() {
        super.init()
        fallbackModeText = "Fallback mode: \(fallbackLocalizationMode.displayName)"
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMemoryWarning()
            }
        }
        resetAppLocalizationStateForNewAttempt()
        refreshSavedMapState()
        loadAnchorsFromDisk()
        refreshRoomSignatureStatus()
        refreshMeshArtifactStatus()
        refreshLocalizationEventLogStatus()
        refreshAnchorActionAvailability()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
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
        refreshLocalizationEventLogStatus()
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
        clearRuntimeFallbackCaches(keepSavedMeshCache: false)
        runtimeVisionKeyframeBuffer.removeAll()
        lastRuntimeVisionKeyframeCaptureAt = .distantPast
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
                    self.captureStructureSignatureIfAvailable(from: frameForMeshCapture)
                    self.captureVisionIndexIfAvailable(from: frameForMeshCapture)
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
            savedStructureSignatureArtifact = try Phase1MapStore.loadStructureSignature()
            savedVisionIndexArtifact = try Phase1MapStore.loadVisionIndex()
            refreshRoomSignatureStatus()
            refreshMeshArtifactStatus()
            awaitingRelocalization = true
            sawRelocalizingState = false
            stableNormalFramesAfterLoad = 0
            loadRequestedAt = Date()
            localizationState = .relocalizing
            relocalizationText = meshOnlyTestModeEnabled
                ? "Mesh-only isolation active. ARWorldMap relocalization disabled; scanning fallback artifacts."
                : "Loaded map. Walk to the same area to relocalize..."
            statusMessage = meshOnlyTestModeEnabled
                ? "Map loaded, fallback isolation running (ARKit relocalization disabled)"
                : "Map loaded, relocalization running"
            errorMessage = nil
            resetAppLocalizationStateForNewAttempt()
            runSession(initialWorldMap: meshOnlyTestModeEnabled ? nil : worldMap)
            refreshCachedSavedMeshPoints()
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
        guard let artifact = MeshRelocalizationEngine.buildMeshMapArtifact(from: frame) else {
            meshArtifactCaptureWarningText = "Mesh artifact not captured (no mesh anchors / extraction failed)"
            return
        }
        saveMeshArtifact(artifact)
    }

    func saveMeshArtifact(_ artifact: MeshMapArtifact) {
        do {
            try Phase1MapStore.saveMeshArtifact(artifact)
            savedMeshArtifact = artifact
            refreshCachedSavedMeshPoints()
            meshArtifactCaptureWarningText = nil
            meshArtifactStatusText = "Mesh Artifact: Available (\(artifact.meshAnchors.count) anchors)"
        } catch {
            meshArtifactCaptureWarningText = "Mesh artifact save failed: \(error.localizedDescription)"
            meshArtifactStatusText = "Mesh Artifact: Save failed"
        }
    }

    func captureStructureSignatureIfAvailable(from frame: ARFrame?) {
        guard let frame else { return }
        guard let artifact = MeshRelocalizationEngine.buildStructureSignature(from: frame) else { return }
        do {
            try Phase1MapStore.saveStructureSignature(artifact)
            savedStructureSignatureArtifact = artifact
        } catch {
            meshArtifactCaptureWarningText = "Structure signature save failed: \(error.localizedDescription)"
        }
    }

    func captureVisionIndexIfAvailable(from frame: ARFrame?) {
        guard let artifact = buildVisionIndexArtifact(from: frame) else { return }
        do {
            try Phase1MapStore.saveVisionIndex(artifact)
            savedVisionIndexArtifact = artifact
        } catch {
            meshArtifactCaptureWarningText = "Vision index save failed: \(error.localizedDescription)"
        }
    }

    func refreshMeshArtifactStatus() {
        do {
            savedMeshArtifact = try Phase1MapStore.loadMeshArtifact()
            savedStructureSignatureArtifact = try Phase1MapStore.loadStructureSignature()
            savedVisionIndexArtifact = try Phase1MapStore.loadVisionIndex()
            refreshCachedSavedMeshPoints()
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

    func refreshCachedSavedMeshPoints() {
        guard let saved = savedMeshArtifact else {
            cachedSavedMeshPoints.removeAll()
            return
        }
        cachedSavedMeshPoints = MeshRelocalizationEngine.downsampleSavedMeshPoints(saved, maxPoints: 1200)
    }

    func buildVisionIndexArtifact(from frame: ARFrame?) -> VisionIndexArtifact? {
        guard let frame else { return nil }
        var records = runtimeVisionKeyframeBuffer
        if let currentRecord = MeshRelocalizationEngine.makeVisionFeatureRecord(from: frame) {
            records = MeshRelocalizationEngine.mergeVisionFeatureRecord(existing: records, candidate: currentRecord)
        }
        return MeshRelocalizationEngine.buildVisionIndex(from: records)
    }

    func updateRuntimeVisionKeyframeBuffer(with frame: ARFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastRuntimeVisionKeyframeCaptureAt) >= 0.6 else { return }
        guard frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending else { return }
        guard (frame.rawFeaturePoints?.points.count ?? 0) >= 120 else { return }
        guard let record = MeshRelocalizationEngine.makeVisionFeatureRecord(from: frame) else { return }
        runtimeVisionKeyframeBuffer = MeshRelocalizationEngine.mergeVisionFeatureRecord(
            existing: runtimeVisionKeyframeBuffer,
            candidate: record
        )
        lastRuntimeVisionKeyframeCaptureAt = now
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
        fallbackNeedsConfirmation = false
        fallbackConfirmationPromptText = nil
        fallbackConfidenceBandText = "Fallback confidence band: Low"
        fallbackLatencyMsText = "Fallback latency: n/a"
        pendingFallbackAcceptance = nil
        hasUserConfirmedMediumFallback = false
        refreshAppLocalizationUI()
    }

    func refreshAppLocalizationUI() {
        let arkitStateForPresentation = meshOnlyTestModeEnabled
            ? "Suppressed (mesh-only test)"
            : localizationState.displayText
        let presentation = AppLocalizationPresentationCoordinator.presentation(
            inputs: .init(
                appLocalizationState: appLocalizationState,
                appLocalizationSource: appLocalizationSource,
                acceptedMeshAlignmentConfidence: acceptedMeshAlignment?.confidence,
                meshFallbackResultConfidence: meshFallbackState.result?.confidence,
                latestLocalizationConfidence: latestLocalizationConfidence,
                arkitLocalizationStateText: arkitStateForPresentation,
                hasAppliedWorldOriginShift: hasAppliedWorldOriginShiftForCurrentAttempt
            )
        )
        appLocalizationStateText = presentation.appLocalizationStateText
        appLocalizationSourceText = presentation.appLocalizationSourceText
        appLocalizationConfidenceText = presentation.appLocalizationConfidenceText
        appLocalizationPromptText = presentation.appLocalizationPromptText
        arkitVsAppStateText = presentation.arkitVsAppStateText
        meshOverrideAppliedText = presentation.meshOverrideAppliedText
    }

    func updateScanReadinessMetrics(with frame: ARFrame, currentTransform: simd_float4x4, currentYaw: Float) {
        let buffers = ScanReadinessCoordinator.appendSamples(
            mappingSamples: recentMappingSamples,
            featurePointSamples: recentFeaturePointSamples,
            trackingNormalSamples: recentTrackingNormalSamples,
            frame: frame
        )
        recentMappingSamples = buffers.mappingSamples
        recentFeaturePointSamples = buffers.featurePointSamples
        recentTrackingNormalSamples = buffers.trackingNormalSamples

        let _ = currentTransform
        let _ = currentYaw
        refreshMapReadinessUI()
    }

    func computeScanReadinessSnapshot() -> ScanReadinessSnapshot {
        ScanReadinessCoordinator.computeScanReadinessSnapshot(
            recentMappingSamples: recentMappingSamples,
            recentFeaturePointSamples: recentFeaturePointSamples,
            recentTrackingNormalSamples: recentTrackingNormalSamples,
            sessionYawCoverageAccumulated: sessionYawCoverageAccumulated,
            sessionTranslationAccumulated: sessionTranslationAccumulated
        )
    }

    func refreshMapReadinessUI() {
        let snapshot = computeScanReadinessSnapshot()
        let presentation = ScanReadinessCoordinator.mapReadinessPresentation(snapshot: snapshot)
        mapReadinessText = presentation.readinessText
        mapReadinessScoreText = presentation.readinessScoreText
        mapReadinessWarningsText = presentation.warningsText
        saveMapWarningText = presentation.saveMapWarningText
    }

    func saveReadinessWarningIfNeeded() -> String? {
        ScanReadinessCoordinator.saveReadinessWarningIfNeeded(snapshot: computeScanReadinessSnapshot())
    }

    func beginRelocalizationAttempt() {
        relocalizationAttemptState = RelocalizationAttemptCoordinator.initialState()
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
        let shouldRunAttemptLoop = awaitingRelocalization
            || localizationState == .relocalizing
            || (meshOnlyTestModeEnabled && appLocalizationState == .searching)
        guard shouldRunAttemptLoop else { return }
        if relocalizationAttemptState == nil {
            beginRelocalizationAttempt()
        }
        guard var state = relocalizationAttemptState else { return }
        let _ = currentTransform
        let recent = recentFeaturePointSamples.suffix(60)
        let outcome = RelocalizationAttemptCoordinator.updateMetrics(
            state: state,
            previousYaw: relocalizationAttemptLastYaw,
            currentYaw: currentYaw,
            trackingState: frame.camera.trackingState,
            recentFeatureMedian: median(Array(recent))
        )
        state = outcome.state
        relocalizationAttemptState = state
        relocalizationAttemptLastYaw = outcome.lastYaw

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
        let decisionLocalizationState: LocalizationState = meshOnlyTestModeEnabled ? .relocalizing : localizationState
        return RelocalizationAttemptCoordinator.shouldEscalateToMicroMovement(
            state: relocalizationAttemptState,
            localizationState: decisionLocalizationState
        )
    }

    func escalateRelocalizationAttemptToMicroMovement() {
        guard var state = relocalizationAttemptState, state.mode == .stationary360 else { return }
        state = RelocalizationAttemptCoordinator.escalatedMicroMovementState(from: state)
        relocalizationAttemptState = state
        relocalizationFallbackPromptText = RelocalizationAttemptCoordinator.microMovementRelocPrompt()
    }

    func stationaryRelocPrompt(rotationDegrees: Float, featureMedian: Int) -> String {
        RelocalizationAttemptCoordinator.stationaryRelocPrompt(
            rotationDegrees: rotationDegrees,
            featureMedian: featureMedian
        )
    }

    func microMovementRelocPrompt() -> String {
        RelocalizationAttemptCoordinator.microMovementRelocPrompt()
    }

    func shouldTriggerMeshFallback() -> Bool {
        if meshOnlyTestModeEnabled,
           appLocalizationState == .searching,
           !meshFallbackState.active,
           let state = relocalizationAttemptState
        {
            // Debug-mode fast path: allow fallback activation without waiting for
            // full stationary->micro-movement escalation when ARKit is already localized.
            let elapsed = Date().timeIntervalSince(state.startedAt)
            if elapsed >= 2 {
                return true
            }
        }

        let decisionLocalizationState: LocalizationState = meshOnlyTestModeEnabled ? .relocalizing : localizationState
        return RelocalizationAttemptCoordinator.shouldTriggerMeshFallback(
            hasSavedMeshArtifact: savedMeshArtifact != nil,
            state: relocalizationAttemptState,
            meshFallbackActive: meshFallbackState.active,
            localizationState: decisionLocalizationState
        )
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
        fallbackModeText = "Fallback mode: \(fallbackLocalizationMode.displayName)"
        fallbackConfidenceBandText = "Fallback confidence band: Low"
        fallbackLatencyMsText = "Fallback latency: 0 ms"
        fallbackNeedsConfirmation = false
        fallbackConfirmationPromptText = nil
        pendingFallbackAcceptance = nil
        hasUserConfirmedMediumFallback = false
        meshFallbackLastEvaluationAt = .distantPast
        lastVisionCandidateEvaluationAt = .distantPast
        meshFallbackSoftTimeoutLogged = false
        if appLocalizationState == .searching && !meshOnlyTestModeEnabled {
            appLocalizationState = .meshAligning
            refreshAppLocalizationUI()
        }
    }

    func updateMeshFallbackProgress(with frame: ARFrame, currentYaw: Float) {
        guard meshFallbackState.active else { return }
        let elapsed = Date().timeIntervalSince(meshFallbackState.startedAt)
        fallbackLatencyMsText = "Fallback latency: \(Int((elapsed * 1000).rounded())) ms"
        if elapsed > RelocalizationCoordinator.fallbackTimeoutSeconds(), !meshFallbackSoftTimeoutLogged {
            meshFallbackSoftTimeoutLogged = true
            recordLocalizationEvent(
                .fallbackTimeout,
                details: "Fallback has not found a usable candidate yet; continuing scan"
            )
        }

        let now = Date()
        // Keep fallback active while searching/meshAligning and re-evaluate on rolling frames.
        let evaluationInterval = now < memoryPressureRelaxedUntil ? max(meshFallbackEvaluationIntervalSeconds, 1.25) : meshFallbackEvaluationIntervalSeconds
        if now.timeIntervalSince(meshFallbackLastEvaluationAt) < evaluationInterval { return }
        meshFallbackLastEvaluationAt = now

        guard let liveFallbackInput = MeshRelocalizationEngine.buildLiveFallbackInput(from: frame) else {
            meshFallbackText = "Mesh Fallback: Searching"
            meshFallbackPromptText = "No live mesh sample yet. Keep scanning stable walls/corners slowly."
            return
        }

        meshFallbackState.phase = .coarseMatching
        meshFallbackState.progressText = String(format: "Coarse matching (%.1fs)", elapsed)
        meshFallbackPhaseText = "Mesh Fallback Phase: coarseMatching"
        let hypotheses = runCoarseMeshSignatureMatch(liveDescriptor: liveFallbackInput.descriptor)
        if hypotheses.isEmpty {
            meshFallbackText = "Mesh Fallback: Searching"
            meshFallbackPromptText = "No strong geometry candidate yet. Keep scanning stable walls/corners slowly."
            return
        }
        var visionCandidate: VisionPlaceCandidate?
        if let vision = savedVisionIndexArtifact,
           now.timeIntervalSince(lastVisionCandidateEvaluationAt) >= visionCandidateEvaluationIntervalSeconds
        {
            lastVisionCandidateEvaluationAt = now
            let selection = MeshRelocalizationEngine.retrieveVisionPlaceCandidateSelection(from: frame, saved: vision)
            if let candidate = selection.candidate {
                visionCandidate = candidate
                recordLocalizationEvent(
                    .visionCandidateSelected,
                    confidence: candidate.confidence,
                    details: visionDiagnosticsSummary(selection.diagnostics)
                )
            }
        }
        meshFallbackState.phase = .refiningICP
        meshFallbackPhaseText = "Mesh Fallback Phase: refiningICP"
        if let result = runICPLiteRefinement(
            hypotheses: hypotheses,
            frame: frame,
            currentYaw: currentYaw,
            liveFallbackInput: liveFallbackInput,
            visionCandidate: visionCandidate
        ) {
            applyMeshFallbackGuidance(result)
        } else {
            meshFallbackState.phase = .coarseMatching
            meshFallbackText = "Mesh Fallback: Searching"
            meshFallbackPromptText = "Refinement was inconclusive. Continue scanning walls/corners for more structure."
        }
    }

    func runCoarseMeshSignatureMatch(liveDescriptor: MeshSignatureDescriptor) -> [MeshRelocalizationHypothesis] {
        guard let saved = savedMeshArtifact else { return [] }
        return MeshRelocalizationEngine.runCoarseMeshSignatureMatch(liveDescriptor: liveDescriptor, saved: saved)
    }

    func runICPLiteRefinement(
        hypotheses: [MeshRelocalizationHypothesis],
        frame: ARFrame,
        currentYaw: Float,
        liveFallbackInput: MeshRelocalizationEngine.LiveFallbackInput,
        visionCandidate: VisionPlaceCandidate?
    ) -> MeshRelocalizationResult? {
        guard let saved = savedMeshArtifact else { return nil }
        return MeshRelocalizationEngine.runICPLiteRefinement(
            hypotheses: hypotheses,
            frame: frame,
            currentYaw: currentYaw,
            saved: saved,
            savedPoints: cachedSavedMeshPoints,
            livePoints: liveFallbackInput.points,
            liveNormals: liveFallbackInput.normals,
            liveDescriptor: liveFallbackInput.descriptor,
            savedStructure: savedStructureSignatureArtifact,
            savedVision: savedVisionIndexArtifact,
            visionCandidate: visionCandidate,
            mode: fallbackLocalizationMode
        )
    }

    func applyMeshFallbackGuidance(_ result: MeshRelocalizationResult) {
        meshFallbackState.result = result
        meshFallbackState.phase = result.confidence >= 0.55 ? .matched : .coarseMatching
        meshFallbackText = result.confidence >= 0.55 ? "Mesh Fallback: Matched" : "Mesh Fallback: Searching"
        meshFallbackPhaseText = "Mesh Fallback Phase: \(meshFallbackState.phase.rawValue)"
        meshFallbackConfidenceText = "Mesh Fallback Confidence: \(Int((result.confidence * 100).rounded()))%"
        fallbackConfidenceBandText = "Fallback confidence band: \(result.confidenceBand.displayName)"
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
            switch RelocalizationCoordinator.fallbackDecision(for: result.confidenceBand) {
            case .accept:
                meshFallbackPromptText = "Mesh geometry suggests you are near the \(result.areaHint ?? "saved room area"). Turn \(direction) about \(angle)° and hold steady."
                recordLocalizationEvent(
                    .geometryRegistrationAccepted,
                    confidence: result.confidence,
                    details: fallbackDiagnosticsSummary(for: result)
                )
            case .needsUserConfirmation:
                let firstRequest = !fallbackNeedsConfirmation
                fallbackNeedsConfirmation = true
                fallbackConfirmationPromptText = "Provisional alignment found. Confirm to proceed cautiously."
                meshFallbackPromptText = "Provisional alignment found near \(result.areaHint ?? "saved room area"). Confirm before enabling anchor/navigation actions."
                if firstRequest {
                    recordLocalizationEvent(
                        .confirmationRequested,
                        confidence: result.confidence,
                        details: fallbackDiagnosticsSummary(for: result)
                    )
                }
            case .reject:
                meshFallbackPromptText = "Geometry match is too weak. Move closer to stable walls/corners and retry."
                recordLocalizationEvent(
                    .meshCandidateRejected,
                    confidence: result.confidence,
                    details: fallbackDiagnosticsSummary(for: result)
                )
            }
        } else {
            meshFallbackPromptText = "Mesh geometry hint is weak. Move closer to a wall/corner and do a slow sweep, then retry relocalization."
            recordLocalizationEvent(
                .meshCandidateRejected,
                confidence: result.confidence,
                details: fallbackDiagnosticsSummary(for: result)
            )
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
        fallbackNeedsConfirmation = false
        fallbackConfirmationPromptText = nil
        pendingFallbackAcceptance = nil
        hasUserConfirmedMediumFallback = false
        lastVisionCandidateEvaluationAt = .distantPast
        fallbackConfidenceBandText = "Fallback confidence band: Low"
        fallbackLatencyMsText = "Fallback latency: n/a"
    }

    func startFallbackIsolationNow() {
        guard meshOnlyTestModeEnabled else {
            statusMessage = "Enable fallback-isolation test mode first."
            return
        }
        refreshMeshArtifactStatus()
        guard savedMeshArtifact != nil else {
            meshFallbackText = "Mesh Fallback: Unavailable"
            meshFallbackPromptText = "Cannot start fallback: no saved mesh artifact. Save a new map with mesh artifact first."
            statusMessage = "Fallback start failed: no saved mesh artifact"
            refreshAppLocalizationUI()
            return
        }
        if relocalizationAttemptState == nil {
            beginRelocalizationAttempt()
        }
        if !meshFallbackState.active {
            beginMeshFallbackRelocalization()
        }
        appLocalizationState = meshOnlyTestModeEnabled ? .searching : .meshAligning
        guidanceText = "Fallback forced on. Rotate slowly 180-360° and target stable walls/corners/openings."
        statusMessage = "Fallback isolation: manual start triggered"
        refreshAppLocalizationUI()
    }

    func confirmFallbackAlignment() {
        hasUserConfirmedMediumFallback = true
        fallbackNeedsConfirmation = false
        fallbackConfirmationPromptText = nil
        recordLocalizationEvent(
            .confirmationAccepted,
            confidence: meshFallbackState.result?.confidence,
            details: "User accepted provisional fallback alignment"
        )
        if let acceptance = pendingFallbackAcceptance {
            pendingFallbackAcceptance = nil
            promoteToMeshAlignedOverride(using: acceptance)
        }
    }

    func rejectFallbackAlignment() {
        hasUserConfirmedMediumFallback = false
        fallbackNeedsConfirmation = false
        fallbackConfirmationPromptText = nil
        pendingFallbackAcceptance = nil
        meshFallbackState.phase = .inconclusive
        meshFallbackText = "Mesh Fallback: Confirmation rejected"
        appLocalizationState = .searching
        guidanceText = "Fallback alignment rejected. Rescan stable walls/corners."
        recordLocalizationEvent(
            .confirmationRejected,
            confidence: meshFallbackState.result?.confidence,
            details: "User rejected provisional fallback alignment"
        )
        refreshAppLocalizationUI()
    }

    func updateAppLocalizationState(with frame: ARFrame, currentYaw: Float) {
        let appDecisionLocalizationState: LocalizationState = meshOnlyTestModeEnabled ? .relocalizing : localizationState

        var tickPlan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: appDecisionLocalizationState,
            loadRequestedAt: loadRequestedAt,
            appLocalizationState: appLocalizationState,
            meshOnlyTestModeEnabled: meshOnlyTestModeEnabled,
            meshFallbackActive: meshFallbackState.active,
            meshResult: meshFallbackState.result,
            hasAppliedWorldOriginShiftForCurrentAttempt: hasAppliedWorldOriginShiftForCurrentAttempt,
            isPoseStableForAnchorActions: isPoseStableForAnchorActions,
            latestLocalizationConfidence: latestLocalizationConfidence,
            meshFallbackPhase: meshFallbackState.phase
        )

        switch tickPlan.startAction {
        case .none:
            break
        case .reconcileMeshOverride:
            if !meshOnlyTestModeEnabled {
                reconcileARKitRelocalizationAgainstMeshOverride(with: frame)
            }
        case .promoteARKitConfirmed:
            if !meshOnlyTestModeEnabled {
                promoteToARKitConfirmed()
            }
        case .enterMeshAligning:
            if meshOnlyTestModeEnabled {
                appLocalizationState = .searching
            } else {
                appLocalizationState = meshFallbackState.active ? .meshAligning : .searching
            }
        }

        if appLocalizationState == .meshAligning && !meshFallbackState.active {
            appLocalizationState = .searching
            meshOverrideStatusText = "Mesh Override: Awaiting stable mesh alignment"
        }

        // Recompute after potential state transitions above.
        tickPlan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: appDecisionLocalizationState,
            loadRequestedAt: loadRequestedAt,
            appLocalizationState: appLocalizationState,
            meshOnlyTestModeEnabled: meshOnlyTestModeEnabled,
            meshFallbackActive: meshFallbackState.active,
            meshResult: meshFallbackState.result,
            hasAppliedWorldOriginShiftForCurrentAttempt: hasAppliedWorldOriginShiftForCurrentAttempt,
            isPoseStableForAnchorActions: isPoseStableForAnchorActions,
            latestLocalizationConfidence: latestLocalizationConfidence,
            meshFallbackPhase: meshFallbackState.phase
        )

        if tickPlan.shouldAttemptMeshAcceptance,
           let result = meshFallbackState.result
        {
            if let acceptance = stabilizeMeshAlignmentCandidate(result) {
                meshOverrideStatusText = RelocalizationCoordinator.acceptedMeshOverrideStatusText(acceptance)
                let decision = RelocalizationCoordinator.fallbackDecision(for: result.confidenceBand)
                switch decision {
                case .accept:
                    promoteToMeshAlignedOverride(using: acceptance)
                case .needsUserConfirmation:
                    if hasUserConfirmedMediumFallback {
                        promoteToMeshAlignedOverride(using: acceptance)
                    } else {
                        pendingFallbackAcceptance = acceptance
                        fallbackNeedsConfirmation = true
                        fallbackConfirmationPromptText = "Provisional alignment found. Confirm to proceed cautiously."
                        guidanceText = fallbackConfirmationPromptText ?? guidanceText
                    }
                case .reject:
                    meshOverrideStatusText = "Mesh Override: Candidate rejected (low confidence band)"
                }
            }
        }

        tickPlan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: appDecisionLocalizationState,
            loadRequestedAt: loadRequestedAt,
            appLocalizationState: appLocalizationState,
            meshOnlyTestModeEnabled: meshOnlyTestModeEnabled,
            meshFallbackActive: meshFallbackState.active,
            meshResult: meshFallbackState.result,
            hasAppliedWorldOriginShiftForCurrentAttempt: hasAppliedWorldOriginShiftForCurrentAttempt,
            isPoseStableForAnchorActions: isPoseStableForAnchorActions,
            latestLocalizationConfidence: latestLocalizationConfidence,
            meshFallbackPhase: meshFallbackState.phase
        )

        if tickPlan.followUpActions.shouldValidatePostShiftAlignment {
            validatePostShiftAlignment(with: frame)
        }
        if tickPlan.followUpActions.shouldReconcileAfterPostShift && !meshOnlyTestModeEnabled {
            reconcileARKitRelocalizationAgainstMeshOverride(with: frame)
        }

        tickPlan = RelocalizationCoordinator.appLocalizationTickPlan(
            localizationState: appDecisionLocalizationState,
            loadRequestedAt: loadRequestedAt,
            appLocalizationState: appLocalizationState,
            meshOnlyTestModeEnabled: meshOnlyTestModeEnabled,
            meshFallbackActive: meshFallbackState.active,
            meshResult: meshFallbackState.result,
            hasAppliedWorldOriginShiftForCurrentAttempt: hasAppliedWorldOriginShiftForCurrentAttempt,
            isPoseStableForAnchorActions: isPoseStableForAnchorActions,
            latestLocalizationConfidence: latestLocalizationConfidence,
            meshFallbackPhase: meshFallbackState.phase
        )

        if tickPlan.shouldDegradeMeshAlignedOverride, let reason = tickPlan.degradeReason {
            degradeAppLocalization(reason: reason)
        }

        if tickPlan.shouldResetMeshAligningToSearching {
            appLocalizationState = .searching
            if let statusText = tickPlan.resetStatusText {
                meshOverrideStatusText = statusText
                recordLocalizationEvent(
                    .meshAligningReset,
                    confidence: meshFallbackState.result?.confidence,
                    details: statusText
                )
            }
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
        recordLocalizationEvent(
            .meshAccepted,
            confidence: acceptance.confidence,
            details: "Promoted to meshAlignedOverride with \(acceptance.supportingFrames) supporting frame(s)"
        )
    }

    func promoteToARKitConfirmed() {
        guard !meshOnlyTestModeEnabled else { return }
        appLocalizationState = .arkitConfirmed
        if acceptedMeshAlignment != nil {
            appLocalizationSource = .arkitAndMeshConsistent
        } else {
            appLocalizationSource = .arkitWorldMap
        }
        localizationConflictText = nil
        lastConflictSnapshot = nil
        conflictDisagreementFrames = 0
        meshOverrideStatusText = RelocalizationCoordinator.arkitConfirmedMeshOverrideStatusText(
            hasAppliedWorldOriginShift: hasAppliedWorldOriginShiftForCurrentAttempt
        )
        recordLocalizationEvent(
            .arkitPromoted,
            confidence: latestLocalizationConfidence,
            details: meshOverrideStatusText
        )
    }

    func degradeAppLocalization(reason: String) {
        guard appLocalizationState != .conflict else { return }
        appLocalizationState = .degraded
        localizationConflictText = nil
        meshOverrideStatusText = "Mesh Override: Degraded"
        guidanceText = RelocalizationCoordinator.degradedGuidanceText(reason: reason)
        recordLocalizationEvent(
            .degraded,
            confidence: effectiveLocalizationConfidenceForEvent(),
            details: reason
        )
    }

    func enterLocalizationConflict(_ conflict: LocalizationConflictSnapshot) {
        appLocalizationState = .conflict
        lastConflictSnapshot = conflict
        let presentation = RelocalizationCoordinator.conflictPresentation(conflict: conflict)
        localizationConflictText = presentation.localizationConflictText
        meshOverrideStatusText = "Mesh Override: Conflict detected"
        guidanceText = presentation.guidanceText
        recordLocalizationEvent(
            .conflictDetected,
            confidence: conflict.meshConfidenceAtConflict,
            details: "Δpos \(String(format: "%.2f", conflict.positionDeltaMeters))m, Δyaw \(String(format: "%.0f", conflict.yawDeltaDegrees))°"
        )
    }

    func evaluateMeshAlignmentCandidate(_ result: MeshRelocalizationResult) -> Bool {
        RelocalizationCoordinator.evaluateMeshAlignmentCandidate(result)
    }

    func stabilizeMeshAlignmentCandidate(_ result: MeshRelocalizationResult) -> MeshAlignmentAcceptance? {
        let outcome = RelocalizationCoordinator.stabilizeMeshAlignmentCandidate(
            buffer: meshAlignmentCandidateBuffer,
            result: result
        )
        meshAlignmentCandidateBuffer = outcome.updatedBuffer
        if let status = outcome.statusText {
            meshOverrideStatusText = status
            if status.contains("Rejected") {
                recordLocalizationEvent(
                    .meshCandidateRejected,
                    confidence: result.confidence,
                    details: "\(status) | \(fallbackDiagnosticsSummary(for: result))"
                )
            } else if status.contains("waiting for stability") {
                recordLocalizationEvent(
                    .meshCandidateStabilizing,
                    confidence: result.confidence,
                    details: "\(status) | \(fallbackDiagnosticsSummary(for: result))"
                )
            }
        }
        if let acceptance = outcome.acceptance {
            recordLocalizationEvent(
                .meshAccepted,
                confidence: acceptance.confidence,
                details: String(
                    format: "Stable mesh acceptance conf %.0f%% residual %.2fm overlap %.0f%% yaw±%.0f°",
                    acceptance.confidence * 100,
                    acceptance.residualErrorMeters,
                    acceptance.overlapRatio * 100,
                    acceptance.yawConfidenceDegrees
                ) + " | " + fallbackDiagnosticsSummary(for: result)
            )
        }
        return outcome.acceptance
    }

    func applyWorldOriginShiftIfNeeded(using acceptance: MeshAlignmentAcceptance) {
        guard !hasAppliedWorldOriginShiftForCurrentAttempt else { return }
        guard let session = sceneView?.session else { return }
        preShiftSessionPoseSnapshot = currentPoseTransform
        // v1 strategy intentionally applies only yaw + XZ correction from mesh alignment.
        // This avoids vertical/tilt jumps and keeps the override predictable for guidance.
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
        recordLocalizationEvent(
            .worldOriginShiftApplied,
            confidence: acceptance.confidence,
            details: worldOriginShiftDebugText
        )
    }

    func computeWorldOriginRelativeTransform(from mapFromSession: simd_float4x4) -> simd_float4x4 {
        // Intentional Phase 2.8 behavior: mesh override authority is yaw + XZ only.
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
        let conflict = computeARKitMeshDisagreement(frame: frame)
        let decision = RelocalizationCoordinator.reconcileDecision(
            appLocalizationState: appLocalizationState,
            localizationState: localizationState,
            loadRequestedAt: loadRequestedAt,
            conflict: conflict,
            conflictDisagreementFrames: conflictDisagreementFrames,
            latestLocalizationConfidence: latestLocalizationConfidence
        )

        switch decision {
        case .noAction:
            return
        case .promoteARKitConfirmed:
            conflictDisagreementFrames = 0
            promoteToARKitConfirmed()
        case .resetConflictCounterAndPromote:
            conflictDisagreementFrames = 0
            promoteToARKitConfirmed()
        case .incrementConflictCounter:
            conflictDisagreementFrames += 1
        case .enterConflict:
            conflictDisagreementFrames += 1
            if let conflict {
                enterLocalizationConflict(conflict)
            }
        }
    }

    func computeARKitMeshDisagreement(frame: ARFrame) -> LocalizationConflictSnapshot? {
        guard let acceptance = acceptedMeshAlignment else { return nil }
        return RelocalizationCoordinator.computeARKitMeshDisagreement(
            frame: frame,
            acceptance: acceptance,
            arkitStateAtConflict: localizationState.displayText
        )
    }

    func shouldTrustARKitOverMesh(conflict: LocalizationConflictSnapshot) -> Bool {
        RelocalizationCoordinator.shouldTrustARKitOverMesh(
            latestLocalizationConfidence: latestLocalizationConfidence,
            conflict: conflict
        )
    }

    func beginFallbackRelocalizationIfNeeded() {
        guard let outcome = FallbackRelocalizationCoordinator.beginOutcome(
            currentState: fallbackRelocalizationState,
            hasRoomSignatureArtifact: hasRoomSignatureArtifact,
            hasSavedArtifact: savedRoomSignatureArtifact != nil
        ) else { return }

        if let state = outcome.state {
            fallbackRelocalizationState = state
        }
        if let presentation = outcome.presentation {
            applyFallbackRelocalizationPresentation(presentation)
        }
    }

    func updateFallbackRelocalizationProgress(currentYaw: Float) {
        guard fallbackRelocalizationState.isActive else { return }
        let outcome = FallbackRelocalizationCoordinator.updateProgress(
            state: fallbackRelocalizationState,
            currentYaw: currentYaw
        )
        fallbackRelocalizationState = outcome.state
        if outcome.shouldRunMatch {
            runRoomSignatureMatch()
            return
        }
        if let presentation = outcome.presentation {
            applyFallbackRelocalizationPresentation(presentation)
        }
    }

    func runRoomSignatureMatch() {
        guard fallbackRelocalizationState.isActive else { return }
        let result = matchCurrentScanToRoomSignature()
        if let result {
            applyFallbackRelocalizationGuidance(result)
        } else {
            let outcome = FallbackRelocalizationCoordinator.matchFailureOutcome(state: fallbackRelocalizationState)
            fallbackRelocalizationState = outcome.state
            applyFallbackRelocalizationPresentation(outcome.presentation)
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
        let outcome = FallbackRelocalizationCoordinator.matchSuccessOutcome(
            state: fallbackRelocalizationState,
            result: result
        )
        fallbackRelocalizationState = outcome.state
        applyFallbackRelocalizationPresentation(outcome.presentation)
    }

    func resetFallbackRelocalizationState() {
        fallbackRelocalizationState = FallbackRelocalizationCoordinator.resetState()
        applyFallbackRelocalizationPresentation(FallbackRelocalizationCoordinator.resetPresentation())
    }

    func shouldTriggerRoomSignatureFallback() -> Bool {
        FallbackRelocalizationCoordinator.shouldTriggerRoomSignatureFallback(
            hasRoomSignatureArtifact: hasRoomSignatureArtifact,
            relocalizationAttemptState: relocalizationAttemptState,
            localizationState: localizationState,
            fallbackIsActive: fallbackRelocalizationState.isActive
        )
    }

    func relocalizationPipelineState() -> String {
        if meshOnlyTestModeEnabled {
            return "Fallback isolation mode (ARKit app gating suppressed)"
        }
        return FallbackRelocalizationCoordinator.pipelineState(
            meshFallbackActive: meshFallbackState.active,
            roomSignatureFallbackActive: fallbackRelocalizationState.isActive
        )
    }

    func applyFallbackRelocalizationPresentation(_ presentation: FallbackRelocalizationCoordinator.Presentation) {
        fallbackRelocalizationActive = presentation.isActive
        fallbackRelocalizationText = presentation.text
        fallbackRelocalizationModeText = presentation.modeText
        fallbackRelocalizationPromptText = presentation.promptText
        fallbackRelocalizationConfidenceText = presentation.confidenceText
        if let guidance = presentation.guidanceOverride {
            guidanceText = guidance
        }
    }

    func refreshLocalizationEventLogStatus() {
        do {
            localizationEvents = try Phase1MapStore.loadLocalizationEvents()
            updateLocalizationEventPresentation()
        } catch {
            localizationEvents = []
            localizationEventCountText = "Localization Events: n/a"
            localizationLastEventText = "Last Localization Event: unavailable (\(error.localizedDescription))"
        }
    }

    func recordLocalizationEvent(
        _ eventType: LocalizationEventType,
        confidence: Float? = nil,
        details: String
    ) {
        let record = LocalizationEventRecord(
            eventType: eventType,
            appState: appLocalizationState.displayLabel,
            arkitState: localizationState.displayText,
            confidence: confidence ?? effectiveLocalizationConfidenceForEvent(),
            details: details
        )
        do {
            try Phase1MapStore.appendLocalizationEvent(record)
            localizationEvents.append(record)
            let now = Date()
            if now.timeIntervalSince(lastLocalizationEventPresentationUpdateAt) >= 0.25 || eventType == .conflictDetected || eventType == .degraded {
                updateLocalizationEventPresentation()
                lastLocalizationEventPresentationUpdateAt = now
            }
        } catch {
            statusMessage = "Localization event log write failed: \(error.localizedDescription)"
        }
    }

    func effectiveLocalizationConfidenceForEvent() -> Float {
        acceptedMeshAlignment?.confidence
            ?? meshFallbackState.result?.confidence
            ?? latestLocalizationConfidence
    }

    func visionDiagnosticsSummary(_ diagnostics: VisionRetrievalDiagnostics) -> String {
        let topDistances = diagnostics.topCandidateDistances
            .prefix(3)
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        let selected = diagnostics.selectedDistance.map { String(format: "%.3f", $0) } ?? "n/a"
        return "Vision selected=\(selected) topK=[\(topDistances)] candidates=\(diagnostics.candidateCount) distinctiveness=\(Int((diagnostics.distinctiveness * 100).rounded()))%"
    }

    func fallbackDiagnosticsSummary(for result: MeshRelocalizationResult) -> String {
        var segments: [String] = []
        if let diagnostics = result.diagnostics {
            segments.append(
                String(
                    format: "score coarse %.0f%% structure %.0f%% vision %.0f%% yawPenalty %.0f%% extentPenalty %.0f%% final %.0f%%",
                    diagnostics.coarseConfidence * 100,
                    diagnostics.structureScore * 100,
                    diagnostics.visionScore * 100,
                    diagnostics.yawPenalty * 100,
                    diagnostics.extentPenalty * 100,
                    diagnostics.finalScore * 100
                )
            )
        }
        if let visionDiagnostics = result.visionDiagnostics {
            segments.append(visionDiagnosticsSummary(visionDiagnostics))
        }
        let rejectionReasons = RelocalizationCoordinator.meshCandidateRejectionReasons(result)
        if !rejectionReasons.isEmpty {
            segments.append("reject=\(rejectionReasons.joined(separator: ","))")
        }
        segments.append(result.debugReason)
        return segments.joined(separator: " | ")
    }

    func updateLocalizationEventPresentation() {
        localizationEventCountText = "Localization Events: \(localizationEvents.count)"
        guard let latest = localizationEvents.last else {
            localizationLastEventText = "Last Localization Event: n/a"
            return
        }
        let confidencePercent = Int((max(0, min(1, latest.confidence)) * 100).rounded())
        localizationLastEventText = "Last Localization Event: \(latest.eventType.rawValue) (\(confidencePercent)%)"
    }

    var debugAppLocalizationState: AppLocalizationState { appLocalizationState }
    var debugHasAppliedWorldOriginShiftForCurrentAttempt: Bool { hasAppliedWorldOriginShiftForCurrentAttempt }
    var debugLocalizationEventCount: Int { localizationEvents.count }
    var debugMeshFallbackActive: Bool { meshFallbackState.active }
    var debugRelocalizationAttemptMode: RelocalizationAttemptMode? { relocalizationAttemptState?.mode }
    var debugCachedSavedMeshPointsCount: Int { cachedSavedMeshPoints.count }

    func debugSetAwaitingRelocalizationForTesting(_ value: Bool) {
        awaitingRelocalization = value
    }

    func debugActivateMeshFallbackForTesting() {
        meshFallbackState = MeshFallbackState(
            active: true,
            phase: .coarseMatching,
            startedAt: Date(),
            progressText: "Testing",
            result: nil
        )
    }

    func debugSetSavedMeshArtifactForTesting(_ artifact: MeshMapArtifact?) {
        savedMeshArtifact = artifact
        refreshCachedSavedMeshPoints()
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
        let result = AnchorManager.loadAnchorsFromDisk()
        anchors = result.anchors
        anchorOperationMessage = result.operationMessage
        if let error = result.errorMessage {
            errorMessage = error
        }
    }

    func enterAnchorMode() {
        applyAnchorModePresentationState(AnchorManager.enterAnchorModePresentationState())
        refreshAnchorTargetPreview()
        refreshAnchorActionAvailability()
    }

    func exitAnchorMode() {
        applyAnchorModePresentationState(AnchorManager.exitAnchorModePresentationState(currentPlacementMode: anchorPlacementMode))
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

        let anchor = AnchorManager.createCurrentPoseAnchor(
            type: type,
            requestedName: name,
            transform: transform,
            existingAnchors: anchors
        )
        anchors.append(anchor)
        persistAnchorsWithStatus(success: "Added anchor: \(anchor.name)")
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

        let anchor = AnchorManager.createAimedAnchor(
            type: type,
            requestedName: name,
            worldPosition: worldPosition,
            existingAnchors: anchors
        )
        anchors.append(anchor)
        persistAnchorsWithStatus(success: "Added aimed anchor: \(anchor.name)")
        anchorDraftName = ""
    }

    func renameAnchor(id: UUID, newName: String) {
        let result = AnchorManager.renameAnchor(&anchors, id: id, newName: newName)
        if let message = result.successMessage {
            persistAnchorsWithStatus(success: message)
        } else if let message = result.errorMessage {
            if message != "Anchor not found" {
                anchorOperationMessage = message
            }
        }
    }

    func deleteAnchor(id: UUID) {
        guard let message = AnchorManager.deleteAnchor(&anchors, id: id) else { return }
        persistAnchorsWithStatus(success: message)
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

        let ping = AnchorManager.distanceAndBearing(from: currentTransform, to: anchorTransform, anchorID: anchor.id, anchorName: anchor.name)
        anchorPingText = AnchorManager.pingSummary(from: ping)
        anchorOperationMessage = "Pinged \(ping.anchorName)"
    }

    func refreshAnchorActionAvailability() {
        let eligibility = anchorActionEligibility(for: anchorPlacementMode)
        anchorPlacementAllowed = eligibility.allowed
        anchorPlacementBlockReason = eligibility.reason
        anchorModeStatusText = AnchorManager.anchorModeStatusText(for: anchorPlacementMode, eligibility: eligibility)
    }

    func currentPoseTransformIfEligibleForAnchor() -> simd_float4x4? {
        validateAnchorPlacementEligibility().allowed ? currentPoseTransform : nil
    }

    func validateAnchorPlacementEligibility() -> (allowed: Bool, reason: String?) {
        let effectiveConfidence = acceptedMeshAlignment?.confidence ?? latestLocalizationConfidence
        return AnchorManager.validateAnchorPlacementEligibility(
            currentPoseTransform: currentPoseTransform,
            appLocalizationState: appLocalizationState,
            isPoseStableForAnchorActions: isPoseStableForAnchorActions,
            effectiveConfidence: effectiveConfidence,
            requiredConfidence: anchorConfidenceThreshold
        )
    }

    func anchorActionEligibility(for mode: AnchorPlacementMode) -> (allowed: Bool, reason: String?) {
        let base = validateAnchorPlacementEligibility()
        return AnchorManager.anchorActionEligibility(
            mode: mode,
            baseEligibility: base,
            anchorTargetingReady: anchorTargetingReady,
            latestAnchorTargetPreview: latestAnchorTargetPreview
        )
    }

    func currentRaycastTarget() -> SIMD3<Float>? {
        AnchorManager.currentRaycastTarget(
            latestAnchorTargetPreview: latestAnchorTargetPreview,
            anchorTargetingReady: anchorTargetingReady
        )
    }

    func refreshAnchorTargetPreview() {
        guard isAnchorModePresented else {
            applyAnchorTargetPreviewState(AnchorManager.inactiveTargetPreviewState())
            return
        }

        guard anchorPlacementMode == .aimedRaycast else {
            let baseEligibility = validateAnchorPlacementEligibility()
            applyAnchorTargetPreviewState(
                AnchorManager.hereModeTargetPreviewState(
                    currentPoseTransform: currentPoseTransform,
                    baseEligibility: baseEligibility
                )
            )
            return
        }

        guard let view = sceneView else {
            applyAnchorTargetPreviewState(AnchorManager.unavailableRaycastPreviewState(reason: "AR view not ready"))
            return
        }

        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let query = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any) else {
            applyAnchorTargetPreviewState(AnchorManager.unavailableRaycastPreviewState(reason: "No target surface in center view"))
            return
        }

        let results = view.session.raycast(query)
        if let hit = results.first {
            let hitPos = hit.worldTransform.translation
            let baseOK = validateAnchorPlacementEligibility().allowed
            let state = AnchorManager.raycastHitPreviewState(
                hitPosition: hitPos,
                hitSurfaceKind: "\(hit.target)",
                currentPoseTransform: currentPoseTransform,
                baseEligibility: (baseOK, nil),
                previousConsecutiveValidFrames: consecutiveValidRaycastFrames
            )
            applyAnchorTargetPreviewState(state)
        } else {
            applyAnchorTargetPreviewState(AnchorManager.unavailableRaycastPreviewState(reason: "No target surface in center view"))
        }
    }

    private func applyAnchorTargetPreviewState(_ state: AnchorManager.TargetPreviewState) {
        latestAnchorTargetPreview = state.preview
        anchorTargetPreviewText = state.previewText
        anchorTargetingReady = state.targetingReady
        consecutiveValidRaycastFrames = state.consecutiveValidRaycastFrames
    }

    private func persistAnchorsWithStatus(success: String) {
        let result = AnchorManager.saveAnchors(anchors, successMessage: success)
        if let operationMessage = result.operationMessage {
            anchorOperationMessage = operationMessage
            errorMessage = nil
        } else if let error = result.errorMessage {
            errorMessage = error
        }
    }

    private func applyAnchorModePresentationState(_ state: AnchorManager.ModePresentationState) {
        isAnchorModePresented = state.isAnchorModePresented
        showDebugOverlay = state.showDebugOverlay
        anchorPlacementMode = state.anchorPlacementMode
        anchorTargetPreviewText = state.anchorTargetPreviewText
        anchorModeStatusText = state.anchorModeStatusText
        anchorTargetingReady = state.anchorTargetingReady
        consecutiveValidRaycastFrames = state.consecutiveValidRaycastFrames
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
        clearRuntimeFallbackCaches(keepSavedMeshCache: false)
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

    func clearRuntimeFallbackCaches(keepSavedMeshCache: Bool) {
        meshAlignmentCandidateBuffer.removeAll()
        pendingFallbackAcceptance = nil
        lastVisionCandidateEvaluationAt = .distantPast
        meshFallbackLastEvaluationAt = .distantPast
        memoryPressureRelaxedUntil = .distantPast
        if !keepSavedMeshCache {
            cachedSavedMeshPoints.removeAll()
        }
    }

    func handleMemoryWarning() {
        clearRuntimeFallbackCaches(keepSavedMeshCache: true)
        memoryPressureRelaxedUntil = Date().addingTimeInterval(20)
        statusMessage = "Memory pressure detected: fallback sampling temporarily throttled."
    }

    private func updateRelocalizationState(with frame: ARFrame) {
        updateRelocalizationStateForTracking(frame.camera.trackingState)
    }

    func updateRelocalizationStateForTracking(_ tracking: ARCamera.TrackingState) {
        if meshOnlyTestModeEnabled, awaitingRelocalization {
            if relocalizationAttemptState == nil { beginRelocalizationAttempt() }
            switch tracking {
            case .limited(.relocalizing):
                sawRelocalizingState = true
                stableNormalFramesAfterLoad = 0
                localizationState = .relocalizing
                relocalizationText = "Mesh-only isolation: ARKit relocalizing (ignored for app localization)"
            case .normal:
                stableNormalFramesAfterLoad += 1
                localizationState = .relocalizing
                relocalizationText = "Mesh-only isolation: ARKit tracking normal (ignored for app localization)"
                statusMessage = "Mesh-only test mode: waiting for fallback alignment"
            case .limited:
                stableNormalFramesAfterLoad = 0
                localizationState = .relocalizing
                relocalizationText = "Mesh-only isolation: tracking limited; continue fallback scanning"
            case .notAvailable:
                stableNormalFramesAfterLoad = 0
                localizationState = .unknown
            }
            refreshAnchorActionAvailability()
            return
        }

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
                if meshOnlyTestModeEnabled {
                    relocalizationText = "ARKit relocalized (ignored in mesh-only test mode)"
                    statusMessage = "Mesh-only test mode: waiting for fallback alignment"
                } else {
                    relocalizationText = sawRelocalizingState
                        ? "Relocalized to saved map (ARKit tracking normal)"
                        : "Tracking normal after map load (likely relocalized)"
                    statusMessage = "Localization ready"
                }
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
        if awaitingRelocalization
            || localizationState == .relocalizing
            || (meshOnlyTestModeEnabled && (appLocalizationState == .searching || appLocalizationState == .meshAligning))
        {
            if relocalizationAttemptState == nil { beginRelocalizationAttempt() }
            refreshRelocalizationGuidanceUI()
            return
        }

        let tracking = frame.camera.trackingState
        let mapping = frame.worldMappingStatus
        let now = Date()
        let readinessSnapshot = computeScanReadinessSnapshot()
        let decision = GuidanceCoordinator.scanningGuidance(
            trackingState: tracking,
            mappingStatus: mapping,
            heuristics: GuidanceCoordinator.ScanHeuristicInputs(
                now: now,
                yawSweepWindowStart: yawSweepWindowStart,
                yawSweepAccumulated: yawSweepAccumulated,
                lastMovementAt: lastMovementAt,
                mapReadinessWarningsText: mapReadinessWarningsText,
                scanReadinessQualityScore: readinessSnapshot.qualityScore
            )
        )
        if decision.shouldResetYawSweepWindow {
            yawSweepWindowStart = now
            yawSweepAccumulated = 0
        }
        guidanceText = decision.guidanceText
    }

    private func currentRelocalizationGuidanceSnapshot() -> RelocalizationGuidanceSnapshot? {
        RelocalizationAttemptCoordinator.currentGuidanceSnapshot(
            state: relocalizationAttemptState,
            localizationState: localizationState
        )
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

            self.updateRuntimeVisionKeyframeBuffer(with: frame)
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
