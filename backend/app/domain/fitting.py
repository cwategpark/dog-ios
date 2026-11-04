"""Deterministic wearing placement migrated from the published fitting workflow."""
import math
import re
import json
from importlib.resources import files
from urllib.parse import urlsplit

from app.providers.errors import DomainValidationError

AXES = {"+X": [1, 0, 0], "-X": [-1, 0, 0], "+Y": [0, 1, 0], "-Y": [0, -1, 0], "+Z": [0, 0, 1], "-Z": [0, 0, -1]}
MODES = {"harness": ("chest_back", "shoulder", ("harness", "胸背带", "胸背")),
         "collar": ("neck", "neck_base", ("collar", "项圈")),
         "vest": ("torso", "shoulder", ("vest", "jacket", "宠物衣", "马甲", "外套"))}


def calibrated_cat_harness(pet_asset_url: str, garment_asset_url: str) -> dict:
    """Only use with the archived, calibrated cat-static/harness-shoulder-local pair."""
    resources = files("app.domain").joinpath("data")
    landmarks = json.loads(resources.joinpath("cat-landmarks.json").read_text(encoding="utf-8"))
    profile = json.loads(resources.joinpath("harness-profile.json").read_text(encoding="utf-8"))
    return {"pet_id": "toon-cat", "pet_asset_url": pet_asset_url, "garment_asset_url": garment_asset_url,
            "wearing": {"mode": "harness"}, "landmarks": landmarks["points"], "garment_profile": profile}


def _vector(value, length, limit):
    if not isinstance(value, list) or len(value) != length or any(type(number) not in (int, float) or not math.isfinite(number) or abs(number) > limit for number in value):
        raise DomainValidationError("Invalid fitting coordinates.")
    return value


def validate_transform(transform):
    if not isinstance(transform, dict):
        raise DomainValidationError("A calibrated transform is required.")
    position = _vector(transform.get("position"), 3, 2)
    quaternion = _vector(transform.get("quaternion"), 4, 1.1)
    scale = _vector(transform.get("scale"), 3, 3)
    norm = math.sqrt(sum(number * number for number in quaternion))
    if not 0.9 <= norm <= 1.1 or any(number < 0.05 for number in scale):
        raise DomainValidationError("Invalid fitting rotation or scale.")
    return {"position": position, "quaternion": [number / norm for number in quaternion], "scale": scale}


def _asset_url(value):
    parsed = urlsplit(str(value or ""))
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise DomainValidationError("Configured fitting assets require HTTPS URLs.")
    return value


def _sub(a, b):
    return [a[index] - b[index] for index in range(3)]


def _length(vector):
    return math.sqrt(sum(number * number for number in vector))


def _norm(vector):
    length = _length(vector)
    if length < 0.0001:
        raise DomainValidationError("Degenerate body landmarks.")
    return [number / length for number in vector]


def _cross(a, b):
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]


def _quaternion(matrix):
    trace = sum(matrix[index][index] for index in range(3))
    if trace > 0:
        size = math.sqrt(trace + 1) * 2
        return [(matrix[2][1]-matrix[1][2])/size, (matrix[0][2]-matrix[2][0])/size, (matrix[1][0]-matrix[0][1])/size, size/4]
    i = max(range(3), key=lambda index: matrix[index][index])
    j, k = (i+1) % 3, (i+2) % 3
    size = math.sqrt(1 + matrix[i][i] - matrix[j][j] - matrix[k][k]) * 2
    q = [0, 0, 0, 0]
    q[i], q[j], q[k], q[3] = size/4, (matrix[i][j]+matrix[j][i])/size, (matrix[i][k]+matrix[k][i])/size, (matrix[k][j]-matrix[j][k])/size
    return q


