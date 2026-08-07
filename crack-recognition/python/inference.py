import json
import os
import sys
from pathlib import Path

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

import cv2
import numpy as np
import torch
from PIL import Image
from skimage.measure import label

BASE_DIR = Path(__file__).resolve().parent
VENDOR_DIR = BASE_DIR / "vendor" / "MobileSAM"
MODELS_DIR = BASE_DIR / "models"
HOUSE_FAULT_DIR = MODELS_DIR / "house_fault"

if str(VENDOR_DIR) not in sys.path:
    sys.path.insert(0, str(VENDOR_DIR))

CLIP_PROMPTS = {
    "water_stain": [
        "a water stain on a wall",
        "water damage mark on a wall",
        "damp patch on a wall",
    ],
    "mold": [
        "mold growth on a wall",
        "black mold on a wall",
        "mildew on a wall",
    ],
    "pollution": [
        "dirt stains on a wall",
        "pollution marks on a wall",
        "dirty wall surface",
    ],
    "crack": [
        "a crack on a wall",
        "hairline crack on a wall",
        "wall fracture",
    ],
    "normal_wall": [
        "a clean normal wall",
        "white painted wall without defects",
        "healthy wall surface",
    ],
}

OWL_PROMPTS = {
    "water_stain": "a water stain on a wall",
    "mold": "mold on a wall",
    "pollution": "dirt stains on a wall",
    "crack": "a crack on a wall",
}


class ModelManager:
    def __init__(self):
        self._yolo = {}
        self._sam = None
        self._sam_predictor = None
        self._clip_model = None
        self._clip_processor = None
        self._vit_model = None
        self._vit_processor = None
        self._vit_labels = None
        self._owl_model = None
        self._owl_processor = None

    def yolo(self, size: str):
        if size not in self._yolo:
            from ultralytics import YOLO

            path = MODELS_DIR / f"crack_seg_{size}.pt"
            self._yolo[size] = YOLO(str(path))
        return self._yolo[size]

    def mobilesam_predictor(self):
        if self._sam_predictor is None:
            from mobile_sam import SamPredictor, sam_model_registry

            sam = sam_model_registry["vit_t"](checkpoint=str(MODELS_DIR / "mobile_sam.pt"))
            sam.to("cpu").eval()
            self._sam = sam
            self._sam_predictor = SamPredictor(sam)
        return self._sam_predictor

    def clip(self):
        if self._clip_model is None:
            from transformers import CLIPModel, CLIPProcessor

            self._clip_model = CLIPModel.from_pretrained(
                "openai/clip-vit-base-patch32",
                local_files_only=True,
            )
            self._clip_processor = CLIPProcessor.from_pretrained(
                "openai/clip-vit-base-patch32",
                local_files_only=True,
            )
        return self._clip_model, self._clip_processor

    def vit(self):
        if self._vit_model is None:
            from transformers import (
                AutoImageProcessor,
                AutoModelForImageClassification,
            )

            self._vit_processor = AutoImageProcessor.from_pretrained(str(HOUSE_FAULT_DIR))
            self._vit_model = AutoModelForImageClassification.from_pretrained(
                str(HOUSE_FAULT_DIR)
            )
            self._vit_labels = json.loads(
                (HOUSE_FAULT_DIR / "label_map.json").read_text(encoding="utf-8")
            )
        return self._vit_model, self._vit_processor, self._vit_labels

    def owl(self):
        if self._owl_model is None:
            from transformers import OwlViTForObjectDetection, OwlViTProcessor

            self._owl_model = OwlViTForObjectDetection.from_pretrained(
                "google/owlvit-base-patch32",
                local_files_only=True,
            )
            self._owl_processor = OwlViTProcessor.from_pretrained(
                "google/owlvit-base-patch32",
                local_files_only=True,
            )
        return self._owl_model, self._owl_processor


def detect_cracks(
    image_rgb,
    model_manager,
    model_size="n",
    conf=0.3,
    iou=0.5,
    imgsz=640,
):
    model = model_manager.yolo(model_size)
    result = model.predict(
        image_rgb,
        conf=conf,
        iou=iou,
        imgsz=imgsz,
        verbose=False,
        device="cpu",
    )[0]
    if result.boxes is None or len(result.boxes) == 0:
        return np.empty((0, 4)), np.empty((0,)), []

    boxes = result.boxes.xyxy.cpu().numpy()
    scores = result.boxes.conf.cpu().numpy()
    masks = []
    if result.masks is not None:
        data = result.masks.data.cpu().numpy()
        for i in range(data.shape[0]):
            resized = cv2.resize(
                data[i],
                (image_rgb.shape[1], image_rgb.shape[0]),
                interpolation=cv2.INTER_NEAREST,
            )
            masks.append(resized > 0.5)
    return boxes, scores, masks


