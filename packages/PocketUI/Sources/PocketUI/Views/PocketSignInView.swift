#if canImport(SwiftUI)
import SwiftUI

public struct PocketSignInView: View {
    private let phase: PocketSignInPhase
    private let send: (PocketProductIntent) -> Void

    public init(phase: PocketSignInPhase, send: @escaping (PocketProductIntent) -> Void) {
        self.phase = phase
        self.send = send
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Sign in to Senti")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("See the sessions you belong to and answer your agents from your phone.")
                        .font(.body)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        providerLabel("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        providerLabel("Google", systemImage: "g.circle.fill")
                    }
                    VStack(spacing: 10) {
                        providerLabel("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        providerLabel("Google", systemImage: "g.circle.fill")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sign-in providers: GitHub or Google")

                phaseCard

                Text("Sign-in opens Senti’s secure authorization page. Pocket never asks for or stores your GitHub or Google password.")
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Account")
        .accessibilityIdentifier("pocket.signin.screen")
        .pocketCanvas()
    }

    @ViewBuilder
    private var phaseCard: some View {
        switch phase {
        case .signedOut:
            actionCard(
                title: "Continue securely",
                detail: "Choose GitHub or Google on Senti’s authorization page.",
                buttonTitle: "Continue with GitHub or Google",
                intent: .beginSignIn
            )

        case .authorizing:
            VStack(spacing: 14) {
                ProgressView()
                    .tint(PocketPalette.accent)
                Text("Waiting for secure sign-in…")
                    .font(.headline)
                Button("Cancel") { send(.cancelSignIn) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pocket.signin.cancel")
            }
            .frame(maxWidth: .infinity)
            .pocketCard()

        case .signedIn:
            Label("Signed in securely", systemImage: "checkmark.shield")
                .font(.headline)
                .foregroundStyle(PocketPalette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pocketCard()
                .accessibilityIdentifier("pocket.signin.signed-in")

        case .reauthenticationRequired:
            actionCard(
                title: "Sign in again",
                detail: "Your authorization is no longer valid. Protected cached content stays hidden until you sign in.",
                buttonTitle: "Sign in again",
                intent: .retryAuthentication,
                color: PocketPalette.warning
            )

        case .signingOut:
            VStack(spacing: 12) {
                ProgressView()
                Text("Securing this device…")
                    .font(.headline)
                Text("Session access remains disabled until local credentials and protected cache are cleared.")
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .pocketCard()

        case .unavailable(let reason):
            actionCard(
                title: "Secure sign-in unavailable",
                detail: reason.userMessage,
                buttonTitle: "Try again",
                intent: .retryAuthentication,
                color: PocketPalette.danger
            )
        }
    }

    private func actionCard(
        title: String,
        detail: String,
        buttonTitle: String,
        intent: PocketProductIntent,
        color: Color = PocketPalette.accent
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(detail)
                .font(.body)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { send(intent) } label: {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketPalette.accent)
            .accessibilityIdentifier("pocket.signin.primary")
        }
        .pocketCard()
    }

    private func providerLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PocketPalette.textSecondary)
    }
}
#endif
