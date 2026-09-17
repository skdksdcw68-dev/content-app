import SwiftUI
import WebKit

/// A TikTok video, playing on the page, through TikTok's own embed player.
///
/// Abel: "they are not able to see their videos on the page, why?" The phone
/// has no copy of a video posted from elsewhere, and TikTok gives apps no file
/// to play -- but it does give an official player for any public video, which
/// is what this loads. Private videos will not play here, the same as on the
/// web.
struct TikTokPlayer: UIViewRepresentable {
    let videoId: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false

        let query = "autoplay=1&loop=1&music_info=0&description=0&rel=0&native_context_menu=0&closed_caption=0"
        if let url = URL(string: "https://www.tiktok.com/player/v1/\(videoId)?\(query)") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
