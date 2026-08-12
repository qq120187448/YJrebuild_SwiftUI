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
            }
        }
    }
}
