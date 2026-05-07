import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
  await Firebase.initializeApp();
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
      home: CalculatorPage(darkMode: darkMode, onThemeChanged: changeTheme),
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
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static Timer? _autoBackupTimer;
  static bool _autoBackupRunning = false;

  static User? get currentUser => _auth.currentUser;
  static Stream<User?> get authChanges => _auth.authStateChanges();

  static void scheduleAutoBackup() {
    if (currentUser == null) return;
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer(const Duration(seconds: 2), () async {
      if (_autoBackupRunning || currentUser == null) return;
      _autoBackupRunning = true;
      try {
        await backupLocalData();
      } catch (_) {
        // Keep the app fast and silent if internet is off. Manual Backup still shows errors.
      } finally {
        _autoBackupRunning = false;
      }
    });
  }

  static Future<User?> signInWithGoogle() async {
    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) return null;

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final result = await _auth.signInWithCredential(credential);
    return result.user;
  }

  static Future<void> signOut() async {
    _autoBackupTimer?.cancel();
    await GoogleSignIn().signOut();
    await _auth.signOut();
  }

  static Future<Map<String, dynamic>> _collectLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'dark_mode': prefs.getBool('dark_mode') ?? true,
      'bangla_word': prefs.getBool('bangla_word') ?? false,
      'saved_calculations': prefs.getStringList('saved_calculations') ?? <String>[],
      'auto_history': prefs.getStringList('auto_history') ?? <String>[],
      'smart_tool_history': prefs.getStringList('smart_tool_history') ?? <String>[],
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static Future<void> backupLocalData() async {
    final user = currentUser;
    if (user == null) throw Exception('Please sign in first');
    final data = await _collectLocalData();
    await _db.collection('user_backups').doc(user.uid).set(data, SetOptions(merge: true));
  }

  static Future<bool> restoreCloudData() async {
    final user = currentUser;
    if (user == null) throw Exception('Please sign in first');
    final doc = await _db.collection('user_backups').doc(user.uid).get();
    if (!doc.exists) return false;

    final data = doc.data() ?? <String, dynamic>{};
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('dark_mode', data['dark_mode'] == true);
    await prefs.setBool('bangla_word', data['bangla_word'] == true);
    await prefs.setStringList('saved_calculations', List<String>.from(data['saved_calculations'] ?? const <String>[]));
    await prefs.setStringList('auto_history', List<String>.from(data['auto_history'] ?? const <String>[]));
    await prefs.setStringList('smart_tool_history', List<String>.from(data['smart_tool_history'] ?? const <String>[]));
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

Future<void> exportTextPdf(BuildContext context, {required String title, required String text, String? fileName}) async {
  try {
    final pdf = pw.Document();
    final now = DateTime.now();
    final lines = text.split('\n');

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
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
          ...lines.map((line) {
            final isHeader = line.trim().isNotEmpty && !line.contains(':') && line.length < 45;
            return pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Text(
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
  final List<String> miniHistory = [];
  final List<AutoHistoryItem> autoHistory = [];
  final List<SavedCalculation> savedItems = [];
  User? firebaseUser;
  StreamSubscription<User?>? authSub;

  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get card => widget.darkMode ? const Color(0xFF0E1B2C) : Colors.white;
  Color get card2 => widget.darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB);
  Color get numBtn => widget.darkMode ? const Color(0xFF18293D) : const Color(0xFFE7EEF7);
  Color get opBtn => widget.darkMode ? const Color(0xFF0FAEC6) : const Color(0xFF0EAFC4);
  Color get dangerBtn => const Color(0xFFFF8A00);
  Color get equalBtn => const Color(0xFF7C4DFF);
  Color get sciBtn => widget.darkMode ? const Color(0xFF26304A) : const Color(0xFFDCE6F6);
  Color get mainTextColor => widget.darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedTextColor => widget.darkMode ? Colors.white60 : const Color(0xFF526070);

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

  bool isOperator(String v) => v == '+' || v == '-' || v == '×' || v == '÷' || v == '%' || v == '^';

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

  void press(String v) {
    HapticFeedback.selectionClick();
    setState(() {
      if (v == 'C') {
        expression = '';
        result = '0';
        updateWordText();
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
      if (v == 'deg') {
        degreeMode = !degreeMode;
        liveCalc();
        return;
      }
      if (['sin', 'cos', 'tan', 'log', 'ln'].contains(v)) {
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
      if (v == 'xʸ') {
        if (expression.isNotEmpty) expression += '^';
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

  Widget premiumButton(String text, Color color, double fontSize) {
    final isEqual = text == '=';
    final isDanger = text == 'C' || text == '⌫';
    final isOperatorBtn = ['+', '-', '×', '÷', '%', '√', 'x²', 'π', '(', ')'].contains(text);
    final isScienceBtn = ['xʸ', 'deg', 'sin', 'cos', 'tan', 'log', 'ln', 'x!', '1/x', 'e'].contains(text);
    late Color topColor, bottomColor, borderColor, textColor, glowColor;

    if (isEqual) {
      topColor = const Color(0xFF9A6BFF); bottomColor = const Color(0xFF6A3DFF); borderColor = const Color(0xFFBFA8FF).withOpacity(0.35); textColor = Colors.white; glowColor = const Color(0xFF7C4DFF);
    } else if (isDanger) {
      topColor = const Color(0xFFFFA733); bottomColor = const Color(0xFFFF7C00); borderColor = const Color(0xFFFFD39A).withOpacity(0.35); textColor = Colors.white; glowColor = const Color(0xFFFF8A00);
    } else if (isOperatorBtn) {
      topColor = const Color(0xFF27D0E4); bottomColor = const Color(0xFF0796AE); borderColor = const Color(0xFFA8F7FF).withOpacity(0.30); textColor = Colors.white; glowColor = const Color(0xFF00D4FF);
    } else if (isScienceBtn) {
      topColor = widget.darkMode ? const Color(0xFF303B56) : const Color(0xFFF4F8FF); bottomColor = widget.darkMode ? const Color(0xFF202A40) : const Color(0xFFDDE9F7); borderColor = widget.darkMode ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.75); textColor = widget.darkMode ? Colors.white : const Color(0xFF071323); glowColor = const Color(0xFF6A7BFF);
    } else {
      topColor = widget.darkMode ? const Color(0xFF243A55) : Colors.white; bottomColor = widget.darkMode ? const Color(0xFF172A41) : const Color(0xFFE7F0FA); borderColor = widget.darkMode ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.85); textColor = widget.darkMode ? Colors.white : const Color(0xFF071323); glowColor = widget.darkMode ? const Color(0xFF193B5C) : const Color(0xFFB8D7F3);
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
                BoxShadow(color: glowColor.withOpacity(widget.darkMode ? 0.26 : 0.16), blurRadius: isEqual ? 22 : 13, offset: const Offset(0, 5)),
                BoxShadow(color: Colors.black.withOpacity(widget.darkMode ? 0.28 : 0.10), blurRadius: 12, offset: const Offset(0, 8)),
              ],
            ),
            child: Stack(
              children: [
                Positioned(top: 5, left: 11, right: 11, child: Container(height: 18, decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: [Colors.white.withOpacity(isOperatorBtn || isDanger || isEqual ? 0.16 : 0.07), Colors.white.withOpacity(0)], begin: Alignment.topCenter, end: Alignment.bottomCenter)))),
                Center(child: text == '⌫' ? Icon(Icons.backspace_rounded, color: textColor, size: 22) : FittedBox(child: Text(text == 'deg' ? (degreeMode ? 'deg' : 'rad') : text, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w900, color: textColor, shadows: [if (widget.darkMode) Shadow(color: Colors.black.withOpacity(0.30), blurRadius: 4, offset: const Offset(0, 1))])))),
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
        buttonRow([premiumButton('xʸ', sciBtn, 14 * f), premiumButton('deg', sciBtn, 13 * f), premiumButton('sin', sciBtn, 14 * f), premiumButton('cos', sciBtn, 14 * f), premiumButton('tan', sciBtn, 14 * f)]),
        buttonRow([premiumButton('√', sciBtn, 15 * f), premiumButton('log', sciBtn, 14 * f), premiumButton('ln', sciBtn, 14 * f), premiumButton('x!', sciBtn, 14 * f), premiumButton('1/x', sciBtn, 13 * f)]),
        buttonRow([premiumButton('C', dangerBtn, 17 * f), premiumButton('⌫', dangerBtn, 17 * f), premiumButton('%', opBtn, 17 * f), premiumButton('÷', opBtn, 17 * f), premiumButton('×', opBtn, 17 * f)]),
        buttonRow([premiumButton('π', sciBtn, 17 * f), premiumButton('7', numBtn, 17 * f), premiumButton('8', numBtn, 17 * f), premiumButton('9', numBtn, 17 * f), premiumButton('-', opBtn, 17 * f)]),
        buttonRow([premiumButton('e', sciBtn, 17 * f), premiumButton('4', numBtn, 17 * f), premiumButton('5', numBtn, 17 * f), premiumButton('6', numBtn, 17 * f), premiumButton('+', opBtn, 17 * f)]),
        buttonRow([premiumButton('1', numBtn, 17 * f), premiumButton('2', numBtn, 17 * f), premiumButton('3', numBtn, 17 * f), premiumButton(')', sciBtn, 17 * f), premiumButton('=', equalBtn, 17 * f)]),
        buttonRow([premiumButton('(', sciBtn, 17 * f), premiumButton('0', numBtn, 17 * f), premiumButton('.', numBtn, 17 * f), premiumButton('+', opBtn, 17 * f), premiumButton('=', equalBtn, 17 * f)]),
      ];

  Widget menuTile({required IconData icon, required String title, required String subtitle, required List<Color> colors, required VoidCallback onTap}) {
    return PressScale(
      borderRadius: BorderRadius.circular(22),
      pressedScale: 0.97,
      onTap: onTap,
      child: Container(
        height: 118,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF071323).withOpacity(0.70) : Colors.white.withOpacity(0.72), borderRadius: BorderRadius.circular(22), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05))),
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
                  colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF071323)] : [Colors.white, const Color(0xFFE8F2FB)],
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
                    decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF071323)] : [Colors.white, const Color(0xFFE8F2FB)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(28), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.85)), boxShadow: [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(widget.darkMode ? 0.13 : 0.06), blurRadius: 28, offset: const Offset(0, 10)), BoxShadow(color: Colors.black.withOpacity(widget.darkMode ? 0.40 : 0.12), blurRadius: 30, offset: const Offset(0, 14))]),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(height: 5, width: 46, decoration: BoxDecoration(color: mutedTextColor.withOpacity(0.45), borderRadius: BorderRadius.circular(20))),
                      const SizedBox(height: 16),
                      Row(children: [Text('Quick Actions', style: TextStyle(color: mainTextColor, fontSize: 20, fontWeight: FontWeight.w900)), const Spacer(), PressScale(borderRadius: BorderRadius.circular(18), onTap: () => Navigator.pop(context), child: Container(height: 34, width: 34, decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB), shape: BoxShape.circle), child: Icon(Icons.close_rounded, color: mainTextColor, size: 20)))]),
                      const SizedBox(height: 16),
                      Row(children: [Expanded(child: menuTile(icon: Icons.save_rounded, title: 'Save', subtitle: 'Calculation', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: () { Navigator.pop(context); saveDialog(); })), const SizedBox(width: 10), Expanded(child: menuTile(icon: Icons.history_rounded, title: 'History', subtitle: 'Records', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () { Navigator.pop(context); openHistory(); }))]),
                      const SizedBox(height: 10),
                      Row(children: [Expanded(child: menuTile(icon: Icons.swap_horiz_rounded, title: 'Converter', subtitle: 'Units', colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => UnitConverterPage(darkMode: widget.darkMode))); })), const SizedBox(width: 10), Expanded(child: menuTile(icon: Icons.apps_rounded, title: 'Tools', subtitle: 'Smart', colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)], onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => ToolsPage(darkMode: widget.darkMode))); }))]),
                      const SizedBox(height: 10),
                      PressScale(borderRadius: BorderRadius.circular(22), pressedScale: 0.98, onTap: () { Navigator.pop(context); openCloudBackupSheet(); }, child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14), decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF071323).withOpacity(0.70) : Colors.white.withOpacity(0.70), borderRadius: BorderRadius.circular(22), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06))), child: Row(children: [Container(height: 44, width: 44, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF7C4DFF)]), borderRadius: BorderRadius.circular(17)), child: Icon(firebaseUser == null ? Icons.login_rounded : Icons.cloud_done_rounded, color: Colors.white)), const SizedBox(width: 12), Expanded(child: Text(firebaseUser == null ? 'Sign in with Google' : 'Auto Backup & Restore', style: TextStyle(color: mainTextColor, fontSize: 16, fontWeight: FontWeight.w900))), Icon(Icons.arrow_forward_ios_rounded, color: mutedTextColor, size: 16)]))),
                      const SizedBox(height: 10),
                      PressScale(borderRadius: BorderRadius.circular(22), pressedScale: 0.98, onTap: () { Navigator.pop(context); widget.onThemeChanged(!widget.darkMode); }, child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14), decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF071323).withOpacity(0.70) : Colors.white.withOpacity(0.70), borderRadius: BorderRadius.circular(22), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.06))), child: Row(children: [Container(height: 44, width: 44, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFFFFD86B), const Color(0xFFFF8A00)] : [const Color(0xFF293BFF), const Color(0xFF071323)]), borderRadius: BorderRadius.circular(17)), child: Icon(widget.darkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded, color: Colors.white)), const SizedBox(width: 12), Expanded(child: Text(widget.darkMode ? 'Switch to Light Mode' : 'Switch to Dark Mode', style: TextStyle(color: mainTextColor, fontSize: 16, fontWeight: FontWeight.w900))), Icon(Icons.arrow_forward_ios_rounded, color: mutedTextColor, size: 16)]))),
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
        TextButton(onPressed: toggleWordLanguage, child: Text(banglaWord ? 'English' : 'বাংলা', style: TextStyle(color: Colors.cyanAccent, fontSize: 12 * fontScale, fontWeight: FontWeight.bold))),
        PressScale(borderRadius: BorderRadius.circular(16), onTap: openCloudBackupSheet, child: Container(height: 34, width: 34, margin: const EdgeInsets.only(right: 6), decoration: BoxDecoration(color: firebaseUser == null ? card2 : const Color(0xFF0F9D58).withOpacity(0.28), shape: BoxShape.circle, border: Border.all(color: firebaseUser == null ? Colors.white12 : Colors.greenAccent.withOpacity(0.35))), child: Icon(firebaseUser == null ? Icons.person_outline_rounded : Icons.cloud_done_rounded, size: 18, color: firebaseUser == null ? mainTextColor : Colors.greenAccent))),
        PressScale(borderRadius: BorderRadius.circular(18), onTap: openPremiumMenu, child: Container(height: 38, width: 38, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF9A6BFF), Color(0xFF22D3EE)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withOpacity(0.18)), boxShadow: [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(0.22), blurRadius: 14, offset: const Offset(0, 6))]), child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 21))),
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
      decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)] : [Colors.white, const Color(0xFFE8F2FB)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80)), boxShadow: [BoxShadow(color: const Color(0xFF00D4FF).withOpacity(widget.darkMode ? 0.12 : 0.06), blurRadius: 26, offset: const Offset(0, 8)), BoxShadow(color: Colors.black.withOpacity(widget.darkMode ? 0.35 : 0.10), blurRadius: 22, offset: const Offset(0, 12))]),
      child: Column(children: [
        Expanded(child: Align(alignment: Alignment.centerRight, child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Text(expression.isEmpty ? '0' : expression, key: ValueKey(expression), style: TextStyle(color: mutedTextColor, fontSize: 15 * fontScale)))))),
        Expanded(child: Row(children: [PressScale(borderRadius: BorderRadius.circular(16), onTap: copyResult, child: Container(width: 34, height: 34, decoration: BoxDecoration(color: Colors.black.withOpacity(0.18), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.cyanAccent.withOpacity(0.25))), child: const Icon(Icons.copy_rounded, size: 18, color: Colors.cyanAccent))), const SizedBox(width: 6), PressScale(borderRadius: BorderRadius.circular(16), onTap: shareCalculatorResult, child: Container(width: 34, height: 34, decoration: BoxDecoration(color: Colors.black.withOpacity(0.18), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.cyanAccent.withOpacity(0.25))), child: const Icon(Icons.share_rounded, size: 18, color: Colors.cyanAccent))), const SizedBox(width: 8), Expanded(child: Align(alignment: Alignment.centerRight, child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)), child: FittedBox(key: ValueKey(result), fit: BoxFit.scaleDown, child: Text(result, style: TextStyle(fontSize: 38 * fontScale, fontWeight: FontWeight.w900, color: mainTextColor))))))])),
      ]),
    );
  }

  Widget wordBox(double h, double fontScale) => AnimatedContainer(duration: const Duration(milliseconds: 220), width: double.infinity, height: scientificMode ? h * 0.065 : h * 0.075, margin: const EdgeInsets.fromLTRB(10, 8, 10, 8), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(22), border: Border.all(color: Colors.white.withOpacity(0.08))), alignment: Alignment.centerLeft, child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Text(wordText, key: ValueKey(wordText), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.cyanAccent, fontSize: 13 * fontScale))));

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
              decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF06101F), const Color(0xFF020611)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
              child: Column(children: [
                topBar(fontScale),
                SizedBox(height: 22, child: Center(child: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Text(miniHistory.isEmpty ? '' : miniHistory.first, key: ValueKey(miniHistory.isEmpty ? '' : miniHistory.first), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: widget.darkMode ? Colors.white38 : Colors.black38, fontSize: 11 * fontScale))))),
                displayBox(h, fontScale),
                wordBox(h, fontScale),
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

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF050B16);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, title: Text(tab == 0 ? 'Auto History' : tab == 1 ? 'Saved Calculations' : tab == 2 ? 'Favorites' : 'Deleted History')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 4), child: TextField(onChanged: (v) => setState(() => search = v), decoration: InputDecoration(hintText: 'Search name, title, note, date, amount...', prefixIcon: const Icon(Icons.search), filled: true, fillColor: const Color(0xFF0E1B2C), border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)))),
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
    return Card(color: const Color(0xFF0E1B2C), margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), child: ListTile(title: Text('${item.expression} = ${item.result}', style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${formatDate(item.dateTime)}, ${formatTime(item.dateTime)}'), trailing: Wrap(children: deletedView ? [IconButton(icon: const Icon(Icons.restore, color: Colors.greenAccent), onPressed: () => setState(() => widget.onRecoverAuto(i))), IconButton(icon: const Icon(Icons.delete_forever, color: Colors.redAccent), onPressed: () => setState(() => widget.onPermanentDeleteAuto(i)))] : [IconButton(icon: Icon(item.isFavorite ? Icons.star : Icons.star_border, color: item.isFavorite ? Colors.amber : Colors.white54), onPressed: () => setState(() => widget.onFavoriteAuto(i))), IconButton(icon: const Icon(Icons.open_in_new, color: Colors.cyanAccent), onPressed: () { widget.onLoadAuto(item); Navigator.pop(context); }), IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () => setState(() => widget.onSoftDeleteAuto(i)))])));
  }

  Widget savedCard(int i, {required bool deletedView}) {
    final item = widget.savedItems[i];
    return Card(color: const Color(0xFF0E1B2C), margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), child: ListTile(title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('Person: ${item.personName}\n${item.expression} = ${item.result}\nNote: ${item.note}\nDate: ${formatDate(item.dateTime)}, ${formatTime(item.dateTime)}'), trailing: Wrap(children: deletedView ? [IconButton(icon: const Icon(Icons.restore, color: Colors.greenAccent), onPressed: () => setState(() => widget.onRecoverSaved(i))), IconButton(icon: const Icon(Icons.delete_forever, color: Colors.redAccent), onPressed: () => setState(() => widget.onPermanentDeleteSaved(i)))] : [IconButton(icon: Icon(item.isFavorite ? Icons.star : Icons.star_border, color: item.isFavorite ? Colors.amber : Colors.white54), onPressed: () => setState(() => widget.onFavoriteSaved(i))), IconButton(icon: const Icon(Icons.open_in_new, color: Colors.cyanAccent), onPressed: () { widget.onLoadSaved(item); Navigator.pop(context); }), IconButton(icon: const Icon(Icons.delete, color: Colors.redAccent), onPressed: () => setState(() => widget.onSoftDeleteSaved(i)))])));
  }
}

