# iOS 集成提示词

把下面的提示词复制到本项目文件夹的另一个对话中，即可开始集成：

```text
在本项目文件夹中完成“墙面裂缝识别”功能的 iOS 集成，把现有 crack-recognition 资源接入 RoboScan 工程。

现有资源：
- crack-recognition/models/crack_seg_n.pt：YOLOv8n-seg 裂缝检测+分割权重
- crack-recognition/models/crack_seg_s.pt：YOLOv8s-seg 裂缝检测+分割权重
- crack-recognition/models/mobile_sam.pt：MobileSAM 精细分割权重
- crack-recognition/python/inference.py：Python 推理参考
- crack-recognition/python/crack_utils.py：骨架化与长度算法参考
- crack-recognition/data/phone_test/：17 张真机测试照片
- crack-recognition/data/results/：conf=0.15、主裂缝模式的参考输出

要求：
1. 在 ios/Robo 现有 SwiftUI 工程中新增“墙面裂缝识别”功能，不破坏现有扫描、导出等功能。
2. 将 crack_seg_n.pt 和 crack_seg_s.pt 导出为 Core ML（.mlmodel/.mlpackage）并放入 iOS 工程资源；如果当前机器无法导出，给出在 Mac/Xcode 上执行的导出命令和依赖清单。
3. 实现拍照或 ARKit 取帧 -> YOLOv8-seg 检测裂缝并输出掩码；提供“常规/发丝级”模式，发丝级使用高分辨率分块推理。
4. 实现裂缝骨架化与长度测量：掩码细化成单像素骨架，沿 8 邻域累加长度；用 ARKit 墙面平面和相机内参把像素长度换算为毫米，输出每条主裂缝长度和总长。
5. 提供主裂缝模式：修剪短分支，只保留最长 1-3 条主裂缝，避免网状骨架。
6. 界面使用中文，提供照片选择/拍照、长度结果、标注预览，并把以下参数做成可调整控件，默认值和取值范围如下：
   - 识别模式：常规 / 发丝级，默认发丝级
   - YOLO 模型：n / s，默认 s
   - 分割引擎：YOLO 分割 / MobileSAM，默认 YOLO 分割
   - 检测置信度：0.1-0.9，默认 0.15
   - IoU：0.1-0.9，默认 0.5
   - 发丝级分块尺寸：512-1600，默认 1024
   - 发丝级分块重叠：64-512，默认 192
   - 最小掩码面积：10-500，默认 50
   - 骨架统计模式：all / main，默认 main
   - 保留主裂缝数量：1-5，默认 3
   - 短分支修剪长度：10-200，默认 30
   - 最短骨架保留长度：20-500，默认 80
   - 长度单位：pixel / known，默认 pixel
   - 每像素毫米数：可输入，默认 0
   参数应像 HTTP 查询参数一样带默认值和取值范围，界面可随时修改；如可行，也应支持通过设置页、配置文件或 URL Scheme 传入。
7. MobileSAM 作为可选精细分割，不能实时时降级为“拍照后处理”。
8. 遵循项目现有架构和代码风格，不重构无关模块；补上相机权限、模型文件引用、构建配置。
9. 验证：至少完成 iOS 模拟器/真机构建；如无真机，说明待真机验证项。
10. 输出修改文件清单、核心实现说明、模型导出命令、测试结果和剩余风险。
```
