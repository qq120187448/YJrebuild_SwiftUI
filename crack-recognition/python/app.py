import json

import gradio as gr
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from crack_utils import measure_mask_areas, measure_mask_lengths
from inference import (
    ModelManager,
    classify_with_clip,
    classify_with_vit,
    detect_cracks,
    detect_cracks_hairline,
    detect_surface_defects_clip,
    segment_with_mobilesam,
)


MANAGER = ModelManager()


def draw_annotations(image_rgb, boxes, scores, masks, skeleton=None):
    image = Image.fromarray(image_rgb).convert("RGBA")
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    for mask in masks:
        color = (230, 40, 40, 120)
        mask_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        mask_array = np.array(mask_layer)
        mask_array[np.asarray(mask, dtype=bool)] = color
        mask_layer = Image.fromarray(mask_array, "RGBA")
        overlay = Image.alpha_composite(overlay, mask_layer)

    if len(masks) > 0 and skeleton is not None:
        skeleton_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        skel_array = np.array(skeleton_layer)
        skel_array[skeleton] = (255, 210, 0, 255)
        skeleton_layer = Image.fromarray(skel_array, "RGBA")
        overlay = Image.alpha_composite(overlay, skeleton_layer)

    composite = Image.alpha_composite(image, overlay)
    draw = ImageDraw.Draw(composite)
    for i, box in enumerate(boxes):
        x1, y1, x2, y2 = box
        label = f"crack {scores[i]:.2f}" if len(scores) > i else "crack"
        draw.rectangle([x1, y1, x2, y2], outline=(255, 40, 40), width=2)
        draw.text((x1 + 4, max(0.0, y1 - 18)), label, fill=(255, 255, 255))

    return np.array(composite.convert("RGB"))


def build_result_text(boxes, length_result, classification=None, clip_scores=None, mm_per_px=None):
    length_serializable = {
        key: value
        for key, value in length_result.items()
        if key != "skeleton"
    }
    result = {
        "detected_cracks": int(len(boxes)),
        "length": length_serializable,
        "scale_mm_per_px": mm_per_px,
    }
    if classification:
        result["vit_classification"] = classification
    if clip_scores:
        result["clip_zero_shot"] = clip_scores
    return json.dumps(result, ensure_ascii=False, indent=2)


DEFECT_NAMES = {
    "water_stain": "水渍",
    "mold": "发霉",
    "pollution": "污染",
    "crack": "裂缝",
}


def draw_defect_annotations(image_rgb, boxes, scores, labels, masks):
    image = Image.fromarray(image_rgb).convert("RGBA")
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    colors = {
        "water_stain": (30, 120, 220, 120),
        "mold": (140, 40, 180, 120),
        "pollution": (180, 140, 30, 120),
        "crack": (230, 40, 40, 120),
    }

    for idx, mask in enumerate(masks):
        label = "crack" if idx >= len(labels) else list(DEFECT_NAMES.keys())[int(labels[idx])]
        color = colors.get(label, (80, 80, 80, 120))
        mask_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
        mask_array = np.array(mask_layer)
        mask_array[np.asarray(mask, dtype=bool)] = color
        mask_layer = Image.fromarray(mask_array, "RGBA")
        overlay = Image.alpha_composite(overlay, mask_layer)

    composite = Image.alpha_composite(image, overlay)
    draw = ImageDraw.Draw(composite)
    for i, box in enumerate(boxes):
        x1, y1, x2, y2 = box
        name = DEFECT_NAMES.get("crack", "crack")
        if i < len(labels):
            key = list(DEFECT_NAMES.keys())[int(labels[i])]
            name = DEFECT_NAMES[key]
        label = f"{name} {scores[i]:.2f}" if len(scores) > i else name
        draw.rectangle([x1, y1, x2, y2], outline=(255, 255, 255), width=2)
        draw.text((x1 + 4, max(0.0, y1 - 18)), label, fill=(255, 255, 255))

    return np.array(composite.convert("RGB"))


def build_defect_result_text(boxes, labels, area_result, mm_per_px=None):
    detections = []
    for i, box in enumerate(boxes):
        key = list(DEFECT_NAMES.keys())[int(labels[i])] if i < len(labels) else "crack"
        detections.append(
            {
                "id": i + 1,
                "category": key,
                "label": DEFECT_NAMES[key],
                "box": [round(v, 1) for v in box],
            }
        )
    result = {
        "detected_defects": len(detections),
        "detections": detections,
        "area": area_result,
        "scale_mm_per_px": mm_per_px,
    }
    return json.dumps(result, ensure_ascii=False, indent=2)


