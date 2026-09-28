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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: _AttentionBox(
              icon: Icons.science_outlined,
              color: scheme.tertiary,
              text: 'Testnet pilot -- test CKB only, no real money.',
            ),
          ),
          if (_connectedWallet != null && _connectedWallet!.balanceCkb < 10)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: _AttentionBox(
                icon: Icons.info_outline,
                color: scheme.secondary,
                text: 'Your wallet needs testnet CKB. Tap your balance above to copy the address, then email it to '
                    'kenneth.njoroge@quantumke.org for a top-up.',
              ),
            ),
          if (_actionError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: _AttentionBox(
                icon: Icons.error_outline,
                color: scheme.error,
                text: _actionError!,
                onDismiss: () => setState(() => _actionError = null),
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

/// Dashed-border outlined notice, inspired by the "Attention" pattern in
/// dark-mode P2P crypto app references: an outline on the dark surface
/// reads as a warning without the heavier solid-fill container blocks
/// used before, which felt more like a full-width toast than an inline
/// notice.
class _AttentionBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onDismiss;
  const _AttentionBox({required this.icon, required this.color, required this.text, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DottedBorderBox(
      color: color.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: scheme.onSurface, height: 1.35))),
            if (onDismiss != null)
              InkWell(
                onTap: onDismiss,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 16, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A dashed rounded-rect border, drawn with CustomPaint since Flutter has
/// no built-in dashed BoxBorder -- lightweight, no new package needed.
class DottedBorderBox extends StatelessWidget {
  final Color color;
  final Widget child;
  const DottedBorderBox({required this.color, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(color: color),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  _DashedRRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    const dashWidth = 5.0;
    const gapWidth = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        canvas.drawPath(metric.extractPath(distance, next.clamp(0, metric.length)), paint);
        distance = next + gapWidth;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) => oldDelegate.color != color;
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
                // Leading circular status badge + amount, mirroring the
                // avatar-led row pattern from the P2P marketplace
                // reference -- a badge reads faster than a text pill at a
                // glance down a list.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.16), shape: BoxShape.circle),
                      child: Icon(isOpen ? Icons.lock_open_rounded : Icons.hourglass_top_rounded, size: 18, color: statusColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(offer.status.toUpperCase(),
                              style: bitshadaMono(context, fontSize: 10.5, fontWeight: FontWeight.w600, color: statusColor)),
                          Text('${offer.amountKes.toStringAsFixed(2)} KES',
                              style: bitshadaMono(context, fontSize: 21, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    Text(offer.shortCell, style: bitshadaMono(context, fontSize: 10.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 12),
                // Receipt-style label/value rows, same convention the
                // reference uses for Crypto/Value/FIAT Value.
                _DetailRow(label: 'Locked in escrow', value: '${offer.capacityCkb.toStringAsFixed(2)} CKB'),
                const SizedBox(height: 6),
                _DetailRow(label: 'Recipient', value: offer.shortRecipient),
                if (canReserve || canClaim || reservedByOther) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (reservedByOther)
                        Expanded(
                          child: Text('Reserved by another buyer',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                        ),
                      if (canReserve)
                        SizedBox(
                          height: 44,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 22),
                                shape: const StadiumBorder()),
                            onPressed: widget.onReserve,
                            child: const Text('Reserve'),
                          ),
                        ),
                      if (canClaim)
                        SizedBox(
                          height: 44,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 22),
                                shape: const StadiumBorder()),
                            onPressed: widget.onClaim,
                            child: const Text('Claim'),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted label / bold mono value row, the receipt-style detail line used
/// throughout the P2P reference's payment/order screens.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        Text(value, style: bitshadaMono(context, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ],
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
