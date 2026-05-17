import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/boost.dart';
import '../services/auth_service.dart';
import '../services/profile_service.dart';

// ──────────────────────────────────────────────────────────
// Default catalogue shown when the server hasn't returned any
// boost definitions (SQL not run, unauthenticated, etc.).
// Keys / values must match what setup.sql seeds into boost_definitions.
// ──────────────────────────────────────────────────────────
const _boostDefaults = [
  // ---------- MASS ----------
  (
    key: 'mass_x2_5m',
    type: 'mass',
    name: '2× Mass – 5 min',
    multiplier: 2.0,
    durationSeconds: 300,
    priceCoins: 200,
    priceDna: 0,
  ),
  (
    key: 'mass_x2_30m',
    type: 'mass',
    name: '2× Mass – 30 min',
    multiplier: 2.0,
    durationSeconds: 1800,
    priceCoins: 1000,
    priceDna: 0,
  ),
  (
    key: 'mass_x3_1h',
    type: 'mass',
    name: '3× Mass – 1 hour',
    multiplier: 3.0,
    durationSeconds: 3600,
    priceCoins: 0,
    priceDna: 5,
  ),
  // ---------- XP ----------
  (
    key: 'xp_x2_5m',
    type: 'xp',
    name: '2× XP – 5 min',
    multiplier: 2.0,
    durationSeconds: 300,
    priceCoins: 150,
    priceDna: 0,
  ),
  (
    key: 'xp_x2_30m',
    type: 'xp',
    name: '2× XP – 30 min',
    multiplier: 2.0,
    durationSeconds: 1800,
    priceCoins: 800,
    priceDna: 0,
  ),
  (
    key: 'xp_x3_1h',
    type: 'xp',
    name: '3× XP – 1 hour',
    multiplier: 3.0,
    durationSeconds: 3600,
    priceCoins: 0,
    priceDna: 3,
  ),
];

List<BoostInventoryEntry> _defaultInventoryFor(String type) {
  return [
    for (final d in _boostDefaults)
      if (d.type == type)
        BoostInventoryEntry(
          def: BoostDefinition(
            id: d.key,
            key: d.key,
            name: d.name,
            type: d.type,
            multiplier: d.multiplier,
            durationSeconds: d.durationSeconds,
            priceCoins: d.priceCoins,
            priceDna: d.priceDna,
          ),
          quantity: 0,
          activeExpiresAt: null,
        ),
  ];
}

/// Modal sheet that shows only Mass OR only XP boost SKUs.
/// Caller passes the [type] ('mass' | 'xp') and the panel pulls the rest
/// from [AuthService.boostInventory].
class BoostPanel extends StatefulWidget {
  const BoostPanel({super.key, required this.type});
  final String type;

  static Future<void> show(BuildContext context, String type) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => BoostPanel(type: type),
    );
  }

  @override
  State<BoostPanel> createState() => _BoostPanelState();
}

class _BoostPanelState extends State<BoostPanel> {
  static final _fmt = NumberFormat.decimalPattern('en_US');
  String? _busyKey;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    AuthService.instance.refreshActiveBoosts();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  bool get _isMass => widget.type == 'mass';

  Color get _accent =>
      _isMass ? const Color(0xFFFF6A00) : const Color(0xFF00C8E0);

  Future<void> _buy(String key) async {
    if (_busyKey != null) return;
    setState(() => _busyKey = key);
    try {
      await ProfileService.instance.buyBoost(key);
      await AuthService.instance.refreshProfile();
      await AuthService.instance.refreshActiveBoosts();
    } catch (e) {
      if (mounted) _snack(_humanError(e));
    }
    if (mounted) setState(() => _busyKey = null);
  }

  Future<void> _activate(String key) async {
    if (_busyKey != null) return;
    setState(() => _busyKey = key);
    try {
      await ProfileService.instance.activateBoost(key);
      await AuthService.instance.refreshActiveBoosts();
    } catch (e) {
      if (mounted) _snack(_humanError(e));
    }
    if (mounted) setState(() => _busyKey = null);
  }

