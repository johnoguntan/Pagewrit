import SwiftUI

/// A short, one-time welcome screen shown before the very first scan.
/// Stoa isn't sandboxed, so the first time it actually reads Documents,
/// Desktop, or Downloads, macOS shows its own native "Stoa would like to
/// access files in your X folder" prompt for each one \u{2014} up to three in a
/// row, completely unexplained, right at cold launch, if nothing here
/// told the person what's about to happen and why. This screen exists
/// only to give that context before those dialogs fire.
struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            Spacer(minLength: 0)

            Image(systemName: "books.vertical.fill")
                .font(.system(size: 40))
                .foregroundStyle(DesignTokens.accent)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Welcome to Stoa")
                    .font(DesignTokens.serifFont(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Stoa looks in your Documents, Desktop, and Downloads folders for EPUB, PDF, and CBZ books, and brings them into one library with a built-in reader.")
                    .font(DesignTokens.sansFont(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                onboardingPoint(
                    icon: "checkmark.shield",
                    text: "macOS will ask for permission to each folder separately, right after this \u{2014} that's expected, just click Allow."
                )
                onboardingPoint(
                    icon: "doc.on.doc",
                    text: "Your files stay exactly where they are \u{2014} Stoa only reads them, it never moves or copies the originals."
                )
                onboardingPoint(
                    icon: "folder.badge.plus",
                    text: "You can add more folders any time from Settings."
                )
            }
            .padding(DesignTokens.Spacing.lg)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 380)

            Spacer(minLength: 0)

            Button {
                onGetStarted()
            } label: {
                Text("Get Started")
                    .font(DesignTokens.sansFont(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 28)
                    .background(DesignTokens.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(width: 480, height: 520)
        .background(DesignTokens.background.ignoresSafeArea())
    }

    private func onboardingPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.accent)
                .frame(width: 18)

            Text(text)
                .font(DesignTokens.sansFont(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    OnboardingView(onGetStarted: {})
}
