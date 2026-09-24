import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/offer.dart';

/// Thin client over Bitshada's own JSON API -- the exact same endpoints
/// the web app's ckb.js talks to (see web/lib/web_web/controllers/api/).
/// This app never holds a private key and never signs anything itself;
/// wallet-connect and transaction signing happen by handing off to the
/// system browser (see wallet_connect.dart), matching the plan's
/// documented "hop out to a URL, come back via deep link" pattern for
/// platforms with no native CKB wallet SDK.
class BitshadaApi {
  final String baseUrl;

  const BitshadaApi({this.baseUrl = 'https://api.bitshada.com'});

  Future<List<Offer>> listOffers() async {
    final res = await http.get(Uri.parse('$baseUrl/api/offers'));
    if (res.statusCode != 200) {
      throw Exception('GET /api/offers failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final offers = body['offers'] as List<dynamic>;
    return offers.map((o) => Offer.fromJson(o as Map<String, dynamic>)).toList();
  }
}
