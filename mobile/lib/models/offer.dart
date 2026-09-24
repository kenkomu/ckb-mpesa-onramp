/// Mirrors the JSON shape Web.Ckb.Offers/OffersController already
/// serve at GET /api/offers -- the same live API the web app's own
/// ckb.js consumes, decoded straight from real mpesa-escrow cells on
/// chain (see web/lib/web/ckb/offers.ex). No mock data anywhere here.
class Offer {
  final String status; // "open" | "reserved"
  final int amountKesMinorUnits;
  final String recipientHash;
  final String outPointTxHash;
  final String outPointIndex;
  final int capacityShannon;
  final String witnessAddress;
  final String registryTypeHash;
  final String offerGuardTypeHash;
  final String? reservedByLockHash;

  Offer({
    required this.status,
    required this.amountKesMinorUnits,
    required this.recipientHash,
    required this.outPointTxHash,
    required this.outPointIndex,
    required this.capacityShannon,
    required this.witnessAddress,
    required this.registryTypeHash,
    required this.offerGuardTypeHash,
    required this.reservedByLockHash,
  });

  factory Offer.fromJson(Map<String, dynamic> json) {
    final outPoint = json['out_point'] as Map<String, dynamic>;
    return Offer(
      status: json['status'] as String,
      amountKesMinorUnits: json['amount'] as int,
      recipientHash: json['recipient_hash'] as String,
      outPointTxHash: outPoint['tx_hash'] as String,
      outPointIndex: outPoint['index'] as String,
      capacityShannon: json['capacity_shannon'] as int,
      witnessAddress: json['witness_address'] as String,
      registryTypeHash: json['registry_type_hash'] as String,
      offerGuardTypeHash: json['offer_guard_type_hash'] as String,
      reservedByLockHash: json['reserved_by_lock_hash'] as String?,
    );
  }

  double get amountKes => amountKesMinorUnits / 100;
  double get capacityCkb => capacityShannon / 100000000;

  String get shortCell {
    final hash = outPointTxHash.substring(0, 10);
    final idx = int.parse(outPointIndex.substring(2), radix: 16);
    return '$hash...:$idx';
  }

  String get shortRecipient => '${recipientHash.substring(0, 10)}...';
}
