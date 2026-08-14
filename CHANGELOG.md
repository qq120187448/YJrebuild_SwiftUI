# RoboScan 版本说明（CHANGELOG）

> **约定（用户要求，2026-08-14 起）**：每次版本更新必须同步更新本文件并提交到 GitHub。

## 未发布 · 当前分支 codex/defect-mesh-uv

### 2026-08-14 · 回退 4C 取景 UI，恢复 AR 红线投影（bd20bae 后）

- 4C 页面回退到 b453b35 布局（取景恢复原比例、下半部原排版），保留 4D.1 算法与官方 RoomCaptureView 扫描 UI；
- 锚点漂移诊断暂停接线（AnchorDriftTracker 文件保留，待红线恢复后按专家分阶段再接入）；
- 原因：全宽正方形取景 + ready 阶段小窗改造后 AR 红线投影不可见，回退消除 UI 变量，便于继续定位。

### 2026-08-14 · 取消 RoomPlan 在线小窗，恢复 AR 红线投影（9a97e55 后修复）

- 移除拍照阶段右下角 RoomCaptureView 小窗与“RoomPlan 在线”标签：该实现会在 ready 时重建视图并再次 `captureSession.run`，等于重开 RoomPlan 会话，导致 ARView.raycast 红线投影失效；
- 保留：全宽正方形取景、下半部重排、锚点漂移诊断（只检测不改测量）。

### 2026-08-14 · 4C 漂移诊断 + 取景 UI（ea689e0, 9a97e55）

- 取景改全宽严格正方形（左右贴屏幕边无空隙、顶部贴安全区上缘/灵动岛下方），下半部重新排版；
- 拍照阶段右下角常驻官方 RoomPlan 模型小窗 + “RoomPlan 在线”标签（复用同一 RoomCaptureView 结果视图，官方模型不自建）；
- 新增 Anchor 漂移诊断：墙 A / 墙 B / 地面 3 个 ARAnchor，0.5s 轮询输出漂移（平移 mm / 旋转°）、一致性、trackingState；**只检测、不改测量**；
- 4D.1：每条裂缝折线强制 ≤7 段；4C 长度改按简化折线 UV 计算；宽度最宽/平均；清理骨架/BFS/距离场残留（b453b35）。

### 2026-08-13 · 4C 扫描 UI 与 A/B 实验（c76cc93 → fa14c9e）

- 扫描 UI 切回官方 RoomCaptureView（原生引导 + 底部 3D 模型），常驻 ARView 不销毁，拍照不再黑屏；
- RoomPlan UI A/B/C/D 四组真机实验：面层/网格与共享 ARSession、预配置 Mesh 无关；
- 4C 报告补 Capture→Raycast 延迟与未分配诊断（05189ee）。

## v0.66（2026-08-12 · 基线 9b3ed08）

- ARMesh 交点 + Surface UV 测量（P0/P1）；
- 基座方案冻结：Apple-first / OSS-second / custom-last，四基座选型与核验完成；
- 阶段 4A（像素闭环）/ 4B（Pixel→ARWorld）真机通过。

## v0.65（2026-08-11）

- 全幅分析 + 边缘过滤修复（按检测框判断，8720507）+ 高分辨率重拍。

## 更早版本

- 详见本机 `版本说明汇总.md`（未提交 git）与 `墙面缺陷扫描技术说明.md`。
