import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp().timeout(const Duration(seconds: 8));
    AuthBackupService.firebaseReady = true;
  } catch (e) {
    // App must open even if Firebase web/android config is missing or internet is slow.
    AuthBackupService.firebaseReady = false;
    debugPrint('Firebase init skipped: $e');
  }

  runApp(const MasumCalcApp());
}

class MasumCalcApp extends StatelessWidget {
  const MasumCalcApp({super.key});

  @override
  Widget build(BuildContext context) => const CalculatorRoot();
}

class CalculatorRoot extends StatefulWidget {
  const CalculatorRoot({super.key});

  @override
  State<CalculatorRoot> createState() => _CalculatorRootState();
}

class _CalculatorRootState extends State<CalculatorRoot> {
  bool darkMode = true;

  @override
  void initState() {
    super.initState();
    loadTheme();
  }

  Future<void> loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => darkMode = prefs.getBool('dark_mode') ?? true);
  }

  Future<void> changeTheme(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', value);
    AuthBackupService.scheduleAutoBackup();
    if (!mounted) return;
    setState(() => darkMode = value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Masum Smart Calculator Pro',
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      darkTheme: ThemeData.dark(useMaterial3: true),
      theme: ThemeData.light(useMaterial3: true),
      home: PinLockGate(
        darkMode: darkMode,
        child: CalculatorPage(darkMode: darkMode, onThemeChanged: changeTheme),
      ),
    );
  }
}

class AutoHistoryItem {
  final String expression;
  final String result;
  final DateTime dateTime;
  bool isDeleted;
  bool isFavorite;

  AutoHistoryItem({required this.expression, required this.result, required this.dateTime, this.isDeleted = false, this.isFavorite = false});

  Map<String, dynamic> toJson() => {
        'expression': expression,
        'result': result,
        'dateTime': dateTime.toIso8601String(),
        'isDeleted': isDeleted,
        'isFavorite': isFavorite,
      };

  factory AutoHistoryItem.fromJson(Map<String, dynamic> json) => AutoHistoryItem(
        expression: json['expression'] ?? '',
        result: json['result'] ?? '0',
        dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now(),
        isDeleted: json['isDeleted'] ?? false,
        isFavorite: json['isFavorite'] ?? false,
      );
}

class SavedCalculation {
  final String expression;
  final String result;
  final String personName;
  final String title;
  final String note;
  final DateTime dateTime;
  bool isDeleted;
  bool isFavorite;

  SavedCalculation({required this.expression, required this.result, required this.personName, required this.title, required this.note, required this.dateTime, this.isDeleted = false, this.isFavorite = false});

  Map<String, dynamic> toJson() => {
        'expression': expression,
        'result': result,
        'personName': personName,
        'title': title,
        'note': note,
        'dateTime': dateTime.toIso8601String(),
        'isDeleted': isDeleted,
        'isFavorite': isFavorite,
      };

  factory SavedCalculation.fromJson(Map<String, dynamic> json) => SavedCalculation(
        expression: json['expression'] ?? '',
        result: json['result'] ?? '0',
        personName: json['personName'] ?? 'No Name',
        title: json['title'] ?? 'Untitled',
        note: json['note'] ?? '',
        dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now(),
        isDeleted: json['isDeleted'] ?? false,
        isFavorite: json['isFavorite'] ?? false,
      );
}

class SmartToolHistoryItem {
  final String type;
  final String title;
  final String details;
  final DateTime dateTime;
  bool isDeleted;

  SmartToolHistoryItem({required this.type, required this.title, required this.details, required this.dateTime, this.isDeleted = false});

  Map<String, dynamic> toJson() => {
        'type': type,
        'title': title,
        'details': details,
        'dateTime': dateTime.toIso8601String(),
        'isDeleted': isDeleted,
      };

  factory SmartToolHistoryItem.fromJson(Map<String, dynamic> json) => SmartToolHistoryItem(
        type: json['type'] ?? 'Tool',
        title: json['title'] ?? '',
        details: json['details'] ?? '',
        dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now(),
        isDeleted: json['isDeleted'] ?? false,
      );
}

Future<void> saveSmartToolHistory(SmartToolHistoryItem item) async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList('smart_tool_history') ?? [];
  final encoded = jsonEncode(item.toJson());
  if (list.isNotEmpty && list.first == encoded) return;
  list.insert(0, encoded);
  if (list.length > 100) list.removeRange(100, list.length);
  await prefs.setStringList('smart_tool_history', list);
  AuthBackupService.scheduleAutoBackup();
}

Future<List<SmartToolHistoryItem>> loadSmartToolHistory() async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList('smart_tool_history') ?? [];
  return list.map((item) => SmartToolHistoryItem.fromJson(jsonDecode(item))).toList();
}


Future<void> saveSmartToolHistoryList(List<SmartToolHistoryItem> items) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('smart_tool_history', items.map((item) => jsonEncode(item.toJson())).toList());
  AuthBackupService.scheduleAutoBackup();
}

class AuthBackupService {
  static bool firebaseReady = false;
  static Timer? _autoBackupTimer;
  static bool _autoBackupRunning = false;

  static FirebaseAuth? get _auth {
    if (!firebaseReady) return null;
    try {
      return FirebaseAuth.instance;
    } catch (_) {
      return null;
    }
  }

  static FirebaseFirestore? get _db {
    if (!firebaseReady) return null;
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  static User? get currentUser {
    final auth = _auth;
    if (auth == null) return null;
    try {
      return auth.currentUser;
    } catch (_) {
      return null;
    }
  }

  static Stream<User?> get authChanges {
    final auth = _auth;
    if (auth == null) return Stream<User?>.value(null);
    try {
      return auth.authStateChanges();
    } catch (_) {
      return Stream<User?>.value(null);
    }
  }

  static void scheduleAutoBackup() {
    if (!firebaseReady || currentUser == null) return;
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer(const Duration(seconds: 2), () async {
      if (_autoBackupRunning || !firebaseReady || currentUser == null) return;
      _autoBackupRunning = true;
      try {
        await backupLocalData();
      } catch (_) {
        // Keep the app fast and silent if internet/firebase is off.
      } finally {
        _autoBackupRunning = false;
      }
    });
  }

  static Future<User?> signInWithGoogle({bool forceAccountPicker = false}) async {
    final auth = _auth;
    if (auth == null) {
      throw Exception('Firebase is not ready. Check Firebase web config first.');
    }

    final googleSignIn = GoogleSignIn();
    if (forceAccountPicker) {
      try {
        await googleSignIn.signOut();
      } catch (_) {}
    }

    final googleUser = await googleSignIn.signIn();
    if (googleUser == null) return null;

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final result = await auth.signInWithCredential(credential);
    return result.user;
  }

  static Future<void> signOut() async {
    _autoBackupTimer?.cancel();
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    final auth = _auth;
    if (auth != null) await auth.signOut();
  }

  static Future<Map<String, dynamic>> _collectLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'dark_mode': prefs.getBool('dark_mode') ?? true,
      'bangla_word': prefs.getBool('bangla_word') ?? false,
      'saved_calculations': prefs.getStringList('saved_calculations') ?? <String>[],
      'auto_history': prefs.getStringList('auto_history') ?? <String>[],
      'smart_tool_history': prefs.getStringList('smart_tool_history') ?? <String>[],
      'customer_notebook': prefs.getStringList('customer_notebook') ?? <String>[],
      'due_payment_records': prefs.getStringList('due_payment_records') ?? <String>[],
      'daily_cashbook_entries': prefs.getStringList('daily_cashbook_entries') ?? <String>[],
      'followup_reminders': prefs.getStringList('followup_reminders') ?? <String>[],
      'receipt_memos': prefs.getStringList('receipt_memos') ?? <String>[],
      'business_profile': prefs.getString('business_profile') ?? '',
      'pin_lock_enabled': prefs.getBool('pin_lock_enabled') ?? false,
      'pin_lock_hash': prefs.getString('pin_lock_hash') ?? '',
      'pin_lock_salt': prefs.getString('pin_lock_salt') ?? '',
      'pin_recovery_code_hash': prefs.getString('pin_recovery_code_hash') ?? '',
      'pin_recovery_code_salt': prefs.getString('pin_recovery_code_salt') ?? '',
      'pin_recovery_phone': prefs.getString('pin_recovery_phone') ?? '',
      'pin_recovery_phone_verified': prefs.getBool('pin_recovery_phone_verified') ?? false,
      'pin_recovery_email': prefs.getString('pin_recovery_email') ?? '',
      'pin_recovery_uid': prefs.getString('pin_recovery_uid') ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Future<void> backupLocalData() async {
    final user = currentUser;
    final db = _db;
    if (user == null || db == null) throw Exception('Please sign in first');
    final data = await _collectLocalData();
    await db.collection('user_backups').doc(user.uid).set(data, SetOptions(merge: true));
  }

  static Future<bool> restoreCloudData() async {
    final user = currentUser;
    final db = _db;
    if (user == null || db == null) throw Exception('Please sign in first');
    final doc = await db.collection('user_backups').doc(user.uid).get();
    if (!doc.exists) return false;

    final data = doc.data() ?? <String, dynamic>{};
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('dark_mode', data['dark_mode'] == true);
    await prefs.setBool('bangla_word', data['bangla_word'] == true);
    await prefs.setStringList('saved_calculations', List<String>.from(data['saved_calculations'] ?? const <String>[]));
    await prefs.setStringList('auto_history', List<String>.from(data['auto_history'] ?? const <String>[]));
    await prefs.setStringList('smart_tool_history', List<String>.from(data['smart_tool_history'] ?? const <String>[]));
    await prefs.setStringList('customer_notebook', List<String>.from(data['customer_notebook'] ?? const <String>[]));
    await prefs.setStringList('due_payment_records', List<String>.from(data['due_payment_records'] ?? const <String>[]));
    await prefs.setStringList('daily_cashbook_entries', List<String>.from(data['daily_cashbook_entries'] ?? const <String>[]));
    await prefs.setStringList('followup_reminders', List<String>.from(data['followup_reminders'] ?? const <String>[]));
    await prefs.setStringList('receipt_memos', List<String>.from(data['receipt_memos'] ?? const <String>[]));
    await prefs.setString('business_profile', data['business_profile'] ?? '');
    await prefs.setBool('pin_lock_enabled', data['pin_lock_enabled'] == true);
    await prefs.setString('pin_lock_hash', data['pin_lock_hash'] ?? '');
    await prefs.setString('pin_lock_salt', data['pin_lock_salt'] ?? '');
    await prefs.setString('pin_recovery_code_hash', data['pin_recovery_code_hash'] ?? '');
    await prefs.setString('pin_recovery_code_salt', data['pin_recovery_code_salt'] ?? '');
    await prefs.setString('pin_recovery_phone', data['pin_recovery_phone'] ?? '');
    await prefs.setBool('pin_recovery_phone_verified', data['pin_recovery_phone_verified'] == true);
    await prefs.setString('pin_recovery_email', data['pin_recovery_email'] ?? '');
    await prefs.setString('pin_recovery_uid', data['pin_recovery_uid'] ?? '');
    return true;
  }
}

Future<void> openExternalUrl(String url) async {
  final uri = Uri.parse(url);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    await launchUrl(uri, mode: LaunchMode.platformDefault);
  }
}

String safePdfFileName(String value) {
  final cleaned = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_|_\$'), '');
  return cleaned.isEmpty ? 'masum_report.pdf' : 'masum_${cleaned}_report.pdf';
}

String generateSecuritySalt() => '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';

String masumSecureHash(String value, String salt) {
  var hash = 2166136261;
  final input = utf8.encode('$salt|$value|masum_smart_calculator_pro');
  for (int round = 0; round < 12; round++) {
    for (final byte in input) {
      hash ^= byte;
      hash = (hash * 16777619) & 0x7fffffff;
      hash ^= (hash >> 13);
    }
  }
  return base64Url.encode(utf8.encode('$hash:$salt'));
}

String generateRecoveryCode() {
  final r = Random.secure();
  String part() => (1000 + r.nextInt(9000)).toString();
  return 'MASUM-${part()}-${part()}';
}

Future<bool> verifySavedPinCode(String pin) async {
  final prefs = await SharedPreferences.getInstance();
  final oldRawPin = prefs.getString('pin_lock_code') ?? '';
  if (oldRawPin.isNotEmpty && pin == oldRawPin) return true;
  final salt = prefs.getString('pin_lock_salt') ?? '';
  final hash = prefs.getString('pin_lock_hash') ?? '';
  return salt.isNotEmpty && hash.isNotEmpty && masumSecureHash(pin, salt) == hash;
}


String normalizeBangladeshPhone(String phone) {
  var p = phone.trim().replaceAll(RegExp(r'[^0-9+]'), '');
  if (p.startsWith('+')) return p;
  if (p.startsWith('880')) return '+$p';
  if (p.startsWith('0') && p.length >= 11) return '+88$p';
  return p;
}

Future<void> masumInfoDialog(BuildContext context, String title, String message) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK'))],
    ),
  );
}

Future<String?> masumInputDialog(
  BuildContext context, {
  required String title,
  required String hint,
  bool pin = false,
  TextInputType? keyboardType,
  int? maxLength,
  String initialValue = '',
}) async {
  if (!context.mounted) return null;
  final controller = TextEditingController(text: initialValue);
  String? output;
  try {
    output = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: pin,
          keyboardType: keyboardType ?? (pin ? TextInputType.number : TextInputType.text),
          maxLength: maxLength ?? (pin ? 4 : null),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hint, counterText: maxLength != null || pin ? '' : null),
          onSubmitted: (_) {
            FocusScope.of(dialogContext).unfocus();
            Navigator.of(dialogContext).pop(controller.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              FocusScope.of(dialogContext).unfocus();
              Navigator.of(dialogContext).pop(null);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              FocusScope.of(dialogContext).unfocus();
              Navigator.of(dialogContext).pop(controller.text.trim());
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  } finally {
    // Delay dispose so Flutter text input/keyboard can detach safely.
    // This prevents: '_dependents.isEmpty' red screen on some Android keyboards.
    Future.delayed(const Duration(milliseconds: 700), () {
      try {
        controller.dispose();
      } catch (_) {}
    });
  }
  await Future.delayed(const Duration(milliseconds: 260));
  return output;
}

Future<void> masumApplyPhoneCredential(PhoneAuthCredential credential) async {
  final auth = FirebaseAuth.instance;
  final current = auth.currentUser;
  if (current != null) {
    try {
      await current.linkWithCredential(credential);
      return;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'provider-already-linked') return;
      if (e.code == 'credential-already-in-use' || e.code == 'email-already-in-use') {
        await auth.signInWithCredential(credential);
        return;
      }
      rethrow;
    }
  }
  await auth.signInWithCredential(credential);
}

Future<bool> verifyPhoneOtpWithFirebase(BuildContext context, String rawPhone) async {
  final phone = normalizeBangladeshPhone(rawPhone);
  if (phone.isEmpty || !phone.startsWith('+')) {
    await masumInfoDialog(context, 'Invalid phone number', 'Phone number country code সহ দাও। Bangladesh হলে 01 দিয়ে দিলেও app +88 করে নিবে। Example: 01306719179');
    return false;
  }
  if (!AuthBackupService.firebaseReady) {
    await masumInfoDialog(context, 'Firebase not ready', 'Phone OTP চালাতে Firebase ready থাকতে হবে। android/app/google-services.json এবং internet check করো।');
    return false;
  }

  final completer = Completer<bool>();
  try {
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phone,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        try {
          await masumApplyPhoneCredential(credential);
          if (!completer.isCompleted) completer.complete(true);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        if (!completer.isCompleted) completer.completeError(e.message ?? e.code);
      },
      codeSent: (String verificationId, int? resendToken) async {
        final smsCode = await masumInputDialog(
          context,
          title: 'Enter OTP',
          hint: '6 digit SMS code',
          keyboardType: TextInputType.number,
          maxLength: 6,
        );
        if (smsCode == null || smsCode.trim().isEmpty) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        try {
          final credential = PhoneAuthProvider.credential(verificationId: verificationId, smsCode: smsCode.trim());
          await masumApplyPhoneCredential(credential);
          if (!completer.isCompleted) completer.complete(true);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
      codeAutoRetrievalTimeout: (String verificationId) {},
    );
    return await completer.future.timeout(const Duration(seconds: 75), onTimeout: () => false);
  } catch (e) {
    if (context.mounted) {
      await masumInfoDialog(context, 'Phone OTP failed', 'OTP verify করা যায়নি: $e\n\nFirebase Console → Authentication → Sign-in method → Phone enable আছে কিনা দেখো।');
    }
    return false;
  }
}


bool hasBanglaText(String value) => RegExp(r'[\u0980-\u09FF]').hasMatch(value);

Future<Uint8List?> renderBanglaTextPng(
  String text, {
  bool bold = false,
  double fontSize = 22,
  double maxWidth = 980,
}) async {
  try {
    final safeText = text.isEmpty ? ' ' : text;
    final textPainter = TextPainter(
      text: TextSpan(
        text: safeText,
        style: TextStyle(
          color: Colors.black,
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          height: 1.35,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth);

    const padding = 10.0;
    final imageWidth = (textPainter.width + padding * 2).ceil().clamp(1, 1400);
    final imageHeight = (textPainter.height + padding * 2).ceil().clamp(1, 800);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, imageWidth.toDouble(), imageHeight.toDouble()));
    textPainter.paint(canvas, const Offset(padding, padding));

    final picture = recorder.endRecording();
    final image = await picture.toImage(imageWidth, imageHeight);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

Future<pw.ThemeData?> masumPdfBanglaTheme() async {
  try {
    final regularFont = await PdfGoogleFonts.notoSansBengaliRegular();
    final boldFont = await PdfGoogleFonts.notoSansBengaliBold();
    return pw.ThemeData.withFont(
      base: regularFont,
      bold: boldFont,
    );
  } catch (_) {
    return null;
  }
}

Future<void> exportTextPdf(BuildContext context, {required String title, required String text, String? fileName}) async {
  try {
    final pdf = pw.Document();
    final pdfTheme = await masumPdfBanglaTheme();
    final now = DateTime.now();
    final lines = text.split('\n');

    // Bengali conjuncts like পঞ্চান্ন can look broken in some Android PDF viewers
    // when written as normal PDF text. For Bangla lines we render the line with
    // Flutter's text engine first, then place it inside the PDF as a crisp image.
    // This keeps app display + PDF display visually the same.
    final banglaLineImages = <int, Uint8List>{};
    for (int index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (!hasBanglaText(line)) continue;
      final isHeader = line.trim().isNotEmpty && !line.contains(':') && line.length < 45;
      final image = await renderBanglaTextPng(
        line.isEmpty ? ' ' : line,
        bold: isHeader,
        fontSize: isHeader ? 28 : 22,
        maxWidth: 980,
      );
      if (image != null) banglaLineImages[index] = image;
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        theme: pdfTheme,
        build: (pw.Context pdfContext) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(18),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#0C1C2E'),
              borderRadius: pw.BorderRadius.circular(14),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Masum Smart Calculator Pro', style: pw.TextStyle(color: PdfColors.white, fontSize: 22, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
                pw.Text(title, style: const pw.TextStyle(color: PdfColors.cyan, fontSize: 14)),
                pw.SizedBox(height: 4),
                pw.Text('Generated: $now', style: const pw.TextStyle(color: PdfColors.grey300, fontSize: 10)),
              ],
            ),
          ),
          pw.SizedBox(height: 18),
          ...List.generate(lines.length, (index) {
            final line = lines[index];
            final isHeader = line.trim().isNotEmpty && !line.contains(':') && line.length < 45;
            final banglaImage = banglaLineImages[index];
            return pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: banglaImage != null
                  ? pw.Image(pw.MemoryImage(banglaImage), width: 500)
                  : pw.Text(
                      line.isEmpty ? ' ' : line,
                      style: pw.TextStyle(
                        fontSize: isHeader ? 14 : 11,
                        fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
                        color: PdfColor.fromHex('#071323'),
                        lineSpacing: 3,
                      ),
                    ),
            );
          }),
          pw.SizedBox(height: 16),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E8F2FB'), borderRadius: pw.BorderRadius.circular(10)),
            child: pw.Text('Shared from Masum Smart Calculator Pro', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          ),
        ],
      ),
    );

    await Printing.sharePdf(bytes: await pdf.save(), filename: fileName ?? safePdfFileName(title));
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF export failed')));
    }
  }
}

void showShareSheet(BuildContext context, {required String title, required String text}) {
  final fullText = '$title\n\n$text\n\nShared from Masum Smart Calculator Pro';
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: SelectableText(fullText),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: fullText));
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Share text copied')));
          },
          child: const Text('Copy'),
        ),
        ElevatedButton.icon(
          onPressed: () {
            openExternalUrl('https://wa.me/?text=${Uri.encodeComponent(fullText)}');
          },
          icon: const Icon(Icons.share_rounded),
          label: const Text('WhatsApp'),
        ),
        OutlinedButton.icon(
          onPressed: () => exportTextPdf(context, title: title, text: fullText),
          icon: const Icon(Icons.picture_as_pdf_rounded),
          label: const Text('PDF'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    ),
  );
}

class PressScale extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final double pressedScale;

  const PressScale({
    super.key,
    required this.child,
    required this.onTap,
    required this.borderRadius,
    this.pressedScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: borderRadius,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}


class AnimatedFadeSlide extends StatelessWidget {
  final Widget child;
  final int delayMs;
  final double beginY;

  const AnimatedFadeSlide({super.key, required this.child, this.delayMs = 0, this.beginY = 0.10});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delayMs),
      curve: Curves.easeOutCubic,
      builder: (context, value, childWidget) {
        final opacity = value.clamp(0.0, 1.0);
        final slide = (1 - value) * beginY;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, slide * 80),
            child: childWidget,
          ),
        );
      },
      child: child,
    );
  }
}

class CalculatorPage extends StatefulWidget {
  final bool darkMode;
  final Function(bool) onThemeChanged;

  const CalculatorPage({super.key, required this.darkMode, required this.onThemeChanged});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  String expression = '';
  String result = '0';
  String wordText = 'Total: Zero Taka Only';
  bool banglaWord = false;
  bool scientificMode = false;
  bool degreeMode = true;
  bool secondMode = false;
  double memoryValue = 0;
  final List<String> miniHistory = [];
  final List<AutoHistoryItem> autoHistory = [];
  final List<SavedCalculation> savedItems = [];
  User? firebaseUser;
  StreamSubscription<User?>? authSub;

