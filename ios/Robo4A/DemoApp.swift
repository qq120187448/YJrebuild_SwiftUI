//
//  DemoApp.swift
//  YOLOv8-seg-iOS
//
//  Created by Marcel Opitz on 18.05.23.
//

import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(viewModel: ContentViewModel())
                    .tabItem {
                        Label("4A 像素", systemImage: "scope")
                    }
                CrackRaycast4BView()
                    .tabItem {
                        Label("4B Raycast", systemImage: "viewfinder")
                    }
                CrackSurfaceUV4CView()
                    .tabItem {
                        Label("4C Surface UV", systemImage: "square.grid.3x3")
                    }
                RoomPlanUIAxExperimentView()
                    .tabItem {
                        Label("4C UI A/B", systemImage: "rectangle.3.group")
                    }
            }
        }
    }
}
