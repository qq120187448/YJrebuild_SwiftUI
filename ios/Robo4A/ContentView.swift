//
//  ContentView.swift
//  YOLOv8-seg-iOS
//
//  Created by Marcel Opitz on 18.05.23.
//

import SwiftUI
import _PhotosUI_SwiftUI
import CoreImage

struct ContentView: View {
    
    @Environment(\.displayScale) var displayScale
    @ObservedObject var viewModel: ContentViewModel
    
    @State var showBoxes: Bool = true
    @State var showMasks: Bool = true
    @State var presentMaskPreview: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            imageView
              .safeAreaPadding(.top)
              .contextMenu {
                  Button(action: {
                    if let selectedImage = viewModel.uiImage, !showBoxes {
                      let scale = 400 / selectedImage.size.height
                      let renderer = ImageRenderer(
                        content: imageView.frame(
                          width: selectedImage.size.width * scale,
                          height: selectedImage.size.height * scale))
                        renderer.scale = displayScale
                        if let renderedImage = renderer.uiImage {
                            print(renderedImage.size)
                            UIImageWriteToSavedPhotosAlbum(renderedImage, nil, nil, nil)
                        }
                    }
                  }) {
                      Label("Save to camera roll", systemImage: "square.and.arrow.down")
                  }
              }
            
            settingsForm
              .safeAreaPadding(.top, 32)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .sheet(isPresented: $presentMaskPreview) {
            buildMasksSheet()
        }
    }
    
    var imageView: some View {
        Group {
            if let uiImage = viewModel.uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color
                    .gray
                    .aspectRatio(contentMode: .fit)
            }
        }
        .overlay(
            buildMaskImage(mask: viewModel.combinedMaskImage)
                .opacity(showMasks ? 0.7 : 0))
        .overlay(
            CenterlineOverlayView(
                result: viewModel.centerlineResult,
                imageSize: viewModel.uiImage?.size ?? .zero
            )
        )
        .overlay(
            DetectionViewRepresentable(
                predictions: $viewModel.predictions)
            .opacity(showBoxes ? 1 : 0))
        .frame(maxHeight: 400)
    }
    
    var settingsForm: some View {
        Form {
            Section {
                PhotosPicker(
                    "Pick Image",
                    selection: $viewModel.imageSelection,
                    matching: .images)
            }

            Section {
                Picker("Model", selection: $viewModel.modelSize) {
                    Text("crack_seg_n").tag("n")
                    Text("crack_seg_s").tag("s")
                }
                .pickerStyle(.segmented)
                Text(viewModel.centerlineStats)
                    .font(.caption)
                    .foregroundStyle(.orange)
                if !viewModel.modelNote.isEmpty {
                    Text(viewModel.modelNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section {
                VStack {
                    Slider(value: $viewModel.confidenceThreshold, in: 0...1)
                    Text("Confidence threshold: \(viewModel.confidenceThreshold, specifier: "%.2f")")
                }
                VStack {
                    Slider(value: $viewModel.iouThreshold, in: 0...1)
                    Text("IoU threshold: \(viewModel.iouThreshold, specifier: "%.2f")")
                }
                VStack {
                    Slider(value: $viewModel.maskThreshold, in: 0...1)
                    Text("Mask threshold: \(viewModel.maskThreshold, specifier: "%.2f")")
                }
                
                Button {
                    Task {
                        await viewModel.runInference()
                    }
                } label: {
                    HStack {
                        Text(viewModel.status?.message ?? "Run inference")
                        Spacer()
                        if viewModel.processing {
                            ProgressView()
                        }
                    }
                }.disabled(viewModel.processing || viewModel.uiImage == nil)
            }
            
            Section {
                if !viewModel.maskPredictions.isEmpty {
                    Toggle("Show boxes:", isOn: $showBoxes)
                    Toggle("Show masks:", isOn: $showMasks)
                    Button("Clear predictions") {
                        viewModel.predictions = []
                        viewModel.maskPredictions = []
                        viewModel.combinedMaskImage = nil
                    }
                    Button("Show all masks") {
                        presentMaskPreview.toggle()
                    }
                }
            }
        }
    }
    
    @ViewBuilder private func buildMaskImage(mask: UIImage?) -> some View {
        if let mask {
            Image(uiImage: mask)
                .resizable()
                .antialiased(false)
                .interpolation(.none)
        }
    }
    
    @ViewBuilder private func buildMasksSheet() -> some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 8) {
                ForEach(Array(viewModel.maskPredictions.enumerated()), id: \.offset) { index, maskPrediction in
                    VStack(alignment: .center) {
                        Group {
                            if let maskImg = maskPrediction.getMaskImage() {
                                Image(uiImage: maskImg)
                                    .resizable()
                                    .antialiased(false)
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .background(Color.black)
                                    .contextMenu {
                                        Button(action: {
                                            UIImageWriteToSavedPhotosAlbum(maskImg, nil, nil, nil)
                                        }) {
                                            Label("Save to camera roll", systemImage: "square.and.arrow.down")
                                        }
                                    }
                            } else {
                                let _ = print("maskImg is nil")
                            }
                        }
                        Divider()
                    }.frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
    }
}

/// 4A 新层：在 MaciDE 原图上叠加红色中心线与蓝色采样点。
struct CenterlineOverlayView: View {
    let result: CrackCenterlineOverlay.Result?
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            if let result, imageSize.width > 0, imageSize.height > 0 {
                let scale = min(
                    geo.size.width / imageSize.width,
                    geo.size.height / imageSize.height
                )
                let offset = CGPoint(
                    x: (geo.size.width - imageSize.width * scale) / 2,
                    y: (geo.size.height - imageSize.height * scale) / 2
                )
                Canvas { context, _ in
                    for polyline in result.polylines {
                        var path = Path()
                        for (index, point) in polyline.enumerated() {
                            let location = CGPoint(
                                x: offset.x + CGFloat(point.x) * scale,
                                y: offset.y + CGFloat(point.y) * scale
                            )
                            if index == 0 {
                                path.move(to: location)
                            } else {
                                path.addLine(to: location)
                            }
                        }
                        context.stroke(path, with: .color(.red), lineWidth: 2)
                    }

                    for point in result.samplePoints {
                        let location = CGPoint(
                            x: offset.x + CGFloat(point.x) * scale,
                            y: offset.y + CGFloat(point.y) * scale
                        )
                        let rect = CGRect(
                            x: location.x - 3,
                            y: location.y - 3,
                            width: 6,
                            height: 6
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(.blue)
                        )
                    }
                }
            }
        }
    }
}