def fitting_manifest(product: dict, pet_id: str = "toon-cat") -> dict:
    config = product.get("fitting")
    if not isinstance(config, dict) or config.get("pet_id") != pet_id:
        raise DomainValidationError("This product has no calibrated asset for the selected pet.")
    pet_url, garment_url = _asset_url(config.get("pet_asset_url")), _asset_url(config.get("garment_asset_url"))
    manual = config.get("manual") or {}
    if manual.get("enabled") is True:
        fingerprint = config.get("asset_fingerprint")
        if not isinstance(fingerprint, str) or not re.fullmatch(r"[a-f0-9]{64}", fingerprint) or manual.get("asset_fingerprint") != fingerprint:
            raise DomainValidationError("The saved calibration belongs to a different asset revision.")
        return {"schema_version": 5, "pet_id": pet_id, "product_id": product["id"],
                "pet_asset_url": pet_url, "garment_asset_url": garment_url,
                "preview_only": True, "coordinate_space": "gltf-y-up", "source": "manual",
                "manual_revision": int(manual.get("revision", 0)),
                "garment_transform": validate_transform(manual.get("transform"))}
    annotation = config.get("wearing") or {}
    mode = annotation.get("mode", "auto")
    if mode == "auto":
        matches = []
        for text in (str(product.get("title", "")), " ".join(product.get("categories", []))):
            matches = [kind for kind, (_, _, terms) in MODES.items() if any(re.search(r"\b"+re.escape(term)+r"\b", text, re.I) if term.isascii() else term in text for term in terms)]
            if matches:
                break
        if len(matches) != 1:
            raise DomainValidationError("The wearing method is ambiguous; add a merchant annotation.")
        mode = matches[0]
    if mode not in MODES:
        raise DomainValidationError("Unsupported wearing method.")
    region, default_anchor, _ = MODES[mode]
    anchor = annotation.get("anchor", "auto")
    anchor = default_anchor if anchor == "auto" else anchor
    allowed = {"harness": ("shoulder",), "collar": ("neck_base",), "vest": ("shoulder", "mid_back")}
    if anchor not in allowed[mode]:
        raise DomainValidationError("The wearing method conflicts with the body anchor.")
    profile, points = config.get("garment_profile", {}), config.get("landmarks", {})
    if profile.get("wear_region") != region or profile.get("anchor") != anchor:
        raise DomainValidationError("This garment asset was calibrated for another wearing region.")
    for key in (anchor, "neck_base", "mid_back", "front_left", "front_right"):
        _vector(points.get(key), 3, 10)
    forward = _norm(_sub(points["neck_base"], points["mid_back"]))
    right = _norm(_cross([0, 1, 0], forward))
    up = _norm(_cross(forward, right))
    basis = [[right[index], up[index], forward[index]] for index in range(3)]
    forward_axis = annotation.get("forward_axis") or profile.get("forward_axis")
    up_axis = annotation.get("up_axis") or profile.get("up_axis")
    if forward_axis not in AXES or up_axis not in AXES:
        raise DomainValidationError("Annotate the model forward and up axes.")
    f, u = AXES[forward_axis], AXES[up_axis]
    if sum(a*b for a, b in zip(f, u)) != 0:
        raise DomainValidationError("Model axes must be perpendicular.")
    r = _cross(u, f)
    model = [[r[index], u[index], f[index]] for index in range(3)]
    rotation = [[sum(basis[i][k]*model[j][k] for k in range(3)) for j in range(3)] for i in range(3)]
    try:
        width = _length(_sub(points["front_left"], points["front_right"])) / float(profile["reference_chest_width"])
        span = _length(_sub(points["neck_base"], points["mid_back"])) / float(profile["reference_torso_span"])
    except (KeyError, ZeroDivisionError, ValueError, TypeError) as error:
        raise DomainValidationError("Missing calibrated garment dimensions.") from error
    if any(not math.isfinite(number) or not 0.8 <= number <= 1.2 for number in (width, span)):
        raise DomainValidationError("The pet is outside this calibrated garment's fitting range.")
    offset = _vector(annotation.get("offset", [0, 0, 0]), 3, 0.2)
    position = [points[anchor][i]+sum(basis[i][j]*offset[j] for j in range(3)) for i in range(3)]
    return {"schema_version": 3, "pet_id": pet_id, "product_id": product["id"], "source": "rules",
            "pet_asset_url": pet_url, "garment_asset_url": garment_url, "coordinate_space": "gltf-y-up",
            "preview_only": True, "wear_region": region, "anchor": anchor,
            "garment_transform": {"position": position, "quaternion": _quaternion(rotation),
                                  "scale": [span if abs(f[i]) == 1 else width for i in range(3)]}}
