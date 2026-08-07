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
    parser.add_argument("--imgsz", type=int, default=640)
    args = parser.parse_args()

    output_dir = Path(args.output).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    for model_path in args.input:
        path = Path(model_path).resolve()
        if not path.exists():
            print(f"Missing model: {path}")
            return 1
        command = [
            sys.executable,
            "-m",
            "ultralytics",
            "export",
            f"model={path}",
            "format=coreml",
            f"imgsz={args.imgsz}",
            "nms=True",
            "half=False",
        ]
        print("Running:", " ".join(command))
        subprocess.run(command, check=True)

        package_dir = path.with_suffix(".mlpackage")
        if not package_dir.exists():
            print(f"Export did not create {package_dir}")
            return 1
        target = output_dir / package_dir.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(package_dir, target)
        print(f"Copied {package_dir} -> {target}")

    print("Done. Add the .mlpackage files to the Xcode project resources.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
