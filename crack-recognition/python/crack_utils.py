import math

import numpy as np
from skimage.measure import label
from skimage.morphology import opening, remove_small_objects, skeletonize


def clean_mask(mask: np.ndarray, min_area: int = 50) -> np.ndarray:
    binary = mask > 0
    binary = opening(binary, footprint=np.ones((3, 3)))
    binary = remove_small_objects(binary, max_size=max(10, min_area))
    return binary


def skeleton_of_masks(masks, shape, min_area: int = 50) -> np.ndarray:
    merged = np.zeros(shape, dtype=bool)
    for mask in masks:
        merged |= clean_mask(np.asarray(mask), min_area)
    return skeletonize(merged)


def _neighbors8(point, points):
    y, x = point
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            neighbor = (y + dy, x + dx)
            if neighbor in points:
                yield neighbor


def _graph_length(points) -> float:
    length = 0.0
    for point in points:
        for neighbor in _neighbors8(point, points):
            length += 1.0 if point[0] == neighbor[0] or point[1] == neighbor[1] else math.sqrt(2.0)
    return length / 2.0


def _trace_spur(start, points, degrees, limit):
    previous = None
    current = start
    distance = 0.0
    path = [start]
    while True:
        neighbors = [n for n in _neighbors8(current, points) if n != previous]
        if not neighbors:
            return path
        nxt = neighbors[0]
        distance += math.dist(current, nxt)
        if distance > limit:
            return []
        path.append(nxt)
        if degrees.get(nxt, 0) != 2:
            if degrees.get(nxt, 0) == 1:
                return path
            return path[:-1]
        previous, current = current, nxt


def prune_skeleton(skeleton: np.ndarray, min_spur_len: int = 30) -> np.ndarray:
    labels = label(skeleton, connectivity=2)
    pruned = np.zeros_like(skeleton, dtype=bool)

    for component_id in range(1, int(labels.max()) + 1):
        component = labels == component_id
        ys, xs = np.nonzero(component)
        points = set(zip(ys.tolist(), xs.tolist()))
        if _graph_length(points) <= min_spur_len:
            continue

        for _ in range(30):
            degrees = {p: sum(1 for _ in _neighbors8(p, points)) for p in points}
            endpoint = next((p for p, degree in degrees.items() if degree == 1), None)
            if endpoint is None:
                break
            path = _trace_spur(endpoint, points, degrees, min_spur_len)
            if not path:
                break
            for point in path:
                points.discard(point)

        for point in points:
            pruned[point[0], point[1]] = True

    return pruned


def measure_mask_lengths(
    masks,
    shape,
    mm_per_px: float | None = None,
    mode: str = "all",
    top_n: int = 3,
    min_spur_len: int = 30,
    min_component_len: int = 50,
):
    merged = np.zeros(shape, dtype=bool)
    for mask in masks:
        merged |= clean_mask(np.asarray(mask), min_area=50)
    skeleton = skeletonize(merged)
    if mode == "main":
        skeleton = prune_skeleton(skeleton, min_spur_len)

    labels = label(skeleton, connectivity=2)

    total_pixel = 0.0
    components = []
    for component_id in range(1, int(labels.max()) + 1):
        component = labels == component_id
        ys, xs = np.nonzero(component)
        if ys.size == 0:
            continue
        points = set(zip(ys.tolist(), xs.tolist()))
        length_px = 0.0
        for y, x in zip(ys.tolist(), xs.tolist()):
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dy == 0 and dx == 0:
                        continue
                    neighbor = (y + dy, x + dx)
                    if neighbor in points:
                        length_px += 1.0 if dy == 0 or dx == 0 else math.sqrt(2.0)
        length_px /= 2.0
        total_pixel += length_px
        components.append(
            {
                "id": component_id,
                "pixel_length": round(length_px, 2),
                "mm_length": round(length_px * mm_per_px, 2) if mm_per_px else None,
            }
        )

    raw_component_count = len(components)
    if mode == "main":
        components = [
            item
            for item in components
            if item["pixel_length"] >= min_component_len
        ]
        components.sort(key=lambda item: item["pixel_length"], reverse=True)
        components = components[:top_n]
        kept_ids = {item["id"] for item in components}
        display_skeleton = np.isin(labels, list(kept_ids))
        total_pixel = sum(item["pixel_length"] for item in components)
    else:
        display_skeleton = skeleton
        total_pixel = sum(item["pixel_length"] for item in components)

    return {
        "component_count": len(components),
        "raw_component_count": raw_component_count,
        "total_pixel_length": round(total_pixel, 2),
        "total_mm_length": round(total_pixel * mm_per_px, 2) if mm_per_px else None,
        "longest_pixel_length": round(
            max((item["pixel_length"] for item in components), default=0.0), 2
        ),
        "longest_mm_length": round(
            max((item["pixel_length"] for item in components), default=0.0)
            * mm_per_px,
            2,
        )
        if mm_per_px
        else None,
        "components": components,
        "skeleton": display_skeleton,
    }


def measure_mask_areas(masks, shape, mm_per_px: float | None = None):
    merged = np.zeros(shape, dtype=bool)
    for mask in masks:
        merged |= clean_mask(np.asarray(mask), min_area=20)
    labels = label(merged, connectivity=2)
    pixel_area = int(merged.sum())
    mm_area = pixel_area * (mm_per_px**2) if mm_per_px else None
    components = []
    for component_id in range(1, int(labels.max()) + 1):
        area_px = int((labels == component_id).sum())
        components.append(
            {
                "id": component_id,
                "pixel_area": area_px,
                "mm2_area": round(area_px * (mm_per_px**2), 2) if mm_per_px else None,
            }
        )
    return {
        "component_count": len(components),
        "total_pixel_area": pixel_area,
        "total_mm2_area": round(mm_area, 2) if mm_area is not None else None,
        "components": components,
    }
