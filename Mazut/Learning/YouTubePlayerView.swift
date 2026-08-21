//
//  YouTubePlayerView.swift
//  Mazut
//
//  Cross-platform wrapper that plays a YouTube video inline via the standard
//  YouTube iframe embed (WKWebView). There is no way to get a directly
//  playable video URL from a YouTube link without violating YouTube's terms,
//  so embedding the official player is the only supported approach here.
//
//  Two things trip up WKWebView specifically (both fine in real Safari):
//  - Loading the `/embed/<id>` URL directly as a top-level navigation has no
//    real page origin, which YouTube's player can reject as a config error.
//    Fixed by loading a tiny HTML wrapper containing the iframe via
//    `loadHTMLString(_:baseURL:)` with a real `https://www.youtube-nocookie.com`
//    base URL, so the embed gets a proper origin.
//  - WKWebView's default user agent sometimes isn't recognized by YouTube's
//    frontend, which then serves a broken/"config error" fallback. Fixed by
//    presenting as a normal mobile Safari.
//  Even with both fixes, some videos will still fail to embed for reasons
//  outside our control (the uploader disabled embedding, region locks, etc.),
//  so the clip player also offers an "Open in YouTube" fallback — see
//  `ClipPlayerSheet` in LearningView.swift.
//

import SwiftUI
import WebKit

private let safariUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " +
    "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

#if canImport(UIKit)
struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration)
        view.customUserAgent = safariUserAgent
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .black
        load(into: view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif canImport(AppKit)
struct YouTubePlayerView: NSViewRepresentable {
    let videoID: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration)
        view.customUserAgent = safariUserAgent
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

private extension YouTubePlayerView {
    static var configuration: WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        return config
    }

    func load(into webView: WKWebView) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; background: #000; height: 100%; }
          iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
        </style>
        </head>
        <body>
        <iframe
          src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&modestbranding=1&rel=0"
          allow="autoplay; encrypted-media; picture-in-picture"
          allowfullscreen>
        </iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }
}
