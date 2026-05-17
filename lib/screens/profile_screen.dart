import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/match_history_entry.dart';
import '../models/player_stats.dart';
import '../models/profile.dart';
import '../services/auth_service.dart';
import '../services/profile_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late int _tab = widget.initialTab.clamp(0, 4);

  // Tab data caches
  PlayerStats? _stats;
  List<MatchHistoryEntry>? _history;
  List<Map<String, dynamic>>? _inventory;
  List<Map<String, dynamic>>? _achievements;

  bool _loadingStats = false;
  bool _loadingHistory = false;
  bool _loadingInventory = false;
  bool _loadingAchievements = false;

  static final _fmt = NumberFormat.decimalPattern('en_US');

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    _loadStats();
    _loadHistory();
    _loadInventory();
    _loadAchievements();
  }

  Future<void> _loadStats() async {
    setState(() => _loadingStats = true);
    try {
      _stats = await ProfileService.instance.fetchStats();
    } catch (_) {
      _stats = null;
    }
    if (mounted) setState(() => _loadingStats = false);
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      _history = await ProfileService.instance.fetchMatchHistory();
    } catch (_) {
      _history = null;
    }
    if (mounted) setState(() => _loadingHistory = false);
  }

  Future<void> _loadInventory() async {
    setState(() => _loadingInventory = true);
    try {
      _inventory = await ProfileService.instance.fetchInventory();
    } catch (_) {
      _inventory = null;
    }
    if (mounted) setState(() => _loadingInventory = false);
  }

  Future<void> _loadAchievements() async {
    setState(() => _loadingAchievements = true);
    try {
      _achievements = await ProfileService.instance.fetchAchievements();
    } catch (_) {
      _achievements = null;
    }
    if (mounted) setState(() => _loadingAchievements = false);
  }

  Future<void> _logout() async {
    await AuthService.instance.signOut();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E2A),
      body: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: AuthService.instance,
          builder: (context, _) {
            final profile = AuthService.instance.profile;
            return Stack(
              children: [
                _backgroundGradient(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                  child: Column(
                    children: [
                      _topBar(),
                      const SizedBox(height: 8),
                      _headerCard(profile),
                      const SizedBox(height: 10),
                      _tabBar(),
                      const SizedBox(height: 8),
                      Expanded(child: _tabContent(profile)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _backgroundGradient() {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF0A0E2A),
              const Color(0xFF1B1247),
              const Color(0xFF0E2147),
              const Color(0xFF0A1E3A),
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: -80,
              top: -60,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    const Color(0xFFA63CFF).withValues(alpha: 0.5),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
            Positioned(
              right: -100,
              bottom: -80,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    const Color(0xFF00C8E0).withValues(alpha: 0.45),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        _circleAction(Icons.arrow_back, () => Navigator.of(context).pop()),
        const SizedBox(width: 12),
        Text(
          'PROFILE',
          style: GoogleFonts.baloo2(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.logout, size: 16, color: Color(0xFFFF4D5E)),
          label: Text(
            'LOGOUT',
            style: GoogleFonts.baloo2(
              color: const Color(0xFFFF4D5E),
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ],
    );
  }

  Widget _circleAction(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFA63CFF), Color(0xFF1E9BFF)],
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFA63CFF).withValues(alpha: 0.4),
              blurRadius: 10,
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }

  Widget _headerCard(Profile? profile) {
    return _glassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          _avatar(profile),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile?.displayName ?? '—',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.baloo2(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  profile?.email ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.baloo2(
                    color: Colors.white60,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _xpBar(profile),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _currencyPill(
            icon: Icons.bubble_chart,
            value: profile?.dna ?? 0,
            color: const Color(0xFFFFD60A),
          ),
          const SizedBox(width: 6),
          _currencyPill(
            icon: Icons.monetization_on,
            value: profile?.coins ?? 0,
            color: const Color(0xFF34C924),
          ),
        ],
      ),
    );
  }

  Widget _avatar(Profile? profile) {
    final level = profile?.level ?? 1;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFFA63CFF), Color(0xFF1E9BFF)],
            ),
            border: Border.all(color: Colors.white24, width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFA63CFF).withValues(alpha: 0.5),
                blurRadius: 18,
              ),
            ],
          ),
          child: const Icon(Icons.person, color: Colors.white, size: 32),
        ),
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFFC107), Color(0xFFFF6A00)],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF0A0E2A), width: 2),
            ),
            child: Text(
              'LV $level',
              style: GoogleFonts.baloo2(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _xpBar(Profile? profile) {
    final progress = profile?.xpProgress ?? 0.0;
    final xp = profile?.xp ?? 0;
    final need = profile?.xpForNextLevel ?? 100;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('XP',
                style: GoogleFonts.baloo2(
                    color: Colors.white60,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1)),
            const Spacer(),
            Text(
              '${_fmt.format(xp)} / ${_fmt.format(need)}',
              style: GoogleFonts.baloo2(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Container(
                height: 8,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              FractionallySizedBox(
                widthFactor: progress,
                child: Container(
                  height: 8,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [
                      Color(0xFFA63CFF),
                      Color(0xFF1E9BFF),
                      Color(0xFF00C8E0),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _currencyPill({
    required IconData icon,
    required int value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 5),
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

  // ----------------------------------------------------------------- tabs
  Widget _tabBar() {
    const labels = ['Overview', 'Stats', 'Inventory', 'Achievements', 'History'];
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _tab = i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    gradient: _tab == i
                        ? const LinearGradient(colors: [
                            Color(0xFFA63CFF),
                            Color(0xFF1E9BFF),
                          ])
                        : null,
                    color: _tab == i ? null : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _tab == i
                          ? Colors.transparent
                          : Colors.white.withValues(alpha: 0.10),
                      width: 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i].toUpperCase(),
                    style: GoogleFonts.baloo2(
                      color: _tab == i ? Colors.white : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabContent(Profile? profile) {
    switch (_tab) {
      case 0:
        return _overviewTab(profile);
      case 1:
        return _statsTab();
      case 2:
        return _inventoryTab();
      case 3:
        return _achievementsTab();
      case 4:
        return _historyTab();
    }
    return const SizedBox.shrink();
  }

  Widget _overviewTab(Profile? profile) {
    final s = _stats;
    return SingleChildScrollView(
      child: Column(
        children: [
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.6,
            children: [
              _statTile('Matches', _fmt.format(s?.matchesPlayed ?? 0),
                  Icons.flag, const Color(0xFF1E9BFF)),
              _statTile('Best Score', _fmt.format(s?.bestScore ?? 0),
                  Icons.emoji_events, const Color(0xFFFFC107)),
              _statTile('Kills', _fmt.format(s?.totalKills ?? 0),
                  Icons.bolt, const Color(0xFFFF6A00)),
              _statTile('Deaths', _fmt.format(s?.totalDeaths ?? 0),
                  Icons.heart_broken, const Color(0xFFFF4D5E)),
            ],
          ),
          const SizedBox(height: 10),
          _glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('SUMMARY'),
                const SizedBox(height: 8),
                _kv('Level', '${profile?.level ?? 1}'),
                _kv('XP', _fmt.format(profile?.xp ?? 0)),
                _kv('Coins', _fmt.format(profile?.coins ?? 0)),
                _kv('DNA', _fmt.format(profile?.dna ?? 0)),
                _kv('Wins', _fmt.format(s?.wins ?? 0)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsTab() {
    if (_loadingStats) return _loading();
    final s = _stats;
    if (s == null) return _empty('No stats yet — play a match to populate this.');
    return SingleChildScrollView(
      child: _glassCard(
        child: Column(
          children: [
            _sectionTitle('PLAYER STATS'),
            const SizedBox(height: 8),
            _kv('Matches played', _fmt.format(s.matchesPlayed)),
            _kv('Wins', _fmt.format(s.wins)),
            _kv('Best score', _fmt.format(s.bestScore)),
            _kv('Total score', _fmt.format(s.totalScore)),
            _kv('Total mass collected', _fmt.format(s.totalMassCollected)),
            _kv('Total kills/eats', _fmt.format(s.totalKills)),
            _kv('Total deaths', _fmt.format(s.totalDeaths)),
            _kv('Total playtime', _formatTime(s.totalSurvivalSeconds)),
          ],
        ),
      ),
    );
  }

  Widget _inventoryTab() {
    if (_loadingInventory) return _loading();
    final items = _inventory;
    if (items == null || items.isEmpty) {
      return _empty('Inventory is empty. Earn or buy items to fill it up.');
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final entry = items[i];
        final raw = entry['inventory_items'];
        final item = raw is Map ? raw.cast<String, dynamic>() : null;
        final name = item?['name'] as String? ?? 'Item';
        final equipped = entry['equipped'] == true;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: equipped
                    ? const Color(0xFF00C8E0)
                    : Colors.white.withValues(alpha: 0.1),
                width: equipped ? 2 : 1),
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.shield, color: Colors.white70, size: 24),
              const SizedBox(height: 4),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.baloo2(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _achievementsTab() {
    if (_loadingAchievements) return _loading();
    final list = _achievements;
    if (list == null || list.isEmpty) {
      return _empty('No achievements yet. Keep playing to unlock them.');
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (ctx, idx) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final entry = list[i];
        final raw = entry['achievements'];
        final ach = raw is Map ? raw.cast<String, dynamic>() : null;
        return _glassCard(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              const Icon(Icons.emoji_events,
                  color: Color(0xFFFFC107), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ach?['name'] as String? ?? 'Achievement',
                      style: GoogleFonts.baloo2(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      ach?['description'] as String? ?? '',
                      style: GoogleFonts.baloo2(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _historyTab() {
    if (_loadingHistory) return _loading();
    final list = _history;
    if (list == null || list.isEmpty) {
      return _empty('No matches played yet. Hit Classic to start.');
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (ctx, idx) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final m = list[i];
        return _glassCard(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [
                    Color(0xFFA63CFF),
                    Color(0xFF1E9BFF),
                  ]),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '#${m.rank}',
                  style: GoogleFonts.baloo2(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Score ${_fmt.format(m.score)} · ${m.kills} kills · ${_formatTime(m.survivalSeconds)}',
                      style: GoogleFonts.baloo2(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '+${m.xpEarned} XP · +${m.coinsEarned} coins · +${m.dnaEarned} DNA',
                      style: GoogleFonts.baloo2(
                        color: Colors.white60,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                DateFormat('MMM d, HH:mm').format(m.createdAt.toLocal()),
                style: GoogleFonts.baloo2(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- helpers
  Widget _glassCard({required Widget child, EdgeInsets? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.10), width: 1),
          ),
          padding:
              padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: child,
        ),
      ),
    );
  }

  Widget _statTile(String label, String value, IconData icon, Color color) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(),
                    style: GoogleFonts.baloo2(
                      color: Colors.white60,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    )),
                Text(value,
                    style: GoogleFonts.baloo2(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String label) => Text(
        label,
        style: GoogleFonts.baloo2(
          color: const Color(0xFF00C8E0),
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.4,
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(k,
                  style: GoogleFonts.baloo2(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  )),
            ),
            Text(v,
                style: GoogleFonts.baloo2(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                )),
          ],
        ),
      );

  Widget _loading() => const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1E9BFF)),
        ),
      );

  Widget _empty(String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined,
                  color: Colors.white.withValues(alpha: 0.4), size: 36),
              const SizedBox(height: 8),
              Text(
                msg,
                textAlign: TextAlign.center,
                style: GoogleFonts.baloo2(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );

  String _formatTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}