def analyze(
    image,
    mode,
    defect_target,
    model_size,
    segment_engine,
    conf,
    iou,
    tile_size,
    tile_overlap,
    min_area,
    skeleton_mode,
    top_n,
    spur_len,
    min_component_len,
    scale_mode,
    mm_per_px,
    classify_mode,
):
    if image is None:
        return None, "请先上传或拍摄一张墙面照片。"

    image_rgb = np.asarray(image, dtype=np.uint8)

    if defect_target == "surface":
        boxes, scores, labels, _ = detect_surface_defects_clip(
            image_rgb,
            MANAGER,
            threshold=0.3,
        )
        masks = segment_with_mobilesam(image_rgb, boxes, MANAGER)
        if scale_mode == "known":
            scale = float(mm_per_px)
        else:
            scale = None
        area_result = measure_mask_areas(masks, image_rgb.shape[:2], mm_per_px=scale)
        annotated = draw_defect_annotations(image_rgb, boxes, scores, labels, masks)
        text = build_defect_result_text(boxes, labels, area_result, scale)
        return annotated, text

    if mode == "发丝级":
        boxes, scores, yolo_masks = detect_cracks_hairline(
            image_rgb,
            MANAGER,
            model_size=model_size,
            conf=conf,
            iou=iou,
            tile_size=int(tile_size),
            overlap=int(tile_overlap),
        )
    else:
        boxes, scores, yolo_masks = detect_cracks(
            image_rgb, MANAGER, model_size=model_size, conf=conf, iou=iou
        )

    if segment_engine == "MobileSAM":
        masks = segment_with_mobilesam(image_rgb, boxes, MANAGER)
    else:
        masks = yolo_masks

    if scale_mode == "known":
        scale = float(mm_per_px)
    else:
        scale = None

    length_result = measure_mask_lengths(
        masks,
        image_rgb.shape[:2],
        mm_per_px=scale,
        mode=skeleton_mode,
        top_n=int(top_n),
        min_spur_len=int(spur_len),
        min_component_len=int(min_component_len),
    )

    classification = None
    clip_scores = None
    if classify_mode == "ViT墙面缺陷分类":
        classification = classify_with_vit(image_rgb, MANAGER)
    elif classify_mode == "CLIP零样本分类":
        clip_scores = classify_with_clip(image_rgb, MANAGER)

    annotated = draw_annotations(
        image_rgb,
        boxes,
        scores,
        masks,
        skeleton=length_result.get("skeleton"),
    )
    text = build_result_text(boxes, length_result, classification, clip_scores, scale)
    return annotated, text


with gr.Blocks(title="墙面缺陷识别与裂缝长度测量") as demo:
    gr.Markdown("## 墙面缺陷识别与裂缝长度测量")
    with gr.Row():
        with gr.Column():
            image_input = gr.Image(
                label="墙面照片",
                type="numpy",
                sources=["upload", "webcam"],
                image_mode="RGB",
            )
            mode = gr.Radio(
                ["常规", "发丝级"],
                value="发丝级",
                label="识别模式",
                info="发丝级使用高分辨率分块推理，速度较慢",
            )
            defect_target = gr.Radio(
                [("裂缝", "crack"), ("水渍/发霉/污染", "surface")],
                value="crack",
                label="识别目标",
            )
            model_size = gr.Dropdown(
                ["n", "s"],
                value="s",
                label="YOLOv8 裂缝模型",
                info="n 更快，s 更准",
            )
            segment_engine = gr.Radio(
                ["YOLO 分割", "MobileSAM"],
                value="YOLO 分割",
                label="裂缝精细分割引擎",
            )
            conf = gr.Slider(0.1, 0.9, value=0.15, step=0.05, label="检测置信度")
            iou = gr.Slider(0.1, 0.9, value=0.5, step=0.05, label="IoU")
            tile_size = gr.Slider(512, 1600, value=1024, step=64, label="发丝级分块尺寸")
            tile_overlap = gr.Slider(64, 512, value=192, step=32, label="发丝级分块重叠")
            min_area = gr.Slider(10, 500, value=50, step=10, label="最小掩码面积(px)")
            skeleton_mode = gr.Radio(
                ["all", "main"],
                value="main",
                label="骨架统计模式",
                info="main 会修剪短分支并只保留最长裂缝",
            )
            top_n = gr.Slider(1, 5, value=3, step=1, label="保留主裂缝数量")
            spur_len = gr.Slider(10, 200, value=30, step=5, label="短分支修剪长度(px)")
            min_component_len = gr.Slider(20, 500, value=80, step=10, label="最短骨架保留长度(px)")
            scale_mode = gr.Radio(
                ["pixel", "known"],
                value="pixel",
                label="长度单位",
                info="pixel 只输出像素长度；known 输入每像素对应毫米数",
            )
            mm_per_px = gr.Number(value=0.0, label="每像素毫米数(mm/px)")
            classify_mode = gr.Dropdown(
                ["不分类", "ViT墙面缺陷分类", "CLIP零样本分类"],
                value="不分类",
                label="缺陷分类",
            )
            run_button = gr.Button("开始分析", variant="primary")
        with gr.Column():
            annotated_output = gr.Image(label="标注结果", type="numpy")
            result_output = gr.Textbox(label="结果 JSON", lines=20)

    run_button.click(
        analyze,
        inputs=[
            image_input,
            mode,
            defect_target,
            model_size,
            segment_engine,
            conf,
            iou,
            tile_size,
            tile_overlap,
            min_area,
            skeleton_mode,
            top_n,
            spur_len,
            min_component_len,
            scale_mode,
            mm_per_px,
            classify_mode,
        ],
        outputs=[annotated_output, result_output],
    )


if __name__ == "__main__":
    demo.launch(server_name="127.0.0.1", server_port=7860, inbrowser=True, show_error=True)
