import 'dart:math';
import 'package:flutter/widgets.dart';
import '../screens/wallet_webview_screen.dart';

/// The mobile half of the project plan's documented wallet-connect
/// pattern: no native Dart/CKB wallet SDK exists (JoyID's own "Native
/// App" docs are still a stub), so this app never touches a private
/// key itself. Instead it opens Bitshada's own web pages in an
/// EMBEDDED WEBVIEW (WalletWebViewScreen) hosted directly inside this
/// app's own widget tree -- no browser chrome, no address bar, just a
/// themed loading state while the real browser engine the user already
/// trusts handles the actual signing, via the same ckb.js the web
/// marketplace uses. The page's own `bitshada://...` redirect is
/// intercepted as a WebView navigation event (not a system deep link),
/// so this stays entirely within the current screen push -- no global
/// stream listener, no stale-link risk. See
/// web/lib/web_web/live/mobile_connect_live.ex and mobile_action_live.ex
/// for the other half of this handshake, and wallet_webview_screen.dart
/// for the embedded-WebView mechanics and its Custom Tab fallback.
class Wallet {
  final String address;
  final String lockHash;
  final double balanceCkb;

  Wallet({required this.address, required this.lockHash, required this.balanceCkb});
}

class ActionResult {
  final bool ok;
  final String action;
  final String? txHash;
  final String? message;

  ActionResult({required this.ok, required this.action, this.txHash, this.message});
}

class WalletConnectService {
  final String baseUrl;
  final _rng = Random.secure();

  WalletConnectService({this.baseUrl = 'https://api.bitshada.com'});

  /// Opens the connect page in an embedded WebView and resolves once it
  /// redirects to bitshada://wallet-connected (or the user backs out).
  /// Call once per app session; the same WebView's own storage keeps its
  /// wallet across repeat connects, same as the web app's own
  /// localStorage-persisted signer.
  Future<Wallet> connect(BuildContext context) async {
    final uri = Uri.parse('$baseUrl/mobile/connect').replace(queryParameters: {'state': _newState()});
    final result = await WalletWebViewScreen.open(context, url: uri, loadingLabel: 'Connecting wallet...');

    if (result == null || result.host != 'wallet-connected') {
      throw Exception('Wallet connect was cancelled.');
    }
    final q = result.queryParameters;
    return Wallet(
      address: q['address'] ?? '',
      lockHash: q['lockHash'] ?? '',
      balanceCkb: double.tryParse(q['balanceCkb'] ?? '0') ?? 0,
    );
  }

  /// Opens /mobile/action in an embedded WebView for one create/reserve/
  /// claim call and resolves once it redirects to bitshada://action-done
  /// or action-error.
  Future<ActionResult> runAction(BuildContext context, Map<String, String> params) async {
    final uri = Uri.parse('$baseUrl/mobile/action').replace(queryParameters: {...params, 'state': _newState()});
    final result = await WalletWebViewScreen.open(context, url: uri, loadingLabel: 'Submitting to the chain...');

    if (result == null) {
      throw Exception('Cancelled -- nothing was submitted.');
    }
    if (result.host == 'action-done') {
      final q = result.queryParameters;
      return ActionResult(ok: true, action: q['action'] ?? '', txHash: q['tx_hash']);
    }
    final q = result.queryParameters;
    return ActionResult(ok: false, action: q['action'] ?? '', message: q['message']);
  }

  /// Random per-request token, echoed back verbatim by the web page in
  /// its redirect (see mobile_connect_live.ex/mobile_action_live.ex).
  /// No longer load-bearing for this client (the embedded WebView's
  /// navigation intercept is already scoped to this one screen push,
  /// so there's no shared stream to replay a stale link into) -- kept
  /// so the page's existing echo-back query shape doesn't need to
  /// change server-side.
  String _newState() => List.generate(16, (_) => _rng.nextInt(16).toRadixString(16)).join();
}
