import SwiftUI

private struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    func reportSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ContentSizeKey.self,
                    value: proxy.size
                )
            }
        )
        .onPreferenceChange(ContentSizeKey.self, perform: onChange)
    }
}
