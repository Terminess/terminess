import SwiftUI

struct WorkingMark: View {
    let tint: Color
    var body: some View {
        Image(systemName: "circle.dotted")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .help("Working")
    }
}