  // Human-made matte palette: AMOLED background, iPhone-style orange operators,
  // charcoal number keys, soft grey action keys. No heavy neon glow.
  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F4F5);
  Color get card => widget.darkMode ? const Color(0xFF111214) : Colors.white;
  Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8E8ED);
  Color get numBtn => widget.darkMode ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
  Color get opBtn => const Color(0xFFFF9F0A);
  Color get dangerBtn => widget.darkMode ? const Color(0xFFA5A5A5) : const Color(0xFFD1D1D6);
  Color get equalBtn => const Color(0xFFFF9F0A);
  Color get sciBtn => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFD1D1D6);
  Color get mainTextColor => widget.darkMode ? Colors.white : const Color(0xFF111111);
  Color get mutedTextColor => widget.darkMode ? const Color(0xFF8E8E93) : const Color(0xFF5F6368);

  @override
  void initState() {
    super.initState();
    loadAllData();
    firebaseUser = AuthBackupService.currentUser;
    authSub = AuthBackupService.authChanges.listen((user) {
      if (!mounted) return;
      setState(() => firebaseUser = user);
    });
  }

  @override
  void dispose() {
    authSub?.cancel();
    super.dispose();
  }

  Future<void> loadAllData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedList = prefs.getStringList('saved_calculations') ?? [];
    final autoList = prefs.getStringList('auto_history') ?? [];
    final savedLanguage = prefs.getBool('bangla_word') ?? false;
    if (!mounted) return;
    setState(() {
      banglaWord = savedLanguage;
      savedItems.clear();
      autoHistory.clear();
      for (final item in savedList) savedItems.add(SavedCalculation.fromJson(jsonDecode(item)));
      for (final item in autoList) autoHistory.add(AutoHistoryItem.fromJson(jsonDecode(item)));
      updateWordText();
    });
  }

  Future<void> saveAllData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('saved_calculations', savedItems.map((item) => jsonEncode(item.toJson())).toList());
    await prefs.setStringList('auto_history', autoHistory.map((item) => jsonEncode(item.toJson())).toList());
    await prefs.setBool('bangla_word', banglaWord);
    AuthBackupService.scheduleAutoBackup();
  }

  bool isOperator(String v) => v == '+' || v == '-' || v == '×' || v == '÷' || v == '^';

  void updateWordText() {
    final value = double.tryParse(result) ?? 0;
    final number = value.round();
    wordText = banglaWord ? 'মোট: ${numberToBanglaWords(number)} টাকা মাত্র' : 'Total: ${numberToEnglishWords(number)} Taka Only';
  }

  void toggleWordLanguage() {
    HapticFeedback.lightImpact();
    setState(() {
      banglaWord = !banglaWord;
      updateWordText();
    });
    saveAllData();
  }

  void toggleScientificMode() {
    HapticFeedback.mediumImpact();
    setState(() => scientificMode = !scientificMode);
  }

  void addAutoHistory(String exp, String res) {
    if (exp.trim().isEmpty || res == 'Error') return;
    autoHistory.insert(0, AutoHistoryItem(expression: exp, result: res, dateTime: DateTime.now()));
    miniHistory.insert(0, '$exp = $res');
    if (miniHistory.length > 5) miniHistory.removeLast();
    saveAllData();
  }

  void copyResult() {
    Clipboard.setData(ClipboardData(text: result));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Result copied')));
  }


  void shareCalculatorResult() {
    HapticFeedback.lightImpact();
    final exp = expression.trim().isEmpty ? '0' : expression.trim();
    showShareSheet(
      context,
      title: 'Calculator Result',
      text: 'Calculation: $exp\nResult: $result\n$wordText',
    );
  }

  void exportCalculatorPdfDirect() {
    HapticFeedback.lightImpact();
    final exp = expression.trim().isEmpty ? '0' : expression.trim();
    exportTextPdf(
      context,
      title: 'Calculator Result',
      text: 'Calculation: $exp\nResult: $result\n$wordText',
      fileName: 'masum_calculator_result_report.pdf',
    );
  }

  void press(String v) {
    HapticFeedback.selectionClick();
    setState(() {
      if (v == 'C' || v == 'AC') {
        expression = '';
        result = '0';
        updateWordText();
        return;
      }
      if (v == '2nd') {
        secondMode = !secondMode;
        return;
      }
      if (v == 'mc') {
        memoryValue = 0;
        return;
      }
      if (v == 'm+') {
        final current = double.tryParse(result);
        if (current != null) memoryValue += current;
        return;
      }
      if (v == 'm-') {
        final current = double.tryParse(result);
        if (current != null) memoryValue -= current;
        return;
      }
      if (v == 'mr') {
        expression += format(memoryValue);
        liveCalc();
        return;
      }
      if (v == 'Rand') {
        expression = Random().nextDouble().toStringAsFixed(6);
        liveCalc();
        return;
      }
      if (v == '+/-') {
        if (expression.isEmpty || expression == '0') {
          expression = result == '0' ? '0' : '-($result)';
        } else if (expression.startsWith('-(') && expression.endsWith(')')) {
          expression = expression.substring(2, expression.length - 1);
        } else if (expression.startsWith('-')) {
          expression = expression.substring(1);
        } else {
          expression = '-($expression)';
        }
        liveCalc();
        return;
      }
      if (v == '⌫') {
        if (expression.isNotEmpty) expression = expression.substring(0, expression.length - 1);
        liveCalc();
        return;
      }
      if (v == '=') {
        finalCalc();
        return;
      }
      if (v == 'deg' || v == 'Deg') {
        degreeMode = !degreeMode;
        liveCalc();
        return;
      }
      if (v == 'log₁₀') {
        expression += 'log(';
        return;
      }
      if (['sin', 'cos', 'tan', 'sinh', 'cosh', 'tanh', 'log', 'ln'].contains(v)) {
        expression += '$v(';
        return;
      }
      if (v == '√') {
        expression += '√(';
        return;
      }
      if (v == 'x²') {
        if (expression.isNotEmpty) expression += '^2';
        liveCalc();
        return;
      }
      if (v == 'x³') {
        if (expression.isNotEmpty) expression += '^3';
        liveCalc();
        return;
      }
      if (v == 'xʸ') {
        if (expression.isNotEmpty) expression += '^';
        return;
      }
      if (v == 'eˣ') {
        if (expression.isNotEmpty) {
          expression = '${e.toString()}^($expression)';
          liveCalc();
        } else {
          expression = '${e.toString()}^(';
        }
        return;
      }
      if (v == '10ˣ') {
        if (expression.isNotEmpty) {
          expression = '10^($expression)';
          liveCalc();
        } else {
          expression = '10^(';
        }
        return;
      }
      if (v == '²√x') {
        if (expression.isNotEmpty) {
          expression = '√($expression)';
          liveCalc();
        } else {
          expression += '√(';
        }
        return;
      }
      if (v == '³√x') {
        if (expression.isNotEmpty) {
          expression = '($expression)^(1÷3)';
          liveCalc();
        }
        return;
      }
      if (v == 'ʸ√x') {
        if (expression.isNotEmpty) expression += '^(1÷';
        return;
      }
      if (v == 'EE') {
        if (expression.isEmpty) {
          expression = '10^';
        } else {
          expression += '×10^';
        }
        return;
      }
      if (v == 'x!') {
        if (expression.isNotEmpty) expression += '!';
        liveCalc();
        return;
      }
      if (v == '1/x') {
        if (expression.isNotEmpty) expression = '1÷($expression)';
        liveCalc();
        return;
      }
      if (v == 'π') {
        expression += pi.toString();
        liveCalc();
        return;
      }
      if (v == 'e') {
        expression += e.toString();
        liveCalc();
        return;
      }
      if (v == '%') {
        if (expression.isEmpty) return;
        final last = expression[expression.length - 1];
        if (isOperator(last) || last == '(' || last == '.' || last == '%') return;
        expression += '%';
        liveCalc();
        return;
      }
      if (isOperator(v)) {
        if (expression.isEmpty) return;
        if (isOperator(expression[expression.length - 1])) {
          expression = expression.substring(0, expression.length - 1) + v;
        } else {
          expression += v;
        }
        return;
      }
      expression += v;
      liveCalc();
    });
  }

  void liveCalc() {
    if (expression.isEmpty) {
      result = '0';
      updateWordText();
      return;
    }
    if (isOperator(expression[expression.length - 1])) return;
    try {
      final value = Parser(expression, degreeMode: degreeMode).parse();
      result = format(value);
      updateWordText();
    } catch (_) {}
  }

  void finalCalc() {
    if (expression.isEmpty || isOperator(expression[expression.length - 1])) return;
    try {
      final exp = expression;
      final res = format(Parser(expression, degreeMode: degreeMode).parse());
      result = res;
      updateWordText();
      HapticFeedback.mediumImpact();
      addAutoHistory(exp, res);
    } catch (_) {
      result = 'Error';
      wordText = banglaWord ? 'মোট: ভুল হিসাব' : 'Total: Invalid Calculation';
    }
  }

  String format(double v) {
    if (v.isNaN || v.isInfinite) return 'Error';
    if (v % 1 == 0) return v.toInt().toString();
    return v.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  void saveDialog() {
    final name = TextEditingController();
    final title = TextEditingController();
    final note = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card2,
        title: const Text('Save Calculation'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Person Name')),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
              TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Note')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                savedItems.insert(0, SavedCalculation(expression: expression, result: result, personName: name.text.trim().isEmpty ? 'No Name' : name.text.trim(), title: title.text.trim().isEmpty ? 'Untitled' : title.text.trim(), note: note.text.trim(), dateTime: DateTime.now()));
              });
              saveAllData();
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistoryPage(
          autoHistory: autoHistory,
          savedItems: savedItems,
          onLoadAuto: (item) => setState(() { expression = item.expression; result = item.result; updateWordText(); }),
          onLoadSaved: (item) => setState(() { expression = item.expression; result = item.result; updateWordText(); }),
          onSoftDeleteAuto: (i) { setState(() => autoHistory[i].isDeleted = true); saveAllData(); },
          onSoftDeleteSaved: (i) { setState(() => savedItems[i].isDeleted = true); saveAllData(); },
          onRecoverAuto: (i) { setState(() => autoHistory[i].isDeleted = false); saveAllData(); },
          onRecoverSaved: (i) { setState(() => savedItems[i].isDeleted = false); saveAllData(); },
          onPermanentDeleteAuto: (i) { setState(() => autoHistory.removeAt(i)); saveAllData(); },
          onPermanentDeleteSaved: (i) { setState(() => savedItems.removeAt(i)); saveAllData(); },
          onFavoriteAuto: (i) { setState(() => autoHistory[i].isFavorite = !autoHistory[i].isFavorite); saveAllData(); },
          onFavoriteSaved: (i) { setState(() => savedItems[i].isFavorite = !savedItems[i].isFavorite); saveAllData(); },
        ),
      ),
    );
  }

  Widget premiumButton(String text, Color color, double fontSize, {bool scientificPanel = false}) {
    final isEqual = text == '=';
    final isDanger = text == 'C' || text == 'AC' || text == '⌫';
    final isOperatorBtn = scientificPanel
        ? ['+', '-', '×', '÷'].contains(text)
        : ['+', '-', '×', '÷', '%', '√', 'x²', 'π', '(', ')'].contains(text);
    final isScienceBtn = [
      '2nd', 'xʸ', 'Deg', 'deg', 'sin', 'cos', 'tan', 'sinh', 'cosh', 'tanh',
      'log', 'log₁₀', 'ln', 'x!', '1/x', 'e', 'Rand', 'mc', 'm+', 'm-', 'mr',
      'x³', 'eˣ', '10ˣ', '²√x', '³√x', 'ʸ√x', 'EE', '+/-', 'π', '(', ')', '%'
    ].contains(text);
    late Color topColor, bottomColor, borderColor, textColor, glowColor;

    if (isEqual) {
      topColor = const Color(0xFFFFB143); bottomColor = const Color(0xFFFF9500); borderColor = Colors.white.withOpacity(0.10); textColor = Colors.white; glowColor = Colors.black;
    } else if (isDanger) {
      topColor = widget.darkMode ? const Color(0xFFB8B8B8) : const Color(0xFFDADADA); bottomColor = widget.darkMode ? const Color(0xFF9B9B9B) : const Color(0xFFC7C7CC); borderColor = Colors.white.withOpacity(0.08); textColor = const Color(0xFF101010); glowColor = Colors.black;
    } else if (isOperatorBtn) {
      topColor = const Color(0xFFFFB143); bottomColor = const Color(0xFFFF9500); borderColor = Colors.white.withOpacity(0.09); textColor = Colors.white; glowColor = Colors.black;
    } else if (isScienceBtn) {
      topColor = widget.darkMode ? const Color(0xFF242426) : const Color(0xFFE1E1E5); bottomColor = widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFD1D1D6); borderColor = widget.darkMode ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04); textColor = widget.darkMode ? Colors.white : const Color(0xFF111111); glowColor = Colors.black;
    } else {
      topColor = widget.darkMode ? const Color(0xFF333335) : Colors.white; bottomColor = widget.darkMode ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA); borderColor = widget.darkMode ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04); textColor = widget.darkMode ? Colors.white : const Color(0xFF111111); glowColor = Colors.black;
    }

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4.5),
        child: PressScale(
          borderRadius: BorderRadius.circular(23),
          onTap: () => press(text),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(23),
              gradient: LinearGradient(colors: [topColor, bottomColor], begin: Alignment.topLeft, end: Alignment.bottomRight),
              border: Border.all(color: borderColor, width: 1),
              boxShadow: [
                BoxShadow(color: glowColor.withOpacity(widget.darkMode ? 0.22 : 0.08), blurRadius: 10, offset: const Offset(0, 5)),
                BoxShadow(color: Colors.white.withOpacity(widget.darkMode ? 0.015 : 0.10), blurRadius: 1, offset: const Offset(0, -1)),
              ],
            ),
            child: Stack(
              children: [
                Positioned(top: 5, left: 11, right: 11, child: Container(height: 14, decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: [Colors.white.withOpacity(isOperatorBtn || isDanger || isEqual ? 0.10 : 0.04), Colors.white.withOpacity(0)], begin: Alignment.topCenter, end: Alignment.bottomCenter)))),
                Center(child: text == '⌫' ? Icon(Icons.backspace_rounded, color: textColor, size: 22) : FittedBox(child: Text((text == 'deg' || text == 'Deg') ? (degreeMode ? 'Deg' : 'Rad') : text, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w900, color: textColor, shadows: [if (widget.darkMode) Shadow(color: Colors.black.withOpacity(0.30), blurRadius: 4, offset: const Offset(0, 1))])))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buttonRow(List<Widget> buttons) => Expanded(child: Row(children: buttons));

  List<Widget> normalButtons(double f) => [
        buttonRow([premiumButton('C', dangerBtn, 20 * f), premiumButton('⌫', dangerBtn, 20 * f), premiumButton('%', opBtn, 20 * f), premiumButton('÷', opBtn, 20 * f)]),
        buttonRow([premiumButton('√', opBtn, 20 * f), premiumButton('x²', opBtn, 20 * f), premiumButton('π', opBtn, 20 * f), premiumButton('×', opBtn, 20 * f)]),
        buttonRow([premiumButton('7', numBtn, 21 * f), premiumButton('8', numBtn, 21 * f), premiumButton('9', numBtn, 21 * f), premiumButton('-', opBtn, 21 * f)]),
        buttonRow([premiumButton('4', numBtn, 21 * f), premiumButton('5', numBtn, 21 * f), premiumButton('6', numBtn, 21 * f), premiumButton('+', opBtn, 21 * f)]),
        buttonRow([premiumButton('1', numBtn, 21 * f), premiumButton('2', numBtn, 21 * f), premiumButton('3', numBtn, 21 * f), premiumButton(')', opBtn, 21 * f)]),
        buttonRow([premiumButton('(', opBtn, 21 * f), premiumButton('0', numBtn, 21 * f), premiumButton('.', numBtn, 21 * f), premiumButton('=', equalBtn, 21 * f)]),
      ];

  List<Widget> scientificButtons(double f) => [
        // Scientific layout inspired by iPhone scientific calculator: all scientific keys visible.
        buttonRow([
          premiumButton('(', sciBtn, 12 * f, scientificPanel: true),
          premiumButton(')', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('mc', sciBtn, 11 * f, scientificPanel: true),
          premiumButton('m+', sciBtn, 11 * f, scientificPanel: true),
          premiumButton('m-', sciBtn, 11 * f, scientificPanel: true),
          premiumButton('mr', sciBtn, 11 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('2nd', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('x²', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('x³', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('xʸ', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('eˣ', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('10ˣ', sciBtn, 11.5 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('1/x', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('²√x', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('³√x', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('ʸ√x', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('ln', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('log₁₀', sciBtn, 10.5 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('x!', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('sin', sciBtn, 11.5 * f, scientificPanel: true),
          premiumButton('cos', sciBtn, 11.5 * f, scientificPanel: true),
          premiumButton('tan', sciBtn, 11.5 * f, scientificPanel: true),
          premiumButton('e', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('EE', sciBtn, 11.5 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('Rand', sciBtn, 9.8 * f, scientificPanel: true),
          premiumButton('sinh', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('cosh', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('tanh', sciBtn, 10.5 * f, scientificPanel: true),
          premiumButton('π', sciBtn, 12 * f, scientificPanel: true),
          premiumButton('Deg', sciBtn, 10.5 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('⌫', dangerBtn, 16 * f, scientificPanel: true),
          premiumButton('AC', dangerBtn, 16 * f, scientificPanel: true),
          premiumButton('%', sciBtn, 16 * f, scientificPanel: true),
          premiumButton('÷', opBtn, 17 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('7', numBtn, 17 * f, scientificPanel: true),
          premiumButton('8', numBtn, 17 * f, scientificPanel: true),
          premiumButton('9', numBtn, 17 * f, scientificPanel: true),
          premiumButton('×', opBtn, 17 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('4', numBtn, 17 * f, scientificPanel: true),
          premiumButton('5', numBtn, 17 * f, scientificPanel: true),
          premiumButton('6', numBtn, 17 * f, scientificPanel: true),
          premiumButton('-', opBtn, 17 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('1', numBtn, 17 * f, scientificPanel: true),
          premiumButton('2', numBtn, 17 * f, scientificPanel: true),
          premiumButton('3', numBtn, 17 * f, scientificPanel: true),
          premiumButton('+', opBtn, 17 * f, scientificPanel: true),
        ]),
        buttonRow([
          premiumButton('+/-', numBtn, 14 * f, scientificPanel: true),
          premiumButton('0', numBtn, 17 * f, scientificPanel: true),
          premiumButton('.', numBtn, 17 * f, scientificPanel: true),
          premiumButton('=', equalBtn, 17 * f, scientificPanel: true),
        ]),
      ];

  Widget menuTile({required IconData icon, required String title, required String subtitle, required List<Color> colors, required VoidCallback onTap}) {
    return PressScale(
      borderRadius: BorderRadius.circular(22),
      pressedScale: 0.97,
      onTap: onTap,
      child: Container(
        height: 118,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF151517).withOpacity(0.70) : Colors.white.withOpacity(0.72), borderRadius: BorderRadius.circular(22), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(height: 42, width: 42, decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: colors.last.withOpacity(0.28), blurRadius: 12, offset: const Offset(0, 6))]), child: Icon(icon, color: Colors.white, size: 22)),
          const Spacer(),
          Text(title, style: TextStyle(color: mainTextColor, fontSize: 15, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: mutedTextColor, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Future<void> signInGoogle() async {
    try {
      HapticFeedback.mediumImpact();

      final user = await AuthBackupService.signInWithGoogle();

      if (user == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in cancelled')),
        );
        return;
      }

      // Important: first restore cloud data, then backup only if no cloud backup exists.
      // This prevents a fresh reinstall from overwriting old cloud data with empty local data.
      final restored = await AuthBackupService.restoreCloudData();
      await loadAllData();

      if (!restored) {
        await AuthBackupService.backupLocalData();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            restored
                ? 'Signed in and cloud data restored'
                : 'Signed in and new cloud backup created',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Google sign in failed: $e')),
      );
    }
  }

  Future<void> backupToCloud() async {
    try {
      if (AuthBackupService.currentUser == null) {
        await signInGoogle();
        if (AuthBackupService.currentUser == null) return;
      }
      await AuthBackupService.backupLocalData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cloud backup completed')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> restoreFromCloud() async {
    try {
      if (AuthBackupService.currentUser == null) {
        await signInGoogle();
        if (AuthBackupService.currentUser == null) return;
      }
      final restored = await AuthBackupService.restoreCloudData();
      await loadAllData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(restored ? 'Cloud data restored' : 'No cloud backup found')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  Future<void> signOutGoogle() async {
    await AuthBackupService.signOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Signed out')));
  }

  void openCloudBackupSheet() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF151517)] : [Colors.white, const Color(0xFFE8F2FB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.85)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Container(height: 5, width: 46, decoration: BoxDecoration(color: mutedTextColor.withOpacity(0.45), borderRadius: BorderRadius.circular(20)))),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        height: 48,
                        width: 48,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF7C4DFF)]),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(Icons.cloud_done_rounded, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Google Login + Auto Backup', style: TextStyle(color: mainTextColor, fontSize: 18, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 3),
                            Text(firebaseUser == null ? 'Not signed in' : firebaseUser!.email ?? 'Google user', style: TextStyle(color: mutedTextColor, fontSize: 13, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (firebaseUser == null)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.pop(context);
                          await signInGoogle();
                        },
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Sign in with Google'),
                      ),
                    )
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.pop(context);
                          await backupToCloud();
                        },
                        icon: const Icon(Icons.cloud_upload_rounded),
                        label: const Text('Backup Now'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(context);
                          await restoreFromCloud();
                        },
                        icon: const Icon(Icons.cloud_download_rounded),
                        label: const Text('Restore Backup'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(context);
                          await signOutGoogle();
                        },
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Sign Out'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void openPremiumMenu() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) {
        final screenHeight = MediaQuery.of(context).size.height;
        return FractionallySizedBox(
          heightFactor: screenHeight < 720 ? 0.86 : 0.72,
          child: SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.94, end: 1),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF151517)] : [Colors.white, const Color(0xFFE8F2FB)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(28), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.85)), boxShadow: [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(widget.darkMode ? 0.13 : 0.06), blurRadius: 28, offset: const Offset(0, 10)), BoxShadow(color: Colors.black.withOpacity(widget.darkMode ? 0.40 : 0.12), blurRadius: 30, offset: const Offset(0, 14))]),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(height: 5, width: 46, decoration: BoxDecoration(color: mutedTextColor.withOpacity(0.45), borderRadius: BorderRadius.circular(20))),
                      const SizedBox(height: 16),
                      Row(children: [Text('Quick Actions', style: TextStyle(color: mainTextColor, fontSize: 20, fontWeight: FontWeight.w900)), const Spacer(), PressScale(borderRadius: BorderRadius.circular(18), onTap: () => Navigator.pop(context), child: Container(height: 34, width: 34, decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB), shape: BoxShape.circle), child: Icon(Icons.close_rounded, color: mainTextColor, size: 20)))]),
                      const SizedBox(height: 16),
                      Row(children: [Expanded(child: menuTile(icon: Icons.history_rounded, title: 'History', subtitle: 'Records', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () { Navigator.pop(context); openHistory(); })), const SizedBox(width: 10), Expanded(child: menuTile(icon: Icons.folder_shared_rounded, title: 'Notebook', subtitle: 'Business', colors: const [Color(0xFFFFB143), Color(0xFFFF7C00)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => BusinessNotebookPage(darkMode: widget.darkMode))); }))]),
                      const SizedBox(height: 10),
                      Row(children: [Expanded(child: menuTile(icon: Icons.swap_horiz_rounded, title: 'Converter', subtitle: 'Units', colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => UnitConverterPage(darkMode: widget.darkMode))); })), const SizedBox(width: 10), Expanded(child: menuTile(icon: Icons.apps_rounded, title: 'Smart Tools', subtitle: 'All tools', colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => ToolsPage(darkMode: widget.darkMode))); }))]),
                      const SizedBox(height: 10),
                      Row(children: [Expanded(child: menuTile(icon: Icons.lock_rounded, title: 'App Lock', subtitle: 'PIN', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => PinLockSettingsPage(darkMode: widget.darkMode))); })), const SizedBox(width: 10), Expanded(child: menuTile(icon: Icons.person_rounded, title: 'About', subtitle: 'Developer', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => AboutDeveloperPage(darkMode: widget.darkMode))); }))]),
                      const SizedBox(height: 10),
                      PressScale(borderRadius: BorderRadius.circular(22), pressedScale: 0.98, onTap: () { Navigator.pop(context); openCloudBackupSheet(); }, child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14), decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF151517).withOpacity(0.70) : Colors.white.withOpacity(0.70), borderRadius: BorderRadius.circular(22), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06))), child: Row(children: [Container(height: 44, width: 44, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF7C4DFF)]), borderRadius: BorderRadius.circular(17)), child: Icon(firebaseUser == null ? Icons.login_rounded : Icons.cloud_done_rounded, color: Colors.white)), const SizedBox(width: 12), Expanded(child: Text(firebaseUser == null ? 'Sign in with Google' : 'Auto Backup & Restore', style: TextStyle(color: mainTextColor, fontSize: 16, fontWeight: FontWeight.w900))), Icon(Icons.arrow_forward_ios_rounded, color: mutedTextColor, size: 16)]))),
                      const SizedBox(height: 10),
                      PressScale(borderRadius: BorderRadius.circular(22), pressedScale: 0.98, onTap: () { Navigator.pop(context); widget.onThemeChanged(!widget.darkMode); }, child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14), decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF151517).withOpacity(0.70) : Colors.white.withOpacity(0.70), borderRadius: BorderRadius.circular(22), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06))), child: Row(children: [Container(height: 44, width: 44, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFFFFD86B), const Color(0xFFFF8A00)] : [const Color(0xFF293BFF), const Color(0xFF151517)]), borderRadius: BorderRadius.circular(17)), child: Icon(widget.darkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded, color: Colors.white)), const SizedBox(width: 12), Expanded(child: Text(widget.darkMode ? 'Switch to Light Mode' : 'Switch to Dark Mode', style: TextStyle(color: mainTextColor, fontSize: 16, fontWeight: FontWeight.w900))), Icon(Icons.arrow_forward_ios_rounded, color: mutedTextColor, size: 16)]))),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget topBar(double fontScale) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(children: [
        PressScale(borderRadius: BorderRadius.circular(20), onTap: toggleScientificMode, child: AnimatedContainer(duration: const Duration(milliseconds: 220), height: 34, width: 34, decoration: BoxDecoration(color: scientificMode ? equalBtn : card2, shape: BoxShape.circle, border: Border.all(color: Colors.white12)), child: Icon(scientificMode ? Icons.calculate_rounded : Icons.science_rounded, size: 18))),
        Expanded(child: Center(child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: Text(scientificMode ? 'Calc+ Scientific' : 'Calc+', key: ValueKey(scientificMode), style: TextStyle(fontSize: 19 * fontScale, fontWeight: FontWeight.w900, color: mainTextColor))))),
        TextButton(onPressed: toggleWordLanguage, child: Text(banglaWord ? 'English' : 'বাংলা', style: TextStyle(color: opBtn, fontSize: 12 * fontScale, fontWeight: FontWeight.bold))),
        PressScale(borderRadius: BorderRadius.circular(16), onTap: openCloudBackupSheet, child: Container(height: 34, width: 34, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: firebaseUser == null ? card2 : const Color(0xFF0F9D58).withOpacity(0.28), shape: BoxShape.circle, border: Border.all(color: firebaseUser == null ? Colors.white12 : Colors.greenAccent.withOpacity(0.35))), child: Icon(firebaseUser == null ? Icons.person_outline_rounded : Icons.cloud_done_rounded, size: 18, color: firebaseUser == null ? mainTextColor : Colors.greenAccent))),
        PressScale(borderRadius: BorderRadius.circular(18), onTap: openPremiumMenu, child: Container(height: 38, width: 38, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF3A3A3C), Color(0xFF1C1C1E)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withOpacity(0.08)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.24), blurRadius: 10, offset: const Offset(0, 5))]), child: const Icon(Icons.auto_awesome_rounded, color: Color(0xFFFF9F0A), size: 21))),
      ]),
    );
  }

  Widget displayBox(double h, double fontScale) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: double.infinity,
      height: h * 0.145,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8E8ED)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.07) : Colors.black.withOpacity(0.04)), boxShadow: [BoxShadow(color: Colors.black.withOpacity(widget.darkMode ? 0.32 : 0.08), blurRadius: 18, offset: const Offset(0, 9))]),
      child: Column(children: [
        Expanded(child: Align(alignment: Alignment.centerRight, child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Text(expression.isEmpty ? '0' : expression, key: ValueKey(expression), style: TextStyle(color: mutedTextColor, fontSize: 15 * fontScale)))))),
        Expanded(child: Align(alignment: Alignment.centerRight, child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)), child: FittedBox(key: ValueKey(result), fit: BoxFit.scaleDown, child: Text(result, style: TextStyle(fontSize: 40 * fontScale, fontWeight: FontWeight.w900, color: mainTextColor)))))),
      ]),
    );
  }

  Widget wordBox(double h, double fontScale) => AnimatedContainer(duration: const Duration(milliseconds: 220), width: double.infinity, height: scientificMode ? h * 0.065 : h * 0.075, margin: const EdgeInsets.fromLTRB(10, 8, 10, 8), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(22), border: Border.all(color: Colors.white.withOpacity(0.06))), alignment: Alignment.centerLeft, child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Text(wordText, key: ValueKey(wordText), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: opBtn, fontSize: 13 * fontScale, fontWeight: FontWeight.w600))));

  Widget smartActionDock(double fontScale) {
    Widget dockItem({
      required IconData icon,
      required String label,
      required List<Color> colors,
      required VoidCallback onTap,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: PressScale(
          borderRadius: BorderRadius.circular(18),
          pressedScale: 0.96,
          onTap: onTap,
          child: Container(
            height: scientificMode ? 34 : 40,
            padding: EdgeInsets.symmetric(horizontal: scientificMode ? 10 : 12),
            decoration: BoxDecoration(
              color: widget.darkMode ? const Color(0xFF151517) : Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05)),
              boxShadow: [BoxShadow(color: colors.last.withOpacity(widget.darkMode ? 0.16 : 0.09), blurRadius: 12, offset: const Offset(0, 5))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                height: scientificMode ? 24 : 27,
                width: scientificMode ? 24 : 27,
                decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(11)),
                child: Icon(icon, color: Colors.white, size: scientificMode ? 14 : 15),
              ),
              SizedBox(width: scientificMode ? 5 : 7),
              Text(label, style: TextStyle(color: mainTextColor, fontSize: (scientificMode ? 10.5 : 12) * fontScale, fontWeight: FontWeight.w900)),
            ]),
          ),
        ),
      );
    }

    return Container(
      height: scientificMode ? 38 : 46,
      margin: EdgeInsets.fromLTRB(10, 0, 10, scientificMode ? 4 : 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(children: [
          dockItem(icon: Icons.copy_rounded, label: 'Copy', colors: const [Color(0xFFFFB143), Color(0xFFFF9500)], onTap: copyResult),
          dockItem(icon: Icons.share_rounded, label: 'Share', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: shareCalculatorResult),
          dockItem(icon: Icons.picture_as_pdf_rounded, label: 'PDF', colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)], onTap: exportCalculatorPdfDirect),
          dockItem(icon: Icons.save_rounded, label: 'Save', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: saveDialog),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final calculatorWidth = w > 700 ? 420.0 : w;
          final fontScale = (calculatorWidth / 390).clamp(0.82, 1.04).toDouble();
          return Center(
            child: Container(
              width: calculatorWidth,
              height: h,
              decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF000000), const Color(0xFF070707)] : [const Color(0xFFF7F7F8), const Color(0xFFEDEDF2)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
              child: Column(children: [
                topBar(fontScale),
                SizedBox(height: 22, child: Center(child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Text(miniHistory.isEmpty ? '' : miniHistory.first, key: ValueKey(miniHistory.isEmpty ? '' : miniHistory.first), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: widget.darkMode ? Colors.white38 : Colors.black38, fontSize: 11 * fontScale))))),
                displayBox(h, fontScale),
                wordBox(h, fontScale),
                smartActionDock(fontScale),
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 0, 6, 8), child: AnimatedSwitcher(duration: const Duration(milliseconds: 240), child: Column(key: ValueKey(scientificMode), children: scientificMode ? scientificButtons(fontScale) : normalButtons(fontScale))))),
              ]),
            ),
          );
        }),
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  final List<AutoHistoryItem> autoHistory;
  final List<SavedCalculation> savedItems;
  final Function(AutoHistoryItem) onLoadAuto;
  final Function(SavedCalculation) onLoadSaved;
  final Function(int) onSoftDeleteAuto;
  final Function(int) onSoftDeleteSaved;
  final Function(int) onRecoverAuto;
  final Function(int) onRecoverSaved;
  final Function(int) onPermanentDeleteAuto;
  final Function(int) onPermanentDeleteSaved;
  final Function(int) onFavoriteAuto;
  final Function(int) onFavoriteSaved;

  const HistoryPage({super.key, required this.autoHistory, required this.savedItems, required this.onLoadAuto, required this.onLoadSaved, required this.onSoftDeleteAuto, required this.onSoftDeleteSaved, required this.onRecoverAuto, required this.onRecoverSaved, required this.onPermanentDeleteAuto, required this.onPermanentDeleteSaved, required this.onFavoriteAuto, required this.onFavoriteSaved});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  int tab = 0;
  String search = '';
  String formatDate(DateTime d) => '${d.day}/${d.month}/${d.year}';
  String formatTime(DateTime d) => '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  bool autoMatches(AutoHistoryItem item) { final q = search.toLowerCase(); return item.expression.toLowerCase().contains(q) || item.result.toLowerCase().contains(q) || formatDate(item.dateTime).contains(q); }
  bool savedMatches(SavedCalculation item) { final q = search.toLowerCase(); return item.expression.toLowerCase().contains(q) || item.result.toLowerCase().contains(q) || item.personName.toLowerCase().contains(q) || item.title.toLowerCase().contains(q) || item.note.toLowerCase().contains(q) || formatDate(item.dateTime).contains(q); }
  List<int> autoIndexes({bool deleted = false, bool favoriteOnly = false}) => [for (int i = 0; i < widget.autoHistory.length; i++) if (widget.autoHistory[i].isDeleted == deleted && (!favoriteOnly || widget.autoHistory[i].isFavorite) && autoMatches(widget.autoHistory[i])) i];
  List<int> savedIndexes({bool deleted = false, bool favoriteOnly = false}) => [for (int i = 0; i < widget.savedItems.length; i++) if (widget.savedItems[i].isDeleted == deleted && (!favoriteOnly || widget.savedItems[i].isFavorite) && savedMatches(widget.savedItems[i])) i];
  Map<String, List<int>> groupAuto(List<int> indexes) { final map = <String, List<int>>{}; for (final i in indexes) { final key = formatDate(widget.autoHistory[i].dateTime); map.putIfAbsent(key, () => []); map[key]!.add(i); } return map; }
  Map<String, List<int>> groupSaved(List<int> indexes) { final map = <String, List<int>>{}; for (final i in indexes) { final key = formatDate(widget.savedItems[i].dateTime); map.putIfAbsent(key, () => []); map[key]!.add(i); } return map; }

  List<int> currentAutoExportIndexes() {
    if (tab == 0) return autoIndexes();
    if (tab == 2) return autoIndexes(favoriteOnly: true);
    if (tab == 3) return autoIndexes(deleted: true);
    return <int>[];
  }

  List<int> currentSavedExportIndexes() {
    if (tab == 1) return savedIndexes();
    if (tab == 2) return savedIndexes(favoriteOnly: true);
    if (tab == 3) return savedIndexes(deleted: true);
    return <int>[];
  }

  String cleanPersonName(String value) {
    final name = value.trim();
    if (name.isEmpty || name.toLowerCase() == 'no name') return 'No Name';
    return name;
  }

  List<String> savedPersonNamesForExport(List<int> indexes) {
    final set = <String>{};
    for (final i in indexes) {
      set.add(cleanPersonName(widget.savedItems[i].personName));
    }
    final list = set.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  String savedReportText(List<SavedCalculation> list, String title) {
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('Total Records: ${list.length}')
      ..writeln('');

    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      buffer
        ..writeln('${i + 1}. ${item.title}')
        ..writeln('Person: ${cleanPersonName(item.personName)}')
        ..writeln('Calculation: ${item.expression} = ${item.result}')
        ..writeln('Note: ${item.note.trim().isEmpty ? '-' : item.note.trim()}')
        ..writeln('Date: ${formatDate(item.dateTime)}, ${formatTime(item.dateTime)}')
        ..writeln('------------------------------');
    }
    return buffer.toString();
  }

  String autoReportText(List<AutoHistoryItem> list, String title) {
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('Total Records: ${list.length}')
      ..writeln('');

    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      buffer
        ..writeln('${i + 1}. ${item.expression} = ${item.result}')
        ..writeln('Date: ${formatDate(item.dateTime)}, ${formatTime(item.dateTime)}')
        ..writeln('------------------------------');
    }
    return buffer.toString();
  }

  Future<void> exportSavedPdf(List<SavedCalculation> list, String title, {String? fileName}) async {
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export করার মতো saved record নেই')));
      return;
    }
    await exportTextPdf(context, title: title, text: savedReportText(list, title), fileName: fileName ?? safePdfFileName(title));
  }

  Future<void> exportAutoPdf(List<AutoHistoryItem> list, String title, {String? fileName}) async {
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export করার মতো auto history নেই')));
      return;
    }
    await exportTextPdf(context, title: title, text: autoReportText(list, title), fileName: fileName ?? safePdfFileName(title));
  }

  void showHistoryExportOptions() {
    final autoIdx = currentAutoExportIndexes();
    final savedIdx = currentSavedExportIndexes();
    final autoList = autoIdx.map((i) => widget.autoHistory[i]).toList();
    final savedList = savedIdx.map((i) => widget.savedItems[i]).toList();

    if (autoList.isEmpty && savedList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export করার মতো record নেই')));
      return;
    }

    final people = savedPersonNamesForExport(savedIdx);
    final title = tab == 0 ? 'Auto History Report' : tab == 1 ? 'Saved Calculations Report' : tab == 2 ? 'Favorite Calculations Report' : 'Deleted Calculations Report';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111214),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 46, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(99)))),
              const SizedBox(height: 16),
              const Text('Download PDF', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              const Text('এই page-এর records PDF করো। Saved tab-এ Person অনুযায়ী আলাদা PDF পাওয়া যাবে।', style: TextStyle(color: Colors.white60, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              if (autoList.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history_rounded, color: Colors.cyanAccent),
                  title: Text(tab == 0 ? 'All Auto History PDF' : '$title - Auto PDF', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  subtitle: Text('${autoList.length} records', style: const TextStyle(color: Colors.white60)),
                  trailing: const Icon(Icons.download_rounded, color: Colors.orangeAccent),
                  onTap: () {
                    Navigator.pop(context);
                    exportAutoPdf(autoList, tab == 0 ? 'Auto History Report' : '$title - Auto', fileName: tab == 0 ? 'masum_auto_history.pdf' : null);
                  },
                ),
              if (savedList.isNotEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.picture_as_pdf_rounded, color: Colors.orangeAccent),
                  title: Text(tab == 1 ? 'All Saved Calculations PDF' : '$title - Saved PDF', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                  subtitle: Text('${savedList.length} records', style: const TextStyle(color: Colors.white60)),
                  trailing: const Icon(Icons.download_rounded, color: Colors.orangeAccent),
                  onTap: () {
                    Navigator.pop(context);
                    exportSavedPdf(savedList, tab == 1 ? 'Saved Calculations Report' : '$title - Saved', fileName: tab == 1 ? 'masum_saved_calculations.pdf' : null);
                  },
                ),
              if (people.isNotEmpty) ...[
                const Divider(color: Colors.white12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: people.length,
                    itemBuilder: (context, i) {
                      final person = people[i];
                      final personItems = savedList.where((item) => cleanPersonName(item.personName).toLowerCase() == person.toLowerCase()).toList();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.person_rounded, color: Colors.cyanAccent),
                        title: Text('$person PDF', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                        subtitle: Text('${personItems.length} saved records', style: const TextStyle(color: Colors.white60)),
                        trailing: const Icon(Icons.download_rounded, color: Colors.orangeAccent),
                        onTap: () {
                          Navigator.pop(context);
                          exportSavedPdf(
                            personItems,
                            '$person Saved Calculations Report',
                            fileName: safePdfFileName('${person}_saved_calculations'),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF050B16);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text(tab == 0 ? 'Auto History' : tab == 1 ? 'Saved Calculations' : tab == 2 ? 'Favorites' : 'Deleted History'),
        actions: [
          IconButton(
            tooltip: 'Download PDF',
            icon: const Icon(Icons.download_rounded, color: Colors.cyanAccent),
            onPressed: showHistoryExportOptions,
          ),
        ],
      ),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 4), child: TextField(onChanged: (v) => setState(() => search = v), decoration: InputDecoration(hintText: 'Search name, title, note, date, amount...', prefixIcon: const Icon(Icons.search), filled: true, fillColor: const Color(0xFF111214), border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)))),
        Row(children: [tabButton('Auto', 0), tabButton('Saved', 1), tabButton('⭐', 2), tabButton('Deleted', 3)]),
        Expanded(child: tab == 0 ? buildAutoList(autoIndexes()) : tab == 1 ? buildSavedList(savedIndexes()) : tab == 2 ? buildFavoriteList() : buildDeletedList()),
      ]),
    );
  }

  Widget tabButton(String text, int value) => Expanded(child: TextButton(onPressed: () => setState(() => tab = value), child: Text(text, style: TextStyle(color: tab == value ? Colors.cyanAccent : Colors.white54, fontWeight: FontWeight.bold))));
  Widget dateHeader(String date) => Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 6), child: Text(date, style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16)));
  Widget buildAutoList(List<int> indexes) { if (indexes.isEmpty) return const Center(child: Text('No auto history found')); final grouped = groupAuto(indexes); return ListView(children: grouped.entries.expand((e) => [dateHeader(e.key), ...e.value.map((i) => autoCard(i, deletedView: false))]).toList()); }
  Widget buildSavedList(List<int> indexes) { if (indexes.isEmpty) return const Center(child: Text('No saved calculation found')); final grouped = groupSaved(indexes); return ListView(children: grouped.entries.expand((e) => [dateHeader(e.key), ...e.value.map((i) => savedCard(i, deletedView: false))]).toList()); }
  Widget buildFavoriteList() { final autoFav = autoIndexes(favoriteOnly: true); final savedFav = savedIndexes(favoriteOnly: true); if (autoFav.isEmpty && savedFav.isEmpty) return const Center(child: Text('No favorite items yet')); return ListView(children: [if (autoFav.isNotEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Auto Favorites', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold))), ...autoFav.map((i) => autoCard(i, deletedView: false)), if (savedFav.isNotEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Saved Favorites', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold))), ...savedFav.map((i) => savedCard(i, deletedView: false))]); }
  Widget buildDeletedList() { final autoDeleted = autoIndexes(deleted: true); final savedDeleted = savedIndexes(deleted: true); if (autoDeleted.isEmpty && savedDeleted.isEmpty) return const Center(child: Text('Deleted history empty')); return ListView(children: [if (autoDeleted.isNotEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Auto Deleted', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold))), ...autoDeleted.map((i) => autoCard(i, deletedView: true)), if (savedDeleted.isNotEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Saved Deleted', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold))), ...savedDeleted.map((i) => savedCard(i, deletedView: true))]); }

  Widget autoCard(int i, {required bool deletedView}) {
    final item = widget.autoHistory[i];
    return Card(color: const Color(0xFF111214), margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), child: ListTile(title: Text('${item.expression} = ${item.result}', style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${formatDate(item.dateTime)}, ${formatTime(item.dateTime)}'), trailing: Wrap(children: deletedView ? [IconButton(icon: const Icon(Icons.restore, color: Colors.greenAccent), onPressed: () => setState(() => widget.onRecoverAuto(i))), IconButton(icon: const Icon(Icons.delete_forever, color: Colors.redAccent), onPressed: () => setState(() => widget.onPermanentDeleteAuto(i)))] : [IconButton(icon: Icon(item.isFavorite ? Icons.star : Icons.star_border, color: item.isFavorite ? Colors.amber : Colors.white54), onPressed: () => setState(() => widget.onFavoriteAuto(i))), IconButton(icon: const Icon(Icons.open_in_new, color: Colors.cyanAccent), onPressed: () { widget.onLoadAuto(item); Navigator.pop(context); }), IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () => setState(() => widget.onSoftDeleteAuto(i)))])));
  }

  Widget savedCard(int i, {required bool deletedView}) {
    final item = widget.savedItems[i];
    return Card(color: const Color(0xFF111214), margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), child: ListTile(title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('Person: ${item.personName}\n${item.expression} = ${item.result}\nNote: ${item.note}\nDate: ${formatDate(item.dateTime)}, ${formatTime(item.dateTime)}'), trailing: Wrap(children: deletedView ? [IconButton(icon: const Icon(Icons.restore, color: Colors.greenAccent), onPressed: () => setState(() => widget.onRecoverSaved(i))), IconButton(icon: const Icon(Icons.delete_forever, color: Colors.redAccent), onPressed: () => setState(() => widget.onPermanentDeleteSaved(i)))] : [IconButton(icon: Icon(item.isFavorite ? Icons.star : Icons.star_border, color: item.isFavorite ? Colors.amber : Colors.white54), onPressed: () => setState(() => widget.onFavoriteSaved(i))), IconButton(icon: const Icon(Icons.open_in_new, color: Colors.cyanAccent), onPressed: () { widget.onLoadSaved(item); Navigator.pop(context); }), IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () => setState(() => widget.onSoftDeleteSaved(i)))])));
  }
}

