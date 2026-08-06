# RoboScan Windows 墙面/天面拼图工具

## 需要安装

1. Python 3.11 或 3.12（64 位）
2. OpenCV、NumPy、Pillow、Tifffile

```bat
pip install -r requirements.txt
```

3. COLMAP（可选，用于相机位姿优化）
4. Blender 3.6+（可选，OBJ/MTL 转 USDZ）

## 使用

从 App 导出 `scan-package-*.zip`，然后执行：

```bat
python stitch_wall.py --package scan-package-xxxx.zip --out result
```

输出：

- `result/wall-1.tif`、`wall-2.tif` 等：每面墙/天面的超高分辨率正射拼图
- `result/walls.json`：墙面平面、尺寸和缩放信息
- `result/mesh.ply`：从扫描包解出的 ARKit 网格

## 说明

- 默认输出约 0.1mm/像素；如果内存或时间不够，可加 `--mm-per-pixel 0.2`。
- 无独显电脑使用 CPU 计算，墙数多或照片多时速度会慢，建议按房间/墙分批处理。
- COLMAP 不是第一版必需；App 已保存 ARKit 相机位姿和内参。
- 后续缺陷识别（裂缝/发霉/水渍/污染）会基于这些正射拼图计算面积和长度。
