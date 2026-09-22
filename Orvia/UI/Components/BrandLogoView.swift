import SwiftUI

struct BrandLogoView: View {
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        Image("OrviaMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Orvia")
    }
}
