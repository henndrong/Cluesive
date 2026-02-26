//
//  RoomPlanExtensions.swift
//  Cluesive
//
//  Math helpers and ARKit/Simd extensions shared by the model and view.
//

import SwiftUI
import ARKit
import SceneKit

extension simd_float4x4 {
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

extension Array where Element == Float {
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

func flatPointsToSIMD(_ flat: [Float]) -> [SIMD3<Float>] {
    flat.chunked3SIMD
}

func centroidXZ(_ points: [SIMD3<Float>]) -> SIMD2<Float> {
    guard !points.isEmpty else { return .zero }
    let sum = points.reduce(SIMD2<Float>.zero) { partial, p in
        partial + SIMD2<Float>(p.x, p.z)
    }
    return sum / Float(points.count)
}

func normalizedDegrees(_ degrees: Float) -> Float {
    var d = degrees
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
}

func angleDistanceDegrees(_ a: Float, _ b: Float) -> Float {
    abs(normalizedDegrees(a - b))
}

extension ARMeshAnchor {
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

extension ARMeshGeometry {
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

extension ARCamera.TrackingState {
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

extension ARFrame.WorldMappingStatus {
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