class ToolsPage extends StatelessWidget {
  final bool darkMode;
  const ToolsPage({super.key, required this.darkMode});
  Color get bg => darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get mainText => darkMode ? Colors.white : const Color(0xFF151517);
  Color get mutedText => darkMode ? Colors.white60 : const Color(0xFF526070);

  Widget toolCard({required BuildContext context, required IconData icon, required String title, required String subtitle, required List<Color> colors, required VoidCallback onTap}) {
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: PressScale(borderRadius: BorderRadius.circular(26), pressedScale: 0.98, onTap: onTap, child: Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8F2FB)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(26), border: Border.all(color: darkMode ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.80)), boxShadow: [BoxShadow(color: colors.last.withOpacity(darkMode ? 0.18 : 0.10), blurRadius: 18, offset: const Offset(0, 8)), BoxShadow(color: Colors.black.withOpacity(darkMode ? 0.28 : 0.08), blurRadius: 18, offset: const Offset(0, 10))]), child: Row(children: [Container(height: 58, width: 58, decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(22), boxShadow: [BoxShadow(color: colors.last.withOpacity(0.32), blurRadius: 14, offset: const Offset(0, 7))]), child: Icon(icon, color: Colors.white, size: 28)), const SizedBox(width: 15), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: mainText, fontSize: 19, fontWeight: FontWeight.w900)), const SizedBox(height: 5), Text(subtitle, style: TextStyle(color: mutedText, fontSize: 13, fontWeight: FontWeight.w600))])), Icon(Icons.arrow_forward_ios_rounded, color: mutedText, size: 18)]))));
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;
    return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Smart Tools', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText)), body: Center(child: Container(width: maxWidth, height: double.infinity, decoration: BoxDecoration(gradient: LinearGradient(colors: darkMode ? [const Color(0xFF050505), const Color(0xFF000000)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Useful daily calculators', style: TextStyle(color: mutedText, fontSize: 14, fontWeight: FontWeight.w700)), const SizedBox(height: 14), toolCard(context: context, icon: Icons.history_rounded, title: 'Smart History', subtitle: 'Age, BMI and discount records', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SmartToolHistoryPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.cake_rounded, title: 'Age Calculator', subtitle: 'Calculate age from date of birth', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AgeCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.monitor_weight_rounded, title: 'BMI Calculator', subtitle: 'Check body mass index with status', colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BMICalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.local_offer_rounded, title: 'Discount Calculator', subtitle: 'Find discount price and savings', colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DiscountCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.trending_up_rounded, title: 'Profit / Loss Calculator', subtitle: 'Calculate profit, loss and percentage', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfitLossCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.account_balance_rounded, title: 'EMI / Loan Calculator', subtitle: 'Monthly EMI, total interest and payment', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EMILoanCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.person_rounded, title: 'About Developer', subtitle: 'Contact, WhatsApp, Email and Feedback', colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AboutDeveloperPage(darkMode: darkMode))))])))));
  }
}

abstract class ToolPageBase<T extends StatefulWidget> extends State<T> {
  Color pageBg(bool darkMode) => darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  String money(double value) { if (value.isNaN || value.isInfinite) return '0'; if (value % 1 == 0) return value.toInt().toString(); return value.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), ''); }
}

