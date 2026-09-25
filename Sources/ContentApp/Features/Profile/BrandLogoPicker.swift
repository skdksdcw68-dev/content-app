import PhotosUI
import SwiftUI

/// Choosing the brand's mark.
///
/// Abel, 25 Sep 2026, on "Your name or logo" in the series flow: *"the user is
/// never asked to upload his logo."* This is where they are asked, and the
/// series flow asks for it too the moment it is chosen.
///
/// The preview sits on a checkerboard rather than a white card, because a logo
/// is almost always a transparent PNG and a white card hides exactly the
/// problem somebody needs to see — a white mark on white, or an opaque box
/// around a mark that should not have one.
struct BrandLogoPicker: View {
    @Environment(AppSession.self) private var session

    @State private var picked: PhotosPickerItem?
    @State private var logo: UIImage?
    @State private var loading = true
    @State private var working = false

    /// Called once a logo is stored, so a flow that asked for one can move on.
    var onStored: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Checkerboard()
                if let logo {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if loading {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 26, weight: .light))
                        Text("No logo yet")
                            .font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }

                if working {
                    Color.black.opacity(0.25)
                    ProgressView().tint(.white)
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous))

            HStack(spacing: 10) {
                PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                    Text(logo == nil ? "Choose a logo" : "Change")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(working)

                if logo != nil {
                    Button {
                        Task {
                            working = true
                            defer { working = false }
                            if await session.removeLogo() { logo = nil }
                        }
                    } label: {
                        Text("Remove")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Color.track, in: Capsule())
                            .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(SoftPressStyle())
                    .disabled(working)
                }
            }

            Text("A transparent PNG works best. It goes on the videos a series makes for you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            logo = await session.logoImage()
            loading = false
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                working = true
                defer { working = false; picked = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    session.lastError = "That picture could not be read."
                    return
                }
                if await session.uploadLogo(image) {
                    logo = image
                    onStored?()
                }
            }
        }
    }
}

/// The grey chequer behind a transparent image, so what is transparent reads
/// as transparent rather than as white.
private struct Checkerboard: View {
    var square: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let light = Color(white: 0.96)
            let dark = Color(white: 0.88)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : square
                while x < size.width {
                    context.fill(
                        Path(CGRect(x: x, y: y, width: square, height: square)),
                        with: .color(dark)
                    )
                    x += square * 2
                }
                y += square
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}
