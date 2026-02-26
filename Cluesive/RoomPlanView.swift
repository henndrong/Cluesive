//
//  RoomPlanView.swift
//  Cluesive
//
//  UI for LiDAR scanning, relocalization debug, and anchor tools.
//

import SwiftUI
import ARKit

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

#Preview {
    RoomPlanView()
}