class AgeCalculatorPage extends StatefulWidget { final bool darkMode; const AgeCalculatorPage({super.key, required this.darkMode}); @override State<AgeCalculatorPage> createState() => _AgeCalculatorPageState(); }
class _AgeCalculatorPageState extends ToolPageBase<AgeCalculatorPage> {
  DateTime? birthDate; final nameController = TextEditingController(); String ageResult = 'Select your date of birth'; String nextBirthday = ''; String lastSig = '';
  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB); Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517); Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  @override void dispose() { nameController.dispose(); super.dispose(); }
  String formatDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  void saveRecord() { if (birthDate == null) return; final name = nameController.text.trim().isEmpty ? 'No Name' : nameController.text.trim(); final sig = 'Age|$name|${birthDate!.toIso8601String()}|$ageResult|$nextBirthday'; if (sig == lastSig) return; lastSig = sig; saveSmartToolHistory(SmartToolHistoryItem(type: 'Age', title: '$name Age', details: '$ageResult | $nextBirthday | DOB: ${formatDate(birthDate!)}', dateTime: DateTime.now())); }
  Future<void> pickBirthDate() async { final now = DateTime.now(); final picked = await showDatePicker(context: context, initialDate: birthDate ?? DateTime(now.year - 18, now.month, now.day), firstDate: DateTime(1900), lastDate: now); if (picked == null) return; setState(() { birthDate = picked; calculateAge(); }); saveRecord(); }
  void calculateAge() { if (birthDate == null) return; final today = DateTime.now(); int y = today.year - birthDate!.year, m = today.month - birthDate!.month, d = today.day - birthDate!.day; if (d < 0) { d += DateTime(today.year, today.month, 0).day; m--; } if (m < 0) { m += 12; y--; } ageResult = '$y Years, $m Months, $d Days'; DateTime next = DateTime(today.year, birthDate!.month, birthDate!.day); if (!next.isAfter(DateTime(today.year, today.month, today.day))) next = DateTime(today.year + 1, birthDate!.month, birthDate!.day); nextBirthday = 'Next birthday in ${next.difference(DateTime(today.year, today.month, today.day)).inDays} days'; }
  Widget glass(Widget child) => Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8F2FB)]), borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80))), child: child);
  Widget resultBox(String title, String value, IconData icon, List<Color> colors) => glass(Row(children: [Container(height: 56, width: 56, decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(22)), child: Icon(icon, color: Colors.white, size: 28)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 5), Text(value, style: TextStyle(color: mainText, fontSize: 21, fontWeight: FontWeight.w900))]))]));
  @override Widget build(BuildContext context) { final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity; return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Age Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText)), body: Center(child: Container(width: maxWidth, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF050505), const Color(0xFF000000)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Column(children: [glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Person Name', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 12), TextField(controller: nameController, onChanged: (_) => saveRecord(), decoration: InputDecoration(hintText: 'Enter name, e.g. Masum', filled: true, fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.person_rounded, color: Colors.cyanAccent)))])), const SizedBox(height: 14), glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Date of Birth', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 12), PressScale(borderRadius: BorderRadius.circular(20), onTap: pickBirthDate, child: Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB), borderRadius: BorderRadius.circular(20)), child: Row(children: [const Icon(Icons.calendar_month_rounded, color: Colors.cyanAccent), const SizedBox(width: 12), Expanded(child: Text(birthDate == null ? 'Tap to select date' : formatDate(birthDate!), style: TextStyle(color: birthDate == null ? mutedText : mainText, fontSize: 18, fontWeight: FontWeight.w800))), const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.cyanAccent)])))])), const SizedBox(height: 14), resultBox('Your Age', ageResult, Icons.cake_rounded, const [Color(0xFF22D3EE), Color(0xFF0E9FB3)]), const SizedBox(height: 14), resultBox('Birthday Reminder', nextBirthday.isEmpty ? 'Select date to see next birthday' : nextBirthday, Icons.celebration_rounded, const [Color(0xFFFFA733), Color(0xFFFF7C00)])]))))); }
}

class BMICalculatorPage extends StatefulWidget {
  final bool darkMode;

  const BMICalculatorPage({super.key, required this.darkMode});

  @override
  State<BMICalculatorPage> createState() => _BMICalculatorPageState();
}

class _BMICalculatorPageState extends ToolPageBase<BMICalculatorPage> {
  final heightController = TextEditingController();
  final weightController = TextEditingController();

  String bmiValue = '0';
  String bmiStatus = 'Enter height and weight';
  String bmiAdvice = 'BMI result will show here';
  String idealWeight = 'Enter height to see ideal weight';
  String healthScore = '0';
  String healthLevel = 'Waiting';
  String smartMessage = 'Enter height and weight to get your smart health message.';
  String lastSig = '';

