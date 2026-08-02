# RoboScan 工程量扫描（v0.1）

基于 Robo 精简改造的 iOS LiDAR 房间扫描应用，只保留房间扫描、历史记录和工程量清单导出，不连接任何后端。

## 功能

- RoomPlan LiDAR 房间扫描
- 中文界面
- 自动生成工程量清单（Excel .xlsx）
- USDZ 模型导出与 3D 预览
- 所有数据仅保存在本机

## 本地编译

```bash
brew install xcodegen
cd ios
xcodegen generate
open RoboScan.xcodeproj
```

在 Xcode 中把 `DEVELOPMENT_TEAM` 改成自己的 Apple 团队，连接带 LiDAR 的 iPhone 后运行。

## 工程量清单

扫描完成后可导出 `工程量清单.xlsx`，表头包含房间名称、建筑面积、层高、房间体积，正文包含：

- 水泥砂浆楼地面、墙面一般抹灰（扣除门窗洞口）、天棚抹灰、踢脚线
- 每樘门、每扇窗的尺寸和洞口面积，以及合计
- 洁具和家具逐个明细及分类数量
- 梁、板、柱目前为占位，需要后续点云分割计算
