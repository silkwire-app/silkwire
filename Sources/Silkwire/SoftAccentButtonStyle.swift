import SwiftUI

/// A quieter orange button for things that are handy but not urgent ("New replies", "New page").
/// Jason loves orange but found the solid filled buttons too bright on Midnight: this keeps the app's tint as a
/// soft wash and outline with crisp tinted text, saving the bright filled style for things that truly need attention.
/// Uses the environment tint (set on the window), so Staging and the working app each keep their own colour.
struct SoftAccentButtonStyle: ButtonStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        SoftAccentButton(configuration: configuration, small: small)
    }

    private struct SoftAccentButton: View {
        let configuration: ButtonStyleConfiguration
        let small: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: small ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, small ? 9 : 11)
                .padding(.vertical, small ? 3 : 5)
                .background(Capsule().fill(.tint.opacity(configuration.isPressed ? 0.24 : 0.12)))
                .overlay(Capsule().strokeBorder(.tint.opacity(0.55), lineWidth: 1))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}