  double animatedBmiTarget = 0;
  double animatedHealthTarget = 0;

  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB);

  @override
  void dispose() {
    heightController.dispose();
    weightController.dispose();
    super.dispose();
  }

  void saveRecord(double h, double w, String bmi, String status, String score) {
    final sig = 'BMI|$h|$w|$bmi|$status|$score';
    if (sig == lastSig) return;
    lastSig = sig;
    saveSmartToolHistory(
      SmartToolHistoryItem(
        type: 'BMI',
        title: 'BMI $bmi ($status)',
        details: 'Height: ${h.toStringAsFixed(0)} cm | Weight: ${w.toStringAsFixed(0)} kg | Health Score: $score/100',
        dateTime: DateTime.now(),
      ),
    );
  }

  void calculateBMI() {
    final h = double.tryParse(heightController.text.trim());
    final w = double.tryParse(weightController.text.trim());

    if (h == null || w == null || h <= 0 || w <= 0 || h < 50 || h > 250 || w < 10 || w > 300) {
      setState(() {
        bmiValue = '0';
        bmiStatus = 'Enter valid values';
        bmiAdvice = 'Use height in cm and weight in kg.';
        idealWeight = 'Valid range: 50-250 cm, 10-300 kg';
        healthScore = '0';
        healthLevel = 'Check Input';
        smartMessage = 'Please enter realistic height and weight.';
        animatedBmiTarget = 0;
        animatedHealthTarget = 0;
      });
      return;
    }

    final hm = h / 100;
    final bmi = w / (hm * hm);
    final min = 18.5 * hm * hm;
    final max = 24.9 * hm * hm;

    int score;
    String level;
    String msg;
    String status;
    String advice;

    if (bmi >= 18.5 && bmi < 25) {
      score = 95;
      level = 'Excellent';
      msg = 'Great! Your BMI is healthy.';
      status = 'Normal';
      advice = 'Great! Your BMI is in a healthy range.';
    } else if (bmi < 18.5) {
      score = bmi < 17 ? 58 : 78;
      level = bmi < 17 ? 'Low' : 'Good';
      msg = 'You are underweight. Try nutritious food.';
      status = 'Underweight';
      advice = 'You may need to gain some healthy weight.';
    } else if (bmi < 30) {
      score = 72;
      level = 'Needs Care';
      msg = 'Regular walking and balanced meals can help.';
      status = 'Overweight';
      advice = 'Try balanced food and regular exercise.';
    } else {
      score = 50;
      level = 'High Risk';
      msg = 'Consider exercise and professional health advice.';
      status = 'Obese';
      advice = 'Consider consulting a health professional.';
    }

    setState(() {
      bmiValue = bmi.toStringAsFixed(1);
      bmiStatus = status;
      bmiAdvice = advice;
      idealWeight = '${min.toStringAsFixed(1)} kg - ${max.toStringAsFixed(1)} kg';
      healthScore = score.toString();
      healthLevel = level;
      smartMessage = msg;
      animatedBmiTarget = bmi;
      animatedHealthTarget = score.toDouble();
    });

    saveRecord(h, w, bmi.toStringAsFixed(1), status, score.toString());
  }

  Color statusColor() {
    if (bmiStatus == 'Normal') return Colors.greenAccent;
    if (bmiStatus == 'Underweight') return Colors.orangeAccent;
    if (bmiStatus == 'Overweight') return Colors.amberAccent;
    if (bmiStatus == 'Obese') return Colors.redAccent;
    return Colors.cyanAccent;
  }

  Widget glass(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8F2FB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80)),
        boxShadow: [
          BoxShadow(color: statusColor().withOpacity(widget.darkMode ? 0.08 : 0.05), blurRadius: 24, offset: const Offset(0, 8)),
          BoxShadow(color: Colors.black.withOpacity(widget.darkMode ? 0.28 : 0.08), blurRadius: 18, offset: const Offset(0, 10)),
        ],
      ),
      child: child,
    );
  }

  Widget input(String label, String hint, IconData icon, TextEditingController c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => calculateBMI(),
          style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: mutedText),
            filled: true,
            fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
            prefixIcon: Icon(icon, color: Colors.cyanAccent),
          ),
        ),
      ],
    );
  }

  Widget bmiResultCard() {
    return glass(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your BMI', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: animatedBmiTarget),
                duration: const Duration(milliseconds: 650),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) {
                  return Text(
                    value <= 0 ? '-' : value.toStringAsFixed(1),
                    style: TextStyle(color: statusColor(), fontSize: 48, fontWeight: FontWeight.w900),
                  );
                },
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: statusColor().withOpacity(0.16),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: statusColor().withOpacity(0.35)),
                  ),
                  child: Text(bmiStatus, style: TextStyle(color: statusColor(), fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              bmiAdvice,
              key: ValueKey(bmiAdvice),
              style: TextStyle(color: mutedText, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void shareBMIResult() {
    showShareSheet(
      context,
      title: 'BMI Result',
      text: 'BMI: $bmiValue\nStatus: $bmiStatus\nIdeal Weight: $idealWeight\nHealth Score: $healthScore/100\nAdvice: $smartMessage',
    );
  }

  Widget healthScoreCard() {
    return glass(
      TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: animatedHealthTarget),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          final progress = (value / 100).clamp(0.0, 1.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Health Score', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(value.round().toString(), style: TextStyle(color: statusColor(), fontSize: 42, fontWeight: FontWeight.w900)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, left: 4),
                    child: Text('/100', style: TextStyle(color: mutedText, fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 10,
                  backgroundColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFE8F2FB),
                  valueColor: AlwaysStoppedAnimation<Color>(statusColor()),
                ),
              ),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(healthLevel, key: ValueKey(healthLevel), style: TextStyle(color: mainText, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text('BMI Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
        iconTheme: IconThemeData(color: mainText),
        actions: [IconButton(onPressed: shareBMIResult, icon: const Icon(Icons.share_rounded, color: Colors.cyanAccent))],
      ),
      body: Center(
        child: Container(
          width: maxWidth,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.darkMode ? [const Color(0xFF050505), const Color(0xFF000000)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                AnimatedFadeSlide(
                  delayMs: 0,
                  child: glass(Column(children: [input('Height', 'Enter height (cm)', Icons.height_rounded, heightController), const SizedBox(height: 16), input('Weight', 'Enter weight (kg)', Icons.monitor_weight_rounded, weightController)])),
                ),
                const SizedBox(height: 14),
                AnimatedFadeSlide(delayMs: 80, child: bmiResultCard()),
                const SizedBox(height: 14),
                AnimatedFadeSlide(
                  delayMs: 140,
                  child: glass(ListTile(
                    leading: const Icon(Icons.favorite_rounded, color: Colors.cyanAccent),
                    title: Text('Ideal Weight Range', style: TextStyle(color: mutedText)),
                    subtitle: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Text(idealWeight, key: ValueKey(idealWeight), style: TextStyle(color: mainText, fontSize: 20, fontWeight: FontWeight.w900)),
                    ),
                  )),
                ),
                const SizedBox(height: 14),
                AnimatedFadeSlide(delayMs: 200, child: healthScoreCard()),
                const SizedBox(height: 14),
                AnimatedFadeSlide(
                  delayMs: 260,
                  child: glass(AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(smartMessage, key: ValueKey(smartMessage), style: TextStyle(color: mainText, fontSize: 15, height: 1.35, fontWeight: FontWeight.w700)),
                  )),
                ),
                const SizedBox(height: 14),
                AnimatedFadeSlide(
                  delayMs: 320,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)),
                    child: Text('BMI Guide\nUnderweight: below 18.5\nNormal: 18.5 - 24.9\nOverweight: 25 - 29.9\nObese: 30 or above', style: TextStyle(color: mutedText, height: 1.5, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DiscountCalculatorPage extends StatefulWidget { final bool darkMode; const DiscountCalculatorPage({super.key, required this.darkMode}); @override State<DiscountCalculatorPage> createState() => _DiscountCalculatorPageState(); }
class _DiscountCalculatorPageState extends ToolPageBase<DiscountCalculatorPage> {
  final priceController = TextEditingController(); final discountController = TextEditingController(); String finalPrice = '0', savedAmount = '0', message = 'Enter price and discount to calculate.', lastSig = '';
  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB); Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517); Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070); Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB);
  @override void dispose() { priceController.dispose(); discountController.dispose(); super.dispose(); }
  void saveRecord(double p, double d, String f, String s) { final sig = 'Discount|$p|$d|$f|$s'; if (sig == lastSig) return; lastSig = sig; saveSmartToolHistory(SmartToolHistoryItem(type: 'Discount', title: 'Discount ${money(d)}%', details: 'Price: ${money(p)} → Final: $f | Saved: $s Taka', dateTime: DateTime.now())); }
  void calculateDiscount() { final p = double.tryParse(priceController.text.trim()); final d = double.tryParse(discountController.text.trim()); if (p == null || d == null || p <= 0 || d < 0 || d > 100) { setState(() { finalPrice = d != null && (d < 0 || d > 100) ? '-' : '0'; savedAmount = finalPrice == '-' ? '-' : '0'; message = d != null && (d < 0 || d > 100) ? 'Discount must be between 0% and 100%.' : 'Enter valid price and discount.'; }); return; } final save = p * d / 100, pay = p - save; setState(() { finalPrice = money(pay); savedAmount = money(save); message = d == 0 ? 'No discount applied.' : d < 10 ? 'Small discount, but still some savings.' : d < 30 ? 'Good deal! You are saving a nice amount.' : d < 60 ? 'Great deal! This discount is valuable.' : 'Excellent deal! Huge savings.'; }); saveRecord(p, d, finalPrice, savedAmount); }
  void shareDiscountResult() {
    showShareSheet(
      context,
      title: 'Discount Result',
      text: 'Final Price: $finalPrice Taka\nSaved Amount: $savedAmount Taka\n$message',
    );
  }

  Widget glass(Widget child) => Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8F2FB)]), borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80))), child: child);
  Widget input(String label, String hint, IconData icon, TextEditingController c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 10), TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => calculateDiscount(), style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.bold), decoration: InputDecoration(hintText: hint, filled: true, fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: Icon(icon, color: Colors.orangeAccent))) ]);
  @override Widget build(BuildContext context) { final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity; return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Discount Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText), actions: [IconButton(onPressed: shareDiscountResult, icon: const Icon(Icons.share_rounded, color: Colors.cyanAccent))]), body: Center(child: Container(width: maxWidth, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF050505), const Color(0xFF000000)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Column(children: [glass(Column(children: [input('Original Price', 'Enter price', Icons.payments_rounded, priceController), const SizedBox(height: 16), input('Discount Percent', 'Enter discount %', Icons.percent_rounded, discountController)])), const SizedBox(height: 14), glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Final Price', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(finalPrice, style: TextStyle(color: finalPrice == '-' ? Colors.redAccent : Colors.greenAccent, fontSize: 48, fontWeight: FontWeight.w900)), Padding(padding: const EdgeInsets.only(bottom: 10, left: 6), child: Text('Taka', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)))]), Text(message, style: TextStyle(color: mutedText, fontWeight: FontWeight.w700))])), const SizedBox(height: 14), glass(ListTile(leading: const Icon(Icons.savings_rounded, color: Colors.orangeAccent), title: Text('You Save', style: TextStyle(color: mutedText)), subtitle: Text('$savedAmount Taka', style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.w900)))), const SizedBox(height: 14), Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)), child: Text('Example: Price 1000, Discount 20% = Final Price 800, Save 200', style: TextStyle(color: mutedText)))]))))); }
}


class SmartToolHistoryPage extends StatefulWidget {
  final bool darkMode;
  const SmartToolHistoryPage({super.key, required this.darkMode});

  @override
  State<SmartToolHistoryPage> createState() => _SmartToolHistoryPageState();
}

class _SmartToolHistoryPageState extends State<SmartToolHistoryPage> {
  List<SmartToolHistoryItem> items = [];
  int tab = 0;

  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get card => widget.darkMode ? const Color(0xFF111214) : Colors.white;
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);

  @override
  void initState() {
    super.initState();
    refreshHistory();
  }

  Future<void> refreshHistory() async {
    final data = await loadSmartToolHistory();
    if (!mounted) return;
    setState(() => items = data);
  }

  Future<void> saveCurrentList() async {
    await saveSmartToolHistoryList(items);
    await refreshHistory();
  }

  List<int> visibleIndexes() {
    return [
      for (int i = 0; i < items.length; i++)
        if ((tab == 0 && !items[i].isDeleted) || (tab == 1 && items[i].isDeleted)) i
    ];
  }

  List<SmartToolHistoryItem> exportItems() {
    return tab == 0
        ? items.where((item) => !item.isDeleted).toList()
        : items.where((item) => item.isDeleted).toList();
  }

  String personNameForReport(SmartToolHistoryItem item) {
    final patterns = <RegExp>[
      RegExp(r'Customer:\s*([^\n|]+)', caseSensitive: false),
      RegExp(r'Person:\s*([^\n|]+)', caseSensitive: false),
      RegExp(r'Name:\s*([^\n|]+)', caseSensitive: false),
      RegExp(r'User:\s*([^\n|]+)', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(item.details);
      final value = match?.group(1)?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    if (item.type == 'Age' && item.title.toLowerCase().endsWith(' age')) {
      final value = item.title.substring(0, item.title.length - 4).trim();
      if (value.isNotEmpty) return value;
    }

    return 'No Person';
  }

  List<String> personNamesForExport() {
    final names = exportItems()
        .map(personNameForReport)
        .where((name) => name.trim().isNotEmpty && name != 'No Person')
        .toSet()
        .toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  String safeReportName(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_\$'), '');
    return cleaned.isEmpty ? 'person' : cleaned;
  }

  void showExportOptions() {
    final list = exportItems();
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No history found to export')),
      );
      return;
    }

    final names = personNamesForExport();

    showModalBottomSheet(
      context: context,
      backgroundColor: card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: mutedText.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Download PDF', style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text('All records অথবা person/customer অনুযায়ী আলাদা PDF download করো।', style: TextStyle(color: mutedText, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.picture_as_pdf_rounded, color: Colors.orangeAccent),
                  title: Text('All Records PDF', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                  subtitle: Text('${list.length} records একসাথে', style: TextStyle(color: mutedText)),
                  onTap: () {
                    Navigator.pop(context);
                    exportHistoryReport();
                  },
                ),
                if (names.isNotEmpty) ...[
                  const Divider(),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: names.length,
                      itemBuilder: (context, i) {
                        final name = names[i];
                        final personList = list.where((item) => personNameForReport(item).toLowerCase() == name.toLowerCase()).toList();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_rounded, color: Colors.cyanAccent),
                          title: Text(name, style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
                          subtitle: Text('${personList.length} records', style: TextStyle(color: mutedText)),
                          trailing: const Icon(Icons.download_rounded, color: Colors.orangeAccent),
                          onTap: () {
                            Navigator.pop(context);
                            exportHistoryReport(
                              customList: personList,
                              customTitle: '$name Smart History Report',
                              customFileName: 'masum_${safeReportName(name)}_smart_history.pdf',
                            );
                          },
                        );
                      },
                    ),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('এই records গুলোতে Customer/Person name পাওয়া যায়নি।', style: TextStyle(color: mutedText)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String formatDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  IconData iconFor(String type) {
    if (type == 'Age') return Icons.cake_rounded;
    if (type == 'BMI') return Icons.monitor_weight_rounded;
    if (type == 'Discount') return Icons.local_offer_rounded;
    if (type == 'ProfitLoss') return Icons.trending_up_rounded;
    if (type == 'EMI') return Icons.account_balance_rounded;
    return Icons.apps_rounded;
  }

  List<Color> colorsFor(String type) {
    if (type == 'Age') return const [Color(0xFF22D3EE), Color(0xFF0E9FB3)];
    if (type == 'BMI') return const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)];
    if (type == 'Discount') return const [Color(0xFFFFA733), Color(0xFFFF7C00)];
    if (type == 'ProfitLoss') return const [Color(0xFF30C96B), Color(0xFF0F9D58)];
    if (type == 'EMI') return const [Color(0xFF22D3EE), Color(0xFF0E9FB3)];
    return const [Color(0xFF30C96B), Color(0xFF0F9D58)];
  }

  Future<void> softDeleteAllActive() async {
    for (final item in items) {
      if (!item.isDeleted) item.isDeleted = true;
    }
    await saveCurrentList();
  }

  Future<void> permanentDeleteAllDeleted() async {
    items.removeWhere((item) => item.isDeleted);
    await saveCurrentList();
  }

  Future<void> softDeleteItem(int i) async {
    items[i].isDeleted = true;
    await saveCurrentList();
  }

  Future<void> recoverItem(int i) async {
    items[i].isDeleted = false;
    await saveCurrentList();
  }

  Future<void> permanentDeleteItem(int i) async {
    items.removeAt(i);
    await saveCurrentList();
  }

  String htmlEscape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;')
        .replaceAll('\n', '<br>');
  }

  String profitLossSummary(List<SmartToolHistoryItem> list) {
    double totalProfit = 0;
    double totalLoss = 0;
    int count = 0;

    for (final item in list) {
      if (item.type != 'ProfitLoss') continue;
      count++;

      final match = RegExp(r'Amount:\s*([0-9.]+)').firstMatch(item.details);
      final amount = match == null ? 0 : double.tryParse(match.group(1) ?? '0') ?? 0;

      if (item.title.toLowerCase().contains('profit')) {
        totalProfit += amount;
      } else if (item.title.toLowerCase().contains('loss')) {
        totalLoss += amount;
      }
    }

    if (count == 0) return '';

    String clean(double v) {
      if (v % 1 == 0) return v.toInt().toString();
      return v.toStringAsFixed(2);
    }

    final net = totalProfit - totalLoss;
    final netStatus = net >= 0 ? 'Net Profit' : 'Net Loss';

    return '''
      <div class="summary">
        <h2>Profit/Loss Summary</h2>
        <p><b>Records:</b> $count</p>
        <p><b>Total Profit:</b> ${clean(totalProfit)} Taka</p>
        <p><b>Total Loss:</b> ${clean(totalLoss)} Taka</p>
        <p><b>$netStatus:</b> ${clean(net.abs())} Taka</p>
      </div>
    ''';
  }

  Future<void> exportHistoryReport({List<SmartToolHistoryItem>? customList, String? customTitle, String? customFileName}) async {
    final list = customList ?? exportItems();
    final reportTitle = customTitle ?? (tab == 0 ? 'Smart History Report' : 'Deleted Smart History Report');

    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No history found to export')),
      );
      return;
    }

    double totalProfit = 0;
    double totalLoss = 0;
    int profitLossCount = 0;

    for (final item in list) {
      if (item.type != 'ProfitLoss') continue;
      profitLossCount++;
      final match = RegExp(r'Amount:\s*([0-9.]+)').firstMatch(item.details);
      final value = match == null ? 0 : double.tryParse(match.group(1) ?? '0') ?? 0;
      if (item.title.toLowerCase().contains('profit')) {
        totalProfit += value;
      } else if (item.title.toLowerCase().contains('loss')) {
        totalLoss += value;
      }
    }

    String clean(double v) {
      if (v % 1 == 0) return v.toInt().toString();
      return v.toStringAsFixed(2);
    }

    final buffer = StringBuffer()
      ..writeln(reportTitle)
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('Total Records: ${list.length}')
      ..writeln('');

    if (profitLossCount > 0) {
      final net = totalProfit - totalLoss;
      buffer
        ..writeln('Profit/Loss Summary')
        ..writeln('Records: $profitLossCount')
        ..writeln('Total Profit: ${clean(totalProfit)} Taka')
        ..writeln('Total Loss: ${clean(totalLoss)} Taka')
        ..writeln('${net >= 0 ? 'Net Profit' : 'Net Loss'}: ${clean(net.abs())} Taka')
        ..writeln('');
    }

    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      buffer
        ..writeln('${i + 1}. ${item.title}')
        ..writeln('Type: ${item.type}')
        ..writeln(item.details)
        ..writeln('Date: ${formatDate(item.dateTime)}')
        ..writeln('------------------------------');
    }

    await exportTextPdf(
      context,
      title: reportTitle,
      text: buffer.toString(),
      fileName: customFileName ?? (tab == 0 ? 'masum_smart_history_report.pdf' : 'masum_deleted_history_report.pdf'),
    );
  }

  Widget tabButton(String title, int value) {
    final active = tab == value;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: PressScale(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => tab = value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              gradient: active ? const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF0E9FB3)]) : null,
              color: active ? null : card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: active ? Colors.cyanAccent.withOpacity(0.25) : Colors.white.withOpacity(0.08)),
            ),
            child: Center(
              child: Text(
                title,
                style: TextStyle(color: active ? Colors.white : mainText, fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tab == 0 ? Icons.history_toggle_off_rounded : Icons.delete_outline_rounded, color: mutedText, size: 58),
            const SizedBox(height: 12),
            Text(
              tab == 0 ? 'No smart history yet' : 'Deleted history empty',
              style: TextStyle(color: mainText, fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              tab == 0
                  ? 'Age, BMI, Discount and Profit/Loss records will appear here.'
                  : 'Deleted records will appear here for recovery.',
              textAlign: TextAlign.center,
              style: TextStyle(color: mutedText, height: 1.35),
            ),
          ],
        ),
      ),
    );
  }

  Widget historyCard(int index) {
    final item = items[index];
    final colors = colorsFor(item.type);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: widget.darkMode
              ? [const Color(0xFF1C1C1E), const Color(0xFF111214)]
              : [Colors.white, const Color(0xFFE8F2FB)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.80)),
      ),
      child: Row(
        children: [
          Container(
            height: 54,
            width: 54,
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(20)),
            child: Icon(iconFor(item.type), color: Colors.white, size: 27),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: TextStyle(color: mainText, fontSize: 17, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(item.details, style: TextStyle(color: mutedText, fontSize: 13, height: 1.35, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(formatDate(item.dateTime), style: TextStyle(color: mutedText.withOpacity(0.85), fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          if (tab == 0)
            IconButton(onPressed: () => softDeleteItem(index), icon: const Icon(Icons.delete_rounded, color: Colors.redAccent))
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(onPressed: () => recoverItem(index), icon: const Icon(Icons.restore_rounded, color: Colors.greenAccent)),
                IconButton(onPressed: () => permanentDeleteItem(index), icon: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent)),
              ],
            )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;
    final indexes = visibleIndexes();

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text('Smart History', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
        iconTheme: IconThemeData(color: mainText),
        actions: [
          IconButton(
            tooltip: 'Download report',
            onPressed: indexes.isEmpty ? null : showExportOptions,
            icon: const Icon(Icons.download_rounded, color: Colors.orangeAccent),
          ),
          IconButton(
            tooltip: tab == 0 ? 'Move all to Deleted' : 'Permanent delete all',
            onPressed: indexes.isEmpty
                ? null
                : () {
                    if (tab == 0) {
                      softDeleteAllActive();
                    } else {
                      permanentDeleteAllDeleted();
                    }
                  },
            icon: Icon(tab == 0 ? Icons.delete_sweep_rounded : Icons.delete_forever_rounded),
          ),
        ],
      ),
      body: Center(
        child: Container(
          width: maxWidth,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.darkMode
                  ? [const Color(0xFF050505), const Color(0xFF000000)]
                  : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                child: Row(children: [tabButton('History', 0), tabButton('Deleted', 1)]),
              ),
              Expanded(
                child: indexes.isEmpty
                    ? emptyState()
                    : RefreshIndicator(
                        onRefresh: refreshHistory,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                          itemCount: indexes.length,
                          itemBuilder: (context, i) => historyCard(indexes[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfitLossCalculatorPage extends StatefulWidget {
  final bool darkMode;

  const ProfitLossCalculatorPage({super.key, required this.darkMode});

  @override
  State<ProfitLossCalculatorPage> createState() => _ProfitLossCalculatorPageState();
}

class _ProfitLossCalculatorPageState extends ToolPageBase<ProfitLossCalculatorPage> {
  final itemController = TextEditingController();
  final costController = TextEditingController();
  final sellController = TextEditingController();
  final customerController = TextEditingController();
  final noteController = TextEditingController();

  String amount = '0';
  String percent = '0';
  String status = 'Enter cost and selling price';
  String message = 'Profit or loss result will show here.';
  String lastSig = '';

  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB);

  @override
  void dispose() {
    itemController.dispose();
    costController.dispose();
    sellController.dispose();
    customerController.dispose();
    noteController.dispose();
    super.dispose();
  }

  Color statusColor() {
    if (status == 'Profit') return Colors.greenAccent;
    if (status == 'Loss') return Colors.redAccent;
    if (status == 'No Profit No Loss') return Colors.orangeAccent;
    return Colors.cyanAccent;
  }

  bool calculateProfitLoss({bool showInvalidMessage = false}) {
    final cost = double.tryParse(costController.text.trim());
    final sell = double.tryParse(sellController.text.trim());

    if (cost == null || sell == null || cost <= 0 || sell < 0) {
      setState(() {
        amount = '0';
        percent = '0';
        status = 'Enter valid values';
        message = 'Cost price must be greater than 0 and selling price must be valid.';
      });
      if (showInvalidMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter valid Cost Price and Selling Price')),
        );
      }
      return false;
    }

    final diff = sell - cost;
    final pct = (diff.abs() / cost) * 100;
    final newAmount = money(diff.abs());
    final newPercent = money(pct);

    String newStatus;
    String newMessage;

    if (diff > 0) {
      newStatus = 'Profit';
      newMessage = 'Great! You made a profit of $newAmount Taka.';
    } else if (diff < 0) {
      newStatus = 'Loss';
      newMessage = 'You made a loss of $newAmount Taka.';
    } else {
      newStatus = 'No Profit No Loss';
      newMessage = 'Selling price is equal to cost price.';
    }

    setState(() {
      amount = newAmount;
      percent = newPercent;
      status = newStatus;
      message = newMessage;
    });

    return true;
  }

  Future<void> saveCurrentRecord() async {
    final ok = calculateProfitLoss(showInvalidMessage: true);
    if (!ok) return;

    final cost = double.tryParse(costController.text.trim());
    final sell = double.tryParse(sellController.text.trim());
    if (cost == null || sell == null) return;

    final itemName = itemController.text.trim().isEmpty ? 'No Item' : itemController.text.trim();
    final customerName = customerController.text.trim().isEmpty ? 'No Customer' : customerController.text.trim();
    final noteText = noteController.text.trim();

    final details = 'Item: $itemName\n'
        'Cost: ${money(cost)} | Sell: ${money(sell)} | Amount: $amount Taka | Percent: $percent%\n'
        'Customer: $customerName'
        '${noteText.isEmpty ? '' : '\nNote: $noteText'}';
    final sig = 'ProfitLoss|$itemName|${money(cost)}|${money(sell)}|$amount|$percent|$status|$customerName|$noteText';

    if (sig == lastSig) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This result is already saved')),
      );
      return;
    }

    final currentItems = await loadSmartToolHistory();
    if (currentItems.isNotEmpty &&
        currentItems.first.type == 'ProfitLoss' &&
        currentItems.first.title == status &&
        currentItems.first.details == details) {
      lastSig = sig;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This result is already saved')),
      );
      return;
    }

    lastSig = sig;
    await saveSmartToolHistory(
      SmartToolHistoryItem(
        type: 'ProfitLoss',
        title: status,
        details: details,
        dateTime: DateTime.now(),
      ),
    );

    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profit/Loss saved to Smart History')),
    );
  }

  Widget glass(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: widget.darkMode
              ? [const Color(0xFF1C1C1E), const Color(0xFF111214)]
              : [Colors.white, const Color(0xFFE8F2FB)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80),
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor().withOpacity(widget.darkMode ? 0.08 : 0.05),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(widget.darkMode ? 0.30 : 0.10),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget textInput(String label, String hint, IconData icon, TextEditingController controller, {int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: mutedText),
            filled: true,
            fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            prefixIcon: Icon(icon, color: Colors.greenAccent),
          ),
        ),
      ],
    );
  }

  Widget input(String label, String hint, IconData icon, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => calculateProfitLoss(),
          style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: mutedText),
            filled: true,
            fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            prefixIcon: Icon(icon, color: Colors.greenAccent),
          ),
        ),
      ],
    );
  }

  void shareProfitLossResult() {
    final itemName = itemController.text.trim().isEmpty ? 'No Item' : itemController.text.trim();
    final customerName = customerController.text.trim().isEmpty ? 'No Customer' : customerController.text.trim();
    final noteText = noteController.text.trim();
    showShareSheet(
      context,
      title: 'Profit / Loss Result',
      text: 'Item: $itemName\nStatus: $status\nAmount: $amount Taka\nPercentage: $percent%\nCustomer: $customerName${noteText.isEmpty ? '' : '\nNote: $noteText'}\n$message',
    );
  }

  Widget saveButton() {
    return PressScale(
      borderRadius: BorderRadius.circular(22),
      pressedScale: 0.98,
      onTap: saveCurrentRecord,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF30C96B), Color(0xFF0F9D58)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0F9D58).withOpacity(0.28),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.save_rounded, color: Colors.white),
            SizedBox(width: 10),
            Text(
              'Save Result to Smart History',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text('Profit / Loss Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
        iconTheme: IconThemeData(color: mainText),
        actions: [IconButton(onPressed: shareProfitLossResult, icon: const Icon(Icons.share_rounded, color: Colors.cyanAccent))],
      ),
      body: Center(
        child: Container(
          width: maxWidth,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.darkMode
                  ? [const Color(0xFF050505), const Color(0xFF000000)]
                  : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                glass(
                  Column(
                    children: [
                      textInput('Item Name', 'What did you buy/sell? e.g. Rice, Phone, Shirt', Icons.inventory_2_rounded, itemController),
                      const SizedBox(height: 16),
                      input('Cost Price', 'Enter buying/cost price', Icons.shopping_bag_rounded, costController),
                      const SizedBox(height: 16),
                      input('Selling Price', 'Enter selling price', Icons.sell_rounded, sellController),
                      const SizedBox(height: 16),
                      textInput('Customer / Buyer', 'Optional, e.g. Rahim', Icons.person_rounded, customerController),
                      const SizedBox(height: 16),
                      textInput('Note', 'Optional note, e.g. local market sale', Icons.note_alt_rounded, noteController, maxLines: 2),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                glass(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Result', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            amount,
                            style: TextStyle(color: statusColor(), fontSize: 48, fontWeight: FontWeight.w900),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10, left: 6),
                            child: Text('Taka', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Chip(
                        label: Text(status),
                        labelStyle: TextStyle(color: statusColor(), fontWeight: FontWeight.w900),
                        backgroundColor: statusColor().withOpacity(0.16),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        message,
                        style: TextStyle(color: mutedText, fontSize: 14, height: 1.35, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                glass(
                  ListTile(
                    leading: const Icon(Icons.percent_rounded, color: Colors.greenAccent),
                    title: Text('Percentage', style: TextStyle(color: mutedText)),
                    subtitle: Text('$percent%', style: TextStyle(color: mainText, fontSize: 24, fontWeight: FontWeight.w900)),
                  ),
                ),
                const SizedBox(height: 14),
                saveButton(),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    'Example: Item Rice, Cost 800, Sell 1000 = Profit 200, Profit 25%\nTip: Add customer and note, then tap Save Result to keep a clean business record.',
                    style: TextStyle(color: mutedText),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class EMILoanCalculatorPage extends StatefulWidget {
  final bool darkMode;
  const EMILoanCalculatorPage({super.key, required this.darkMode});

  @override
  State<EMILoanCalculatorPage> createState() => _EMILoanCalculatorPageState();
}

class _EMILoanCalculatorPageState extends ToolPageBase<EMILoanCalculatorPage> {
  final loanController = TextEditingController();
  final rateController = TextEditingController();
  final yearController = TextEditingController();
  final titleController = TextEditingController();
  final noteController = TextEditingController();

  String emi = '0';
  String totalInterest = '0';
  String totalPayment = '0';
  String message = 'Enter loan amount, rate and time.';
  String lastSig = '';

  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB);

  @override
  void dispose() {
    loanController.dispose();
    rateController.dispose();
    yearController.dispose();
    titleController.dispose();
    noteController.dispose();
    super.dispose();
  }

  bool calculateEMI({bool showInvalidMessage = false}) {
    final principal = double.tryParse(loanController.text.trim());
    final annualRate = double.tryParse(rateController.text.trim());
    final years = double.tryParse(yearController.text.trim());

    if (principal == null || annualRate == null || years == null || principal <= 0 || annualRate < 0 || years <= 0) {
      setState(() {
        emi = '0';
        totalInterest = '0';
        totalPayment = '0';
        message = 'Enter valid loan amount, interest rate and time.';
      });

      if (showInvalidMessage) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter valid Loan Amount, Interest Rate and Time')),
        );
      }
      return false;
    }

    final months = (years * 12).round();
    double monthlyEMI;

    if (annualRate == 0) {
      monthlyEMI = principal / months;
    } else {
      final monthlyRate = annualRate / 12 / 100;
      final power = pow(1 + monthlyRate, months).toDouble();
      monthlyEMI = principal * monthlyRate * power / (power - 1);
    }

    final totalPay = monthlyEMI * months;
    final interest = totalPay - principal;

    setState(() {
      emi = money(monthlyEMI);
      totalInterest = money(interest);
      totalPayment = money(totalPay);

      if (annualRate == 0) {
        message = 'No interest loan. You only pay the principal amount monthly.';
      } else if (annualRate <= 5) {
        message = 'Low interest loan. This looks comparatively affordable.';
      } else if (annualRate <= 12) {
        message = 'Moderate interest. Check monthly budget before taking this loan.';
      } else {
        message = 'High interest loan. Be careful before taking this loan.';
      }
    });

    return true;
  }

  Future<void> saveCurrentRecord() async {
    final ok = calculateEMI(showInvalidMessage: true);
    if (!ok) return;

    final principal = double.tryParse(loanController.text.trim());
    final annualRate = double.tryParse(rateController.text.trim());
    final years = double.tryParse(yearController.text.trim());

    if (principal == null || annualRate == null || years == null) return;

    final loanTitle = titleController.text.trim().isEmpty ? 'Loan Plan' : titleController.text.trim();
    final noteText = noteController.text.trim();

    final details = 'Title: $loanTitle\n'
        'Loan: ${money(principal)} Taka | Rate: ${money(annualRate)}% | Time: ${money(years)} Years\n'
        'Monthly EMI: $emi Taka | Interest: $totalInterest Taka | Total: $totalPayment Taka'
        '${noteText.isEmpty ? '' : '\nNote: $noteText'}';

    final sig = 'EMI|$loanTitle|${money(principal)}|${money(annualRate)}|${money(years)}|$emi|$totalInterest|$totalPayment|$noteText';

    if (sig == lastSig) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This EMI result is already saved')),
      );
      return;
    }

    final currentItems = await loadSmartToolHistory();
    if (currentItems.isNotEmpty &&
        currentItems.first.type == 'EMI' &&
        currentItems.first.title == 'EMI: $emi Taka' &&
        currentItems.first.details == details) {
      lastSig = sig;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This EMI result is already saved')),
      );
      return;
    }

    lastSig = sig;
    await saveSmartToolHistory(
      SmartToolHistoryItem(
        type: 'EMI',
        title: 'EMI: $emi Taka',
        details: details,
        dateTime: DateTime.now(),
      ),
    );

    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('EMI result saved to Smart History')),
    );
  }

  Widget glass(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: widget.darkMode
              ? [const Color(0xFF1C1C1E), const Color(0xFF111214)]
              : [Colors.white, const Color(0xFFE8F2FB)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22D3EE).withOpacity(widget.darkMode ? 0.08 : 0.05),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(widget.darkMode ? 0.30 : 0.10),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget numberInput(String label, String hint, IconData icon, TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => calculateEMI(),
          style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: mutedText),
            filled: true,
            fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
            prefixIcon: Icon(icon, color: Colors.cyanAccent),
          ),
        ),
      ],
    );
  }

  Widget textInput(String label, String hint, IconData icon, TextEditingController controller, {int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          maxLines: maxLines,
          style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: mutedText),
            filled: true,
            fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
            prefixIcon: Icon(icon, color: Colors.cyanAccent),
          ),
        ),
      ],
    );
  }

  void shareEMIResult() {
    final loanTitle = titleController.text.trim().isEmpty ? 'Loan Plan' : titleController.text.trim();
    final noteText = noteController.text.trim();
    showShareSheet(
      context,
      title: 'EMI / Loan Result',
      text: 'Title: $loanTitle\nMonthly EMI: $emi Taka\nTotal Interest: $totalInterest Taka\nTotal Payment: $totalPayment Taka\n$message${noteText.isEmpty ? '' : '\nNote: $noteText'}',
    );
  }

  Widget saveButton() {
    return PressScale(
      borderRadius: BorderRadius.circular(22),
      pressedScale: 0.98,
      onTap: saveCurrentRecord,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF22D3EE), Color(0xFF0E9FB3)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0E9FB3).withOpacity(0.28),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.save_rounded, color: Colors.white),
            SizedBox(width: 10),
            Text(
              'Save EMI to Smart History',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  Widget resultTile({
    required IconData icon,
    required String title,
    required String value,
    required List<Color> colors,
  }) {
    return glass(
      Row(
        children: [
          Container(
            height: 56,
            width: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: colors.last.withOpacity(0.25),
                  blurRadius: 14,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: mutedText, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                Text(value, style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.w900)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text('EMI / Loan Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
        iconTheme: IconThemeData(color: mainText),
        actions: [IconButton(onPressed: shareEMIResult, icon: const Icon(Icons.share_rounded, color: Colors.cyanAccent))],
      ),
      body: Center(
        child: Container(
          width: maxWidth,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.darkMode
                  ? [const Color(0xFF050505), const Color(0xFF000000)]
                  : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                glass(
                  Column(
                    children: [
                      textInput('Loan Title', 'Optional, e.g. Bike Loan, Business Loan', Icons.title_rounded, titleController),
                      const SizedBox(height: 16),
                      numberInput('Loan Amount', 'Enter loan amount', Icons.payments_rounded, loanController),
                      const SizedBox(height: 16),
                      numberInput('Annual Interest Rate', 'Enter yearly rate %', Icons.percent_rounded, rateController),
                      const SizedBox(height: 16),
                      numberInput('Time Period', 'Enter years, e.g. 2', Icons.calendar_month_rounded, yearController),
                      const SizedBox(height: 16),
                      textInput('Note', 'Optional note', Icons.note_alt_rounded, noteController, maxLines: 2),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                resultTile(
                  icon: Icons.account_balance_wallet_rounded,
                  title: 'Monthly EMI',
                  value: '$emi Taka',
                  colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)],
                ),
                const SizedBox(height: 14),
                resultTile(
                  icon: Icons.trending_up_rounded,
                  title: 'Total Interest',
                  value: '$totalInterest Taka',
                  colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)],
                ),
                const SizedBox(height: 14),
                resultTile(
                  icon: Icons.receipt_long_rounded,
                  title: 'Total Payment',
                  value: '$totalPayment Taka',
                  colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)],
                ),
                const SizedBox(height: 14),
                glass(
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.psychology_rounded, color: Colors.cyanAccent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          message,
                          style: TextStyle(color: mutedText, height: 1.35, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                saveButton(),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    'Example: Loan 100000, Rate 10%, Time 2 Years = monthly EMI and total interest.',
                    style: TextStyle(color: mutedText, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}




class AboutDeveloperPage extends StatelessWidget {
  final bool darkMode;

  const AboutDeveloperPage({
    super.key,
    required this.darkMode,
  });

  static const String developerName = 'Masum';
  static const String appName = 'Masum Smart Calculator Pro';
  static const String whatsappNumber = '8801820806464';
  static const String emailAddress = 'farabi13577@gmail.com';
  static const String portfolioUrl = 'https://masum462441.github.io/portfolio/';

  Color get bg => darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get mainText => darkMode ? Colors.white : const Color(0xFF151517);
  Color get mutedText => darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card => darkMode ? const Color(0xFF111214) : Colors.white;
  Color get card2 => darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB);

  void openUrl(String url) {
    openExternalUrl(url);
  }

  void openPortfolio() {
    openUrl(portfolioUrl);
  }

  void openWhatsApp() {
    openUrl('https://wa.me/$whatsappNumber?text=Hello%20Masum,%20I%20am%20using%20Masum%20Smart%20Calculator%20Pro.');
  }

  void openEmail() {
    final subject = Uri.encodeComponent('Masum Smart Calculator Pro');
    final body = Uri.encodeComponent('Hello Masum,');
    openUrl('https://mail.google.com/mail/?view=cm&fs=1&to=$emailAddress&su=$subject&body=$body');
  }

  void showFeedbackDialog(BuildContext context) {
    final feedbackController = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: darkMode ? const Color(0xFF111214) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 6),
        contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
        actionsPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Row(
          children: [
            Container(
              height: 42,
              width: 42,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFFFA733), Color(0xFFFF7C00)]),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.feedback_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Send Feedback',
                style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        content: TextField(
          controller: feedbackController,
          maxLines: 5,
          style: TextStyle(color: mainText, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            hintText: 'Write what you like, problem, or suggestion...',
            hintStyle: TextStyle(color: mutedText),
            filled: true,
            fillColor: darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final feedback = feedbackController.text.trim();

              if (feedback.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please write feedback first')),
                );
                return;
              }

              final encodedFeedback = Uri.encodeComponent(
                'Assalamu Alaikum Masum,\n\nI am using Masum Smart Calculator Pro.\n\nMy feedback:\n$feedback',
              );

              final subject = Uri.encodeComponent('Feedback for Masum Smart Calculator Pro');
              final gmailUrl =
                  'https://mail.google.com/mail/?view=cm&fs=1&to=$emailAddress&su=$subject&body=$encodedFeedback';

              openExternalUrl(gmailUrl);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.send_rounded),
            label: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Widget glassCard({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(18),
    List<Color>? glowColors,
  }) {
    final colors = glowColors ?? const [Color(0xFF22D3EE), Color(0xFF7C4DFF)];

    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: darkMode
              ? [const Color(0xFF1C1C1E), const Color(0xFF111214)]
              : [Colors.white, const Color(0xFFE8F2FB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.85),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.last.withOpacity(darkMode ? 0.16 : 0.08),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(darkMode ? 0.30 : 0.10),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget heroProfile() {
    return glassCard(
      padding: EdgeInsets.zero,
      glowColors: const [Color(0xFF9A6BFF), Color(0xFF22D3EE)],
      child: Stack(
        children: [
          Positioned(
            top: -48,
            right: -35,
            child: Container(
              height: 140,
              width: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF22D3EE).withOpacity(0.18),
              ),
            ),
          ),
          Positioned(
            bottom: -55,
            left: -38,
            child: Container(
              height: 135,
              width: 135,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF9A6BFF).withOpacity(0.16),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF30C96B).withOpacity(0.16),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFF30C96B).withOpacity(0.35)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_rounded, color: Colors.greenAccent, size: 17),
                      SizedBox(width: 6),
                      Text(
                        'Available for Support',
                        style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w900, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  height: 92,
                  width: 92,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF9A6BFF), Color(0xFF22D3EE)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF7C4DFF).withOpacity(0.36),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/logo.jpeg',
                      width: 92,
                      height: 92,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const Icon(Icons.person_rounded, color: Colors.white, size: 50);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  developerName,
                  style: TextStyle(color: mainText, fontSize: 31, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text(
                  'Flutter App Developer',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: mutedText, fontSize: 14, height: 1.35, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 7),
                Text(
                  'Verified Developer • Bangladesh',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: const Color(0xFF30C96B), fontSize: 12, height: 1.35, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  decoration: BoxDecoration(
                    color: darkMode ? const Color(0xFF151517).withOpacity(0.72) : Colors.white.withOpacity(0.72),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.18)),
                  ),
                  child: const Text(
                    'Smart Calculator • Business Tools • PDF Reports',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget infoRow(IconData icon, String title, String value, List<Color> colors) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 42,
          width: 42,
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: mutedText, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(color: mainText, fontSize: 15, height: 1.25, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
      ],
    );
  }

  Widget quickStats() {
    return Row(
      children: [
        Expanded(child: statBox('Tools', '12+', Icons.apps_rounded, const [Color(0xFF22D3EE), Color(0xFF0E9FB3)])),
        const SizedBox(width: 10),
        Expanded(child: statBox('Mode', 'Pro', Icons.workspace_premium_rounded, const [Color(0xFFFFA733), Color(0xFFFF7C00)])),
        const SizedBox(width: 10),
        Expanded(child: statBox('Build', '36.3', Icons.rocket_launch_rounded, const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)])),
      ],
    );
  }

  Widget statBox(String title, String value, IconData icon, List<Color> colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05)),
        boxShadow: [
          BoxShadow(
            color: colors.last.withOpacity(darkMode ? 0.12 : 0.07),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: colors.first, size: 24),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text(title, style: TextStyle(color: mutedText, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget contactButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Color> colors,
    required VoidCallback onTap,
    bool featured = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PressScale(
        borderRadius: BorderRadius.circular(25),
        pressedScale: 0.98,
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: featured
                ? LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight)
                : null,
            color: featured ? null : card,
            borderRadius: BorderRadius.circular(25),
            border: Border.all(
              color: featured
                  ? Colors.white.withOpacity(0.18)
                  : darkMode
                      ? Colors.white.withOpacity(0.08)
                      : Colors.black.withOpacity(0.05),
            ),
            boxShadow: [
              BoxShadow(
                color: colors.last.withOpacity(darkMode ? 0.18 : 0.09),
                blurRadius: 18,
                offset: const Offset(0, 9),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                height: 54,
                width: 54,
                decoration: BoxDecoration(
                  color: featured ? Colors.white.withOpacity(0.17) : null,
                  gradient: featured ? null : LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: colors.last.withOpacity(0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 27),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: featured ? Colors.white : mainText, fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: featured ? Colors.white.withOpacity(0.82) : mutedText,
                        fontSize: 12,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded, color: featured ? Colors.white : mutedText, size: 17),
            ],
          ),
        ),
      ),
    );
  }

  Widget premiumFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card2,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Column(
        children: [
          Text(
            'Built with care by Masum',
            style: TextStyle(color: mainText, fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            'Made for daily calculation, smart records and small business support. Portfolio, WhatsApp and Feedback are connected.',
            textAlign: TextAlign.center,
            style: TextStyle(color: mutedText, height: 1.35, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        title: Text('About Developer', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
        iconTheme: IconThemeData(color: mainText),
      ),
      body: Center(
        child: Container(
          width: maxWidth,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: darkMode
                  ? [const Color(0xFF050505), const Color(0xFF000000)]
                  : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
            child: Column(
              children: [
                AnimatedFadeSlide(delayMs: 0, child: heroProfile()),
                const SizedBox(height: 14),
                AnimatedFadeSlide(delayMs: 80, child: quickStats()),
                const SizedBox(height: 14),
                AnimatedFadeSlide(delayMs: 160, child: glassCard(
                    child: Column(
                      children: [
                        infoRow(Icons.apps_rounded, 'App Name', appName, const [Color(0xFF22D3EE), Color(0xFF0E9FB3)]),
                        const SizedBox(height: 16),
                        infoRow(Icons.public_rounded, 'Portfolio', portfolioUrl, const [Color(0xFF00C9FF), Color(0xFF0072FF)]),
                        const SizedBox(height: 16),
                        infoRow(Icons.verified_rounded, 'Version', 'Version 1.0.0\nBuild 36.3\nPremium Edition', const [Color(0xFF30C96B), Color(0xFF0F9D58)]),
                        const SizedBox(height: 16),
                        infoRow(Icons.favorite_rounded, 'Purpose', 'Daily calculator, smart tools and small business records.', const [Color(0xFFFFA733), Color(0xFFFF7C00)]),
                        const SizedBox(height: 16),
                        infoRow(Icons.auto_awesome_rounded, 'Why this app?', 'Fast calculation, smart records, person-wise PDF and useful business tools in one app.', const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                AnimatedFadeSlide(delayMs: 240, child: contactButton(
                    icon: Icons.public_rounded,
                    title: 'Portfolio / Website',
                    subtitle: portfolioUrl,
                    colors: const [Color(0xFF00C9FF), Color(0xFF0072FF)],
                    onTap: openPortfolio,
                    featured: true,
                  ),
                ),
                AnimatedFadeSlide(delayMs: 320, child: contactButton(
                    icon: Icons.chat_rounded,
                    title: 'WhatsApp Support',
                    subtitle: '+$whatsappNumber • Support: 10:00 AM - 10:00 PM',
                    colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)],
                    onTap: openWhatsApp,
                  ),
                ),
                AnimatedFadeSlide(delayMs: 400, child: contactButton(
                    icon: Icons.email_rounded,
                    title: 'Email',
                    subtitle: emailAddress,
                    colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)],
                    onTap: openEmail,
                  ),
                ),
                AnimatedFadeSlide(delayMs: 480, child: contactButton(
                    icon: Icons.feedback_rounded,
                    title: 'Send Feedback',
                    subtitle: 'Write feedback and send to $emailAddress',
                    colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)],
                    onTap: () => showFeedbackDialog(context),
                  ),
                ),
                AnimatedFadeSlide(delayMs: 560, child: premiumFooter()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}




class PinLockGate extends StatefulWidget {
  final Widget child;
  final bool darkMode;
  const PinLockGate({super.key, required this.child, required this.darkMode});

  @override
  State<PinLockGate> createState() => _PinLockGateState();
}

class _PinLockGateState extends State<PinLockGate> {
  bool loading = true;
  bool enabled = false;
  bool hasPinData = false;
  final pinController = TextEditingController();
  String error = '';

  @override
  void initState() {
    super.initState();
    loadPin();
  }

  @override
  void dispose() {
    pinController.dispose();
    super.dispose();
  }

  Future<void> loadPin() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      enabled = prefs.getBool('pin_lock_enabled') ?? false;
      final oldRawPin = prefs.getString('pin_lock_code') ?? '';
      final hash = prefs.getString('pin_lock_hash') ?? '';
      hasPinData = oldRawPin.isNotEmpty || hash.isNotEmpty;
      loading = false;
    });
  }

  Future<void> unlock() async {
    if (await verifySavedPinCode(pinController.text.trim())) {
      if (!mounted) return;
      setState(() => enabled = false);
    } else {
      if (!mounted) return;
      setState(() => error = 'Wrong PIN');
      HapticFeedback.mediumImpact();
    }
  }

  Future<String?> askText({required String title, required String hint, bool pin = false}) async {
    return masumInputDialog(context, title: title, hint: hint, pin: pin);
  }

  Future<String?> askNewPinDialog() async {
    final first = TextEditingController();
    final second = TextEditingController();
    String localError = '';
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Set New PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: const InputDecoration(counterText: '', hintText: 'Enter 4 digit new PIN'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: second,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: const InputDecoration(counterText: '', hintText: 'Confirm 4 digit PIN'),
              ),
              if (localError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(localError, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final a = first.text.trim();
                final b = second.text.trim();
                if (a.length != 4 || int.tryParse(a) == null) {
                  setDialogState(() => localError = '4 digit PIN দিন');
                  return;
                }
                if (a != b) {
                  setDialogState(() => localError = 'Confirm PIN মিলছে না');
                  return;
                }
                FocusScope.of(dialogContext).unfocus();
                Navigator.pop(dialogContext, a);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    second.dispose();
    return result;
  }

  Future<void> setNewPinAfterRecovery() async {
    final newPin = await askNewPinDialog();
    if (newPin == null) return;
    final prefs = await SharedPreferences.getInstance();
    final salt = generateSecuritySalt();
    await prefs.setBool('pin_lock_enabled', true);
    await prefs.setString('pin_lock_salt', salt);
    await prefs.setString('pin_lock_hash', masumSecureHash(newPin, salt));
    await prefs.remove('pin_lock_code');
    AuthBackupService.scheduleAutoBackup();
    if (!mounted) return;
    pinController.clear();
    setState(() {
      enabled = false;
      error = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN reset completed')));
  }

  Future<void> resetWithRecoveryCode() async {
    final code = await masumInputDialog(context, title: 'Recovery Code', hint: 'MASUM-0000-0000', initialValue: 'MASUM-');
    if (code == null) return;
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString('pin_recovery_code_salt') ?? '';
    final hash = prefs.getString('pin_recovery_code_hash') ?? '';
    final cleanCode = code.trim().toUpperCase().replaceAll(' ', '');
    if (salt.isNotEmpty && hash.isNotEmpty && masumSecureHash(cleanCode, salt) == hash) {
      await setNewPinAfterRecovery();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recovery code ভুল')));
    }
  }

  Future<void> resetWithGmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUid = prefs.getString('pin_recovery_uid') ?? '';
      final savedEmail = prefs.getString('pin_recovery_email') ?? '';
      if (savedUid.isEmpty) {
        if (!mounted) return;
        await masumInfoDialog(context, 'Gmail Recovery Not Setup', 'এই PIN-এর জন্য Gmail recovery আগে connect করা হয়নি। App Lock settings থেকে Connect Gmail Recovery চাপলে পরেরবার Google account verify করে reset হবে। এখন Recovery Code ব্যবহার করো।');
        return;
      }
      await masumInfoDialog(context, 'Gmail Verify', 'Gmail recovery-তে email OTP যায় না। নিরাপত্তার জন্য Google account আবার select/login করতে হবে। একই Gmail verify হলে নতুন PIN set করা যাবে।');
      final user = await AuthBackupService.signInWithGoogle(forceAccountPicker: true);
      if (user == null) return;
      if (user.uid != savedUid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('এই Gmail দিয়ে recovery হবে না। Setup Gmail: ${savedEmail.isEmpty ? 'unknown' : savedEmail}')));
        }
        return;
      }
      await setNewPinAfterRecovery();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gmail recovery failed: $e')));
    }
  }

  Future<void> phoneOtpDisabledInfo() async {
    await masumInfoDialog(context, 'Phone OTP disabled', 'Phone OTP চালাতে Firebase Blaze/Billing লাগে। তাই এই version-এ Phone OTP recovery বন্ধ রাখা হয়েছে। Recovery Code বা Gmail Verify ব্যবহার করো।');
  }

  Future<void> resetAppLockLocal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset App Lock?'),
        content: const Text('এটা শুধু PIN lock remove করবে। Business data delete হবে না। Phone আপনার নিজের হলে Continue চাপুন।'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pin_lock_enabled', false);
    await prefs.remove('pin_lock_code');
    await prefs.remove('pin_lock_hash');
    await prefs.remove('pin_lock_salt');
    AuthBackupService.scheduleAutoBackup();
    if (!mounted) return;
    setState(() {
      enabled = false;
      error = '';
      pinController.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App Lock reset done')));
  }

  void forgotPinSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: widget.darkMode ? const Color(0xFF111214) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Forgot PIN?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text('Phone OTP billing লাগে, তাই এখন Recovery Code অথবা Gmail Verify ব্যবহার করো।', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.vpn_key_rounded, color: Colors.cyan),
            title: const Text('Reset with Recovery Code'),
            subtitle: const Text('Saved recovery code দিয়ে reset'),
            onTap: () async {
              Navigator.of(sheetContext).pop();
              await Future.delayed(const Duration(milliseconds: 260));
              if (mounted) resetWithRecoveryCode();
            },
          ),
          ListTile(
            leading: const Icon(Icons.email_rounded, color: Colors.orangeAccent),
            title: const Text('Reset with Gmail Verify'),
            subtitle: const Text('Same Gmail আবার verify করলে reset হবে'),
            onTap: () async {
              Navigator.of(sheetContext).pop();
              await Future.delayed(const Duration(milliseconds: 260));
              if (mounted) resetWithGmail();
            },
          ),
          ListTile(
            leading: const Icon(Icons.phone_disabled_rounded, color: Colors.grey),
            title: const Text('Phone OTP disabled'),
            subtitle: const Text('Firebase Billing লাগবে'),
            onTap: () async {
              Navigator.of(sheetContext).pop();
              await Future.delayed(const Duration(milliseconds: 260));
              if (mounted) phoneOtpDisabledInfo();
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock_reset_rounded, color: Colors.redAccent),
            title: const Text('Reset App Lock'),
            subtitle: const Text('শুধু PIN lock remove হবে, data delete হবে না'),
            onTap: () async {
              Navigator.of(sheetContext).pop();
              await Future.delayed(const Duration(milliseconds: 260));
              if (mounted) resetAppLockLocal();
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading || !enabled || !hasPinData) return widget.child;
    final bg = widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
    final card = widget.darkMode ? const Color(0xFF111214) : Colors.white;
    final mainText = widget.darkMode ? Colors.white : const Color(0xFF111111);
    final muted = widget.darkMode ? Colors.white60 : const Color(0xFF526070);
    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Container(
          width: MediaQuery.of(context).size.width > 700 ? 420 : double.infinity,
          padding: const EdgeInsets.all(22),
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: widget.darkMode ? Colors.white12 : Colors.black12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(height: 70, width: 70, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFFFB143), Color(0xFFFF7C00)]), borderRadius: BorderRadius.circular(24)), child: const Icon(Icons.lock_rounded, color: Colors.white, size: 34)),
                const SizedBox(height: 16),
                Text('Masum App Lock', style: TextStyle(color: mainText, fontSize: 24, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text('Enter your 4 digit PIN', style: TextStyle(color: muted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 18),
                TextField(
                  controller: pinController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: mainText, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 8),
                  decoration: InputDecoration(counterText: '', filled: true, fillColor: widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), errorText: error.isEmpty ? null : error),
                  onSubmitted: (_) { unlock(); },
                ),
                const SizedBox(height: 16),
                SizedBox(width: double.infinity, height: 52, child: ElevatedButton.icon(onPressed: () { unlock(); }, icon: const Icon(Icons.lock_open_rounded), label: const Text('Unlock'))),
                const SizedBox(height: 8),
                TextButton(onPressed: forgotPinSheet, child: const Text('Forgot PIN?')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PinLockSettingsPage extends StatefulWidget {
  final bool darkMode;
  const PinLockSettingsPage({super.key, required this.darkMode});

  @override
  State<PinLockSettingsPage> createState() => _PinLockSettingsPageState();
}

class _PinLockSettingsPageState extends State<PinLockSettingsPage> {
  final pinController = TextEditingController();
  final confirmPinController = TextEditingController();
  final phoneController = TextEditingController();
  String lastRecoveryCode = '';
  bool enabled = false;
  bool phoneVerified = false;
  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get card => widget.darkMode ? const Color(0xFF111214) : Colors.white;
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF111111);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);

  @override
  void initState() {
    super.initState();
    loadPinState();
  }

  @override
  void dispose() {
    pinController.dispose();
    confirmPinController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  Future<void> loadPinState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      enabled = prefs.getBool('pin_lock_enabled') ?? false;
      phoneController.text = prefs.getString('pin_recovery_phone') ?? '';
      phoneVerified = prefs.getBool('pin_recovery_phone_verified') ?? false;
    });
  }

  Future<void> savePin() async {
    final pin = pinController.text.trim();
    final confirm = confirmPinController.text.trim();
    if (pin.length != 4 || int.tryParse(pin) == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('4 digit number PIN দিন')));
      return;
    }
    if (pin != confirm) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Confirm PIN মিলছে না')));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final pinSalt = generateSecuritySalt();
    final recoveryCode = generateRecoveryCode();
    final recoverySalt = generateSecuritySalt();
    await prefs.setBool('pin_lock_enabled', true);
    await prefs.setString('pin_lock_salt', pinSalt);
    await prefs.setString('pin_lock_hash', masumSecureHash(pin, pinSalt));
    await prefs.remove('pin_lock_code');
    await prefs.setString('pin_recovery_code_salt', recoverySalt);
    await prefs.setString('pin_recovery_code_hash', masumSecureHash(recoveryCode, recoverySalt));
    final currentUser = AuthBackupService.currentUser;
    if (currentUser != null) {
      await prefs.setString('pin_recovery_uid', currentUser.uid);
      await prefs.setString('pin_recovery_email', currentUser.email ?? '');
    }
    final enteredPhone = normalizeBangladeshPhone(phoneController.text.trim());
    if (enteredPhone.isNotEmpty) {
      final oldPhone = prefs.getString('pin_recovery_phone') ?? '';
      final oldVerified = prefs.getBool('pin_recovery_phone_verified') ?? false;
      await prefs.setString('pin_recovery_phone', enteredPhone);
      await prefs.setBool('pin_recovery_phone_verified', oldVerified && oldPhone == enteredPhone);
    }
    AuthBackupService.scheduleAutoBackup();
    if (!mounted) return;
    setState(() { enabled = true; lastRecoveryCode = recoveryCode; phoneVerified = prefs.getBool('pin_recovery_phone_verified') ?? false; });
    pinController.clear();
    confirmPinController.clear();
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Recovery Code Save করো'),
      content: SelectableText('PIN ভুলে গেলে এই code দিয়ে reset করতে পারবে:\n\n$recoveryCode\n\nএটা screenshot নিয়ে রাখো বা খাতায় লিখে রাখো।'),
      actions: [ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Saved'))],
    ));
  }

  Future<void> setupGmailRecovery() async {
    try {
      var user = AuthBackupService.currentUser;
      user ??= await AuthBackupService.signInWithGoogle();
      if (user == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gmail login cancel হয়েছে')));
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pin_recovery_uid', user.uid);
      await prefs.setString('pin_recovery_email', user.email ?? '');
      AuthBackupService.scheduleAutoBackup();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gmail recovery connected: ${user.email ?? 'Gmail'}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gmail recovery failed: $e')));
    }
  }

  Future<void> verifyPhoneRecovery() async {
    final phone = phoneController.text.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Phone number দাও')));
      return;
    }
    final ok = await verifyPhoneOtpWithFirebase(context, phone);
    if (!mounted) return;
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      final normalizedPhone = normalizeBangladeshPhone(phone);
      await prefs.setString('pin_recovery_phone', normalizedPhone);
      await prefs.setBool('pin_recovery_phone_verified', true);
      AuthBackupService.scheduleAutoBackup();
      setState(() {
        phoneController.text = normalizedPhone;
        phoneVerified = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Phone recovery verified: $normalizedPhone')));
    }
  }

  Future<void> disablePin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pin_lock_enabled', false);
    await prefs.remove('pin_lock_code');
    await prefs.remove('pin_lock_hash');
    await prefs.remove('pin_lock_salt');
    await prefs.remove('pin_recovery_code_hash');
    await prefs.remove('pin_recovery_code_salt');
    await prefs.remove('pin_recovery_email');
    await prefs.remove('pin_recovery_uid');
    await prefs.remove('pin_recovery_phone');
    await prefs.remove('pin_recovery_phone_verified');
    AuthBackupService.scheduleAutoBackup();
    if (!mounted) return;
    setState(() => enabled = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN lock disabled')));
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, iconTheme: IconThemeData(color: mainText), title: Text('App Lock / PIN', style: TextStyle(color: mainText, fontWeight: FontWeight.w900))),
      body: Center(
        child: Container(
          width: maxWidth,
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white12 : Colors.black12)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(enabled ? 'PIN Lock is ON' : 'PIN Lock is OFF', style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Text('Customer notes, phone number, due records protect করার জন্য 4 digit PIN ব্যবহার করো।', style: TextStyle(color: mutedText, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 16),
                    TextField(controller: pinController, keyboardType: TextInputType.number, maxLength: 4, obscureText: true, style: TextStyle(color: mainText, fontSize: 20, fontWeight: FontWeight.bold), decoration: InputDecoration(counterText: '', hintText: 'Enter 4 digit PIN', filled: true, fillColor: widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.lock_rounded, color: Colors.orangeAccent))),
                    const SizedBox(height: 10),
                    TextField(controller: confirmPinController, keyboardType: TextInputType.number, maxLength: 4, obscureText: true, style: TextStyle(color: mainText, fontSize: 20, fontWeight: FontWeight.bold), decoration: InputDecoration(counterText: '', hintText: 'Confirm 4 digit PIN', filled: true, fillColor: widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.verified_user_rounded, color: Colors.greenAccent))),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFF4F7FB),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: widget.darkMode ? Colors.white10 : Colors.black12),
                      ),
                      child: Text('Recovery: Recovery Code auto generate হবে। Gmail recovery connect করলে Forgot PIN থেকে Google account verify করে reset করা যাবে। Phone OTP আপাতত বন্ধ রাখা হয়েছে, কারণ Firebase Billing লাগে।', style: TextStyle(color: mutedText, fontSize: 12, height: 1.4, fontWeight: FontWeight.w700)),
                    ),
                    if (lastRecoveryCode.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: SelectableText('Recovery Code: $lastRecoveryCode', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w900))),
                    const SizedBox(height: 10),
                    SizedBox(width: double.infinity, height: 48, child: OutlinedButton.icon(onPressed: setupGmailRecovery, icon: const Icon(Icons.email_rounded), label: const Text('Connect Gmail Recovery'))),
                    const SizedBox(height: 10),
                    SizedBox(width: double.infinity, height: 48, child: OutlinedButton.icon(onPressed: () => masumInfoDialog(context, 'Phone OTP disabled', 'Phone OTP চালাতে Firebase Blaze/Billing লাগে। তাই এই version-এ Phone OTP recovery বন্ধ রাখা হয়েছে।'), icon: const Icon(Icons.phone_disabled_rounded), label: const Text('Phone OTP disabled'))),
                    const SizedBox(height: 12),
                    Row(children: [Expanded(child: ElevatedButton.icon(onPressed: savePin, icon: const Icon(Icons.save_rounded), label: Text(enabled ? 'Change PIN' : 'Enable PIN'))), const SizedBox(width: 10), Expanded(child: OutlinedButton.icon(onPressed: enabled ? disablePin : null, icon: const Icon(Icons.lock_open_rounded), label: const Text('Disable')))]),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ShopProfile {
  String shopName;
  String ownerName;
  String phone;
  String address;
  String email;
  String footer;

  ShopProfile({required this.shopName, required this.ownerName, required this.phone, required this.address, required this.email, required this.footer});

  factory ShopProfile.empty() => ShopProfile(shopName: 'Masum Smart Calculator Pro', ownerName: '', phone: '', address: '', email: '', footer: 'Thank you for your business');

  Map<String, dynamic> toJson() => {'shopName': shopName, 'ownerName': ownerName, 'phone': phone, 'address': address, 'email': email, 'footer': footer};

  factory ShopProfile.fromJson(Map<String, dynamic> json) => ShopProfile(
    shopName: json['shopName'] ?? 'Masum Smart Calculator Pro',
    ownerName: json['ownerName'] ?? '',
    phone: json['phone'] ?? '',
    address: json['address'] ?? '',
    email: json['email'] ?? '',
    footer: json['footer'] ?? 'Thank you for your business',
  );
}