class ToolsPage extends StatelessWidget {
  final bool darkMode;
  const ToolsPage({super.key, required this.darkMode});
  Color get bg => darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get mainText => darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedText => darkMode ? Colors.white60 : const Color(0xFF526070);

  Widget toolCard({required BuildContext context, required IconData icon, required String title, required String subtitle, required List<Color> colors, required VoidCallback onTap}) {
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: PressScale(borderRadius: BorderRadius.circular(26), pressedScale: 0.98, onTap: onTap, child: Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: darkMode ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)] : [Colors.white, const Color(0xFFE8F2FB)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(26), border: Border.all(color: darkMode ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.80)), boxShadow: [BoxShadow(color: colors.last.withOpacity(darkMode ? 0.18 : 0.10), blurRadius: 18, offset: const Offset(0, 8)), BoxShadow(color: Colors.black.withOpacity(darkMode ? 0.28 : 0.08), blurRadius: 18, offset: const Offset(0, 10))]), child: Row(children: [Container(height: 58, width: 58, decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(22), boxShadow: [BoxShadow(color: colors.last.withOpacity(0.32), blurRadius: 14, offset: const Offset(0, 7))]), child: Icon(icon, color: Colors.white, size: 28)), const SizedBox(width: 15), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: mainText, fontSize: 19, fontWeight: FontWeight.w900)), const SizedBox(height: 5), Text(subtitle, style: TextStyle(color: mutedText, fontSize: 13, fontWeight: FontWeight.w600))])), Icon(Icons.arrow_forward_ios_rounded, color: mutedText, size: 18)]))));
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity;
    return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Smart Tools', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText)), body: Center(child: Container(width: maxWidth, height: double.infinity, decoration: BoxDecoration(gradient: LinearGradient(colors: darkMode ? [const Color(0xFF06101F), const Color(0xFF020611)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Useful daily calculators', style: TextStyle(color: mutedText, fontSize: 14, fontWeight: FontWeight.w700)), const SizedBox(height: 14), toolCard(context: context, icon: Icons.history_rounded, title: 'Smart History', subtitle: 'Age, BMI and discount records', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SmartToolHistoryPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.cake_rounded, title: 'Age Calculator', subtitle: 'Calculate age from date of birth', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AgeCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.monitor_weight_rounded, title: 'BMI Calculator', subtitle: 'Check body mass index with status', colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BMICalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.local_offer_rounded, title: 'Discount Calculator', subtitle: 'Find discount price and savings', colors: const [Color(0xFFFFA733), Color(0xFFFF7C00)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DiscountCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.trending_up_rounded, title: 'Profit / Loss Calculator', subtitle: 'Calculate profit, loss and percentage', colors: const [Color(0xFF30C96B), Color(0xFF0F9D58)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfitLossCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.account_balance_rounded, title: 'EMI / Loan Calculator', subtitle: 'Monthly EMI, total interest and payment', colors: const [Color(0xFF22D3EE), Color(0xFF0E9FB3)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EMILoanCalculatorPage(darkMode: darkMode)))), toolCard(context: context, icon: Icons.person_rounded, title: 'About Developer', subtitle: 'Contact, WhatsApp, Email and Feedback', colors: const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)], onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AboutDeveloperPage(darkMode: darkMode))))])))));
  }
}

