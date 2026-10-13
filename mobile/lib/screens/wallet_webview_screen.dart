import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Hosts the wallet-connect / sign-and-submit page directly inside the
/// app's own widget tree (a real WebView, no browser chrome at all) so
/// the hand-off never LOOKS like leaving Bitshada -- just a themed
/// loading state, then (if the signer needs it) the real page content,
/// then back to the offers screen automatically.
///
/// Why this exists instead of just the in-app-browser Custom Tab this
/// app used before: a Custom Tab still shows a small system address
/// bar/title strip on top, which reads as "now I'm in a browser." An
/// embedded WebView has none of that -- only whatever UI this screen
/// itself draws.
///
/// The trade-off (why the Custom Tab path is kept as a manual escape
/// hatch, not deleted): the signing flow's passkey/WebAuthn step is
/// touchier inside an embedded WebView than a full browser tab on some
/// Android/iOS versions. If it ever looks stuck or broken here, the
/// AppBar's "Open in browser" action re-runs the exact same URL through
/// a real Custom Tab instead.
///
/// Returns the `bitshada://...` Uri the page redirected to once the
/// flow finishes, or null if the user backed out.
class WalletWebViewScreen extends StatefulWidget {
  final Uri url;
  final String loadingLabel;

  const WalletWebViewScreen({super.key, required this.url, required this.loadingLabel});

  static Future<Uri?> open(BuildContext context, {required Uri url, required String loadingLabel}) {
    return Navigator.of(context).push<Uri>(
      MaterialPageRoute(builder: (_) => WalletWebViewScreen(url: url, loadingLabel: loadingLabel)),
    );
  }

  @override
  State<WalletWebViewScreen> createState() => _WalletWebViewScreenState();
}

class _WalletWebViewScreenState extends State<WalletWebViewScreen> {
  late final WebViewController _controller;
  bool _loadingFirstPage = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && uri.scheme == 'bitshada') {
              Navigator.of(context).pop(uri);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _failed = false);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loadingFirstPage = false);
          },
          onWebResourceError: (error) {
            // Only the main frame failing is worth surfacing -- a
            // sub-resource hiccup (an ad-blocked font, a flaky
            // analytics call) shouldn't flip the whole screen to an
            // error state the user can't recover from except by
            // backing out.
            if (error.isForMainFrame ?? true) {
              if (mounted) setState(() { _loadingFirstPage = false; _failed = true; });
            }
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  Future<void> _openInBrowser() async {
    await launchUrl(widget.url, mode: LaunchMode.inAppBrowserView);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_failed ? 'Something went wrong' : widget.loadingLabel),
        actions: [
          TextButton(
            onPressed: _openInBrowser,
            child: const Text('Open in browser'),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (!_failed) WebViewWidget(controller: _controller),
          if (_failed)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 40, color: scheme.error),
                    const SizedBox(height: 12),
                    const Text('This page did not load. Try "Open in browser" above, or go back and try again.', textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          if (_loadingFirstPage)
            Container(
              color: scheme.surface,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(height: 18),
                    Text(widget.loadingLabel, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