class CustomerNote {
  String id;
  String name;
  String phone;
  String address;
  String note;
  String tag;
  double amount;
  bool important;
  DateTime dateTime;

  CustomerNote({required this.id, required this.name, required this.phone, required this.address, required this.note, required this.tag, required this.amount, required this.important, required this.dateTime});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'address': address, 'note': note, 'tag': tag, 'amount': amount, 'important': important, 'dateTime': dateTime.toIso8601String()};
  factory CustomerNote.fromJson(Map<String, dynamic> json) => CustomerNote(id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(), name: json['name'] ?? '', phone: json['phone'] ?? '', address: json['address'] ?? '', note: json['note'] ?? '', tag: json['tag'] ?? 'Customer', amount: (json['amount'] is num ? (json['amount'] as num).toDouble() : double.tryParse('${json['amount']}') ?? 0), important: json['important'] == true, dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now());
}

class DuePaymentRecord {
  String id;
  String name;
  String phone;
  double total;
  double paid;
  String note;
  DateTime dateTime;

  DuePaymentRecord({required this.id, required this.name, required this.phone, required this.total, required this.paid, required this.note, required this.dateTime});
  double get due => total - paid;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'total': total, 'paid': paid, 'note': note, 'dateTime': dateTime.toIso8601String()};
  factory DuePaymentRecord.fromJson(Map<String, dynamic> json) => DuePaymentRecord(id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(), name: json['name'] ?? '', phone: json['phone'] ?? '', total: (json['total'] is num ? (json['total'] as num).toDouble() : double.tryParse('${json['total']}') ?? 0), paid: (json['paid'] is num ? (json['paid'] as num).toDouble() : double.tryParse('${json['paid']}') ?? 0), note: json['note'] ?? '', dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now());
}

