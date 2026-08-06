import argparse
import json
import math
import os
import sys
import tempfile
import zipfile

import cv2
import numpy as np
import tifffile


def load_poses(package_dir):
    with open(os.path.join(package_dir, "poses.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def load_mesh(package_dir):
    path = os.path.join(package_dir, "mesh.ply")
    vertices = []
    faces = []
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    idx = 0
    vertex_count = 0
    face_count = 0
    while idx < len(lines):
        line = lines[idx].strip()
        idx += 1
        if line == "end_header":
            break
        parts = line.split()
        if len(parts) == 3 and parts[0] == "element":
            if parts[1] == "vertex":
                vertex_count = int(parts[2])
            elif parts[1] == "face":
                face_count = int(parts[2])
    for _ in range(vertex_count):
        parts = lines[idx].split()
        idx += 1
        vertices.append([float(parts[0]), float(parts[1]), float(parts[2])])
    for _ in range(face_count):
        parts = lines[idx].split()
        idx += 1
        faces.append([int(v) for v in parts[1:]])
    return np.asarray(vertices, dtype=np.float32), faces


def detect_planes(vertices, faces):
    normals = []
    for face in faces:
        if len(face) < 3:
            normals.append(np.zeros(3, dtype=np.float32))
            continue
        v0 = vertices[face[0]]
        v1 = vertices[face[1]]
        v2 = vertices[face[2]]
        normal = np.cross(v1 - v0, v2 - v0)
        length = np.linalg.norm(normal)
        normals.append(normal / length if length > 1e-6 else np.zeros(3, dtype=np.float32))

    groups = {}
    for i, face in enumerate(faces):
        if len(face) < 3:
            continue
        normal = normals[i]
        if np.max(np.abs(normal)) < 0.6:
            continue
        axis = int(np.argmax(np.abs(normal)))
        sign = 1 if normal[axis] >= 0 else -1
        centroid = np.mean(vertices[face], axis=0)
        bucket = int(round(centroid[axis] / 0.1))
        key = (axis, sign, bucket)
        groups.setdefault(key, []).append(i)

    planes = []
    for (axis, sign, _), group_faces in groups.items():
        if len(group_faces) < 3:
            continue
        normal = np.zeros(3, dtype=np.float32)
        normal[axis] = float(sign)
        up = np.array([0.0, 1.0, 0.0])
        if axis == 1:
            u_axis = np.array([1.0, 0.0, 0.0])
            v_axis = np.array([0.0, 0.0, 1.0])
        else:
            u_axis = np.cross(up, normal)
            u_axis /= np.linalg.norm(u_axis)
            v_axis = up

        pts = []
        for face_idx in group_faces:
            for vertex_idx in faces[face_idx]:
                pts.append(vertices[vertex_idx])
        pts = np.asarray(pts, dtype=np.float32)
        us = pts @ u_axis
        vs = pts @ v_axis
        min_u = float(np.min(us))
        max_u = float(np.max(us))
        min_v = float(np.min(vs))
        max_v = float(np.max(vs))
        width = max_u - min_u
        height = max_v - min_v
        if width < 0.05 or height < 0.05:
            continue

        offsets = []
        for face_idx in group_faces:
            centroid = np.mean(vertices[faces[face_idx]], axis=0)
            offsets.append(float(np.dot(centroid, normal)))
        plane_origin = normal * (sum(offsets) / len(offsets))
        origin = plane_origin + u_axis * min_u + v_axis * min_v
        planes.append(
            {
                "faces": group_faces,
                "normal": normal,
                "origin": origin,
                "u_axis": u_axis,
                "v_axis": v_axis,
                "min_u": min_u,
                "min_v": min_v,
                "width": width,
                "height": height,
            }
        )

    planes.sort(key=lambda p: len(p["faces"]), reverse=True)
    return planes


def camera_from_pose(transform_flat, intrinsics_flat):
    values = [float(v) for v in transform_flat]
    transform = np.array(
        [
            [values[0], values[4], values[8], values[12]],
            [values[1], values[5], values[9], values[13]],
            [values[2], values[6], values[10], values[14]],
            [values[3], values[7], values[11], values[15]],
        ],
        dtype=np.float64,
    )
    k = [float(v) for v in intrinsics_flat]
    intrinsics = np.array(
        [[k[0], 0.0, k[6]], [0.0, k[4], k[7]], [0.0, 0.0, 1.0]],
        dtype=np.float64,
    )
    return transform, intrinsics


def project(world, transform, intrinsics):
    camera = np.linalg.inv(transform) @ np.array(
        [world[0], world[1], world[2], 1.0], dtype=np.float64
    )
    if camera[2] <= 0.05:
        return None
    point = intrinsics @ np.array(
        [camera[0] / camera[2], camera[1] / camera[2], 1.0], dtype=np.float64
    )
    return point[0] / point[2], point[1] / point[2]


def wall_corners(plane):
    origin = plane["origin"]
    u = plane["u_axis"] * plane["width"]
    v = plane["v_axis"] * plane["height"]
    return [
        origin,
        origin + u,
        origin + v,
        origin + u + v,
    ]


def stitch_plane(plane, poses, photos_dir, out_w, out_h, mm_per_pixel):
    corners = wall_corners(plane)
    accumulated = np.zeros((out_h, out_w, 3), dtype=np.float64)
    weights = np.zeros((out_h, out_w), dtype=np.float64)
    used = 0

    scored = []
    for pose in poses:
        transform, intrinsics = camera_from_pose(
            pose["cameraTransform"], pose["intrinsics"]
        )
        inside = 0
        for corner in corners:
            point = project(corner, transform, intrinsics)
            if point is None:
                continue
            if 0 <= point[0] < pose["imageWidth"] and 0 <= point[1] < pose["imageHeight"]:
                inside += 1
        if inside >= 2:
            scored.append((inside, pose))

    scored.sort(key=lambda item: item[0], reverse=True)
    for _, pose in scored[:40]:
        path = os.path.join(photos_dir, pose["file"])
        image = cv2.imread(path)
        if image is None:
            continue
        transform, intrinsics = camera_from_pose(
            pose["cameraTransform"], pose["intrinsics"]
        )
        src = np.array(
            [[0, 0], [out_w, 0], [0, out_h], [out_w, out_h]], dtype=np.float32
        )
        dst = []
        valid = True
        for corner in corners:
            point = project(corner, transform, intrinsics)
            if point is None:
                valid = False
                break
            u = (np.dot(corner, plane["u_axis"]) - plane["min_u"]) / plane["width"]
            v = (np.dot(corner, plane["v_axis"]) - plane["min_v"]) / plane["height"]
            dst.append([u * out_w, (1.0 - v) * out_h])
        if not valid or len(dst) != 4:
            continue
        homography = cv2.getPerspectiveTransform(src, np.asarray(dst, dtype=np.float32))
        warped = cv2.warpPerspective(
            image,
            homography,
            (out_w, out_h),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        ).astype(np.float64)
        mask = cv2.warpPerspective(
            np.ones(image.shape[:2], dtype=np.uint8) * 255,
            homography,
            (out_w, out_h),
            flags=cv2.INTER_NEAREST,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        ).astype(np.float64) / 255.0
        accumulated += warped * mask[..., None]
        weights += mask
        used += 1

    if used == 0:
        return None
    valid_mask = weights > 0
    result = np.zeros((out_h, out_w, 3), dtype=np.uint8)
    result[valid_mask] = (accumulated[valid_mask] / weights[valid_mask, None]).astype(
        np.uint8
    )
    result[~valid_mask] = (96, 104, 118)
    return result


def main():
    parser = argparse.ArgumentParser(description="RoboScan wall/ceiling stitcher")
    parser.add_argument("--package", required=True, help="scan-package-*.zip")
    parser.add_argument("--out", default="result", help="output directory")
    parser.add_argument(
        "--mm-per-pixel",
        type=float,
        default=0.5,
        help="target mm per pixel (larger = faster, lower memory)",
    )
    parser.add_argument(
        "--max-dimension",
        type=int,
        default=12000,
        help="cap longest side in pixels to protect 16GB machines",
    )
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    temp = tempfile.mkdtemp(prefix="roboscan_pkg_")
    with zipfile.ZipFile(args.package, "r") as archive:
        archive.extractall(temp)

    poses = load_poses(temp)
    vertices, faces = load_mesh(temp)
    planes = detect_planes(vertices, faces)
    if not planes:
        print("No wall planes found in mesh.ply")
        sys.exit(1)

    photos_dir = os.path.join(temp, "photos")
    walls_info = []
    for index, plane in enumerate(planes, start=1):
        width_px = int(plane["width"] * 1000.0 / args.mm_per_pixel)
        height_px = int(plane["height"] * 1000.0 / args.mm_per_pixel)
        scale = min(
            1.0,
            float(args.max_dimension) / max(width_px, height_px, 1),
        )
        out_w = max(1, int(width_px * scale))
        out_h = max(1, int(height_px * scale))
        effective = plane["width"] * 1000.0 / out_w
        print(
            f"Wall {index}: {plane['width']:.2f}m x {plane['height']:.2f}m -> "
            f"{out_w}x{out_h} px ({effective:.3f} mm/px)"
        )
        result = stitch_plane(plane, poses, photos_dir, out_w, out_h, effective)
        if result is None:
            print(f"  no usable photos, skipped")
            continue
        out_path = os.path.join(args.out, f"wall-{index}.tif")
        tifffile.imwrite(out_path, result, photometric="rgb")
        walls_info.append(
            {
                "file": os.path.basename(out_path),
                "width_m": plane["width"],
                "height_m": plane["height"],
                "mm_per_pixel": effective,
                "width_px": out_w,
                "height_px": out_h,
                "normal": plane["normal"].tolist(),
                "origin": plane["origin"].tolist(),
                "u_axis": plane["u_axis"].tolist(),
                "v_axis": plane["v_axis"].tolist(),
            }
        )
        print(f"  wrote {out_path}")

    with open(os.path.join(args.out, "walls.json"), "w", encoding="utf-8") as f:
        json.dump(walls_info, f, ensure_ascii=False, indent=2)
    shutil_rmtree = __import__("shutil").rmtree
    shutil_rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    main()
