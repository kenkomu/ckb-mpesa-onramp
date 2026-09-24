import 'package:flutter/material.dart';
import '../models/offer.dart';
import '../services/api.dart';

/// The marketplace list -- a real, read-only mirror of the same offers
/// the web app shows at api.bitshada.com/offers, backed by the exact
/// same JSON API. Create/reserve/claim (which need a signature) are the
/// next increment, via the deep-link-to-browser wallet-connect pattern
/// described in the project plan -- this screen proves the read side
/// end to end first, the same order the web app itself was built in.
class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  final _api = const BitshadaApi();
  late Future<List<Offer>> _offersFuture;

  @override
  void initState() {
    super.initState();
    _offersFuture = _api.listOffers();
  }

  Future<void> _refresh() async {
    setState(() {
      _offersFuture = _api.listOffers();
    });
    await _offersFuture;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bitshada', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Open offers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.normal)),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.tertiaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.science_outlined, size: 16, color: Theme.of(context).colorScheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Testnet pilot -- test CKB only, no real money.',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onTertiaryContainer),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<Offer>>(
                future: _offersFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorView(error: snapshot.error.toString(), onRetry: _refresh);
                  }
                  final offers = snapshot.data ?? [];
                  if (offers.isEmpty) {
                    return ListView(
                      // ListView (not a bare Center) so pull-to-refresh
                      // still works when the list is empty.
                      children: const [
                        SizedBox(height: 120),
                        Icon(Icons.inbox_outlined, size: 40, color: Colors.grey),
                        SizedBox(height: 12),
                        Center(child: Text('No open offers right now.')),
                      ],
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: offers.length,
                    itemBuilder: (context, i) => _OfferCard(offer: offers[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  final Offer offer;
  const _OfferCard({required this.offer});

  @override
  Widget build(BuildContext context) {
    final isOpen = offer.status == 'open';
    final statusColor = isOpen ? Colors.green : Colors.orange;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 6, height: 6, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Text(offer.status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: statusColor)),
                    ],
                  ),
                ),
                Text(offer.shortCell, style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${offer.amountKes.toStringAsFixed(2)} KES',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text('${offer.capacityCkb.toStringAsFixed(2)} CKB locked in escrow', style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 2),
            Text('Recipient: ${offer.shortRecipient}', style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        const Icon(Icons.error_outline, size: 40, color: Colors.red),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text('Could not reach Bitshada: $error', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
        ),
        const SizedBox(height: 16),
        Center(child: FilledButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}
