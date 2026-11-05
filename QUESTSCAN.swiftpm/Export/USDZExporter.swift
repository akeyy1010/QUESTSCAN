import Foundation

/// Self-contained USDZ export: meter-based Y-up meshes and packaged JPEG assets.
/// USDA/ZIP construction is portable; native image edits use the renderer's exact pipeline.
enum USDZExporter {
    enum ExportError: Error, LocalizedError {
        case invalidDestination
        case invalidAdjustedTexture
        case nativeImageProcessingRequired

        var errorDescription: String? {
            switch self {
            case .invalidDestination: return "USDZ の保存先がローカルファイルではありません。"
            case .invalidAdjustedTexture: return "調整済みテクスチャが空、または上限を超えています。"
            case .nativeImageProcessingRequired: return "写真の色調整には iOS の画像処理が必要です。"
            }
        }
    }

    static func export(_ document: SceneDocument, to url: URL) throws {
        guard url.isFileURL else { throw ExportError.invalidDestination }
        let archive = try makeArchive(document) { data, adjustment in
            #if canImport(UIKit)
            return try SceneRenderer.adjustedJPEG(data, adjustment: adjustment)
            #else
            // Do not silently export unedited pixels on platforms lacking Core Image.
            throw ExportError.nativeImageProcessingRequired
            #endif
        }
        try archive.write(to: url, options: [.atomic])
    }

    /// Injection is for portable tests only; the production entry point above always
    /// calls SceneRenderer.adjustedJPEG, including its image decoding/size guards.
    static func makeArchive(_ document: SceneDocument,
                            adjustTexture: (Data, ColorAdjustment) throws -> Data) throws -> Data {
        try StoredZIP.archive(entries: makeEntries(document, adjustTexture: adjustTexture))
    }

    static func makeEntries(_ document: SceneDocument,
                            adjustTexture: (Data, ColorAdjustment) throws -> Data) throws -> [StoredZIP.Entry] {
        try ScanLibrary.validate(document)
        var textures: [StoredZIP.Entry] = []
        var texturePaths: [UUID: String] = [:]
        var totalTextureBytes = 0
        for part in document.parts {
            if let jpeg = part.textureJPEG {
                let adjusted = try adjustTexture(jpeg, part.adjustment)
                guard !adjusted.isEmpty, adjusted.count <= ScanLibrary.maximumTextureBytes,
                      adjusted.count <= StoredZIP.maximumArchiveBytes - totalTextureBytes else {
                    throw ExportError.invalidAdjustedTexture
                }
                totalTextureBytes += adjusted.count
                let path = "textures/" + part.id.uuidString.lowercased() + ".jpeg"
                texturePaths[part.id] = path
                textures.append(StoredZIP.Entry(name: path, data: adjusted))
            }
        }

        var scene = """
        #usda 1.0
        (
            defaultPrim = "QuestScan"
            metersPerUnit = 1
            upAxis = "Y"
            documentation = \(quoted("QUESTSCAN — " + document.name))
        )

        def Xform "QuestScan" (
            kind = "component"
            displayName = \(quoted(document.name))
        )
        {
            def Scope "Looks"
            {

        """
        for part in document.parts {
            scene += material(part, texturePath: texturePaths[part.id])
        }
        scene += "    }\n\n"
        for part in document.parts { scene += mesh(part) }
        scene += "}\n"
        let layer = Data(scene.utf8)
        guard layer.count <= StoredZIP.maximumArchiveBytes - totalTextureBytes else {
            throw StoredZIP.ArchiveError.tooLarge
        }
        // The default layer is necessarily the first local AND central ZIP entry.
        return [StoredZIP.Entry(name: "scene.usda", data: layer)] + textures
    }

