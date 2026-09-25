import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show bitshadaMono;
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
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sell CKB for KES', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: identifierController,
              decoration: const InputDecoration(
                labelText: 'M-Pesa number (any test value works)',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Amount (KES)',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bitshada', style: Theme.of(context).textTheme.titleLarge),
            Text('Open offers', style: Theme.of(context).textTheme.bodySmall),
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
            color: scheme.tertiaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.science_outlined, size: 16, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Testnet pilot -- test CKB only, no real money.',
                    style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
                  ),
                ),
              ],
            ),
          ),
          if (_connectedWallet != null && _connectedWallet!.balanceCkb < 10)
            Container(
              width: double.infinity,
              color: scheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Your wallet needs testnet CKB. Tap your balance above to copy the address, then email it to '
                'kenneth.njoroge@quantumke.org for a top-up.',
                style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
              ),
            ),
          if (_actionError != null)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_actionError!, style: TextStyle(fontSize: 12, color: scheme.onErrorContainer)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _actionError = null),
                    color: scheme.onErrorContainer,
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
                      children: [
                        const SizedBox(height: 120),
                        Icon(Icons.inbox_outlined, size: 40, color: scheme.onSurface.withValues(alpha: 0.35)),
                        const SizedBox(height: 12),
                        Center(child: Text('No open offers right now.', style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6)))),
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
    final scheme = Theme.of(context).colorScheme;

    if (connecting) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (wallet == null) {
      return TextButton(onPressed: onTap, child: const Text('Connect wallet'));
    }
    final short = '${wallet!.address.substring(0, 10)}...';
    // Tapping copies the FULL address -- the label only ever shows a
    // short form, and a tester has no other way to get the real value
    // to ask for a testnet top-up. Same gap the web app already closed
    // with its own copy-address funding guidance.
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: wallet!.address));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Wallet address copied'), duration: Duration(seconds: 2)),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(short, style: bitshadaMono(context, fontSize: 10, color: scheme.onSurfaceVariant)),
                Text('${wallet!.balanceCkb.toStringAsFixed(2)} CKB',
                    style: bitshadaMono(context, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OfferCard extends StatefulWidget {
  final Offer offer;
  final Wallet? wallet;
  final VoidCallback onReserve;
  final VoidCallback onClaim;
  const _OfferCard({required this.offer, required this.wallet, required this.onReserve, required this.onClaim});

  @override
  State<_OfferCard> createState() => _OfferCardState();
}

/// Subtle fade + slide-up entrance, mirroring the web app's
/// `animate-fade-slide-up` CSS keyframe -- same motion language on both
/// surfaces, done here with Flutter's own implicit animations rather
/// than a new package.
class _OfferCardState extends State<_OfferCard> {
  double _opacity = 0;
  double _dy = 6;

  @override
  void initState() {
    super.initState();
    // Skip the entrance motion entirely when the system's reduced-motion
    // accessibility setting is on, instead of just shortening it.
    if (WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations) {
      _opacity = 1;
      _dy = 0;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() { _opacity = 1; _dy = 0; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final offer = widget.offer;
    final wallet = widget.wallet;
    final isOpen = offer.status == 'open';
    final statusColor = isOpen ? scheme.primary : scheme.secondary;
    final canReserve = wallet != null && isOpen;
    final canClaim = wallet != null && !isOpen && offer.reservedByLockHash == wallet.lockHash;
    final reservedByOther = !isOpen && (wallet == null || offer.reservedByLockHash != wallet.lockHash);

    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 250),
      child: AnimatedSlide(
        offset: Offset(0, _dy / 60),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        child: Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: scheme.outlineVariant),
          ),
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
                          Text(offer.status, style: bitshadaMono(context, fontSize: 11, fontWeight: FontWeight.w600, color: statusColor)),
                        ],
                      ),
                    ),
                    Text(offer.shortCell, style: bitshadaMono(context, fontSize: 11, color: scheme.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${offer.amountKes.toStringAsFixed(2)} KES', style: bitshadaMono(context, fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${offer.capacityCkb.toStringAsFixed(2)} CKB locked in escrow',
                    style: bitshadaMono(context, fontSize: 13, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text('Recipient: ${offer.shortRecipient}', style: bitshadaMono(context, fontSize: 11, color: scheme.onSurfaceVariant)),
                if (canReserve || canClaim || reservedByOther) ...[
                  const SizedBox(height: 10),
                  if (canReserve)
                    SizedBox(width: double.infinity, height: 48, child: FilledButton(onPressed: widget.onReserve, child: const Text('Reserve'))),
                  if (canClaim)
                    SizedBox(width: double.infinity, height: 48, child: FilledButton(onPressed: widget.onClaim, child: const Text('Claim'))),
                  if (reservedByOther)
                    Center(child: Text('Reserved by another buyer', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
                ],
              ],
            ),
          ),
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
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      children: [
        const SizedBox(height: 80),
        Icon(Icons.error_outline, size: 40, color: scheme.error),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text('Could not reach Bitshada: $error', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 16),
        Center(child: FilledButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}
