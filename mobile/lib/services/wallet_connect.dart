import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

/// The mobile half of the project plan's documented wallet-connect
/// pattern: no native Dart/CKB wallet SDK exists (JoyID's own "Native
/// App" docs are still a stub), so this app never touches a private
/// key itself. Instead it opens Bitshada's own web pages in the SYSTEM
/// browser (never an embedded WebView -- the real browser the user
/// already trusts handles the actual signing, via the same ckb.js the
/// web marketplace uses), then listens for the bitshada:// redirect
/// those pages push once they're done. See
/// web/lib/web_web/live/mobile_connect_live.ex and mobile_action_live.ex
/// for the other half of this handshake.
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
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  WalletConnectService({this.baseUrl = 'https://api.bitshada.com'});

  /// Opens the connect page and resolves once bitshada://wallet-connected
  /// (or an error) comes back. Call once per app session; the same
  /// browser tab/profile keeps its own wallet across repeat connects,
  /// same as the web app's own localStorage-persisted signer.
  Future<Wallet> connect() async {
    final completer = Completer<Wallet>();
    _listenOnce((uri) {
      if (uri.host == 'wallet-connected') {
        final q = uri.queryParameters;
        completer.complete(Wallet(
          address: q['address'] ?? '',
          lockHash: q['lockHash'] ?? '',
          balanceCkb: double.tryParse(q['balanceCkb'] ?? '0') ?? 0,
        ));
      }
    });

    final uri = Uri.parse('$baseUrl/mobile/connect');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _sub?.cancel();
      throw Exception('Could not open the browser to connect a wallet.');
    }

    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        _sub?.cancel();
        throw Exception('Wallet connect timed out -- try again.');
      },
    );
  }

  /// Opens /mobile/action for one create/reserve/claim call and resolves
  /// once bitshada://action-done or action-error comes back.
  Future<ActionResult> runAction(Map<String, String> params) async {
    final completer = Completer<ActionResult>();
    _listenOnce((uri) {
      if (uri.host == 'action-done') {
        final q = uri.queryParameters;
        completer.complete(ActionResult(ok: true, action: q['action'] ?? '', txHash: q['tx_hash']));
      } else if (uri.host == 'action-error') {
        final q = uri.queryParameters;
        completer.complete(ActionResult(ok: false, action: q['action'] ?? '', message: q['message']));
      }
    });

    final uri = Uri.parse('$baseUrl/mobile/action').replace(queryParameters: params);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _sub?.cancel();
      throw Exception('Could not open the browser to complete this action.');
    }

    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        _sub?.cancel();
        throw Exception('Timed out waiting for the browser -- try again.');
      },
    );
  }

  void _listenOnce(void Function(Uri uri) onLink) {
    _sub?.cancel();
    _sub = _appLinks.uriLinkStream.listen((uri) {
      if (uri.scheme == 'bitshada') {
        onLink(uri);
        _sub?.cancel();
      }
    });
  }

  void dispose() {
    _sub?.cancel();
  }
}