abstract class ToolPageBase<T extends StatefulWidget> extends State<T> {
  Color pageBg(bool darkMode) => darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  String money(double value) { if (value.isNaN || value.isInfinite) return '0'; if (value % 1 == 0) return value.toInt().toString(); return value.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), ''); }
}

class AgeCalculatorPage extends StatefulWidget { final bool darkMode; const AgeCalculatorPage({super.key, required this.darkMode}); @override State<AgeCalculatorPage> createState() => _AgeCalculatorPageState(); }
class _AgeCalculatorPageState extends ToolPageBase<AgeCalculatorPage> {
  DateTime? birthDate; final nameController = TextEditingController(); String ageResult = 'Select your date of birth'; String nextBirthday = ''; String lastSig = '';
  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB); Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323); Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  @override void dispose() { nameController.dispose(); super.dispose(); }
  String formatDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  void saveRecord() { if (birthDate == null) return; final name = nameController.text.trim().isEmpty ? 'No Name' : nameController.text.trim(); final sig = 'Age|$name|${birthDate!.toIso8601String()}|$ageResult|$nextBirthday'; if (sig == lastSig) return; lastSig = sig; saveSmartToolHistory(SmartToolHistoryItem(type: 'Age', title: '$name Age', details: '$ageResult | $nextBirthday | DOB: ${formatDate(birthDate!)}', dateTime: DateTime.now())); }
  Future<void> pickBirthDate() async { final now = DateTime.now(); final picked = await showDatePicker(context: context, initialDate: birthDate ?? DateTime(now.year - 18, now.month, now.day), firstDate: DateTime(1900), lastDate: now); if (picked == null) return; setState(() { birthDate = picked; calculateAge(); }); saveRecord(); }
  void calculateAge() { if (birthDate == null) return; final today = DateTime.now(); int y = today.year - birthDate!.year, m = today.month - birthDate!.month, d = today.day - birthDate!.day; if (d < 0) { d += DateTime(today.year, today.month, 0).day; m--; } if (m < 0) { m += 12; y--; } ageResult = '$y Years, $m Months, $d Days'; DateTime next = DateTime(today.year, birthDate!.month, birthDate!.day); if (!next.isAfter(DateTime(today.year, today.month, today.day))) next = DateTime(today.year + 1, birthDate!.month, birthDate!.day); nextBirthday = 'Next birthday in ${next.difference(DateTime(today.year, today.month, today.day)).inDays} days'; }
  Widget glass(Widget child) => Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)] : [Colors.white, const Color(0xFFE8F2FB)]), borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80))), child: child);
  Widget resultBox(String title, String value, IconData icon, List<Color> colors) => glass(Row(children: [Container(height: 56, width: 56, decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(22)), child: Icon(icon, color: Colors.white, size: 28)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 5), Text(value, style: TextStyle(color: mainText, fontSize: 21, fontWeight: FontWeight.w900))]))]));
  @override Widget build(BuildContext context) { final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity; return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Age Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText)), body: Center(child: Container(width: maxWidth, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF06101F), const Color(0xFF020611)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Column(children: [glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Person Name', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 12), TextField(controller: nameController, onChanged: (_) => saveRecord(), decoration: InputDecoration(hintText: 'Enter name, e.g. Masum', filled: true, fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.person_rounded, color: Colors.cyanAccent)))])), const SizedBox(height: 14), glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Date of Birth', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 12), PressScale(borderRadius: BorderRadius.circular(20), onTap: pickBirthDate, child: Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB), borderRadius: BorderRadius.circular(20)), child: Row(children: [const Icon(Icons.calendar_month_rounded, color: Colors.cyanAccent), const SizedBox(width: 12), Expanded(child: Text(birthDate == null ? 'Tap to select date' : formatDate(birthDate!), style: TextStyle(color: birthDate == null ? mutedText : mainText, fontSize: 18, fontWeight: FontWeight.w800))), const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.cyanAccent)])))])), const SizedBox(height: 14), resultBox('Your Age', ageResult, Icons.cake_rounded, const [Color(0xFF22D3EE), Color(0xFF0E9FB3)]), const SizedBox(height: 14), resultBox('Birthday Reminder', nextBirthday.isEmpty ? 'Select date to see next birthday' : nextBirthday, Icons.celebration_rounded, const [Color(0xFFFFA733), Color(0xFFFF7C00)])]))))); }
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

  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card2 => widget.darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB);

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
          colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)] : [Colors.white, const Color(0xFFE8F2FB)],
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
            fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB),
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
                  backgroundColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFE8F2FB),
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
              colors: widget.darkMode ? [const Color(0xFF06101F), const Color(0xFF020611)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)],
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
  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB); Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323); Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070); Color get card2 => widget.darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB);
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

  Widget glass(Widget child) => Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)] : [Colors.white, const Color(0xFFE8F2FB)]), borderRadius: BorderRadius.circular(26), border: Border.all(color: widget.darkMode ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.80))), child: child);
  Widget input(String label, String hint, IconData icon, TextEditingController c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 10), TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => calculateDiscount(), style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.bold), decoration: InputDecoration(hintText: hint, filled: true, fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: Icon(icon, color: Colors.orangeAccent))) ]);
  @override Widget build(BuildContext context) { final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity; return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Discount Calculator', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText), actions: [IconButton(onPressed: shareDiscountResult, icon: const Icon(Icons.share_rounded, color: Colors.cyanAccent))]), body: Center(child: Container(width: maxWidth, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF06101F), const Color(0xFF020611)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Column(children: [glass(Column(children: [input('Original Price', 'Enter price', Icons.payments_rounded, priceController), const SizedBox(height: 16), input('Discount Percent', 'Enter discount %', Icons.percent_rounded, discountController)])), const SizedBox(height: 14), glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Final Price', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(finalPrice, style: TextStyle(color: finalPrice == '-' ? Colors.redAccent : Colors.greenAccent, fontSize: 48, fontWeight: FontWeight.w900)), Padding(padding: const EdgeInsets.only(bottom: 10, left: 6), child: Text('Taka', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)))]), Text(message, style: TextStyle(color: mutedText, fontWeight: FontWeight.w700))])), const SizedBox(height: 14), glass(ListTile(leading: const Icon(Icons.savings_rounded, color: Colors.orangeAccent), title: Text('You Save', style: TextStyle(color: mutedText)), subtitle: Text('$savedAmount Taka', style: TextStyle(color: mainText, fontSize: 22, fontWeight: FontWeight.w900)))), const SizedBox(height: 14), Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)), child: Text('Example: Price 1000, Discount 20% = Final Price 800, Save 200', style: TextStyle(color: mutedText)))]))))); }
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

  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get card => widget.darkMode ? const Color(0xFF0E1B2C) : Colors.white;
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323);
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

  Future<void> exportHistoryReport() async {
    final list = exportItems();

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
      ..writeln(tab == 0 ? 'Smart History Report' : 'Deleted Smart History Report')
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
      title: tab == 0 ? 'Smart History Report' : 'Deleted Smart History Report',
      text: buffer.toString(),
      fileName: tab == 0 ? 'masum_smart_history_report.pdf' : 'masum_deleted_history_report.pdf',
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
              ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)]
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
            onPressed: indexes.isEmpty ? null : exportHistoryReport,
            icon: const Icon(Icons.download_rounded, color: Colors.cyanAccent),
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
                  ? [const Color(0xFF06101F), const Color(0xFF020611)]
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

  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card2 => widget.darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB);

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
              ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)]
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
            fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB),
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
            fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB),
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
                  ? [const Color(0xFF06101F), const Color(0xFF020611)]
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

  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card2 => widget.darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB);

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
              ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)]
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
            fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB),
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
            fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB),
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
                  ? [const Color(0xFF06101F), const Color(0xFF020611)]
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

  Color get bg => darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB);
  Color get mainText => darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedText => darkMode ? Colors.white60 : const Color(0xFF526070);
  Color get card => darkMode ? const Color(0xFF0E1B2C) : Colors.white;
  Color get card2 => darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB);

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
        backgroundColor: darkMode ? const Color(0xFF0E1B2C) : Colors.white,
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
            fillColor: darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB),
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
              ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)]
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
                  'Developer of $appName',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: mutedText, fontSize: 14, height: 1.35, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  decoration: BoxDecoration(
                    color: darkMode ? const Color(0xFF071323).withOpacity(0.72) : Colors.white.withOpacity(0.72),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.18)),
                  ),
                  child: const Text(
                    'Calculator • Business Tools • Smart Records',
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
        Expanded(child: statBox('Tools', '8+', Icons.apps_rounded, const [Color(0xFF22D3EE), Color(0xFF0E9FB3)])),
        const SizedBox(width: 10),
        Expanded(child: statBox('Mode', 'Pro', Icons.workspace_premium_rounded, const [Color(0xFFFFA733), Color(0xFFFF7C00)])),
        const SizedBox(width: 10),
        Expanded(child: statBox('Build', '36', Icons.rocket_launch_rounded, const [Color(0xFF9A6BFF), Color(0xFF6A3DFF)])),
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
            'Made with ❤️ by Masum',
            style: TextStyle(color: mainText, fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            'Portfolio, WhatsApp and Feedback are connected. Users can send feedback to your Gmail.',
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
                  ? [const Color(0xFF06101F), const Color(0xFF020611)]
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
                        infoRow(Icons.verified_rounded, 'Version', 'Step 36.3 Premium Build', const [Color(0xFF30C96B), Color(0xFF0F9D58)]),
                        const SizedBox(height: 16),
                        infoRow(Icons.favorite_rounded, 'Purpose', 'Daily calculator, smart tools and small business records.', const [Color(0xFFFFA733), Color(0xFFFF7C00)]),
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
                    subtitle: '+$whatsappNumber',
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


class UnitConverterPage extends StatefulWidget { final bool darkMode; const UnitConverterPage({super.key, required this.darkMode}); @override State<UnitConverterPage> createState() => _UnitConverterPageState(); }
class _UnitConverterPageState extends State<UnitConverterPage> {
  String category = 'Length', fromUnit = 'Meter', toUnit = 'Kilometer', result = '0'; final valueController = TextEditingController();
  final units = {'Length': ['Meter', 'Kilometer', 'Centimeter', 'Millimeter', 'Inch', 'Foot'], 'Weight': ['Kilogram', 'Gram', 'Pound', 'Ounce'], 'Temperature': ['Celsius', 'Fahrenheit', 'Kelvin']};
  Color get bg => widget.darkMode ? const Color(0xFF050B16) : const Color(0xFFF4F7FB); Color get card => widget.darkMode ? const Color(0xFF0E1B2C) : Colors.white; Color get card2 => widget.darkMode ? const Color(0xFF132A42) : const Color(0xFFE8F2FB); Color get mainText => widget.darkMode ? Colors.white : const Color(0xFF071323); Color get mutedText => widget.darkMode ? Colors.white60 : const Color(0xFF526070);
  @override void dispose() { valueController.dispose(); super.dispose(); }
  void changeCategory(String c) { setState(() { category = c; fromUnit = units[category]![0]; toUnit = units[category]![1]; calculate(); }); }
  double toBase(double v, String u) { if (category == 'Length') { switch (u) { case 'Kilometer': return v * 1000; case 'Centimeter': return v / 100; case 'Millimeter': return v / 1000; case 'Inch': return v * 0.0254; case 'Foot': return v * 0.3048; } } if (category == 'Weight') { switch (u) { case 'Gram': return v / 1000; case 'Pound': return v * 0.45359237; case 'Ounce': return v * 0.028349523125; } } if (category == 'Temperature') { switch (u) { case 'Fahrenheit': return (v - 32) * 5 / 9; case 'Kelvin': return v - 273.15; } } return v; }
  double fromBase(double v, String u) { if (category == 'Length') { switch (u) { case 'Kilometer': return v / 1000; case 'Centimeter': return v * 100; case 'Millimeter': return v * 1000; case 'Inch': return v / 0.0254; case 'Foot': return v / 0.3048; } } if (category == 'Weight') { switch (u) { case 'Gram': return v * 1000; case 'Pound': return v / 0.45359237; case 'Ounce': return v / 0.028349523125; } } if (category == 'Temperature') { switch (u) { case 'Fahrenheit': return (v * 9 / 5) + 32; case 'Kelvin': return v + 273.15; } } return v; }
  String fmt(double v) { if (v.isNaN || v.isInfinite) return 'Error'; if (v % 1 == 0) return v.toInt().toString(); return v.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), ''); }
  void calculate() { final input = double.tryParse(valueController.text.trim()); if (input == null) { setState(() => result = '0'); return; } setState(() => result = fmt(fromBase(toBase(input, fromUnit), toUnit))); }
  void swapUnits() { setState(() { final old = fromUnit; fromUnit = toUnit; toUnit = old; calculate(); }); }
  Widget categoryButton(String text, IconData icon) { final active = category == text; return Expanded(child: Padding(padding: const EdgeInsets.all(4), child: PressScale(borderRadius: BorderRadius.circular(18), onTap: () => changeCategory(text), child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(gradient: active ? const LinearGradient(colors: [Color(0xFF22D3EE), Color(0xFF0E9FB3)]) : null, color: active ? null : card, borderRadius: BorderRadius.circular(18)), child: Column(children: [Icon(icon, color: active ? Colors.white : const Color(0xFF22D3EE), size: 22), const SizedBox(height: 5), Text(text, style: TextStyle(color: active ? Colors.white : mainText, fontWeight: FontWeight.bold, fontSize: 12))]))))); }
  Widget unitDropdown(String value, Function(String) onChanged) => Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withOpacity(0.08))), child: DropdownButtonHideUnderline(child: DropdownButton<String>(dropdownColor: card, value: value, isExpanded: true, items: units[category]!.map((u) => DropdownMenuItem(value: u, child: Text(u, style: TextStyle(color: mainText, fontWeight: FontWeight.w700)))).toList(), onChanged: (v) { if (v != null) onChanged(v); }))));
  @override Widget build(BuildContext context) { final maxWidth = MediaQuery.of(context).size.width > 700 ? 420.0 : double.infinity; return Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: bg, title: Text('Unit Converter', style: TextStyle(color: mainText, fontWeight: FontWeight.w900)), iconTheme: IconThemeData(color: mainText)), body: Center(child: Container(width: maxWidth, decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF06101F), const Color(0xFF020611)] : [const Color(0xFFF7FBFF), const Color(0xFFEAF1FA)], begin: Alignment.topCenter, end: Alignment.bottomCenter)), child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 18), child: Column(children: [Row(children: [categoryButton('Length', Icons.straighten_rounded), categoryButton('Weight', Icons.monitor_weight_rounded), categoryButton('Temperature', Icons.thermostat_rounded)]), const SizedBox(height: 14), Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(24)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Enter value', style: TextStyle(color: mutedText, fontWeight: FontWeight.bold)), const SizedBox(height: 10), TextField(controller: valueController, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), onChanged: (_) => calculate(), style: TextStyle(color: mainText, fontSize: 24, fontWeight: FontWeight.bold), decoration: InputDecoration(hintText: '0', filled: true, fillColor: widget.darkMode ? const Color(0xFF071323) : const Color(0xFFF4F7FB), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), prefixIcon: const Icon(Icons.edit_rounded, color: Colors.cyanAccent))), const SizedBox(height: 14), Row(children: [unitDropdown(fromUnit, (v) => setState(() { fromUnit = v; calculate(); })), Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: PressScale(borderRadius: BorderRadius.circular(20), onTap: swapUnits, child: Container(height: 42, width: 42, decoration: BoxDecoration(color: const Color(0xFF7C4DFF), borderRadius: BorderRadius.circular(18)), child: const Icon(Icons.swap_horiz_rounded, color: Colors.white)))), unitDropdown(toUnit, (v) => setState(() { toUnit = v; calculate(); }))])])), const SizedBox(height: 14), Container(width: double.infinity, padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: LinearGradient(colors: widget.darkMode ? [const Color(0xFF173A56), const Color(0xFF0C1C2E)] : [Colors.white, const Color(0xFFE8F2FB)]), borderRadius: BorderRadius.circular(26)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Result', style: TextStyle(color: mutedText)), const SizedBox(height: 8), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: FittedBox(alignment: Alignment.centerLeft, fit: BoxFit.scaleDown, child: Text(result, style: TextStyle(color: mainText, fontSize: 42, fontWeight: FontWeight.w900)))), const SizedBox(width: 8), Padding(padding: const EdgeInsets.only(bottom: 7), child: Text(toUnit, style: const TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold)))])])), const SizedBox(height: 14), Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(20)), child: Text('Example: 1 Kilometer = 1000 Meter, 1 Kg = 1000 Gram', style: TextStyle(color: mutedText)))]))))); }
}

