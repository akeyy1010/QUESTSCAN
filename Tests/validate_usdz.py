"""Independent ZIP/USD validation: python validate_usdz.py <fixture-directory>.
Requires OpenUSD Python bindings (`pip install usd-core`). Does not claim to test
Quick Look, RealityKit GPU rendering, or the intentionally synthetic JPEG stub.
"""
from pathlib import Path
import json
import struct
import sys
import zipfile
from pxr import Usd, UsdGeom, UsdShade


def validate(path: Path) -> dict:
    raw = path.read_bytes()
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        assert infos and infos[0].filename == "scene.usda", "Default layer must be first"
        assert archive.testzip() is None, "ZIP CRC validation failed"
        for info in infos:
            assert info.compress_type == zipfile.ZIP_STORED, "USDZ must be uncompressed"
            assert not (info.flag_bits & 1), "Encrypted files are unsupported"
            offset = info.header_offset
            name_size, extra_size = struct.unpack_from("<HH", raw, offset + 26)
            data_offset = offset + 30 + name_size + extra_size
            assert data_offset % 64 == 0, f"Misaligned data: {info.filename}"
        embedded = {i.filename for i in infos}

    stage = Usd.Stage.Open(str(path.resolve()))
    assert stage, f"OpenUSD could not parse {path}"
    assert stage.GetDefaultPrim().GetPath().pathString == "/QuestScan"
    assert UsdGeom.GetStageUpAxis(stage) == "Y"
    assert UsdGeom.GetStageMetersPerUnit(stage) == 1
    meshes = []
    references = 0
    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Mesh):
            mesh = UsdGeom.Mesh(prim)
            points = mesh.GetPointsAttr().Get()
            counts = mesh.GetFaceVertexCountsAttr().Get()
            indices = mesh.GetFaceVertexIndicesAttr().Get()
            assert points and counts and indices
            assert all(c == 3 for c in counts)
            assert len(indices) == sum(counts)
            assert all(0 <= i < len(points) for i in indices)
            assert len(mesh.GetNormalsAttr().Get()) == len(points)
            assert mesh.GetNormalsInterpolation() == "vertex"
            material, relationship = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
            assert material and relationship, f"Unbound material: {prim.GetPath()}"
            assert material.ComputeSurfaceSource()[0], "Missing surface shader connection"
            meshes.append({"path": str(prim.GetPath()), "triangles": len(counts), "vertices": len(points)})
        if prim.IsA(UsdShade.Shader):
            shader = UsdShade.Shader(prim)
            if shader.GetIdAttr().Get() == "UsdUVTexture":
                asset = shader.GetInput("file").Get()
                assert asset and asset.path.lstrip("./") in embedded
                assert asset.resolvedPath, f"Texture package path unresolved: {asset.path}"
                assert shader.GetInput("st").GetConnectedSource(), "No texture UV input"
                references += 1
    assert meshes, "No meshes found"
    return {"file": path.name, "entries": len(infos), "meshes": meshes, "texture_references": references,
            "image_decoding_checked": False,
            "checks": ["CRC32", "uncompressed ZIP", "64-byte alignment", "OpenUSD parse", "meters/Y-up", "topology", "normals", "material binding", "texture paths"]}


if __name__ == "__main__":
    directory = Path(sys.argv[1])
    fixtures = sorted(directory.glob("*.usdz"))
    assert fixtures, "No USDZ fixtures found"
    result = [validate(path) for path in fixtures]
    print(json.dumps(result, ensure_ascii=False, indent=2))