    private static func material(_ part: ScenePart, texturePath: String?) -> String {
        let name = materialName(part.id)
        let base = "/QuestScan/Looks/" + name
        var result = """
                def Material "\(name)"
                {
                    token outputs:surface.connect = <\(base)/Surface.outputs:surface>
                    def Shader "Surface"
                    {
                        uniform token info:id = "UsdPreviewSurface"
                        float inputs:metallic = 0
                        float inputs:opacity = 1
                        token outputs:surface

        """
        if let path = texturePath {
            // The native renderer uses an UnlitMaterial for captured photos. Emission
            // with zero diffuse/specular preserves those baked colors under any light.
            result += """
                        color3f inputs:diffuseColor = (0, 0, 0)
                        color3f inputs:emissiveColor.connect = <\(base)/ColorTexture.outputs:rgb>
                        int inputs:useSpecularWorkflow = 1
                        color3f inputs:specularColor = (0, 0, 0)
                        float inputs:ior = 1
                        float inputs:roughness = 1
                    }
                    def Shader "UVReader"
                    {
                        uniform token info:id = "UsdPrimvarReader_float2"
                        string inputs:varname = "st"
                        float2 inputs:fallback = (0, 0)
                        float2 outputs:result
                    }
                    def Shader "ColorTexture"
                    {
                        uniform token info:id = "UsdUVTexture"
                        asset inputs:file = @./\(path)@
                        float2 inputs:st.connect = <\(base)/UVReader.outputs:result>
                        token inputs:sourceColorSpace = "sRGB"
                        token inputs:wrapS = "clamp"
                        token inputs:wrapT = "clamp"
                        float4 inputs:fallback = (1, 1, 1, 1)
                        float3 outputs:rgb
                    }
                }

            """
        } else {
            let rgb = solidDiffuse(part.adjustment)
            // UIColor and JPEG are sRGB; USD shader color values are scene-linear.
            let linear = SIMD3<Float>(linearize(rgb.x), linearize(rgb.y), linearize(rgb.z))
            result += """
                        color3f inputs:diffuseColor = \(tuple(linear))
                        float inputs:roughness = 0.85
                        color3f inputs:emissiveColor = (0, 0, 0)
                    }
                }

            """
        }
        return result
    }

    private static func mesh(_ part: ScenePart) -> String {
        var low = part.vertices[0], high = low
        for vertex in part.vertices {
            low = SIMD3<Float>(min(low.x, vertex.x), min(low.y, vertex.y), min(low.z, vertex.z))
            high = SIMD3<Float>(max(high.x, vertex.x), max(high.y, vertex.y), max(high.z, vertex.z))
        }
        let normals = part.normals.map { normal -> SIMD3<Float> in
            let length = sqrt(Double(normal.x) * Double(normal.x) + Double(normal.y) * Double(normal.y) +
                              Double(normal.z) * Double(normal.z))
            return SIMD3<Float>(Float(Double(normal.x) / length), Float(Double(normal.y) / length),
                                Float(Double(normal.z) / length))
        }
        var result = """
            def Mesh "\(meshName(part.id))" (
                prepend apiSchemas = ["MaterialBindingAPI"]
                displayName = \(quoted(part.name))
            )
            {
                uniform token subdivisionScheme = "none"
                uniform token orientation = "rightHanded"
                bool doubleSided = true
                int[] faceVertexCounts = [\(Array(repeating: "3", count: part.triangleCount).joined(separator: ", "))]
                int[] faceVertexIndices = [\(part.indices.map { String($0) }.joined(separator: ", "))]
                point3f[] points = [\(part.vertices.map(tuple).joined(separator: ", "))]
                float3[] extent = [\(tuple(low)), \(tuple(high))]
                normal3f[] normals = [\(normals.map(tuple).joined(separator: ", "))] (
                    interpolation = "vertex"
                )
                rel material:binding = </QuestScan/Looks/\(materialName(part.id))>

        """
        if !part.textureCoordinates.isEmpty {
            result += """
                texCoord2f[] primvars:st = [\(part.textureCoordinates.map { "(" + number($0.x) + ", " + number($0.y) + ")" }.joined(separator: ", "))] (
                    interpolation = "vertex"
                )

            """
        }
        result += "    }\n\n"
        return result
    }

    private static func meshName(_ id: UUID) -> String { "Part_" + identifier(id) }
    private static func materialName(_ id: UUID) -> String { "Material_" + identifier(id) }
    private static func identifier(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "_")
    }

    /// Swift's numeric description is locale-independent and round-trips Float.
    /// Inputs are already finite/bounded; never use localized NumberFormatter here.
    private static func number(_ value: Float) -> String { value == 0 ? "0" : String(value) }
    private static func tuple(_ value: SIMD3<Float>) -> String {
        "(" + number(value.x) + ", " + number(value.y) + ", " + number(value.z) + ")"
    }
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private static func solidDiffuse(_ adjustment: ColorAdjustment) -> SIMD3<Float> {
        #if canImport(UIKit)
        return SceneRenderer.adjustedDiffuseRGB(adjustment)
        #else
        // Mirror the renderer's documented neutral-white diffuse rule for tests.
        let neutral = 0.5 * min(3, adjustment.contrast) + 0.5 + adjustment.brightness
        let tint = SIMD3<Float>(repeating: 1 - adjustment.tintAmount) +
            SIMD3<Float>(adjustment.red, adjustment.green, adjustment.blue) * adjustment.tintAmount
        let rgb = tint * neutral
        return SIMD3<Float>(min(1, max(0, rgb.x)), min(1, max(0, rgb.y)), min(1, max(0, rgb.z)))
        #endif
    }
    private static func linearize(_ srgb: Float) -> Float {
        srgb <= 0.04045 ? srgb / 12.92 : Float(pow((Double(srgb) + 0.055) / 1.055, 2.4))
    }
}