class Parser {
  final String text; final bool degreeMode; int i = 0; Parser(this.text, {required this.degreeMode});
  double parse() { final value = parseExpression(); if (i < text.length) throw Exception('Invalid expression'); return value; }
  double parseExpression() { double value = parseTerm(); while (i < text.length) { if (text[i] == '+') { i++; value += parseTerm(); } else if (text[i] == '-') { i++; value -= parseTerm(); } else { break; } } return value; }
  double parseTerm() { double value = parsePower(); while (i < text.length) { if (text[i] == '×') { i++; value *= parsePower(); } else if (text[i] == '÷') { i++; value /= parsePower(); } else if (text[i] == '%') { i++; value = value % parsePower(); } else { break; } } return value; }
  double parsePower() { double value = parseFactor(); while (i < text.length && text[i] == '^') { i++; value = pow(value, parseFactor()).toDouble(); } return value; }
  double parseFactor() { if (i < text.length && text[i] == '-') { i++; return -parseFactor(); } if (match('sin(')) { final v = parseExpression(); closeParen(); return sin(toAngle(v)); } if (match('cos(')) { final v = parseExpression(); closeParen(); return cos(toAngle(v)); } if (match('tan(')) { final v = parseExpression(); closeParen(); return tan(toAngle(v)); } if (match('log(')) { final v = parseExpression(); closeParen(); return log(v) / ln10; } if (match('ln(')) { final v = parseExpression(); closeParen(); return log(v); } if (i < text.length && text[i] == '(') { i++; final value = parseExpression(); closeParen(); if (i < text.length && text[i] == '!') { i++; return factorial(value); } return value; } if (i < text.length && text[i] == '√') { i++; if (i < text.length && text[i] == '(') { i++; final value = parseExpression(); closeParen(); return sqrt(value); } } double value = parseNumber(); if (i < text.length && text[i] == '!') { i++; value = factorial(value); } return value; }
  double toAngle(double v) => degreeMode ? v * pi / 180 : v; bool match(String s) { if (text.substring(i).startsWith(s)) { i += s.length; return true; } return false; } void closeParen() { if (i < text.length && text[i] == ')') i++; } double factorial(double v) { final n = v.round(); if (n < 0 || n > 170) throw Exception('Invalid factorial'); double r = 1; for (int x = 2; x <= n; x++) { r *= x; } return r; } double parseNumber() { final start = i; while (i < text.length && RegExp(r'[0-9.]').hasMatch(text[i])) { i++; } if (start == i) throw Exception('Invalid number'); return double.parse(text.substring(start, i)); }
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
  final ones = ['', 'এক', 'দুই', 'তিন', 'চার', 'পাঁচ', 'ছয়', 'সাত', 'আট', 'নয়', 'দশ', 'এগারো', 'বারো', 'তেরো', 'চৌদ্দ', 'পনেরো', 'ষোল', 'সতেরো', 'আঠারো', 'উনিশ'];
  final tens = ['', '', 'বিশ', 'ত্রিশ', 'চল্লিশ', 'পঞ্চাশ', 'ষাট', 'সত্তর', 'আশি', 'নব্বই'];
  String small(int n) { String w = ''; if (n >= 100) { w += '${ones[n ~/ 100]} শত '; n %= 100; } if (n >= 20) { w += '${tens[n ~/ 10]} '; n %= 10; } if (n > 0) w += '${ones[n]} '; return w.trim(); }
  String words = ''; if (number >= 10000000) { words += '${small(number ~/ 10000000)} কোটি '; number %= 10000000; } if (number >= 100000) { words += '${small(number ~/ 100000)} লাখ '; number %= 100000; } if (number >= 1000) { words += '${small(number ~/ 1000)} হাজার '; number %= 1000; } if (number > 0) words += small(number); return words.trim();
}
