# RoboScan 版本说明（CHANGELOG）

> **约定（用户要求，2026-08-14 起）**：每次版本更新必须同步更新本文件并提交到 GitHub。

## 未发布 · 当前分支 codex/defect-mesh-uv-polyline

### 2026-08-14 · 0.74C 累计日志补全 4C 完整诊断

- 累计日志与"复制报告"由精简版（仅长度/宽度）改为完整版：含表面总数（wall/floor/other）、每条裂缝采样点/world 命中/分配率、未分配候选 local/planeDistance/insideX/Y/Z、20/30/40/50mm 阈值分配率、estimated vs existing raycast 对比；
- 目的：真机出现"world 命中但分配率 0"时，可直接从日志定量判断世界点与 RoomPlan 表面的偏移方向与量级，落实专家"0% 分配单独诊断"要求；
- UI 报告区仍显示精简版，不占屏幕。

### 2026-08-14 · 定稿 0.74C（fa14c9e 方案为 4C 正式基线）

- 版本号更新为 0.74C（project.yml MARKETING_VERSION）；
- 4C 测量路径从自研帧锁定映射（CaptureFrameSurfaceMapper）改回 Apple 系统 ARView.raycast（fa14c9e 真机已验证：命中/分配 100%、红线正确）；
- stopScan 恢复 restoreMesh()（无 .resetTracking，保持 RoomPlan 世界原点；恢复 mesh 供系统 raycast 命中）；
- 保留 4D.1 折线优化（SwiftSimplify ≤6 段）、宽度全量统计、dense/simplified 长度一致性、y 镜像修复；
- 实测对照：fa14c9e 原版（系统 raycast + restoreMesh）命中 100% 分配 100%；去掉 restoreMesh 后 ARView.raycast 无 mesh 可命中，分配率 0；b453b35 帧锁定映射因 y 镜像出现长直线。确认系统 raycast + restoreMesh 为正确底座。

### 2026-08-14 · 4C 反投影 y 镜像修复（长直线根因）

- 修复 CaptureFrameSurfaceMapper 与 CrackRaycast4B.measureFrameLocked 两处自研反投影的 y 分量未翻转问题：`localDirection.y` 由 `(sensorY - cy) / fy` 改为 `-(sensorY - cy) / fy`（传感器坐标 y 向下、相机坐标 y 向上，标准针孔反投影需翻转）；
- 修复前：射线垂直方向镜像，画面中线上方点打到下方、下方点打到上方；裂缝偏离画面水平中线越远错位越大，导致"红线变成长直线、交点聚在相机旁/背后"、裂缝长度异常偏大（实测 2.119m vs 真实 ~0.77m）；
- 修复后：CapturedRoom 表面与 ARSession 相机帧正确对应（同一空间），命中率不受影响（原 100% 系交点仍在表面容差内）。

### 2026-08-14 · 4D.1 折线优化（SwiftSimplify + 宽度全量统计）

- 折线简化改用 SwiftSimplify（MIT，Douglas-Peucker），新管线不再调用自研 DP；落实专家合规原则（Zhang-Suen / EDT / DP 不手写，主 App 旧骨架管线原样保留）；
- 每条裂缝折线上限由 ≤7 段（8 点）改为 ≤6 段（≤7 点），对齐 PC max_pts=7；
- 新增长度一致性诊断：dense（简化前）/ simplified（简化后）总像素长度与 loss%；
- 宽度扩展为全量统计：min/avg/max、P10/P50/P90、10 段剖面、widthQuality（<2px 低分辨率 / 2–4px 受限 / >4px 正常）；
- 4C/4D.1 报告 UI 仍只显示平均/最大宽度，全量宽度统计与长度一致性进 4A 统计与 4D 诊断日志。

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
