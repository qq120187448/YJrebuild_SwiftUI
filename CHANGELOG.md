# RoboScan 版本说明（CHANGELOG）

> **约定（用户要求，2026-08-14 起）**：每次版本更新必须同步更新本文件并提交到 GitHub。

## 未发布 · 当前分支 codex/defect-mesh-uv-polyline

### 2026-08-14 · 4D.1A 标定决策阶段（专家批复，只做标定版不改算法）

- 不直接上线 A/C，进入 Ground Truth 标定：新增 CalibrationView（4C 页面"标定"入口），已知长度 500/1000/2000mm × 方向 0/45/90° × 距离 1/2m，照片点选线段两端 → Raw/Snap/Isect 三路长度与误差（mm + %），记入累计日志；
- 固定 CrackSamplePoint 数据模型（pixel/rawWorld/snapWorld/snapDistanceMM/surfaceID/surfaceLocal/uvMeters/trackingState/anchorQuality/reprojection），rawWorld 用于 AR 显示、snapWorld/uv 用于持久化测量（测量与显示分离）；
- Isect 0px 指标改名 roundTripReprojectionError（数学闭环自证，不代表真实精度）；
- 正式吸附门控 snapDistance ≤20mm（取消 150mm 实验帽）；Snap 仅 abs(localZ)≤20mm 才吸附，超限不强吸附；
- existingPlaneGeometry 措辞修正：有潜力备用候选，未达生产 fallback 证据级别，不做 estimated→existing 自动切换；
- 4D 长度算法冻结暂缓：先完成 A/Snap/Isect 真值标定再定主测量路径。

### 2026-08-14 · A' 修复：Isect 路传感器坐标归一化 + 拍照帧投影

- 真机 A' 数据发现 Isect 路异常（reprojection 34079px、UV length 3.234m）：根因一为 sensorPoint 缺"除以 viewportSize 归一化"步骤（displayTransform 输入输出均为归一化 [0,1]，当前直接拿屏幕点逆变换导致射线方向错误）；根因二为 Isect 世界点基于拍照帧相机，却用当前帧 arView.project 投影（用户拍照后移动 0.8~1.8m 必然巨大偏差）；
- 修复：CaptureFrameSpatialContext 增加 viewportSize；sensorPoint 先归一化 viewPoint 再逆变换；A' Isect 路改用拍照帧手动投影（cameraTransform+intrinsics→sensor→displayTransform→屏幕点）；
- Raw/Snap 路不受影响：Raw 分配 100%、reprojection ≤1px、长度 0.769/0.766m；Snap UV length 与 Raw 完全一致；Snap 投影误差随吸附距离增大（6~8.5mm→P95 1.3px；16.5~19.4mm→P95 3.4px），提示吸附距离需作为验收约束。

### 2026-08-14 · A' 三轨对照实验版（专家批准，不直接上生产）

- 专家否决把"15cm 法向吸附"直接作为正式算法；`SurfaceUV4C.map()` 默认退回正式 20mm 容差（snapMaxM=nil），吸附仅实验路径显式传 debugSafetyCap=150mm；
- 新增 AStarDiagnostics（A' Diagnostic Mode）：同一批采样点三轨对照 Raw（20mm 正式分配）/ Snap（法向吸附，cap 150mm）/ Isect（拍照帧相机射线 → RoomPlan Surface 直接求交，方案 C 验证基准）；
- 输出：三路 assignment、snapDistance P50/P90/P95/max、三路重投影（avg/max/P95）、三路 UV length、|Snap−Isect|/Isect 差异%、trackingState、anchor 门控（GOOD ≤5mm / WARNING 5–10mm / UNSAFE >10mm 或 tracking≠normal）；
- 重新引入拍照帧空间上下文（CaptureFrameSpatialContext），仅用于对照路与重投影，不改变主测量路径；
- CaptureFrameSurfaceMapper 的 sensorPoint / nearestSurfaceIntersection 改为 internal 供 A' 复用；
- 措辞严谨化：已确认 ARKit raycast 表面与 RoomPlan Surface 存在 2.6–8.5cm 法向不一致（随拍摄时刻/设备状态变化），是否"时间累积漂移"需固定点分时实验进一步验证；
- 宽度不随 A 验证（误差来源独立：mask 分辨率/EDT/中心线/图像投影），A 先验位置/Surface/UV/长度。

### 2026-08-14 · P4C-Drift 第一阶段：锚点漂移检测/诊断接入（专家批准，只检测不改测量）

- 恢复 AnchorDriftTracker（f3151bc 保留文件）：finishRoomReview 时在墙A（最大墙）/墙B（离A最远）/地面放置 ARAnchor（transform=surface.transform），记录初始位姿；
- 0.5s 轮询 currentFrame.anchors，输出各锚点漂移（平移 mm / 旋转°）、锚点间一致性（Δmax-min）、trackingState；
- 测量完成后在累计日志追加"漂移诊断"行；UI 显示实时漂移文本；
- 本次定位背景：0.74C 出现"world 命中但分配率 0"——未分配点最近 wall local.z=3.7~5cm（超出 2cm 容差），确认 ARKit 实时估计平面与 RoomPlan 表面存在逐实例不同的法向偏差；漂移诊断用于量化该偏差是否随时间/移动变化；
- 测量路径不变（系统 raycast + restoreMesh），无测量行为改动。

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
