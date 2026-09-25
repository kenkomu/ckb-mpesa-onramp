import 'package:flutter/material.dart';
import '../models/offer.dart';
import '../services/api.dart';
import '../services/wallet_connect.dart';

/// The marketplace screen: browse, create, reserve, and claim offers.
/// This app never signs anything itself -- every action that needs a
/// signature hands off to the system browser (WalletConnectService,
/// which reuses the exact same ckb.js the web app uses) and waits for
/// the bitshada:// redirect. See wallet_connect.dart's own header
/// comment for why.
class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  final _api = const BitshadaApi();
  final _wallet = WalletConnectService();

  late Future<List<Offer>> _offersFuture;
  Wallet? _connectedWallet;
  bool _connecting = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _offersFuture = _api.listOffers();
  }

  @override
  void dispose() {
    _wallet.dispose();
    super.dispose();
  }

  Future<void> _refreshOffers() async {
    setState(() => _offersFuture = _api.listOffers());
    await _offersFuture;
  }

  Future<void> _connectWallet() async {
    setState(() {
      _connecting = true;
      _actionError = null;
    });
    try {
      final wallet = await _wallet.connect();
      if (!mounted) return;
      setState(() => _connectedWallet = wallet);
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = e.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _runAction(Map<String, String> params) async {
    setState(() => _actionError = null);
    try {
      final result = await _wallet.runAction(params);
      if (!mounted) return;
      if (result.ok) {
        await _refreshOffers();
      } else {
        setState(() => _actionError = '${result.action} failed: ${result.message}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = e.toString());
    }
  }

  Future<void> _showCreateOfferSheet() async {
    final identifierController = TextEditingController();
    final amountController = TextEditingController();

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sell CKB for KES', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: identifierController,
              decoration: const InputDecoration(labelText: 'M-Pesa number (any test value works)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount (KES)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Create offer'),
              ),
            ),
          ],
        ),
      ),
    );

    if (submitted == true) {
      await _runAction({
        'action': 'create',
        'identifier': identifierController.text,
        'amount': amountController.text,
      });
    }
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: _WalletButton(wallet: _connectedWallet, connecting: _connecting, onTap: _connectWallet)),
          ),
        ],
      ),
      floatingActionButton: _connectedWallet == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _showCreateOfferSheet,
              icon: const Icon(Icons.add),
              label: const Text('Create offer'),
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
          if (_actionError != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_actionError!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onErrorContainer)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _actionError = null),
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshOffers,
              child: FutureBuilder<List<Offer>>(
                future: _offersFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorView(error: snapshot.error.toString(), onRetry: _refreshOffers);
                  }
                  final offers = snapshot.data ?? [];
                  if (offers.isEmpty) {
                    return ListView(
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
                    itemBuilder: (context, i) => _OfferCard(
                      offer: offers[i],
                      wallet: _connectedWallet,
                      onReserve: () => _runAction({'action': 'reserve', 'tx_hash': offers[i].outPointTxHash, 'index': offers[i].outPointIndex}),
                      onClaim: () => _runAction({'action': 'claim', 'tx_hash': offers[i].outPointTxHash, 'index': offers[i].outPointIndex}),
                    ),
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

class _WalletButton extends StatelessWidget {
  final Wallet? wallet;
  final bool connecting;
  final VoidCallback onTap;
  const _WalletButton({required this.wallet, required this.connecting, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (connecting) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (wallet == null) {
      return TextButton(onPressed: onTap, child: const Text('Connect wallet'));
    }
    final short = '${wallet!.address.substring(0, 10)}...';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(short, style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
        Text('${wallet!.balanceCkb.toStringAsFixed(2)} CKB', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _OfferCard extends StatelessWidget {
  final Offer offer;
  final Wallet? wallet;
  final VoidCallback onReserve;
  final VoidCallback onClaim;
  const _OfferCard({required this.offer, required this.wallet, required this.onReserve, required this.onClaim});

  @override
  Widget build(BuildContext context) {
    final isOpen = offer.status == 'open';
    final statusColor = isOpen ? Colors.green : Colors.orange;
    final canReserve = wallet != null && isOpen;
    final canClaim = wallet != null && !isOpen && offer.reservedByLockHash == wallet!.lockHash;
    final reservedByOther = !isOpen && (wallet == null || offer.reservedByLockHash != wallet!.lockHash);

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
                  decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
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
            Text('${offer.amountKes.toStringAsFixed(2)} KES', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('${offer.capacityCkb.toStringAsFixed(2)} CKB locked in escrow', style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 2),
            Text('Recipient: ${offer.shortRecipient}', style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
            if (canReserve || canClaim || reservedByOther) ...[
              const SizedBox(height: 10),
              if (canReserve)
                SizedBox(width: double.infinity, child: FilledButton(onPressed: onReserve, child: const Text('Reserve'))),
              if (canClaim)
                SizedBox(width: double.infinity, child: FilledButton(onPressed: onClaim, child: const Text('Claim'))),
              if (reservedByOther)
                const Center(child: Text('Reserved by another buyer', style: TextStyle(fontSize: 12, color: Colors.grey))),
            ],
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