def detect_cracks_hairline(
    image_rgb,
    model_manager,
    model_size="s",
    conf=0.2,
    iou=0.5,
    tile_size=1024,
    overlap=192,
):
    height, width = image_rgb.shape[:2]
    step = max(64, tile_size - overlap)
    if height <= tile_size and width <= tile_size:
        return detect_cracks(
            image_rgb,
            model_manager,
            model_size=model_size,
            conf=conf,
            iou=iou,
            imgsz=tile_size,
        )

    all_boxes = []
    all_scores = []
    all_masks = []
    all_origins = []
    for y in range(0, height, step):
        for x in range(0, width, step):
            y1, y2 = y, min(height, y + tile_size)
            x1, x2 = x, min(width, x + tile_size)
            tile = image_rgb[y1:y2, x1:x2]
            tile_boxes, tile_scores, tile_masks = detect_cracks(
                tile,
                model_manager,
                model_size=model_size,
                conf=conf,
                iou=iou,
                imgsz=tile_size,
            )
            for box, score, mask in zip(tile_boxes, tile_scores, tile_masks):
                all_boxes.append(
                    [
                        box[0] + x1,
                        box[1] + y1,
                        box[2] + x1,
                        box[3] + y1,
                    ]
                )
                all_scores.append(score)
                all_masks.append(mask)
                all_origins.append((x1, y1))

    if not all_boxes:
        return np.empty((0, 4)), np.empty((0,)), []

    keep = _nms(np.asarray(all_boxes), np.asarray(all_scores), iou)
    merged = np.zeros((height, width), dtype=bool)
    for idx in keep:
        ox, oy = all_origins[idx]
        mask = all_masks[idx]
        merged[oy : oy + mask.shape[0], ox : ox + mask.shape[1]] |= mask > 0

    boxes = np.asarray(all_boxes)[keep]
    scores = np.asarray(all_scores)[keep]
    return boxes, scores, [merged]


def detect_surface_defects(
    image_rgb,
    model_manager,
    threshold=0.1,
    iou=0.5,
):
    model, processor = model_manager.owl()
    prompts = list(OWL_PROMPTS.values())
    inputs = processor(
        text=prompts,
        images=Image.fromarray(image_rgb).convert("RGB"),
        return_tensors="pt",
    )
    with torch.no_grad():
        outputs = model(**inputs)
    target_sizes = torch.tensor([image_rgb.shape[1], image_rgb.shape[0]]).unsqueeze(0)
    results = processor.post_process_grounded_object_detection(
        outputs,
        threshold=threshold,
        target_sizes=target_sizes,
        text_labels=[prompts],
    )[0]
    if results["boxes"].shape[0] == 0:
        return np.empty((0, 4)), np.empty((0,)), np.empty((0,), dtype=int)

    boxes = results["boxes"].numpy().astype(float)
    scores = results["scores"].numpy()
    labels = results["labels"].numpy().astype(int)
    keep = _nms(boxes, scores, iou)
    return boxes[keep], scores[keep], labels[keep]


