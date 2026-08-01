//
//  LiDARPointCloudScanView.swift
//  RoomPlanDemo
//
//  SwiftUI screen for ARKit mesh scanning and PLY export.
//

import ARKit
import SceneKit
import SwiftUI
import UIKit

struct LiDARPointCloudScanView: View {
    @StateObject private var engine = LiDARScanEngine()
    @Environment(\.dismiss) private var dismiss
    @State private var exportedFile: ExportedFile?

    var body: some View {
        ZStack {
            ARSCNViewContainer(sceneView: engine.sceneView)
                .ignoresSafeArea()

            VStack {
                headerView
                Spacer()
                statsView
                controlsView
            }
        }
        .onAppear { engine.startScanning() }
        .onDisappear { engine.stopScanning() }
        .sheet(item: $exportedFile) { file in
            ActivityView(activityItems: [file.url])
        }
        .alert("Error", isPresented: $engine.isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engine.errorMessage)
        }
    }

    private var headerView: some View {
        HStack {
            Button {
                engine.stopScanning()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }

            Spacer()

            Text(engine.isScanning ? "SCANNING" : "PAUSED")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var statsView: some View {
        VStack(spacing: 4) {
            Text("Vertices \(engine.meshVertexCount)  Faces \(engine.meshFaceCount)")
                .font(.caption.monospaced())
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())

            Text("Move around the room to build the mesh")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.bottom, 12)
    }

    private var controlsView: some View {
        HStack(spacing: 16) {
            Button {
                if engine.isScanning {
                    engine.stopScanning()
                } else {
                    engine.startScanning()
                }
            } label: {
                Text(engine.isScanning ? "Pause" : "Scan")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 96, height: 48)
                    .background(Color.red)
                    .clipShape(Capsule())
            }

            Button {
                engine.resetScanning()
            } label: {
                Text("Reset")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 84, height: 48)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }

            Button {
                exportPLY()
            } label: {
                Text(engine.isExporting ? "Exporting..." : "Export PLY")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 120, height: 48)
                    .background(Color.green)
                    .clipShape(Capsule())
            }
            .disabled(engine.meshVertexCount == 0 || engine.isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }

    private func exportPLY() {
        engine.exportColoredPLY { result in
            switch result {
            case .success(let url):
                exportedFile = ExportedFile(url: url)
            case .failure(let error):
                engine.reportError(error.localizedDescription)
            }
        }
    }
}

private struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ARSCNViewContainer: UIViewRepresentable {
    let sceneView: ARSCNView

    func makeUIView(context: Context) -> ARSCNView {
        sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