class CashbookEntry {
  String id;
  String title;
  String type;
  double amount;
  String note;
  DateTime dateTime;

  CashbookEntry({required this.id, required this.title, required this.type, required this.amount, required this.note, required this.dateTime});
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'type': type, 'amount': amount, 'note': note, 'dateTime': dateTime.toIso8601String()};
  factory CashbookEntry.fromJson(Map<String, dynamic> json) => CashbookEntry(id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(), title: json['title'] ?? '', type: json['type'] ?? 'Income', amount: (json['amount'] is num ? (json['amount'] as num).toDouble() : double.tryParse('${json['amount']}') ?? 0), note: json['note'] ?? '', dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now());
}

class FollowupReminder {
  String id;
  String name;
  String phone;
  String note;
  DateTime reminderDate;
  bool done;

  FollowupReminder({required this.id, required this.name, required this.phone, required this.note, required this.reminderDate, required this.done});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'note': note, 'reminderDate': reminderDate.toIso8601String(), 'done': done};
  factory FollowupReminder.fromJson(Map<String, dynamic> json) => FollowupReminder(id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(), name: json['name'] ?? '', phone: json['phone'] ?? '', note: json['note'] ?? '', reminderDate: DateTime.tryParse(json['reminderDate'] ?? '') ?? DateTime.now(), done: json['done'] == true);
}

class ReceiptMemo {
  String id;
  String name;
  String phone;
  String items;
  double total;
  double paid;
  String note;
  DateTime dateTime;

  ReceiptMemo({required this.id, required this.name, required this.phone, required this.items, required this.total, required this.paid, required this.note, required this.dateTime});
  double get due => total - paid;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'items': items, 'total': total, 'paid': paid, 'note': note, 'dateTime': dateTime.toIso8601String()};
  factory ReceiptMemo.fromJson(Map<String, dynamic> json) => ReceiptMemo(id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(), name: json['name'] ?? '', phone: json['phone'] ?? '', items: json['items'] ?? '', total: (json['total'] is num ? (json['total'] as num).toDouble() : double.tryParse('${json['total']}') ?? 0), paid: (json['paid'] is num ? (json['paid'] as num).toDouble() : double.tryParse('${json['paid']}') ?? 0), note: json['note'] ?? '', dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now());
}

class BusinessNotebookPage extends StatefulWidget {
  final bool darkMode;
  const BusinessNotebookPage({super.key, required this.darkMode});

  @override
  State<BusinessNotebookPage> createState() => _BusinessNotebookPageState();
}

class _BusinessNotebookPageState extends State<BusinessNotebookPage> {
  final searchController = TextEditingController();
  String query = '';
  List<CustomerNote> customers = [];
  List<DuePaymentRecord> dues = [];
  List<CashbookEntry> cashbook = [];
  List<FollowupReminder> reminders = [];
  List<ReceiptMemo> receipts = [];
  ShopProfile shopProfile = ShopProfile.empty();
  bool busy = false;

  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB);
  Color get card => widget.darkMode ? const Color(0xFF111214) : Colors.white;
  Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF111111);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);

  @override
  void initState() {
    super.initState();
    loadAll();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  String id() => DateTime.now().microsecondsSinceEpoch.toString();
  String money(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  String date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Future<void> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      customers = (prefs.getStringList('customer_notebook') ?? []).map((e) => CustomerNote.fromJson(Map<String, dynamic>.from(jsonDecode(e)))).toList();
      dues = (prefs.getStringList('due_payment_records') ?? []).map((e) => DuePaymentRecord.fromJson(Map<String, dynamic>.from(jsonDecode(e)))).toList();
      cashbook = (prefs.getStringList('daily_cashbook_entries') ?? []).map((e) => CashbookEntry.fromJson(Map<String, dynamic>.from(jsonDecode(e)))).toList();
      reminders = (prefs.getStringList('followup_reminders') ?? []).map((e) => FollowupReminder.fromJson(Map<String, dynamic>.from(jsonDecode(e)))).toList();
      receipts = (prefs.getStringList('receipt_memos') ?? []).map((e) => ReceiptMemo.fromJson(Map<String, dynamic>.from(jsonDecode(e)))).toList();
      final profileRaw = prefs.getString('business_profile') ?? '';
      if (profileRaw.isNotEmpty) shopProfile = ShopProfile.fromJson(Map<String, dynamic>.from(jsonDecode(profileRaw)));
    });
  }

  Future<void> saveAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('customer_notebook', customers.map((e) => jsonEncode(e.toJson())).toList());
    await prefs.setStringList('due_payment_records', dues.map((e) => jsonEncode(e.toJson())).toList());
    await prefs.setStringList('daily_cashbook_entries', cashbook.map((e) => jsonEncode(e.toJson())).toList());
    await prefs.setStringList('followup_reminders', reminders.map((e) => jsonEncode(e.toJson())).toList());
    await prefs.setStringList('receipt_memos', receipts.map((e) => jsonEncode(e.toJson())).toList());
    await prefs.setString('business_profile', jsonEncode(shopProfile.toJson()));
    AuthBackupService.scheduleAutoBackup();
  }

  bool has(String value) => value.toLowerCase().contains(query.toLowerCase());
  List<CustomerNote> get filteredCustomers => customers.where((e) => query.isEmpty || has('${e.name} ${e.phone} ${e.address} ${e.note} ${e.tag}')).toList();
  List<DuePaymentRecord> get filteredDues => dues.where((e) => query.isEmpty || has('${e.name} ${e.phone} ${e.note}')).toList();
  List<CashbookEntry> get filteredCashbook => cashbook.where((e) => query.isEmpty || has('${e.title} ${e.type} ${e.note} ${date(e.dateTime)}')).toList();
  List<FollowupReminder> get filteredReminders => reminders.where((e) => query.isEmpty || has('${e.name} ${e.phone} ${e.note} ${date(e.reminderDate)}')).toList();
  List<ReceiptMemo> get filteredReceipts => receipts.where((e) => query.isEmpty || has('${e.name} ${e.phone} ${e.items} ${e.note}')).toList();

  InputDecoration fieldDecoration(String label, IconData icon) => InputDecoration(labelText: label, prefixIcon: Icon(icon, color: Colors.orangeAccent), filled: true, fillColor: widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none));

  void editShopProfileDialog() {
    final shopName = TextEditingController(text: shopProfile.shopName);
    final ownerName = TextEditingController(text: shopProfile.ownerName);
    final phone = TextEditingController(text: shopProfile.phone);
    final address = TextEditingController(text: shopProfile.address);
    final email = TextEditingController(text: shopProfile.email);
    final footer = TextEditingController(text: shopProfile.footer);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card2,
        title: const Text('Shop / Business Profile'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: shopName, decoration: fieldDecoration('Shop / Business Name', Icons.storefront_rounded)),
              const SizedBox(height: 10),
              TextField(controller: ownerName, decoration: fieldDecoration('Owner Name', Icons.person_rounded)),
              const SizedBox(height: 10),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: fieldDecoration('Shop Phone', Icons.phone_rounded)),
              const SizedBox(height: 10),
              TextField(controller: address, maxLines: 2, decoration: fieldDecoration('Shop Address', Icons.location_on_rounded)),
              const SizedBox(height: 10),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: fieldDecoration('Email optional', Icons.email_rounded)),
              const SizedBox(height: 10),
              TextField(controller: footer, maxLines: 2, decoration: fieldDecoration('Footer Message', Icons.favorite_rounded)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                shopProfile = ShopProfile(
                  shopName: shopName.text.trim().isEmpty ? 'Masum Smart Calculator Pro' : shopName.text.trim(),
                  ownerName: ownerName.text.trim(),
                  phone: phone.text.trim(),
                  address: address.text.trim(),
                  email: email.text.trim(),
                  footer: footer.text.trim().isEmpty ? 'Thank you for your business' : footer.text.trim(),
                );
              });
              saveAll();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Shop profile saved')));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget searchBox() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: TextField(
          controller: searchController,
          onChanged: (v) => setState(() => query = v.trim()),
          style: TextStyle(color: mainText, fontWeight: FontWeight.w700),
          decoration: fieldDecoration('Search name, phone, date, amount', Icons.search_rounded).copyWith(suffixIcon: query.isEmpty ? null : IconButton(icon: const Icon(Icons.close_rounded), onPressed: () { searchController.clear(); setState(() => query = ''); })),
        ),
      );

  Widget emptyText(String text) => Center(child: Padding(padding: const EdgeInsets.all(22), child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: mutedText, fontWeight: FontWeight.w800))));

  Widget premiumCard({required Widget child}) => Container(margin: const EdgeInsets.fromLTRB(14, 0, 14, 12), padding: const EdgeInsets.all(14), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8F2FB)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(24), border: Border.all(color: widget.darkMode ? Colors.white12 : Colors.black12)), child: child);

  Future<DateTime?> pickDate(DateTime initial) => showDatePicker(context: context, initialDate: initial, firstDate: DateTime(2020), lastDate: DateTime(2100));

  Future<void> exportBusinessPdf(String title, String body, String fileName) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await exportTextPdf(context, title: title, text: body, fileName: fileName);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String customerReportText(List<CustomerNote> list, String title) {
    final b = StringBuffer()..writeln(title)..writeln('Total Records: ${list.length}')..writeln('');
    for (final e in list) {
      b..writeln('Name: ${e.name}')..writeln('Phone: ${e.phone}')..writeln('Address: ${e.address}')..writeln('Tag: ${e.tag}')..writeln('Amount/Due: ${money(e.amount)}')..writeln('Important: ${e.important ? 'Yes' : 'No'}')..writeln('Note: ${e.note}')..writeln('Date: ${date(e.dateTime)}')..writeln('------------------------------');
    }
    return b.toString();
  }

  String dueReportText(List<DuePaymentRecord> list, String title) {
    final total = list.fold<double>(0, (p, e) => p + e.total);
    final paid = list.fold<double>(0, (p, e) => p + e.paid);
    final b = StringBuffer()..writeln(title)..writeln('Total: ${money(total)}')..writeln('Paid: ${money(paid)}')..writeln('Due: ${money(total - paid)}')..writeln('');
    for (final e in list) {
      b..writeln('Customer: ${e.name}')..writeln('Phone: ${e.phone}')..writeln('Total: ${money(e.total)}')..writeln('Paid: ${money(e.paid)}')..writeln('Due: ${money(e.due)}')..writeln('Note: ${e.note}')..writeln('Date: ${date(e.dateTime)}')..writeln('------------------------------');
    }
    return b.toString();
  }

  String cashbookReportText(List<CashbookEntry> list, String title) {
    final income = list.where((e) => e.type == 'Income').fold<double>(0, (p, e) => p + e.amount);
    final expense = list.where((e) => e.type == 'Expense').fold<double>(0, (p, e) => p + e.amount);
    final b = StringBuffer()..writeln(title)..writeln('Income: ${money(income)}')..writeln('Expense: ${money(expense)}')..writeln('Balance: ${money(income - expense)}')..writeln('');
    for (final e in list) {
      b..writeln('${e.type}: ${e.title}')..writeln('Amount: ${money(e.amount)}')..writeln('Note: ${e.note}')..writeln('Date: ${date(e.dateTime)}')..writeln('------------------------------');
    }
    return b.toString();
  }

  String receiptText(ReceiptMemo e) {
    final receiptNo = e.id.length > 8 ? e.id.substring(e.id.length - 8) : e.id;
    final b = StringBuffer();
    b.writeln(shopProfile.shopName);
    if (shopProfile.ownerName.trim().isNotEmpty) b.writeln('Owner: ${shopProfile.ownerName}');
    if (shopProfile.phone.trim().isNotEmpty) b.writeln('Phone: ${shopProfile.phone}');
    if (shopProfile.address.trim().isNotEmpty) b.writeln('Address: ${shopProfile.address}');
    if (shopProfile.email.trim().isNotEmpty) b.writeln('Email: ${shopProfile.email}');
    b.writeln('');
    b.writeln('Receipt / Memo');
    b.writeln('Receipt No: $receiptNo');
    b.writeln('Date: ${date(e.dateTime)}');
    b.writeln('');
    b.writeln('Customer: ${e.name}');
    b.writeln('Phone: ${e.phone}');
    b.writeln('');
    b.writeln('Items / Details:');
    b.writeln(e.items);
    b.writeln('');
    b.writeln('Total: ${money(e.total)}');
    b.writeln('Paid: ${money(e.paid)}');
    b.writeln('Due: ${money(e.due)}');
    if (e.note.trim().isNotEmpty) b.writeln('Note: ${e.note}');
    b.writeln('');
    b.writeln('Signature: __________________');
    b.writeln('');
    b.writeln(shopProfile.footer.trim().isEmpty ? 'Thank you for your business' : shopProfile.footer.trim());
    return b.toString();
  }

  void exportAllCurrentTab(int tabIndex) {
    if (tabIndex == 0) exportBusinessPdf('Customer Notebook Report', customerReportText(filteredCustomers, 'Customer Notebook Report'), 'masum_customer_notebook.pdf');
    if (tabIndex == 1) exportBusinessPdf('Due Payment Report', dueReportText(filteredDues, 'Due Payment Report'), 'masum_due_payment_report.pdf');
    if (tabIndex == 2) exportBusinessPdf('Daily Cashbook Report', cashbookReportText(filteredCashbook, 'Daily Cashbook Report'), 'masum_daily_cashbook_report.pdf');
    if (tabIndex == 3) {
      final b = StringBuffer()..writeln('Follow-up Reminders')..writeln('Total: ${filteredReminders.length}')..writeln('');
      for (final e in filteredReminders) { b..writeln('Name: ${e.name}')..writeln('Phone: ${e.phone}')..writeln('Reminder Date: ${date(e.reminderDate)}')..writeln('Status: ${e.done ? 'Done' : 'Pending'}')..writeln('Note: ${e.note}')..writeln('------------------------------'); }
      exportBusinessPdf('Follow-up Reminders', b.toString(), 'masum_followup_reminders.pdf');
    }
    if (tabIndex == 4) {
      final b = StringBuffer()..writeln('Receipt / Memo Report')..writeln('Total: ${filteredReceipts.length}')..writeln('');
      for (final e in filteredReceipts) { b..writeln(receiptText(e))..writeln('------------------------------'); }
      exportBusinessPdf('Receipt / Memo Report', b.toString(), 'masum_receipt_memo_report.pdf');
    }
  }

  void addCustomerDialog({CustomerNote? edit}) {
    final name = TextEditingController(text: edit?.name ?? '');
    final phone = TextEditingController(text: edit?.phone ?? '');
    final address = TextEditingController(text: edit?.address ?? '');
    final note = TextEditingController(text: edit?.note ?? '');
    final tag = TextEditingController(text: edit?.tag ?? 'Customer');
    final amount = TextEditingController(text: edit == null ? '' : money(edit.amount));
    bool important = edit?.important ?? false;
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(backgroundColor: card2, title: Text(edit == null ? 'Add Customer Note' : 'Edit Customer Note'), content: SingleChildScrollView(child: Column(children: [TextField(controller: name, decoration: fieldDecoration('Name', Icons.person_rounded)), const SizedBox(height: 10), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: fieldDecoration('Phone Number', Icons.phone_rounded)), const SizedBox(height: 10), TextField(controller: address, maxLines: 2, decoration: fieldDecoration('Address', Icons.location_on_rounded)), const SizedBox(height: 10), TextField(controller: amount, keyboardType: TextInputType.number, decoration: fieldDecoration('Amount / Due', Icons.payments_rounded)), const SizedBox(height: 10), TextField(controller: tag, decoration: fieldDecoration('Tag: Customer / Supplier / Personal', Icons.sell_rounded)), const SizedBox(height: 10), TextField(controller: note, maxLines: 3, decoration: fieldDecoration('Important Note', Icons.note_alt_rounded)), SwitchListTile(value: important, onChanged: (v) => setLocal(() => important = v), title: const Text('Mark Important'))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () { final item = CustomerNote(id: edit?.id ?? id(), name: name.text.trim().isEmpty ? 'No Name' : name.text.trim(), phone: phone.text.trim(), address: address.text.trim(), note: note.text.trim(), tag: tag.text.trim().isEmpty ? 'Customer' : tag.text.trim(), amount: double.tryParse(amount.text.trim()) ?? 0, important: important, dateTime: edit?.dateTime ?? DateTime.now()); setState(() { if (edit == null) { customers.insert(0, item); } else { final i = customers.indexWhere((e) => e.id == edit.id); if (i >= 0) customers[i] = item; } }); saveAll(); Navigator.pop(context); }, child: const Text('Save'))])));
  }

  void addDueDialog({DuePaymentRecord? edit}) {
    final name = TextEditingController(text: edit?.name ?? '');
    final phone = TextEditingController(text: edit?.phone ?? '');
    final total = TextEditingController(text: edit == null ? '' : money(edit.total));
    final paid = TextEditingController(text: edit == null ? '' : money(edit.paid));
    final note = TextEditingController(text: edit?.note ?? '');
    showDialog(context: context, builder: (_) => AlertDialog(backgroundColor: card2, title: Text(edit == null ? 'Add Due / Payment' : 'Edit Due / Payment'), content: SingleChildScrollView(child: Column(children: [TextField(controller: name, decoration: fieldDecoration('Customer Name', Icons.person_rounded)), const SizedBox(height: 10), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: fieldDecoration('Phone', Icons.phone_rounded)), const SizedBox(height: 10), TextField(controller: total, keyboardType: TextInputType.number, decoration: fieldDecoration('Total Amount', Icons.payments_rounded)), const SizedBox(height: 10), TextField(controller: paid, keyboardType: TextInputType.number, decoration: fieldDecoration('Paid Amount', Icons.savings_rounded)), const SizedBox(height: 10), TextField(controller: note, maxLines: 3, decoration: fieldDecoration('Note', Icons.note_rounded))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () { final item = DuePaymentRecord(id: edit?.id ?? id(), name: name.text.trim().isEmpty ? 'No Name' : name.text.trim(), phone: phone.text.trim(), total: double.tryParse(total.text.trim()) ?? 0, paid: double.tryParse(paid.text.trim()) ?? 0, note: note.text.trim(), dateTime: edit?.dateTime ?? DateTime.now()); setState(() { if (edit == null) { dues.insert(0, item); } else { final i = dues.indexWhere((e) => e.id == edit.id); if (i >= 0) dues[i] = item; } }); saveAll(); Navigator.pop(context); }, child: const Text('Save'))]));
  }

  void addCashDialog({CashbookEntry? edit}) {
    final title = TextEditingController(text: edit?.title ?? '');
    final amount = TextEditingController(text: edit == null ? '' : money(edit.amount));
    final note = TextEditingController(text: edit?.note ?? '');
    String type = edit?.type ?? 'Income';
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(backgroundColor: card2, title: Text(edit == null ? 'Add Cashbook Entry' : 'Edit Cashbook Entry'), content: SingleChildScrollView(child: Column(children: [DropdownButtonFormField<String>(value: type, items: const [DropdownMenuItem(value: 'Income', child: Text('Income')), DropdownMenuItem(value: 'Expense', child: Text('Expense'))], onChanged: (v) => setLocal(() => type = v ?? 'Income'), decoration: fieldDecoration('Type', Icons.swap_vert_rounded)), const SizedBox(height: 10), TextField(controller: title, decoration: fieldDecoration('Title', Icons.title_rounded)), const SizedBox(height: 10), TextField(controller: amount, keyboardType: TextInputType.number, decoration: fieldDecoration('Amount', Icons.payments_rounded)), const SizedBox(height: 10), TextField(controller: note, maxLines: 3, decoration: fieldDecoration('Note', Icons.note_rounded))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () { final item = CashbookEntry(id: edit?.id ?? id(), title: title.text.trim().isEmpty ? type : title.text.trim(), type: type, amount: double.tryParse(amount.text.trim()) ?? 0, note: note.text.trim(), dateTime: edit?.dateTime ?? DateTime.now()); setState(() { if (edit == null) { cashbook.insert(0, item); } else { final i = cashbook.indexWhere((e) => e.id == edit.id); if (i >= 0) cashbook[i] = item; } }); saveAll(); Navigator.pop(context); }, child: const Text('Save'))])));
  }

  void addReminderDialog({FollowupReminder? edit}) {
    final name = TextEditingController(text: edit?.name ?? '');
    final phone = TextEditingController(text: edit?.phone ?? '');
    final note = TextEditingController(text: edit?.note ?? '');
    DateTime picked = edit?.reminderDate ?? DateTime.now().add(const Duration(days: 1));
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(backgroundColor: card2, title: Text(edit == null ? 'Add Reminder' : 'Edit Reminder'), content: SingleChildScrollView(child: Column(children: [TextField(controller: name, decoration: fieldDecoration('Person Name', Icons.person_rounded)), const SizedBox(height: 10), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: fieldDecoration('Phone', Icons.phone_rounded)), const SizedBox(height: 10), ListTile(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), tileColor: widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFF4F7FB), leading: const Icon(Icons.calendar_month_rounded, color: Colors.orangeAccent), title: Text('Reminder Date: ${date(picked)}', style: TextStyle(color: mainText, fontWeight: FontWeight.w800)), onTap: () async { final d = await pickDate(picked); if (d != null) setLocal(() => picked = d); }), const SizedBox(height: 10), TextField(controller: note, maxLines: 3, decoration: fieldDecoration('Note', Icons.note_rounded))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () { final item = FollowupReminder(id: edit?.id ?? id(), name: name.text.trim().isEmpty ? 'No Name' : name.text.trim(), phone: phone.text.trim(), note: note.text.trim(), reminderDate: picked, done: edit?.done ?? false); setState(() { if (edit == null) { reminders.insert(0, item); } else { final i = reminders.indexWhere((e) => e.id == edit.id); if (i >= 0) reminders[i] = item; } }); saveAll(); Navigator.pop(context); }, child: const Text('Save'))])));
  }

  void addReceiptDialog({ReceiptMemo? edit}) {
    final name = TextEditingController(text: edit?.name ?? '');
    final phone = TextEditingController(text: edit?.phone ?? '');
    final items = TextEditingController(text: edit?.items ?? '');
    final total = TextEditingController(text: edit == null ? '' : money(edit.total));
    final paid = TextEditingController(text: edit == null ? '' : money(edit.paid));
    final note = TextEditingController(text: edit?.note ?? '');
    showDialog(context: context, builder: (_) => AlertDialog(backgroundColor: card2, title: Text(edit == null ? 'Create Receipt / Memo' : 'Edit Receipt / Memo'), content: SingleChildScrollView(child: Column(children: [TextField(controller: name, decoration: fieldDecoration('Customer Name', Icons.person_rounded)), const SizedBox(height: 10), TextField(controller: phone, keyboardType: TextInputType.phone, decoration: fieldDecoration('Phone', Icons.phone_rounded)), const SizedBox(height: 10), TextField(controller: items, maxLines: 4, decoration: fieldDecoration('Items / Details', Icons.receipt_long_rounded)), const SizedBox(height: 10), TextField(controller: total, keyboardType: TextInputType.number, decoration: fieldDecoration('Total', Icons.payments_rounded)), const SizedBox(height: 10), TextField(controller: paid, keyboardType: TextInputType.number, decoration: fieldDecoration('Paid', Icons.savings_rounded)), const SizedBox(height: 10), TextField(controller: note, maxLines: 2, decoration: fieldDecoration('Note', Icons.note_rounded))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () { final item = ReceiptMemo(id: edit?.id ?? id(), name: name.text.trim().isEmpty ? 'No Name' : name.text.trim(), phone: phone.text.trim(), items: items.text.trim(), total: double.tryParse(total.text.trim()) ?? 0, paid: double.tryParse(paid.text.trim()) ?? 0, note: note.text.trim(), dateTime: edit?.dateTime ?? DateTime.now()); setState(() { if (edit == null) { receipts.insert(0, item); } else { final i = receipts.indexWhere((e) => e.id == edit.id); if (i >= 0) receipts[i] = item; } }); saveAll(); Navigator.pop(context); }, child: const Text('Save'))]));
  }

  Widget actionIcon(IconData icon, Color color, VoidCallback onTap) => IconButton(onPressed: onTap, icon: Icon(icon, color: color));

  Widget customerList() {
    final list = filteredCustomers;
    if (list.isEmpty) return emptyText('No customer notes yet');
    return ListView(children: list.map((e) => premiumCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(e.important ? Icons.star_rounded : Icons.person_rounded, color: e.important ? Colors.amber : Colors.orangeAccent), const SizedBox(width: 10), Expanded(child: Text(e.name, style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.w900))), Text(e.tag, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold))]), const SizedBox(height: 8), Text('Phone: ${e.phone}\nAddress: ${e.address}\nAmount/Due: ${money(e.amount)}\nNote: ${e.note}\nDate: ${date(e.dateTime)}', style: TextStyle(color: mutedText, height: 1.45, fontWeight: FontWeight.w600)), Row(mainAxisAlignment: MainAxisAlignment.end, children: [actionIcon(Icons.picture_as_pdf_rounded, Colors.orangeAccent, () => exportBusinessPdf('${e.name} Customer Note', customerReportText([e], '${e.name} Customer Note'), safePdfFileName('${e.name}_customer_note'))), actionIcon(Icons.edit_rounded, Colors.cyanAccent, () => addCustomerDialog(edit: e)), actionIcon(Icons.delete_rounded, Colors.redAccent, () { setState(() => customers.removeWhere((x) => x.id == e.id)); saveAll(); })])]))).toList());
  }

  Widget dueList() {
    final list = filteredDues;
    if (list.isEmpty) return emptyText('No due/payment records yet');
    return ListView(children: list.map((e) => premiumCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Icon(Icons.account_balance_wallet_rounded, color: Colors.greenAccent), const SizedBox(width: 10), Expanded(child: Text(e.name, style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.w900))), Text('Due ${money(e.due)}', style: TextStyle(color: e.due > 0 ? Colors.orangeAccent : Colors.greenAccent, fontWeight: FontWeight.w900))]), const SizedBox(height: 8), Text('Phone: ${e.phone}\nTotal: ${money(e.total)} | Paid: ${money(e.paid)} | Due: ${money(e.due)}\nNote: ${e.note}\nDate: ${date(e.dateTime)}', style: TextStyle(color: mutedText, height: 1.45, fontWeight: FontWeight.w600)), Row(mainAxisAlignment: MainAxisAlignment.end, children: [actionIcon(Icons.receipt_long_rounded, Colors.orangeAccent, () => exportBusinessPdf('${e.name} Due Receipt', dueReportText([e], '${e.name} Due Receipt'), safePdfFileName('${e.name}_due_receipt'))), actionIcon(Icons.edit_rounded, Colors.cyanAccent, () => addDueDialog(edit: e)), actionIcon(Icons.delete_rounded, Colors.redAccent, () { setState(() => dues.removeWhere((x) => x.id == e.id)); saveAll(); })])]))).toList());
  }

  Widget cashbookList() {
    final list = filteredCashbook;
    if (list.isEmpty) return emptyText('No cashbook entry yet');
    return ListView(children: list.map((e) => premiumCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(e.type == 'Income' ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, color: e.type == 'Income' ? Colors.greenAccent : Colors.redAccent), const SizedBox(width: 10), Expanded(child: Text(e.title, style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.w900))), Text('${e.type}: ${money(e.amount)}', style: TextStyle(color: e.type == 'Income' ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.w900))]), const SizedBox(height: 8), Text('Note: ${e.note}\nDate: ${date(e.dateTime)}', style: TextStyle(color: mutedText, height: 1.45, fontWeight: FontWeight.w600)), Row(mainAxisAlignment: MainAxisAlignment.end, children: [actionIcon(Icons.edit_rounded, Colors.cyanAccent, () => addCashDialog(edit: e)), actionIcon(Icons.delete_rounded, Colors.redAccent, () { setState(() => cashbook.removeWhere((x) => x.id == e.id)); saveAll(); })])]))).toList());
  }

  Widget reminderList() {
    final list = filteredReminders;
    if (list.isEmpty) return emptyText('No reminder yet');
    return ListView(children: list.map((e) => premiumCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(e.done ? Icons.check_circle_rounded : Icons.notifications_active_rounded, color: e.done ? Colors.greenAccent : Colors.orangeAccent), const SizedBox(width: 10), Expanded(child: Text(e.name, style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.w900))), Text(date(e.reminderDate), style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w900))]), const SizedBox(height: 8), Text('Phone: ${e.phone}\nNote: ${e.note}\nStatus: ${e.done ? 'Done' : 'Pending'}', style: TextStyle(color: mutedText, height: 1.45, fontWeight: FontWeight.w600)), Row(mainAxisAlignment: MainAxisAlignment.end, children: [actionIcon(e.done ? Icons.undo_rounded : Icons.done_rounded, Colors.greenAccent, () { setState(() => e.done = !e.done); saveAll(); }), actionIcon(Icons.edit_rounded, Colors.cyanAccent, () => addReminderDialog(edit: e)), actionIcon(Icons.delete_rounded, Colors.redAccent, () { setState(() => reminders.removeWhere((x) => x.id == e.id)); saveAll(); })])]))).toList());
  }

  Widget receiptList() {
    final list = filteredReceipts;
    if (list.isEmpty) return emptyText('No receipt/memo yet');
    return ListView(children: list.map((e) => premiumCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Icon(Icons.receipt_long_rounded, color: Colors.orangeAccent), const SizedBox(width: 10), Expanded(child: Text(e.name, style: TextStyle(color: mainText, fontSize: 18, fontWeight: FontWeight.w900))), Text('Due ${money(e.due)}', style: TextStyle(color: e.due > 0 ? Colors.orangeAccent : Colors.greenAccent, fontWeight: FontWeight.w900))]), const SizedBox(height: 8), Text('Phone: ${e.phone}\nItems: ${e.items}\nTotal: ${money(e.total)} | Paid: ${money(e.paid)} | Due: ${money(e.due)}\nDate: ${date(e.dateTime)}', style: TextStyle(color: mutedText, height: 1.45, fontWeight: FontWeight.w600)), Row(mainAxisAlignment: MainAxisAlignment.end, children: [actionIcon(Icons.picture_as_pdf_rounded, Colors.orangeAccent, () => exportBusinessPdf('${e.name} Receipt Memo', receiptText(e), safePdfFileName('${e.name}_receipt_memo'))), actionIcon(Icons.edit_rounded, Colors.cyanAccent, () => addReceiptDialog(edit: e)), actionIcon(Icons.delete_rounded, Colors.redAccent, () { setState(() => receipts.removeWhere((x) => x.id == e.id)); saveAll(); })])]))).toList());
  }

  void addForTab(int tab) {
    if (tab == 0) addCustomerDialog();
    if (tab == 1) addDueDialog();
    if (tab == 2) addCashDialog();
    if (tab == 3) addReminderDialog();
    if (tab == 4) addReceiptDialog();
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;
    return DefaultTabController(
      length: 5,
      child: Builder(builder: (context) {
        final tabController = DefaultTabController.of(context);
        return Scaffold(
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: bg,
            iconTheme: IconThemeData(color: mainText),
            title: Text('Business Notebook', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)),
            actions: [
              if (busy) const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              IconButton(onPressed: editShopProfileDialog, tooltip: 'Shop Profile', icon: const Icon(Icons.storefront_rounded, color: Colors.cyanAccent)),
              IconButton(onPressed: () => exportAllCurrentTab(tabController.index), icon: const Icon(Icons.picture_as_pdf_rounded, color: Colors.orangeAccent)),
              IconButton(onPressed: () => addForTab(tabController.index), icon: const Icon(Icons.add_circle_rounded, color: Colors.greenAccent)),
            ],
            bottom: TabBar(
              isScrollable: true,
              labelColor: Colors.orangeAccent,
              unselectedLabelColor: mutedText,
              indicatorColor: Colors.orangeAccent,
              tabs: const [Tab(text: 'Notes'), Tab(text: 'Dues'), Tab(text: 'Cashbook'), Tab(text: 'Reminder'), Tab(text: 'Receipt')],
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(backgroundColor: const Color(0xFFFF9500), onPressed: () => addForTab(tabController.index), icon: const Icon(Icons.add_rounded), label: const Text('Add')),
          body: Center(
            child: Container(
              width: maxWidth,
              decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF050505), const Color(0xFF000000)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                    child: InkWell(
                      onTap: editShopProfileDialog,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20), border: Border.all(color: widget.darkMode ? Colors.white12 : Colors.black12)),
                        child: Row(children: [const Icon(Icons.storefront_rounded, color: Colors.orangeAccent), const SizedBox(width: 10), Expanded(child: Text(shopProfile.shopName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: mainText, fontWeight: FontWeight.w900))), Text('Edit', style: TextStyle(color: mutedText, fontWeight: FontWeight.w800))]),
                      ),
                    ),
                  ),
                  searchBox(),
                  Expanded(child: TabBarView(children: [customerList(), dueList(), cashbookList(), reminderList(), receiptList()])),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class UnitConverterPage extends StatefulWidget { final bool darkMode; const UnitConverterPage({super.key, required this.darkMode}); @override State<UnitConverterPage> createState() => _UnitConverterPageState(); }
class _UnitConverterPageState extends State<UnitConverterPage> {
  String category = 'Length', fromUnit = 'Meter', toUnit = 'Kilometer', result = '0'; final valueController = TextEditingController();
  final units = {'Length': ['Meter', 'Kilometer', 'Centimeter', 'Millimeter', 'Inch', 'Foot'], 'Weight': ['Kilogram', 'Gram', 'Pound', 'Ounce'], 'Temperature': ['Celsius', 'Fahrenheit', 'Kelvin']};
  Color get bg => widget.darkMode ? const Color(0xFF000000) : const Color(0xFFF4F7FB); Color get card => widget.darkMode ? const Color(0xFF111214) : Colors.white; Color get card2 => widget.darkMode ? const Color(0xFF1C1C1E) : const Color(0xFFE8F2FB); Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF151517); Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  @override void dispose() { valueController.dispose(); super.dispose(); }
  void changeCategory(String c) { setState(() { category = c; fromUnit = units[category]![0]; toUnit = units[category]![1]; calculate(); }); }
  double toBase(double v, String u) { if (category == 'Length') { switch (u) { case 'Kilometer': return v * 1000; case 'Centimeter': return v / 100; case 'Millimeter': return v / 1000; case 'Inch': return v * 0.0254; case 'Foot': return v * 0.3048; } } if (category == 'Weight') { switch (u) { case 'Gram': return v / 1000; case 'Pound': return v * 0.45359237; case 'Ounce': return v * 0.028349523125; } } if (category == 'Temperature') { switch (u) { case 'Fahrenheit': return (v - 32) * 5 / 9; case 'Kelvin': return v - 273.15; } } return v; }
  double fromBase(double v, String u) { if (category == 'Length') { switch (u) { case 'Kilometer': return v / 1000; case 'Centimeter': return v * 100; case 'Millimeter': return v * 1000; case 'Inch': return v / 0.0254; case 'Foot': return v / 0.3048; } } if (category == 'Weight') { switch (u) { case 'Gram': return v * 1000; case 'Pound': return v / 0.45359237; case 'Ounce': return v / 0.028349523125; } } if (category == 'Temperature') { switch (u) { case 'Fahrenheit': return (v * 9 / 5) + 32; case 'Kelvin': return v + 273.15; } } return v; }
  String fmt(double v) { if (v.isNaN || v.isInfinite) return 'Error'; if (v % 1 == 0) return v.toInt().toString(); return v.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), ''); }
  void calculate() { final input = double.tryParse(valueController.text.trim()); if (input == null) { setState(() => result = '0'); return; } setState(() => result = fmt(fromBase(toBase(input, fromUnit), toUnit))); }
  void swapUnits() { setState(() { final old = fromUnit; fromUnit = toUnit; toUnit = old; calculate(); }); }
  Widget categoryButton(String text, IconData icon) { final active = category == text; return Expanded(child: Padding(padding: const EdgeInsets.all(4), child: PressScale(borderRadius: BorderRadius.circular(18), onTap: () => changeCategory(text), child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(gradient: active ? const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF0E9FB3)]) : null, color: active ? null : card, borderRadius: BorderRadius.circular(18)), child: Column(children: [Icon(icon, color: active ? Colors.white : const Color(0xFF22D3EE), size: 22), const SizedBox(height: 5), Text(text, style: TextStyle(color: active ? Colors.white : mainText, fontWeight: FontWeight.bold, fontSize: 12))]))))); }
  Widget unitDropdown(String value, Function(String) onChanged) => Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withOpacity(0.08))), child: DropdownButtonHideUnderline(child: DropdownButton<String>(dropdownColor: card, value: value, isExpanded: true, items: units[category]!.map((u) => DropdownMenuItem(value: u, child: Text(u, style: TextStyle(color: mainText, fontWeight: FontWeight.w700)))).toList(), onChanged: (v) { if (v != null) onChanged(v); }))));
  @override Widget build(BuildContext context) { final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity; return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Unit Converter', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText)), body: Center(child: Container(width: maxWidth, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF050505), const Color(0xFF000000)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 18), child: Column(children: [Row(children: [categoryButton('Length', Icons.straighten_rounded), categoryButton('Weight', Icons.monitor_weight_rounded), categoryButton('Temperature', Icons.thermostat_rounded)]), const SizedBox(height: 14), Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(24)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Enter value', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 10), TextField(controller: valueController, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), onChanged: (_) => calculate(), style: TextStyle(color: mainText, fontSize: 24, fontWeight: FontWeight.bold), decoration: InputDecoration(hintText: '0', filled: true, fillColor: widget.darkMode ? const Color(0xFF151517) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.edit_rounded, color: Colors.cyanAccent))), const SizedBox(height: 14), Row(children: [unitDropdown(fromUnit, (v) => setState(() { fromUnit = v; calculate(); })), Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: PressScale(borderRadius: BorderRadius.circular(20), onTap: swapUnits, child: Container(height: 42, width: 42, decoration: BoxDecoration(color: const Color(0xFF7C4DFF), borderRadius: BorderRadius.circular(18)), child: const Icon(Icons.swap_horiz_rounded, color: Colors.white)))), unitDropdown(toUnit, (v) => setState(() { toUnit = v; calculate(); }))])])), const SizedBox(height: 14), Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF1C1C1E), const Color(0xFF111214)] : [Colors.white, const Color(0xFFE8F2FB)]), borderRadius: BorderRadius.circular(26)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Result', style: TextStyle(color: mutedText)), const SizedBox(height: 8), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: FittedBox(alignment: Alignment.centerLeft, fit: BoxFit.scaleDown, child: Text(result, style: TextStyle(color: mainText, fontSize: 42, fontWeight: FontWeight.w900)))), const SizedBox(width: 8), Padding(padding: const EdgeInsets.only(bottom: 7), child: Text(toUnit, style: const TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold)))])])), const SizedBox(height: 14), Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)), child: Text('Example: 1 Kilometer = 1000 Meter, 1 Kg = 1000 Gram', style: TextStyle(color: mutedText)))]))))); }
}

