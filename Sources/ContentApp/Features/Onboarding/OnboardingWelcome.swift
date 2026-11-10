import SwiftUI

/// The first screen: a 16 s ad for Postpilot (idea typed, video made, posted,
/// likes climbing) playing full screen on a loop, with the two buttons over
/// its empty bottom. The clip is rendered at the phone's own shape
/// (`welcome-ad.mp4`, from the Abel-approved ad of 9 Nov 2026); it is always
/// light, so the Sign In line keeps a fixed dark colour. With Reduce Motion
/// on, only its first frame and the tagline show.
struct OnboardingWelcome: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                MediaStill(name: "welcome-ad")
            } else {
                OnboardingClip(name: "welcome-ad")
            }

            MockupCanvas {
                ZStack(alignment: .topLeading) {
                    if reduceMotion {
                        Text("Viral videos, made and posted for you")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.3)
                            .lineSpacing(5)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color(red: 0.055, green: 0.055, blue: 0.07))
                            .at(24, 400, w: 342, align: .top)
                    }

                    ObPurpleButton(title: "Get Started") { session.onboardingNext() }
                        .at(20, 724)

                    Button { session.goToEmail(.login) } label: {
                        Text("Already have an account? **Sign In**")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.055, green: 0.055, blue: 0.07))
                    }
                    .buttonStyle(.plain)
                    .at(0, 792, w: 390, align: .top)
                }
            }
        }
        .ignoresSafeArea()
        .background(Color(red: 0.97, green: 0.96, blue: 1))
    }
}

/// White heavy capitals with a black outline, as the videos' captions are.
struct StrokedWord: View {
    let text: String
    let size: CGFloat
    var stroke: CGFloat = 1.5
    var color: Color = .white

    var body: some View {
        let word = Text(text).font(.system(size: size, weight: .black))
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * .pi / 4
                word.foregroundStyle(.black)
                    .offset(x: cos(angle) * stroke, y: sin(angle) * stroke)
            }
            word.foregroundStyle(color)
        }
        .fixedSize()
    }
}