  String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('Not enough Coins')) return 'Not enough Coins.';
    if (s.contains('Not enough DNA')) return 'Not enough DNA.';
    if (s.contains("don't own")) return "You don't own this boost yet.";
    if (s.contains('already have an active')) {
      return _isMass
          ? 'You already have an active Mass Boost.'
          : 'You already have an active XP Boost.';
    }
    return s
        .replaceAll('Exception: ', '')
        .replaceAll('PostgrestException(message: ', '')
        .replaceAll(RegExp(r', code:.*$'), '');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF1B1247),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use server inventory when available; fall back to the hardcoded
    // catalogue so the store is always visible even before SQL migrations
    // have been run or while the user is unauthenticated.
    final serverInv = AuthService.instance.boostInventory
        .where((e) => e.def.type == widget.type)
        .toList();
    final inv = serverInv.isNotEmpty
        ? serverInv
        : _defaultInventoryFor(widget.type);
    // Sort: active first, then most-owned, then cheapest.
    inv.sort((a, b) {
      final aActive = a.isActive ? 0 : 1;
      final bActive = b.isActive ? 0 : 1;
      if (aActive != bActive) return aActive - bActive;
      if (b.quantity != a.quantity) return b.quantity - a.quantity;
      return (a.def.priceCoins + a.def.priceDna * 10) -
          (b.def.priceCoins + b.def.priceDna * 10);
    });

    final active = inv.firstWhere(
      (e) => e.isActive,
      orElse: () => inv.isEmpty
          ? BoostInventoryEntry(
              def: BoostDefinition(
                id: '',
                key: '',
                name: '',
                type: widget.type,
                multiplier: 1,
                durationSeconds: 0,
                priceCoins: 0,
                priceDna: 0,
              ),
              quantity: 0,
              activeExpiresAt: null,
            )
          : inv.first,
    );

    return AnimatedBuilder(
      animation: AuthService.instance,
      builder: (context, _) {
        return SafeArea(
          top: false,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xE60E0E2A),
                      const Color(0xE6181233),
                      const Color(0xE61E3556),
                    ],
                  ),
                  border: Border(
                    top: BorderSide(
                      color: _accent.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _grabber(),
                      const SizedBox(height: 6),
                      _header(),
                      const SizedBox(height: 10),
                      if (active.isActive) _activeBanner(active),
                      const SizedBox(height: 8),
                      Flexible(child: _list(inv)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _grabber() => Container(
        width: 44,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(4),
        ),
      );

  Widget _header() {
    final profile = AuthService.instance.profile;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              _accent,
              _accent.withValues(alpha: 0.6),
            ]),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.5),
                blurRadius: 14,
              ),
            ],
          ),
          child: Icon(
            _isMass ? Icons.fitness_center : Icons.bolt,
            color: Colors.white,
            size: 20,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _isMass ? 'Mass Boosts' : 'XP Boosts',
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ),
        _balancePill(
          icon: Icons.bubble_chart,
          color: const Color(0xFFFFD60A),
          value: profile?.dna ?? 0,
        ),
        const SizedBox(width: 6),
        _balancePill(
          icon: Icons.monetization_on,
          color: const Color(0xFF34C924),
          value: profile?.coins ?? 0,
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white70, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _balancePill({
    required IconData icon,
    required Color color,
    required int value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            _fmt.format(value),
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _activeBanner(BoostInventoryEntry e) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          _accent.withValues(alpha: 0.28),
          _accent.withValues(alpha: 0.08),
        ]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.55), width: 1),
      ),
      child: Row(
        children: [
          Icon(
            _isMass ? Icons.fitness_center : Icons.bolt,
            color: _accent,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_mult(e.def.multiplier)}× Active',
                  style: GoogleFonts.baloo2(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  'Ends in ${_formatCountdown(e.remaining)}',
                  style: GoogleFonts.baloo2(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'ACTIVE',
              style: GoogleFonts.baloo2(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(List<BoostInventoryEntry> items) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            'No boosts of this type available yet.',
            style: GoogleFonts.baloo2(
              color: Colors.white60,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      itemCount: items.length,
      separatorBuilder: (ctx, idx) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _row(items[i]),
    );
  }

  Widget _row(BoostInventoryEntry e) {
    final profile = AuthService.instance.profile;
    final coins = profile?.coins ?? 0;
    final dna = profile?.dna ?? 0;
    final affordable = e.def.priceCoins > 0
        ? coins >= e.def.priceCoins
        : dna >= e.def.priceDna;
    final sameTypeAlreadyActive = AuthService.instance.boostInventory.any(
      (entry) => entry.def.type == widget.type && entry.isActive,
    );
    final canActivate = e.quantity > 0 && !sameTypeAlreadyActive;
    final busy = _busyKey == e.def.key;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.10), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _iconBadge(e),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_mult(e.def.multiplier)}× ${_isMass ? 'Mass' : 'XP'} Boost',
                      style: GoogleFonts.baloo2(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      _durationLabel(e.def.durationSeconds),
                      style: GoogleFonts.baloo2(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _ownedPill(e.quantity),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _pricePill(e.def),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  label: 'BUY',
                  enabled: affordable && !busy,
                  busy: busy && _busyKey == e.def.key,
                  onTap: () => _buy(e.def.key),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _actionButton(
                  label: sameTypeAlreadyActive ? 'ACTIVE' : 'USE',
                  enabled: canActivate && !busy,
                  busy: busy && _busyKey == e.def.key,
                  onTap: () => _activate(e.def.key),
                  primary: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconBadge(BoostInventoryEntry e) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          _accent.withValues(alpha: 0.95),
          _accent.withValues(alpha: 0.55),
        ]),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: _accent.withValues(alpha: 0.4), blurRadius: 10),
        ],
      ),
      child: Center(
        child: Icon(
          _isMass ? Icons.fitness_center : Icons.bolt,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }

  Widget _ownedPill(int qty) {
    final empty = qty <= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: empty
            ? Colors.white.withValues(alpha: 0.05)
            : _accent.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: empty
                ? Colors.white.withValues(alpha: 0.15)
                : _accent.withValues(alpha: 0.5),
            width: 1),
      ),
      child: Text(
        'Owned $qty',
        style: GoogleFonts.baloo2(
          color: empty ? Colors.white54 : Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _pricePill(BoostDefinition def) {
    final isDna = def.priceDna > 0;
    final value = isDna ? def.priceDna : def.priceCoins;
    final color = isDna ? const Color(0xFFFFD60A) : const Color(0xFF34C924);
    final icon = isDna ? Icons.bubble_chart : Icons.monetization_on;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            _fmt.format(value),
            style: GoogleFonts.baloo2(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required bool enabled,
    required bool busy,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final base = primary
        ? LinearGradient(colors: [_accent, _accent.withValues(alpha: 0.7)])
        : LinearGradient(colors: [
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.06),
          ]);
    final disabledBase = const LinearGradient(
      colors: [Color(0xFF3B3B58), Color(0xFF2A2A40)],
    );
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 38,
        decoration: BoxDecoration(
          gradient: enabled ? base : disabledBase,
          borderRadius: BorderRadius.circular(10),
          boxShadow: enabled && primary
              ? [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.45),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                label,
                style: GoogleFonts.baloo2(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
      ),
    );
  }

  static String _mult(double m) =>
      m % 1 == 0 ? m.toStringAsFixed(0) : m.toStringAsFixed(1);

  static String _durationLabel(int seconds) {
    if (seconds >= 3600) {
      final h = seconds / 3600;
      return h == h.toInt()
          ? '${h.toInt()} hour${h == 1 ? '' : 's'}'
          : '${h.toStringAsFixed(1)}h';
    }
    final m = (seconds / 60).round();
    return '$m min';
  }

  static String _formatCountdown(Duration d) {
    if (d.inSeconds <= 0) return '00:00';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