double sinh(double x) => (exp(x) - exp(-x)) / 2;
double cosh(double x) => (exp(x) + exp(-x)) / 2;
double tanh(double x) {
  final ex = exp(x);
  final enx = exp(-x);
  return (ex - enx) / (ex + enx);
}

class Parser {
  final String text;
  final bool degreeMode;
  int i = 0;

  Parser(this.text, {required this.degreeMode});

  double parse() {
    final value = parseExpression();
    if (i < text.length) throw Exception('Invalid expression');
    return value;
  }

  double parseExpression() {
    double value = parseTerm();
    while (i < text.length) {
      if (text[i] == '+') {
        i++;
        value += parseTerm();
      } else if (text[i] == '-') {
        i++;
        value -= parseTerm();
      } else {
        break;
      }
    }
    return value;
  }

  double parseTerm() {
    double value = parsePower();
    while (i < text.length) {
      if (text[i] == '×') {
        i++;
        value *= parsePower();
      } else if (text[i] == '÷') {
        i++;
        value /= parsePower();
      } else {
        break;
      }
    }
    return value;
  }

  double parsePower() {
    double value = parseFactor();
    while (i < text.length && text[i] == '^') {
      i++;
      value = pow(value, parseFactor()).toDouble();
    }
    return value;
  }

  double parseFactor() {
    if (i < text.length && text[i] == '-') {
      i++;
      return -parseFactor();
    }

    double value;

    if (match('sinh(')) {
      final v = parseExpression();
      closeParen();
      value = sinh(v);
    } else if (match('cosh(')) {
      final v = parseExpression();
      closeParen();
      value = cosh(v);
    } else if (match('tanh(')) {
      final v = parseExpression();
      closeParen();
      value = tanh(v);
    } else if (match('sin(')) {
      final v = parseExpression();
      closeParen();
      value = sin(toAngle(v));
    } else if (match('cos(')) {
      final v = parseExpression();
      closeParen();
      value = cos(toAngle(v));
    } else if (match('tan(')) {
      final v = parseExpression();
      closeParen();
      value = tan(toAngle(v));
    } else if (match('log(')) {
      final v = parseExpression();
      closeParen();
      value = log(v) / ln10;
    } else if (match('ln(')) {
      final v = parseExpression();
      closeParen();
      value = log(v);
    } else if (i < text.length && text[i] == '(') {
      i++;
      value = parseExpression();
      closeParen();
    } else if (i < text.length && text[i] == '√') {
      i++;
      if (i < text.length && text[i] == '(') {
        i++;
        value = parseExpression();
        closeParen();
        value = sqrt(value);
      } else {
        value = sqrt(parseFactor());
      }
    } else {
      value = parseNumber();
    }

    while (i < text.length) {
      if (text[i] == '!') {
        i++;
        value = factorial(value);
      } else if (text[i] == '%') {
        i++;
        value = value / 100;
      } else {
        break;
      }
    }

    return value;
  }

  double toAngle(double v) => degreeMode ? v * pi / 180 : v;

  bool match(String s) {
    if (text.substring(i).startsWith(s)) {
      i += s.length;
      return true;
    }
    return false;
  }

  void closeParen() {
    if (i < text.length && text[i] == ')') i++;
  }

  double factorial(double v) {
    final n = v.round();
    if (n < 0 || n > 170 || v != n) throw Exception('Invalid factorial');
    double r = 1;
    for (int x = 2; x <= n; x++) {
      r *= x;
    }
    return r;
  }

  double parseNumber() {
    final start = i;
    while (i < text.length && RegExp(r'[0-9.]').hasMatch(text[i])) {
      i++;
    }
    if (start == i) throw Exception('Invalid number');
    return double.parse(text.substring(start, i));
  }
}

String numberToEnglishWords(int number) {
  if (number == 0) return 'Zero';
  final ones = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
  final tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  String small(int n) { String w = ''; if (n >= 100) { w += '${ones[n ~/ 100]} Hundred '; n %= 100; } if (n >= 20) { w += '${tens[n ~/ 10]} '; n %= 10; } if (n > 0) w += '${ones[n]} '; return w.trim(); }
  String words = ''; if (number >= 10000000) { words += '${small(number ~/ 10000000)} Crore '; number %= 10000000; } if (number >= 100000) { words += '${small(number ~/ 100000)} Lakh '; number %= 100000; } if (number >= 1000) { words += '${small(number ~/ 1000)} Thousand '; number %= 1000; } if (number > 0) words += small(number); return words.trim();
}

String numberToBanglaWords(int number) {
  if (number == 0) return 'শূন্য';

  const banglaNumbers = <int, String>{
    0: 'শূন্য',
    1: 'এক',
    2: 'দুই',
    3: 'তিন',
    4: 'চার',
    5: 'পাঁচ',
    6: 'ছয়',
    7: 'সাত',
    8: 'আট',
    9: 'নয়',
    10: 'দশ',
    11: 'এগারো',
    12: 'বারো',
    13: 'তেরো',
    14: 'চৌদ্দ',
    15: 'পনেরো',
    16: 'ষোল',
    17: 'সতেরো',
    18: 'আঠারো',
    19: 'উনিশ',
    20: 'বিশ',
    21: 'একুশ',
    22: 'বাইশ',
    23: 'তেইশ',
    24: 'চব্বিশ',
    25: 'পঁচিশ',
    26: 'ছাব্বিশ',
    27: 'সাতাশ',
    28: 'আটাশ',
    29: 'ঊনত্রিশ',
    30: 'ত্রিশ',
    31: 'একত্রিশ',
    32: 'বত্রিশ',
    33: 'তেত্রিশ',
    34: 'চৌত্রিশ',
    35: 'পঁয়ত্রিশ',
    36: 'ছত্রিশ',
    37: 'সাঁইত্রিশ',
    38: 'আটত্রিশ',
    39: 'ঊনচল্লিশ',
    40: 'চল্লিশ',
    41: 'একচল্লিশ',
    42: 'বিয়াল্লিশ',
    43: 'তেতাল্লিশ',
    44: 'চুয়াল্লিশ',
    45: 'পঁয়তাল্লিশ',
    46: 'ছেচল্লিশ',
    47: 'সাতচল্লিশ',
    48: 'আটচল্লিশ',
    49: 'ঊনপঞ্চাশ',
    50: 'পঞ্চাশ',
    51: 'একান্ন',
    52: 'বাহান্ন',
    53: 'তেপ্পান্ন',
    54: 'চুয়ান্ন',
    55: 'পঞ্চান্ন',
    56: 'ছাপ্পান্ন',
    57: 'সাতান্ন',
    58: 'আটান্ন',
    59: 'ঊনষাট',
    60: 'ষাট',
    61: 'একষট্টি',
    62: 'বাষট্টি',
    63: 'তেষট্টি',
    64: 'চৌষট্টি',
    65: 'পঁয়ষট্টি',
    66: 'ছেষট্টি',
    67: 'সাতষট্টি',
    68: 'আটষট্টি',
    69: 'ঊনসত্তর',
    70: 'সত্তর',
    71: 'একাত্তর',
    72: 'বাহাত্তর',
    73: 'তিয়াত্তর',
    74: 'চুয়াত্তর',
    75: 'পঁচাত্তর',
    76: 'ছিয়াত্তর',
    77: 'সাতাত্তর',
    78: 'আটাত্তর',
    79: 'ঊনআশি',
    80: 'আশি',
    81: 'একাশি',
    82: 'বিরাশি',
    83: 'তিরাশি',
    84: 'চুরাশি',
    85: 'পঁচাশি',
    86: 'ছিয়াশি',
    87: 'সাতাশি',
    88: 'আটাশি',
    89: 'ঊননব্বই',
    90: 'নব্বই',
    91: 'একানব্বই',
    92: 'বিরানব্বই',
    93: 'তিরানব্বই',
    94: 'চুরানব্বই',
    95: 'পঁচানব্বই',
    96: 'ছিয়ানব্বই',
    97: 'সাতানব্বই',
    98: 'আটানব্বই',
    99: 'নিরানব্বই',
  };

  String small(int n) {
    String w = '';
    if (n >= 100) {
      w += '${banglaNumbers[n ~/ 100]} শত ';
      n %= 100;
    }
    if (n > 0) {
      w += '${banglaNumbers[n]} ';
    }
    return w.trim();
  }

  String words = '';
  if (number >= 10000000) {
    words += '${small(number ~/ 10000000)} কোটি ';
    number %= 10000000;
  }
  if (number >= 100000) {
    words += '${small(number ~/ 100000)} লাখ ';
    number %= 100000;
  }
  if (number >= 1000) {
    words += '${small(number ~/ 1000)} হাজার ';
    number %= 1000;
  }
  if (number > 0) words += small(number);
  return words.trim();
}
