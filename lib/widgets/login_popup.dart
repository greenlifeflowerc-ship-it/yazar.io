import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/auth_service.dart';

enum _Mode { signIn, signUp }

class LoginPopup extends StatefulWidget {
  const LoginPopup({super.key, this.dismissible = true});
  final bool dismissible;

  static Future<void> show(BuildContext context, {bool dismissible = true}) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: dismissible,
      barrierLabel: 'login',
      barrierColor: Colors.black.withValues(alpha: 0.65),
      pageBuilder: (ctx, a, b) => LoginPopup(dismissible: dismissible),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (ctx, anim, b, child) {
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0)
                .chain(CurveTween(curve: Curves.easeOutCubic))
                .animate(anim),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<LoginPopup> createState() => _LoginPopupState();
}

class _LoginPopupState extends State<LoginPopup> {
  final _emailCtl = TextEditingController();
  final _pwdCtl = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  bool _hidePwd = true;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _emailCtl.dispose();
    _pwdCtl.dispose();
    super.dispose();
  }

  bool _isValidEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

  Future<void> _submit() async {
    if (!_isValidEmail(_emailCtl.text)) {
      setState(() => _error = 'Enter a valid email');
      return;
    }
    if (_pwdCtl.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      if (_mode == _Mode.signIn) {
        final ok = await AuthService.instance.signInWithPassword(
          email: _emailCtl.text,
          password: _pwdCtl.text,
        );
        if (!mounted) return;
        if (ok) {
          Navigator.of(context).pop(true);
          return;
        }
        // Edge case: session null but no exception — usually means email
        // not yet confirmed.
        setState(() =>
            _error = 'Email not confirmed yet. Check your inbox.');
      } else {
        final ok = await AuthService.instance.signUp(
          email: _emailCtl.text,
          password: _pwdCtl.text,
        );
        if (!mounted) return;
        if (ok) {
          Navigator.of(context).pop(true);
          return;
        }
        // Confirmation email path.
        setState(() {
          _info =
              'Account created. Check ${_emailCtl.text} to confirm, then sign in.';
          _mode = _Mode.signIn;
        });
      }
    } catch (e) {
      setState(() => _error = _humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('Invalid login credentials')) {
      return 'Wrong email or password.';
    }
    if (s.contains('User already registered') ||
        s.contains('user_already_exists')) {
      return 'An account with that email already exists. Try signing in.';
    }
    if (s.contains('Email not confirmed')) {
      return 'Email not confirmed yet. Check your inbox.';
    }
    if (s.contains('Password should be at least')) {
      return 'Password must be at least 6 characters.';
    }
    if (s.contains('rate limit') ||
        s.contains('over_email_send_rate_limit')) {
      return 'Too many requests, please wait a minute.';
    }
    return s
        .replaceAll('Exception: ', '')
        .replaceAll('AuthException: ', '')
        .replaceAll('AuthApiException(message: ', '')
        .replaceAll(RegExp(r', statusCode:.*$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xE6181233),
                        Color(0xE60E2147),
                        Color(0xE61E3556),
                      ],
                    ),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                        width: 1),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                  child: _form(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 12),
        _modeTabs(),
        const SizedBox(height: 12),
        _label('Email'),
        _input(
          controller: _emailCtl,
          hint: 'you@example.com',
          keyboardType: TextInputType.emailAddress,
          autofill: const [AutofillHints.email],
        ),
        const SizedBox(height: 10),
        _label('Password'),
        _passwordField(),
        if (_error != null) ...[
          const SizedBox(height: 10),
          _bar(_error!, const Color(0xFFFF4D5E), Icons.error_outline),
        ],
        if (_info != null && _error == null) ...[
          const SizedBox(height: 10),
          _bar(_info!, const Color(0xFF34C924), Icons.check_circle_outline),
        ],
        const SizedBox(height: 14),
        _primaryButton(),
      ],
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFA63CFF), Color(0xFF1E9BFF)],
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFA63CFF).withValues(alpha: 0.5),
                blurRadius: 16,
              ),
            ],
          ),
          child:
              const Icon(Icons.shield_moon, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Save Your Progress',
                style: GoogleFonts.baloo2(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                _mode == _Mode.signIn
                    ? 'Sign in with email + password to keep your coins, DNA, XP, level, skins, boosts and achievements.'
                    : 'Create an account to save your coins, DNA, XP, level, boosts, skins and match history.',
                style: GoogleFonts.baloo2(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (widget.dismissible)
          IconButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close,
                color: Colors.white70, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
      ],
    );
  }

  Widget _modeTabs() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.10), width: 1),
      ),
      child: Row(
        children: [
          _tab('SIGN IN', _mode == _Mode.signIn,
              () => _setMode(_Mode.signIn)),
          _tab('SIGN UP', _mode == _Mode.signUp,
              () => _setMode(_Mode.signUp)),
        ],
      ),
    );
  }

  Widget _tab(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _busy ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 32,
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(colors: [
                    Color(0xFFA63CFF),
                    Color(0xFF1E9BFF),
                  ])
                : null,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.baloo2(
              color: selected ? Colors.white : Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  void _setMode(_Mode m) {
    if (_busy || _mode == m) return;
    setState(() {
      _mode = m;
      _error = null;
      _info = null;
    });
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: GoogleFonts.baloo2(
            color: Colors.white60,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _input({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboardType,
    Iterable<String>? autofill,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.15), width: 1),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        autofillHints: autofill,
        enabled: !_busy,
        style: GoogleFonts.baloo2(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          isCollapsed: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hintText: hint,
          hintStyle: GoogleFonts.baloo2(
            color: Colors.white30,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _passwordField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.15), width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _pwdCtl,
              obscureText: _hidePwd,
              enabled: !_busy,
              autofillHints: _mode == _Mode.signIn
                  ? const [AutofillHints.password]
                  : const [AutofillHints.newPassword],
              style: GoogleFonts.baloo2(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                hintText: _mode == _Mode.signIn
                    ? 'Your password'
                    : 'At least 6 characters',
                hintStyle: GoogleFonts.baloo2(
                  color: Colors.white30,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          IconButton(
            tooltip: _hidePwd ? 'Show password' : 'Hide password',
            onPressed: _busy
                ? null
                : () => setState(() => _hidePwd = !_hidePwd),
            icon: Icon(
              _hidePwd ? Icons.visibility_off : Icons.visibility,
              color: Colors.white54,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(String text, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.baloo2(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _primaryButton() {
    final label = _mode == _Mode.signIn ? 'SIGN IN' : 'CREATE ACCOUNT';
    return GestureDetector(
      onTap: _busy ? null : _submit,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 50,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: _busy
                ? [const Color(0xFF555575), const Color(0xFF6E6E92)]
                : [
                    const Color(0xFFA63CFF),
                    const Color(0xFF1E9BFF),
                    const Color(0xFF00C8E0),
                  ],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: _busy
              ? []
              : [
                  BoxShadow(
                    color: const Color(0xFF1E9BFF).withValues(alpha: 0.45),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        alignment: Alignment.center,
        child: _busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                label,
                style: GoogleFonts.baloo2(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
      ),
    );
  }
}
