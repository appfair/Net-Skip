// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import SwiftUI
import SkipWeb

@available(iOS 17, macOS 14.0, *)
public struct ContentView: View {
    @AppStorage("setting") var setting = true

    public init() {
    }

    public var body: some View {
        TabView {
            BrowserView()
                .tabItem { Label("Apps", systemImage: "list.bullet") }

            VStack {
                Text("Welcome to Net Skip!")
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
            }
            .font(.largeTitle)
            .tabItem { Label("Net Skip", systemImage: "house.fill") }

            Form {
                Text("Settings")
                    .font(.largeTitle)
                Toggle("Option", isOn: $setting)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

@available(iOS 17, macOS 14.0, *)
public struct BrowserView: View {
    @State var viewModel = ViewModel(url: "https://search.inetol.net/")

    public init() {
    }

    public var body: some View {
        VStack {
            WebView(url: URL(string: "https://search.inetol.net/")!)
            TextField(text: $viewModel.url) {
                Text("URL or search")
            }
            .font(.title)
            .autocorrectionDisabled()
            #if !SKIP
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            #endif
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
@Observable class ViewModel {
    var url = ""
    init(url: String) {
        self.url = url
    }
}