def detect_surface_defects_clip(
    image_rgb,
    model_manager,
    threshold=0.3,
    max_side=768,
    patch_size=224,
    stride=192,
):
    height, width = image_rgb.shape[:2]
    scale = min(1.0, max_side / max(height, width))
    small_w = max(patch_size, int(round(width * scale)))
    small_h = max(patch_size, int(round(height * scale)))
    small = cv2.resize(image_rgb, (small_w, small_h), interpolation=cv2.INTER_AREA)

    positive = np.zeros((small_h, small_w), dtype=bool)
    class_map = np.zeros((small_h, small_w), dtype=np.uint8)
    keys = list(OWL_PROMPTS.keys())
    class_index = {name: idx for idx, name in enumerate(keys)}

    y_positions = list(range(0, small_h - patch_size + 1, stride))
    if y_positions[-1] < small_h - patch_size:
        y_positions.append(small_h - patch_size)
    x_positions = list(range(0, small_w - patch_size + 1, stride))
    if x_positions[-1] < small_w - patch_size:
        x_positions.append(small_w - patch_size)

    for y in y_positions:
        for x in x_positions:
            patch = small[y : y + patch_size, x : x + patch_size]
            scores = classify_with_clip(patch, model_manager)
            top = max(scores, key=scores.get)
            if top in ("water_stain", "mold", "pollution") and scores[top] >= threshold:
                positive[y : y + patch_size, x : x + patch_size] = True
                class_map[y : y + patch_size, x : x + patch_size] = class_index[top]

    if not positive.any():
        return (
            np.empty((0, 4)),
            np.empty((0,)),
            np.empty((0,), dtype=int),
            [],
        )

    positive = cv2.morphologyEx(
        positive.astype(np.uint8),
        cv2.MORPH_CLOSE,
        np.ones((5, 5), np.uint8),
    ).astype(bool)
    labels = label(positive, connectivity=2)

    boxes = []
    scores = []
    out_labels = []
    masks = []
    for component_id in range(1, int(labels.max()) + 1):
        component_small = labels == component_id
        ys, xs = np.nonzero(component_small)
        if ys.size == 0:
            continue
        if component_small.sum() < 200:
            continue
        x1, x2 = xs.min(), xs.max()
        y1, y2 = ys.min(), ys.max()
        pad = 4
        x1 = max(0, x1 - pad)
        y1 = max(0, y1 - pad)
        x2 = min(small_w - 1, x2 + pad)
        y2 = min(small_h - 1, y2 + pad)

        full_mask = cv2.resize(
            component_small.astype(np.uint8),
            (width, height),
            interpolation=cv2.INTER_NEAREST,
        ).astype(bool)
        fys, fxs = np.nonzero(full_mask)
        if fys.size == 0:
            continue
        boxes.append([float(fxs.min()), float(fys.min()), float(fxs.max()), float(fys.max())])

        class_values = class_map[component_small]
        category = int(np.bincount(class_values.flatten()).argmax())
        out_labels.append(category)
        scores.append(threshold + 0.1)
        masks.append(full_mask)

    if not boxes:
        return np.empty((0, 4)), np.empty((0,)), np.empty((0,), dtype=int), []
    return (
        np.asarray(boxes),
        np.asarray(scores),
        np.asarray(out_labels, dtype=int),
        masks,
    )


def _nms(boxes, scores, iou_threshold):
    from torchvision.ops import nms

    keep = nms(
        torch.tensor(boxes, dtype=torch.float32),
        torch.tensor(scores, dtype=torch.float32),
        iou_threshold,
    )
    return keep.numpy()


def segment_with_mobilesam(image_rgb, boxes, model_manager, pad_ratio=0.05):
    if len(boxes) == 0:
        return []
    predictor = model_manager.mobilesam_predictor()
    predictor.set_image(image_rgb)
    height, width = image_rgb.shape[:2]
    masks = []
    for box in boxes:
        x1, y1, x2, y2 = box
        pad_x = max(1.0, (x2 - x1) * pad_ratio)
        pad_y = max(1.0, (y2 - y1) * pad_ratio)
        prompt_box = np.array(
            [
                max(0.0, x1 - pad_x),
                max(0.0, y1 - pad_y),
                min(width, x2 + pad_x),
                min(height, y2 + pad_y),
            ],
            dtype=float,
        )
        mask, _, _ = predictor.predict(
            box=prompt_box, multimask_output=False
        )
        masks.append(mask[0] > 0)
    return masks


def classify_with_clip(image_rgb, model_manager):
    model, processor = model_manager.clip()
    prompts = [prompt for group in CLIP_PROMPTS.values() for prompt in group]
    inputs = processor(
        text=prompts,
        images=Image.fromarray(image_rgb).convert("RGB"),
        return_tensors="pt",
        padding=True,
    )
    with torch.no_grad():
        image_output = model.get_image_features(pixel_values=inputs["pixel_values"])
        image_features = image_output["pooler_output"].squeeze(0)
        text_output = model.get_text_features(input_ids=inputs["input_ids"], attention_mask=inputs["attention_mask"])
        text_features = text_output["pooler_output"]
        image_features = image_features / image_features.norm(dim=-1, keepdim=True)
        text_features = text_features / text_features.norm(dim=-1, keepdim=True)
        prompt_logits = (text_features @ image_features) * model.logit_scale.exp()

    class_logits = []
    idx = 0
    for group in CLIP_PROMPTS.values():
        class_logits.append(float(prompt_logits[idx : idx + len(group)].mean()))
        idx += len(group)
    class_tensor = torch.tensor(class_logits)
    probs = torch.softmax(class_tensor, dim=0).numpy()
    return dict(zip(CLIP_PROMPTS.keys(), probs.tolist()))


def classify_with_vit(image_rgb, model_manager):
    model, processor, labels = model_manager.vit()
    inputs = processor(images=Image.fromarray(image_rgb).convert("RGB"), return_tensors="pt")
    with torch.no_grad():
        logits = model(**inputs).logits
        probs = torch.softmax(logits[0], dim=0).numpy()
    ranked = sorted(
        ((labels[str(i)], float(prob)) for i, prob in enumerate(probs)),
        key=lambda item: item[1],
        reverse=True,
    )
    return ranked
