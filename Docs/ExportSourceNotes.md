# Export implementation source notes

USDZ is an unencrypted ZIP archive using compression method 0. Every file's data begins at an absolute offset divisible by 64, and the first entry must be a native USD layer for the package to open directly as a stage. QUESTSCAN writes `scene.usda` first and uses valid ZIP extra-field records for padding rather than bytes outside ZIP headers. All texture references use anchored package-relative paths. [1]

The preview material network uses `UsdPreviewSurface`, `UsdUVTexture`, and `UsdPrimvarReader_float2`. Texture `inputs:st` connects to the primvar reader's `outputs:result`, and the reader's string `inputs:varname` identifies the `st` primvar. USD texture coordinates have a bottom-left origin; QUESTSCAN's processing contract already supplies this orientation, so export must not flip it again. JPEG color textures are marked `sRGB` and use clamp wrapping. [2]

Geometry is explicitly bound to material prims with `MaterialBindingAPI` applied on each mesh. The implementation validates input geometry and creates identifiers and asset filenames from UUIDs, not user-provided names. User-facing names are escaped only as USD string metadata.

## References

[1]: https://openusd.org/25.11/spec_usdz.html "OpenUSD USDZ File Format Specification version 1.3"
[2]: https://openusd.org/dev/spec_usdpreviewsurface.html "OpenUSD UsdPreviewSurface Specification"

The binding API is explicitly applied because OpenUSD recommends applying this single-apply schema when binding a material. [3] Textured native materials are unlit, so their adjusted color texture drives preview-surface emission with zero diffuse and specular rather than being lit a second time. Untextured materials use `SceneRenderer.adjustedDiffuseRGB`; its sRGB diffuse value is converted to scene-linear shader color.

[3]: https://openusd.org/dev/api/class_usd_shade_material_binding_a_p_i.html "OpenUSD UsdShadeMaterialBindingAPI Reference"

## Validation and test execution

OpenUSD Python bindings version 26.11 parsed solid and textured scenes assembled directly from the exporter’s USDA templates. The checks verified geometry arrays, vertex normal interpolation, applied material binding API, resolved material, connected surface output, string-typed `st` primvar reader, texture coordinate connection, emission connection and UV array. This is template/schema validation, not execution of the Swift exporter.

The Linux Swift compiler requested for this task was unavailable, and the parent switched compiler testing to macOS CI. `Tests/ExportTests.swift` defaults to a standalone archive test executable requiring only `StoredZIP.swift`. Defining `QUESTSCAN_MODEL_TESTS` enables the complete model/export/persistence suite in the same file, with `ScanData.swift`, `ScanLibrary.swift`, `StoredZIP.swift` and `USDZExporter.swift` as compilation inputs. The latter uses an injected adjustment closure on non-iOS platforms; actual Core Image JPEG edits and Apple Quick Look viewing require iOS-device or iOS-simulator checks.

Persistence reads file attributes for file type and byte size but does not consume filesystem timestamps. Displayed dates are from the document’s JSON `createdAt`. The parent should include the requested-app-container-access privacy-manifest reason `C617.1` for any covered file-attribute API usage.
