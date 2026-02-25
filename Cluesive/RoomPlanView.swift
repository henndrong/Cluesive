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
    @Published var isSessionRunning = false
    @Published var trackingStateText = "Not started"
    @Published var mappingStatusText = "n/a"
    @Published var guidanceText = "Start a scan and slowly move around walls/furniture."
    @Published var relocalizationText = "No map loaded"
    @Published var poseText = "x 0.00  y 0.00  z 0.00  yaw 0°"
    @Published var meshAnchorCount = 0
    @Published var planeAnchorCount = 0
    @Published var featurePointCount = 0
    @Published var hasSavedMap = false
    @Published var lastSavedText = "No saved map"
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    fileprivate weak var sceneView: ARSCNView?

    private var awaitingRelocalization = false
    private var sawRelocalizingState = false
    private var stableNormalFramesAfterLoad = 0
    private var loadRequestedAt: Date?

    private var lastTransform: simd_float4x4?
    private var lastMovementAt = Date()
    private var yawSweepWindowStart = Date()
    private var yawSweepAccumulated: Float = 0
    private var lastYaw: Float?

    override init() {
        super.init()
        refreshSavedMapState()
    }

    func attachSceneView(_ view: ARSCNView) {
        sceneView = view
        view.session.delegate = self
        view.delegate = self
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.debugOptions = [.showFeaturePoints]
        refreshSavedMapState()
    }

    func startFreshScan() {
        guard ARWorldTrackingConfiguration.isSupported else {
            errorMessage = "ARWorldTracking is not supported on this device."
            return
        }
        runSession(initialWorldMap: nil)
        relocalizationText = "Fresh scan session"
        statusMessage = "Scanning started"
        errorMessage = nil
        awaitingRelocalization = false
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
                    self.hasSavedMap = true
                    self.lastSavedText = "Saved \(metadata.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                    self.statusMessage = "Map saved on device"
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
            awaitingRelocalization = true
            sawRelocalizingState = false
            stableNormalFramesAfterLoad = 0
            loadRequestedAt = Date()
            relocalizationText = "Loaded map. Walk to the same area to relocalize..."
            statusMessage = "Map loaded, relocalization running"
            errorMessage = nil
            runSession(initialWorldMap: worldMap)
        } catch {
            errorMessage = "Load failed: \(error.localizedDescription)"
        }
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
        yawSweepAccumulated = 0
        yawSweepWindowStart = Date()
        lastMovementAt = Date()
    }

    private func updateRelocalizationState(with frame: ARFrame) {
        guard awaitingRelocalization else { return }

        let tracking = frame.camera.trackingState
        if case .limited(.relocalizing) = tracking {
            sawRelocalizingState = true
            stableNormalFramesAfterLoad = 0
            relocalizationText = "Relocalizing... point camera at previously scanned surfaces"
            return
        }

        if case .normal = tracking {
            stableNormalFramesAfterLoad += 1
            let longEnoughSinceLoad = (loadRequestedAt.map { Date().timeIntervalSince($0) > 1.5 } ?? true)
            if stableNormalFramesAfterLoad > 15 && longEnoughSinceLoad {
                awaitingRelocalization = false
                relocalizationText = sawRelocalizingState
                    ? "Relocalized to saved map (ARKit tracking normal)"
                    : "Tracking normal after map load (likely relocalized)"
                statusMessage = "Localization ready"
            }
        } else {
            stableNormalFramesAfterLoad = 0
        }
    }

    private func updateGuidance(with frame: ARFrame) {
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
        let yaw = transform.yawRadians

        Task { @MainActor in
            self.featurePointCount = featureCount
            self.meshAnchorCount = meshCount
            self.planeAnchorCount = planeCount
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
            self.updateRelocalizationState(with: frame)
            self.updateGuidance(with: frame)
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
        }

        if let lastYaw {
            let deltaYaw = abs(normalizedAngle(currentYaw - lastYaw))
            yawSweepAccumulated += deltaYaw
            if deltaYaw > (.pi / 36) {
                lastMovementAt = Date()
            }
        }
    }

    @MainActor
    private func normalizedAngle(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
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

    var body: some View {
        ZStack {
            RoomCaptureContainerView(model: model)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topStatusPanel
                Spacer()
                bottomControlPanel
            }
            .padding()
        }
        .onAppear {
            model.refreshSavedMapState()
            if !model.isSessionRunning {
                model.startFreshScan()
            }
        }
        .onDisappear {
            model.stopScan()
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

            Text("Tracking: \(model.trackingStateText)")
            Text("Mapping: \(model.mappingStatusText)")
            Text("Reloc: \(model.relocalizationText)")
            Text("Guidance: \(model.guidanceText)")
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Mesh anchors: \(model.meshAnchorCount)  Planes: \(model.planeAnchorCount)  Features: \(model.featurePointCount)")
            Text(model.poseText)
            Text(model.lastSavedText)
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomControlPanel: some View {
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
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension simd_float4x4 {
    nonisolated var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    nonisolated var yawRadians: Float {
        atan2(columns.0.z, columns.0.x)
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
