#!/usr/bin/env python3
"""Export YOLOv8-seg crack models to Core ML on macOS."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Export crack_seg models to Core ML")
    parser.add_argument(
        "--input",
        nargs="+",
        default=[
            "crack-recognition/models/crack_seg_n.pt",
            "crack-recognition/models/crack_seg_s.pt",
        ],
    )
    parser.add_argument(
        "--output",
        default="ios/Robo/Resources/Models",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=640,
        help="Base export resolution (kept for compatibility)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    paths = {Path(p).resolve(): Path(p).stem for p in args.input}

    def export_one(path: Path, imgsz: int, output_name: str) -> None:
        if not path.exists():
            print(f"Missing model: {path}")
            raise FileNotFoundError(path)
        command = [
            "yolo",
            "export",
            f"model={path}",
            "format=coreml",
            f"imgsz={imgsz}",
            "nms=True",
            "half=False",
        ]
        print("Running:", " ".join(command))
        subprocess.run(command, check=True)

        package_dir = path.with_suffix(".mlpackage")
        if not package_dir.exists():
            raise FileNotFoundError(f"Export did not create {package_dir}")
        target = output_dir / f"{output_name}.mlpackage"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(package_dir, target)
        print(f"Copied {package_dir} -> {target}")

    for path, stem in paths.items():
        if stem == "crack_seg_n":
            export_one(path, args.imgsz, "crack_seg_n")
        else:
            export_one(path, args.imgsz, stem)

    print("Done. Add the .mlpackage files to the Xcode project resources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
