# YOLOv8-seg CoreML 导出说明

当前开发机是 Windows，无法生成 iOS Core ML 模型。请在 macOS 上执行以下步骤，然后把 `.mlpackage` 放入 `ios/Robo/Resources/Models/`。

## 依赖清单

- macOS 13 或更高版本
- Python 3.10+
- `torch`、`ultralytics`、`coremltools`
- 建议使用虚拟环境：

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install "ultralytics>=8.2" coremltools torch torchvision
```

## 导出命令

在仓库根目录执行：

```bash
python tools/coreml_export/export_yolo_seg.py
```

脚本会执行：

```bash
python -m ultralytics export \
  model=crack-recognition/models/crack_seg_n.pt \
  format=coreml imgsz=640 nms=True half=False

python -m ultralytics export \
  model=crack-recognition/models/crack_seg_s.pt \
  format=coreml imgsz=640 nms=True half=False
```

然后把生成的 `crack_seg_n.mlpackage`、`crack_seg_s.mlpackage` 拷贝到 `ios/Robo/Resources/Models/`，重新生成 Xcode 工程并编译：

```bash
cd ios
xcodegen generate
```

## 预期 CoreML 输出

`YOLOv8-seg` 导出后输出两个 MultiArray：

- 检测头：`1 x (4 + 类别数 + 32) x 8400`
- 掩码原型：`1 x 32 x 160 x 160`

App 内 `CrackYOLODecoder` 会按此格式解码，先做 NMS，再用每个目标的 32 个掩码系数与原型张量相乘并 `sigmoid`，得到裂缝掩码。
