//
//  RoomPlanView.swift
//  Cluesive
//
//  Mode-based UI for scanning, anchors, and manual graph editing.
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
    @State private var showScanDebug = false

    private var workspaceBinding: Binding<WorkspaceMode> {
        Binding(
            get: { model.workspaceMode },
            set: { model.setWorkspaceMode($0) }
        )
    }

    var body: some View {
        ZStack {
            RoomCaptureContainerView(model: model)
                .ignoresSafeArea()

            if model.workspaceMode == .anchors || model.workspaceMode == .graph {
                centerReticleOverlay
                    .allowsHitTesting(false)
            }

            VStack(spacing: 12) {
                compactStatusPanel
                Spacer()
                activeWorkspacePanel
            }
            .padding()
        }
        .onAppear {
            model.refreshSavedMapState()
            model.loadAnchorsFromDisk()
            model.loadNavGraphFromDisk()
            model.refreshRoomSignatureStatus()
            model.refreshMeshArtifactStatus()
            model.refreshLocalizationEventLogStatus()
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

    private var compactStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            } else if let status = model.statusMessage {
                Text(status)
                    .foregroundStyle(.green)
            }

            Text("Mode: \(model.workspaceMode.displayName)")
            Text("Tracking: \(model.trackingStateText)")
            Text(model.appLocalizationStateText)
            Text(model.appLocalizationPromptText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Workspace", selection: workspaceBinding) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var activeWorkspacePanel: some View {
        switch model.workspaceMode {
        case .scan:
            scanPanel
        case .anchors:
            anchorModePanel
        case .graph:
            graphModePanel
        }
    }

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            VStack(alignment: .leading, spacing: 4) {
                Text(model.mapReadinessText)
                Text(model.mapReadinessScoreText)
                Text("Graph saved: \(model.hasSavedNavGraph ? "Yes" : "No")")
                Text(model.graphValidationText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)

            DisclosureGroup("Diagnostics", isExpanded: $showScanDebug) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mapping: \(model.mappingStatusText)")
                    Text("Reloc: \(model.relocalizationText)")
                    Text(model.localizationConfidenceText)
                    Text(model.poseStabilityText)
                    Text("Guidance: \(model.guidanceText)")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.meshArtifactStatusText)
                    Text(model.roomSignatureStatusText)
                    Text(model.localizationEventCountText)
                    Text(model.localizationLastEventText)
                    Text(model.poseDebugText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .padding(.top, 4)
            }
        }
        .workspacePanelStyle()
    }

    private var anchorModePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Anchor Tools")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Back to Scan") {
                    if renamingAnchorID != nil {
                        renamingAnchorID = nil
                        renameDraft = ""
                    }
                    model.setWorkspaceMode(.scan)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Reloc: \(model.relocalizationText)")
                Text(model.anchorModeStatusText)
                if let target = model.anchorTargetPreviewText {
                    Text("Target: \(target)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let ping = model.anchorPingText {
                    Text("Ping: \(ping)")
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Placement", selection: $model.anchorPlacementMode) {
                ForEach(AnchorPlacementMode.allCases) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            anchorControls
            anchorList
        }
        .workspacePanelStyle()
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

                Spacer()
                Text("\(model.anchors.count) saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reason = model.anchorPlacementBlockReason, !model.anchorPlacementAllowed {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
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
        .frame(maxHeight: 240)
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
                Button("Link Nearest") {
                    model.autoLinkNearestWaypointToAnchor(anchorID: anchor.id)
                }
                .buttonStyle(.bordered)
                .disabled(model.navGraph.nodes.isEmpty)
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
                        model.deleteAnchor(id: anchor.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var graphModePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Add Waypoint") {
                    model.addWaypointAtAimPoint()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.graphPlacementAllowed)

                Button("Save Graph") {
                    model.saveNavGraphToDisk()
                }
                .buttonStyle(.borderedProminent)

                Button("Validate") {
                    model.validateNavGraph()
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.graphTargetPreviewText ?? "Aim at floor to place waypoint")
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = model.graphPlacementBlockReason, !model.graphPlacementAllowed {
                    Text(reason)
                        .foregroundStyle(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status = model.graphStatusMessage {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.graphValidationText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)

            graphSelectionPanel
            graphWaypointsList
            graphEdgesList
        }
        .workspacePanelStyle()
    }

    private var graphSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedNodeID = model.selectedGraphNodeID,
               let node = model.navGraph.nodes.first(where: { $0.id == selectedNodeID }) {
                Text("Selected: \(node.name)")
                    .font(.caption.weight(.semibold))

                HStack(spacing: 8) {
                    TextField("Waypoint name", text: $model.graphDraftName)
                        .textFieldStyle(.roundedBorder)
                    Button("Rename") {
                        model.renameSelectedWaypoint(to: model.graphDraftName)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Delete", role: .destructive) {
                        model.deleteSelectedWaypoint()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Menu("Connect To") {
                        ForEach(model.navGraph.nodes.filter { $0.id != selectedNodeID }) { candidate in
                            Button(candidate.name) {
                                model.connectSelectedWaypoint(to: candidate.id)
                            }
                        }
                    }
                    .disabled(model.navGraph.nodes.count < 2)

                    Menu("Link Anchor") {
                        if model.anchors.isEmpty {
                            Text("No anchors")
                        } else {
                            ForEach(model.anchors) { anchor in
                                Button(anchor.name) {
                                    model.linkSelectedWaypointToAnchor(anchor.id)
                                }
                            }
                        }
                    }

                    Button("Clear Link") {
                        model.linkSelectedWaypointToAnchor(nil)
                    }
                    .buttonStyle(.bordered)
                }

                if let link = model.graphAnchorLinkText {
                    Text("Linked anchor: \(link)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No waypoint selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var graphWaypointsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waypoints")
                .font(.caption.weight(.semibold))

            ScrollView {
                VStack(spacing: 8) {
                    if model.navGraph.nodes.isEmpty {
                        Text("No waypoints yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(model.navGraph.nodes) { node in
                            Button {
                                model.selectWaypoint(node.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(node.name)
                                        Text(String(format: "x %.2f z %.2f", node.position.x, node.position.z))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let linkedAnchorID = node.linkedAnchorID,
                                       let anchor = model.anchors.first(where: { $0.id == linkedAnchorID }) {
                                        Text(anchor.name)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedGraphNodeID == node.id ? Color.white.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    private var graphEdgesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Edges")
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.selectedGraphEdgeID != nil {
                    Button("Remove Edge", role: .destructive) {
                        model.deleteSelectedEdge()
                    }
                    .buttonStyle(.bordered)
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    if model.navGraph.edges.isEmpty {
                        Text("No edges yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(model.navGraph.edges) { edge in
                            let fromName = model.navGraph.nodes.first(where: { $0.id == edge.fromNodeID })?.name ?? "Unknown"
                            let toName = model.navGraph.nodes.first(where: { $0.id == edge.toNodeID })?.name ?? "Unknown"
                            Button {
                                model.selectedGraphEdgeID = edge.id
                                model.selectedGraphNodeID = nil
                                model.refreshGraphSceneOverlays()
                            } label: {
                                HStack {
                                    Text("\(fromName) -> \(toName)")
                                    Spacer()
                                    Text(String(format: "%.2fm", edge.distanceMeters))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedGraphEdgeID == edge.id ? Color.white.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 130)
        }
    }

    private var centerReticleOverlay: some View {
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
        switch model.workspaceMode {
        case .anchors:
            if model.anchorPlacementAllowed { return .green }
            return model.anchorTargetPreviewText?.localizedCaseInsensitiveContains("No target") == true ? .yellow : .red
        case .graph:
            if model.graphPlacementAllowed { return .green }
            return model.graphPlacementBlockReason?.localizedCaseInsensitiveContains("floor") == true ? .yellow : .red
        case .scan:
            return .clear
        }
    }

    private var reticleLabel: String {
        switch model.workspaceMode {
        case .anchors:
            return model.anchorPlacementAllowed ? "Anchor Ready" : "Aim Anchor"
        case .graph:
            return model.graphPlacementAllowed ? "Waypoint Ready" : "Aim Floor"
        case .scan:
            return ""
        }
    }
}

private extension View {
    func workspacePanelStyle() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    RoomPlanView()
}
