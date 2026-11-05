# Processing implementation references

- Apple, RealityKit 2 dynamic mesh API (iOS 15 and later): https://developer.apple.com/videos/play/wwdc2021/10075/ — `MeshDescriptor.positions`, `.normals`, `.textureCoordinates`, `.primitives = .triangles`, `MeshResource.generate(from:)`.
- Procedural Mesh in RealityKit, May 2022: https://markhorgan.com/blog/procedural-mesh-in-realitykit/ — iOS-era concrete MeshDescriptor example and UV attributes.
- TextureResource CGImage options example, March 2023: https://gist.github.com/sakrist/b22e7280487d3cf44e250fd6bd9c0e34 — `.init(semantic: .color)` for color texture creation/replacement.

Native camera images are not screen-oriented: projection uses the inverse camera transform, negative camera Z for depth, flipped camera Y for raw top-left image pixels, and bottom-left UVs. JPEG resizing does not change normalized UV coordinates. Rendering and export must both use `SceneRenderer.adjustedJPEG(_:adjustment:)`; the tint is baked there, so the textured material tint stays white.

Apple's concrete CGImage creation example: https://developer.apple.com/videos/play/wwdc2021/10074/ — `TextureResource.generate(from: cgImage, options: .init(semantic: .color))`. Core Image controls: https://developer.apple.com/documentation/coreimage/cicolorcontrols — brightness, contrast and saturation properties.

Untextured parts use `SceneRenderer.adjustedDiffuseRGB(_:)` as their material color. Exporters should call this helper rather than implement a second tint formula. Textured parts use an UnlitMaterial with white tint and the exact JPEG bytes returned by the export adjustment helper; exported lighting may differ by viewer, but edited base-color pixels are identical.
