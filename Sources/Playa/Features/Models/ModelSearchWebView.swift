import SwiftUI
import WebKit

/// Identifies which model registry search page to display.
enum ModelSearchPage: String, CaseIterable, Identifiable {
    case huggingface
    case modelScope

    var id: String { rawValue }

    var title: String {
        switch self {
        case .huggingface: "HuggingFace"
        case .modelScope: "ModelScope"
        }
    }

    var url: URL {
        switch self {
        case .huggingface:
            URL(string: "https://huggingface.co/models?sort=trending&search=")!
        case .modelScope:
            URL(string: "https://modelscope.cn/models?sort=Default&name=")!
        }
    }

    var systemImage: String {
        switch self {
        case .huggingface: "face.smiling"
        case .modelScope: "cube.box"
        }
    }
}

/// SwiftUI wrapper around WKWebView for displaying model registry search pages.
struct ModelSearchWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if the URL host changed (switching between registries).
        if let currentURL = webView.url, currentURL.host != url.host {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject a minimal CSS to improve in-app appearance.
            let css = """
            document.head.insertAdjacentHTML('beforeend',
                '<style>body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }</style>');
            """
            webView.evaluateJavaScript(css, completionHandler: nil)
        }
    }
}

/// Container view that shows a model search page with a header bar.
struct ModelSearchPageView: View {
    let page: ModelSearchPage
    @Binding var activePage: ModelSearchPage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: page.systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                    Text("Search and inspect models in the registry.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    activePage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close model search")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .background(.regularMaterial)

            ModelSearchWebView(url: page.url)
        }
    }
}
