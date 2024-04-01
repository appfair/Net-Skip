// This is free software: you can redistribute and/or modify it
// under the terms of the GNU General Public License 3.0
// as published by the Free Software Foundation https://fsf.org

import SwiftUI
import SkipWeb

public struct ContentView: View {
    @AppStorage("setting") var setting = true
    let config = WebEngineConfiguration(javaScriptEnabled: true)
    
    public init() {
    }

    public var body: some View {
        NavigationStack {
            #if SKIP || os(iOS)
            WebBrowser(configuration: config)
                #if SKIP
                // eliminate blank space on Android: https://github.com/skiptools/skip/issues/99#issuecomment-2010650774
                .toolbar(.hidden, for: .navigationBar)
                #endif
            #endif
        }
    }
}
