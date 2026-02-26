# Cluesive

Cluesive is an iOS capstone project exploring indoor LiDAR-based navigation for blind and low-vision users using an iPhone 16 Pro.

The current focus is:
- scanning and persisting indoor maps
- relocalizing in a previously scanned space
- semantic anchors (doors, entrances, corners, custom points)
- accessible guidance foundations (debug ping / distance-bearing, speech+haptics planned)

## Goal

Enable a user to:
1. Scan a home environment (example: 3-room apartment)
2. Save a navigable map + anchors
3. Re-open later and relocalize from an arbitrary start pose
4. Receive orientation and navigation guidance (audio/haptics)

## Current Status (High Level)

Implemented / in progress:
- ARKit LiDAR scanning session with tracking indicators
- map persistence (AR world mapping data + metadata)
- anchor creation/listing/rename/delete + semantic anchor types
- explicit relocalization state handling
- pose/heading debug readout
- mesh-based relocalization alignment work (ICP-lite style refinement) and coordinator extraction refactors

Planned next:
- stronger validation of relocalization from arbitrary position/orientation
- app-level dual localization state (ARKit + mesh override)
- waypoint graph + routing (A*)
- speech/haptics guidance loop
- accessibility polish and evaluation trials

## Tech Stack

- Swift
- SwiftUI
- ARKit (world tracking, relocalization, scene reconstruction)
- LiDAR-capable iPhone (target device: iPhone 16 Pro)
- Xcode + Swift Package Manager (if/when packages are added)

## Repository Structure

```text
Cluesive/
├── Cluesive/                    # Main app target source
│   ├── CluesiveApp.swift
│   ├── ContentView.swift
│   ├── RoomPlanView.swift       # Main UI for scan/relocalization/anchors
│   ├── RoomPlanModel.swift      # App orchestration state
│   ├── RoomPlanCore.swift       # Shared types + persistence helpers
│   ├── RoomPlanExtensions.swift # Math / transform / mesh helpers
│   ├── MeshRelocalizationEngine.swift
│   ├── AnchorManager.swift
│   ├── RelocalizationCoordinator.swift
│   └── ...other coordinators/helpers
├── Cluesive.xcodeproj/
├── CluesiveTests/
└── CluesiveUITests/
```

## Running the App

### Prerequisites
- Xcode (recent version with iOS SDK supporting your device)
- A physical LiDAR-enabled iPhone (simulator will not support LiDAR/ARKit scanning flows)
- Developer signing configured in Xcode

### Steps
1. Open `/Users/josh/Desktop/Capstone/Cluesive/Cluesive.xcodeproj` in Xcode.
2. Select the `Cluesive` app target and a connected LiDAR-enabled iPhone.
3. Build and run.
4. Grant camera/motion permissions when prompted.

## Notes
- The planning documents (`project.md`, `todo.md`, `techstack.md`, `documentation.md`) live in the workspace parent directory: `/Users/josh/Desktop/Capstone`.
- The actual git repository root is this directory: `/Users/josh/Desktop/Capstone/Cluesive`.
- This project is under active refactor; architecture is being split into focused coordinators/managers to keep `RoomPlanModel` orchestration-centric.

## Roadmap (Capstone)

1. Validate reliable save/load + relocalization in the same room
2. Improve mesh-assisted localization fallback and conflict handling
3. Build waypoint graph and route planning
4. Add orientation-first guidance (heading alignment)
5. Add navigation speech/haptics and accessibility polish
6. Run evaluation trials and document results
