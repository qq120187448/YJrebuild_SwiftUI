# 墙面裂缝识别资源

本目录用于把已验证的墙面裂缝识别方案接入 RoboScan iOS App，包含模型权重、测试照片、参考推理代码和参考结果。

## 目录

- `models/`：裂缝检测/分割模型权重
- `data/phone_test/`：17 张手机拍摄测试照片
- `data/results/`：`conf=0.15`、主裂缝模式下的参考输出
- `data/samples/`：公开 DeepCrack 样例与标注效果图
- `python/`：Python 参考推理与长度算法

## 模型

- `crack_seg_n.pt`：YOLOv8n-seg，裂缝检测 + 分割，约 6.5MB，速度快
- `crack_seg_s.pt`：YOLOv8s-seg，精度更高，约 22.8MB
- `mobile_sam.pt`：MobileSAM，用于候选框精细分割，约 38.8MB

权重来源：

- `OpenSistemas/YOLOv8-crack-seg`（Hugging Face）
- `dhkim2810/MobileSAM`（Hugging Face）

商用前请核对各仓库的许可证和权重条款。

## 参考算法

1. YOLOv8-seg 检测裂缝并输出掩码。
2. 发丝级模式：把图片切成分块并带重叠推理，再拼接掩码。
3. 主裂缝模式：掩码细化成骨架，修剪短分支，只保留最长 1–3 条主裂缝。
4. 长度计算：沿 8 邻域骨架累加像素长度，水平/垂直为 1px，斜对角为 sqrt(2)px。
5. 毫米换算：需要 ARKit 墙平面与相机内参，把像素长度反投影到墙面。

## 参考结果

测试参数：发丝级 + YOLOv8s + YOLO 分割 + 主裂缝模式 + `conf=0.15`。

结果汇总见 `data/results/summary.csv`，每张照片包含标注图和 JSON。
