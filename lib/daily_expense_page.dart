import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DailyMoneyEntry {
  final String id;
  final String type; // Expense or Income
  final DateTime dateTime;
  final String title;
  final String category;
  final double amount;
  final String paymentMethod;
  final String note;
  final DateTime createdAt;
  final DateTime updatedAt;

  DailyMoneyEntry({
    required this.id,
    required this.type,
    required this.dateTime,
    required this.title,
    required this.category,
    required this.amount,
    required this.paymentMethod,
    required this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'dateTime': dateTime.toIso8601String(),
    'title': title,
    'category': category,
    'amount': amount,
    'paymentMethod': paymentMethod,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory DailyMoneyEntry.fromJson(Map<String, dynamic> json) {
    return DailyMoneyEntry(
      id: json['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
      type: json['type'] ?? 'Expense',
      dateTime: DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime.now(),
      title: json['title'] ?? '',
      category: json['category'] ?? 'Others',
      amount: (json['amount'] is num)
          ? (json['amount'] as num).toDouble()
          : double.tryParse('${json['amount']}') ?? 0,
      paymentMethod: json['paymentMethod'] ?? 'Cash',
      note: json['note'] ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
    );
  }
}

class DailyExpensePage extends StatefulWidget {
  final bool darkMode;

  const DailyExpensePage({super.key, required this.darkMode});

  @override
  State<DailyExpensePage> createState() => _DailyExpensePageState();
}

class _DailyExpensePageState extends State<DailyExpensePage> {
  static const String storageKey = 'daily_money_entries_v1';
  static const String deletedStorageKey = 'daily_money_deleted_entries_v1';
  static const String languageKey = 'daily_expense_bangla_ui_v1';

  final List<String> expenseCategories = const [
    'Food',
    'Grocery',
    'Transport',
    'Medicine',
    'Mobile Recharge',
    'Shopping',
    'Family',
    'Office',
    'Business',
    'Bill',
    'Others',
  ];

  final List<String> incomeCategories = const [
    'Salary',
    'Business',
    'Cash Receive',
    'Gift',
    'Bonus',
    'Other Income',
  ];

  final List<String> paymentMethods = const [
    'Cash',
    'bKash',
    'Nagad',
    'Bank',
    'Card',
    'Others',
  ];

  List<DailyMoneyEntry> entries = [];
  List<DailyMoneyEntry> deletedEntries = [];
  bool banglaUi = false;
  DateTime selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? fromDate;
  DateTime? toDate;

  Color get bg =>
      widget.darkMode ? const Color(0xFF050505) : const Color(0xFFF7FBFF);
  Color get card => widget.darkMode ? const Color(0xFF151517) : Colors.white;
  Color get card2 =>
      widget.darkMode ? const Color(0xFF1F1F22) : const Color(0xFFEAF1FA);
  Color get mainText =>
      widget.darkMode ? Colors.white : const Color(0xFF071323);
  Color get mutedText =>
      widget.darkMode ? Colors.white70 : const Color(0xFF5C6470);
  Color get orange => const Color(0xFFFFA31A);
  Color get green => const Color(0xFF30C96B);
  Color get red => const Color(0xFFFF5A5A);
  Color get cyan => const Color(0xFF22D3EE);

  @override
  void initState() {
    super.initState();
    loadEntries();
  }

  String ui(String en, String bn) => banglaUi ? bn : en;

  String dxLabel(String value) {
    if (!banglaUi) return value;
    switch (value) {
      case 'Daily Expense':
        return 'দৈনিক খরচ';
      case 'Money Summary':
        return 'টাকার হিসাব';
      case 'Income':
        return 'আয়';
      case 'Expense':
        return 'খরচ';
      case 'Balance':
        return 'বাকি';
      case 'Add':
        return 'যোগ';
      case 'Add Daily Record':
        return 'নতুন রেকর্ড';
      case 'Edit Record':
        return 'রেকর্ড এডিট';
      case 'What did you buy?':
        return 'কি কিনলেন?';
      case 'Income source':
        return 'আয়ের উৎস';
      case 'Amount':
        return 'টাকার পরিমাণ';
      case 'Note optional':
        return 'নোট ঐচ্ছিক';
      case 'Save Record':
        return 'সেভ করুন';
      case 'Update Record':
        return 'আপডেট করুন';
      case 'Month':
        return 'মাস';
      case 'From Date':
        return 'শুরুর তারিখ';
      case 'To Date':
        return 'শেষ তারিখ';
      case 'Records':
        return 'রেকর্ড';
      case 'Deleted History':
        return 'ডিলিট হিস্ট্রি';
      case 'Expense by Category':
        return 'ক্যাটাগরি অনুযায়ী খরচ';
      case 'No record found. Tap Add to save your expense or income.':
        return 'কোনো রেকর্ড নেই। যোগ করুন চাপুন।';
      case 'No deleted record found.':
        return 'কোনো ডিলিট রেকর্ড নেই।';
      case 'Move to Deleted History?':
        return 'ডিলিট হিস্ট্রিতে রাখবেন?';
      case 'Move to Trash':
        return 'ডিলিটে রাখুন';
      case 'Cancel':
        return 'বাতিল';
      case 'Delete permanently?':
        return 'স্থায়ীভাবে ডিলিট করবেন?';
      case 'Permanent Delete':
        return 'স্থায়ী ডিলিট';
      case 'Record restored':
        return 'রেকর্ড ফিরিয়ে আনা হয়েছে';
      case 'Moved to Deleted History':
        return 'ডিলিট হিস্ট্রিতে রাখা হয়েছে';
      case 'Food':
        return 'খাবার';
      case 'Grocery':
        return 'বাজার';
      case 'Transport':
        return 'যাতায়াত';
      case 'Medicine':
        return 'ঔষধ';
      case 'Mobile Recharge':
        return 'মোবাইল রিচার্জ';
      case 'Shopping':
        return 'কেনাকাটা';
      case 'Family':
        return 'পরিবার';
      case 'Office':
        return 'অফিস';
      case 'Business':
        return 'ব্যবসা';
      case 'Bill':
        return 'বিল';
      case 'Others':
        return 'অন্যান্য';
      case 'Salary':
        return 'বেতন';
      case 'Cash Receive':
        return 'টাকা পাওয়া';
      case 'Gift':
        return 'উপহার';
      case 'Bonus':
        return 'বোনাস';
      case 'Other Income':
        return 'অন্যান্য আয়';
      case 'Cash':
        return 'নগদ';
      case 'bKash':
        return 'বিকাশ';
      case 'Nagad':
        return 'নগদ';
      case 'Bank':
        return 'ব্যাংক';
      case 'Card':
        return 'কার্ড';
      default:
        return value;
    }
  }

  String uiOption(String value) {
    if (!banglaUi) return value;
    switch (value) {
      case 'Food':
        return 'খাবার';
      case 'Grocery':
        return 'বাজার';
      case 'Transport':
        return 'যাতায়াত';
      case 'Medicine':
        return 'ঔষধ';
      case 'Mobile Recharge':
        return 'মোবাইল রিচার্জ';
      case 'Shopping':
        return 'কেনাকাটা';
      case 'Family':
        return 'পরিবার';
      case 'Office':
        return 'অফিস';
      case 'Business':
        return 'ব্যবসা';
      case 'Bill':
        return 'বিল';
      case 'Others':
        return 'অন্যান্য';
      case 'Salary':
        return 'বেতন';
      case 'Cash Receive':
        return 'টাকা পাওয়া';
      case 'Gift':
        return 'উপহার';
      case 'Bonus':
        return 'বোনাস';
      case 'Other Income':
        return 'অন্যান্য আয়';
      case 'Cash':
        return 'নগদ';
      case 'bKash':
        return 'বিকাশ';
      case 'Nagad':
        return 'নগদ';
      case 'Bank':
        return 'ব্যাংক';
      case 'Card':
        return 'কার্ড';
      default:
        return value;
    }
  }

  Future<void> toggleLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => banglaUi = !banglaUi);
    await prefs.setBool(languageKey, banglaUi);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            banglaUi ? 'ভাষা বাংলা করা হয়েছে' : 'Language changed to English',
          ),
        ),
      );
    }
  }

  Future<void> loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final savedBanglaUi = prefs.getBool(languageKey) ?? false;
    final raw = prefs.getStringList(storageKey) ?? [];
    final deletedRaw = prefs.getStringList(deletedStorageKey) ?? [];
    final loaded = raw
        .map((e) {
          try {
            return DailyMoneyEntry.fromJson(jsonDecode(e));
          } catch (_) {
            return null;
          }
        })
        .whereType<DailyMoneyEntry>()
        .toList();

    loaded.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    final deletedLoaded = deletedRaw
        .map((e) {
          try {
            return DailyMoneyEntry.fromJson(jsonDecode(e));
          } catch (_) {
            return null;
          }
        })
        .whereType<DailyMoneyEntry>()
        .toList();
    deletedLoaded.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (mounted) {
      setState(() {
        entries = loaded;
        deletedEntries = deletedLoaded;
        banglaUi = savedBanglaUi;
      });
    }
  }

  Future<void> saveEntries() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      storageKey,
      entries.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  String money(double value) {
    final suffix = banglaUi ? 'টাকা' : 'Taka';
    if (value % 1 == 0) return '${value.toInt()} $suffix';
    return '${value.toStringAsFixed(2)} $suffix';
  }

  String dateText(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d-$m-${dt.year}';
  }

  String timeText(DateTime dt) {
    final h = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final mm = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$mm $ampm';
  }

  List<DailyMoneyEntry> get monthEntries {
    return entries
        .where(
          (e) =>
              e.dateTime.year == selectedMonth.year &&
              e.dateTime.month == selectedMonth.month,
        )
        .toList();
  }

  List<DailyMoneyEntry> get rangeEntries {
    if (fromDate == null || toDate == null) return monthEntries;
    final start = DateTime(fromDate!.year, fromDate!.month, fromDate!.day);
    final end = DateTime(toDate!.year, toDate!.month, toDate!.day, 23, 59, 59);
    return entries
        .where((e) => !e.dateTime.isBefore(start) && !e.dateTime.isAfter(end))
        .toList();
  }

  double totalOf(List<DailyMoneyEntry> list, String type) {
    return list
        .where((e) => e.type == type)
        .fold(0, (sum, e) => sum + e.amount);
  }

  Map<String, double> categorySummary(List<DailyMoneyEntry> list, String type) {
    final map = <String, double>{};
    for (final e in list.where((x) => x.type == type)) {
      map[e.category] = (map[e.category] ?? 0) + e.amount;
    }
    return map;
  }

  Future<void> pickMonth() async {
    final date = await showDatePicker(
      context: context,
      initialDate: selectedMonth,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date != null) {
      setState(() {
        selectedMonth = DateTime(date.year, date.month);
        fromDate = null;
        toDate = null;
      });
    }
  }

  Future<void> pickRange(bool isFrom) async {
    final date = await showDatePicker(
      context: context,
      initialDate: isFrom
          ? (fromDate ?? DateTime.now())
          : (toDate ?? DateTime.now()),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date != null) {
      setState(() {
        if (isFrom) {
          fromDate = date;
        } else {
          toDate = date;
        }
      });
    }
  }

  void openEntrySheet({DailyMoneyEntry? editItem}) {
    HapticFeedback.selectionClick();

    String type = editItem?.type ?? 'Expense';
    DateTime entryDateTime = editItem?.dateTime ?? DateTime.now();
    String category = editItem?.category ?? 'Food';
    String paymentMethod = editItem?.paymentMethod ?? 'Cash';

    final titleCtrl = TextEditingController(text: editItem?.title ?? '');
    final amountCtrl = TextEditingController(
      text: editItem == null ? '' : editItem.amount.toString(),
    );
    final noteCtrl = TextEditingController(text: editItem?.note ?? '');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final categories = type == 'Expense'
                ? expenseCategories
                : incomeCategories;
            if (!categories.contains(category)) category = categories.first;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                decoration: BoxDecoration(
                  color: card,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  border: Border.all(
                    color: widget.darkMode
                        ? Colors.white.withOpacity(0.10)
                        : Colors.black.withOpacity(0.06),
                  ),
                ),
                child: SafeArea(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              editItem == null
                                  ? 'Add Daily Record'
                                  : 'Edit Record',
                              style: TextStyle(
                                color: mainText,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              onPressed: () => Navigator.pop(context),
                              icon: Icon(Icons.close_rounded, color: mainText),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _choiceButton(
                                title: dxLabel('Expense'),
                                selected: type == 'Expense',
                                color: red,
                                onTap: () => setSheetState(() {
                                  type = 'Expense';
                                  category = expenseCategories.first;
                                }),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _choiceButton(
                                title: dxLabel('Income'),
                                selected: type == 'Income',
                                color: green,
                                onTap: () => setSheetState(() {
                                  type = 'Income';
                                  category = incomeCategories.first;
                                }),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _input(
                          titleCtrl,
                          type == 'Expense'
                              ? 'What did you buy?'
                              : 'Income source',
                          Icons.edit_rounded,
                        ),
                        const SizedBox(height: 10),
                        _input(
                          amountCtrl,
                          dxLabel('Amount'),
                          Icons.payments_rounded,
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _dropDown(
                                value: category,
                                items: categories,
                                icon: Icons.category_rounded,
                                onChanged: (v) => setSheetState(
                                  () => category = v ?? categories.first,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _dropDown(
                                value: paymentMethod,
                                items: paymentMethods,
                                icon: Icons.account_balance_wallet_rounded,
                                onChanged: (v) => setSheetState(
                                  () => paymentMethod = v ?? 'Cash',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: entryDateTime,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (picked == null) return;
                            final pickedTime = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.fromDateTime(
                                entryDateTime,
                              ),
                            );
                            setSheetState(() {
                              entryDateTime = DateTime(
                                picked.year,
                                picked.month,
                                picked.day,
                                pickedTime?.hour ?? entryDateTime.hour,
                                pickedTime?.minute ?? entryDateTime.minute,
                              );
                            });
                          },
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: card2,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.calendar_month_rounded,
                                  color: orange,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '${dateText(entryDateTime)}  ${timeText(entryDateTime)}',
                                    style: TextStyle(
                                      color: mainText,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.edit_calendar_rounded,
                                  color: mutedText,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _input(
                          noteCtrl,
                          dxLabel('Note optional'),
                          Icons.note_alt_rounded,
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: type == 'Expense'
                                  ? orange
                                  : green,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            onPressed: () async {
                              final title = titleCtrl.text.trim();
                              final amount = double.tryParse(
                                amountCtrl.text.trim(),
                              );
                              if (title.isEmpty ||
                                  amount == null ||
                                  amount <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ui(
                                        'Enter title and valid amount',
                                        'নাম এবং সঠিক টাকা দিন',
                                      ),
                                    ),
                                  ),
                                );
                                return;
                              }

                              final now = DateTime.now();
                              final item = DailyMoneyEntry(
                                id:
                                    editItem?.id ??
                                    now.microsecondsSinceEpoch.toString(),
                                type: type,
                                dateTime: entryDateTime,
                                title: title,
                                category: category,
                                amount: amount,
                                paymentMethod: paymentMethod,
                                note: noteCtrl.text.trim(),
                                createdAt: editItem?.createdAt ?? now,
                                updatedAt: now,
                              );

                              setState(() {
                                if (editItem == null) {
                                  entries.insert(0, item);
                                } else {
                                  final index = entries.indexWhere(
                                    (e) => e.id == editItem.id,
                                  );
                                  if (index >= 0) entries[index] = item;
                                }
                                entries.sort(
                                  (a, b) => b.dateTime.compareTo(a.dateTime),
                                );
                              });
                              await saveEntries();

                              if (mounted) Navigator.pop(context);
                            },
                            icon: const Icon(Icons.save_rounded),
                            label: Text(
                              editItem == null
                                  ? 'Save Record'
                                  : 'Update Record',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _choiceButton({
    required String title,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: selected ? color : card2,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              color: selected ? Colors.white : mainText,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  Widget _input(
    TextEditingController ctrl,
    String label,
    IconData icon, {
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: TextStyle(color: mainText, fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: orange),
        labelText: dxLabel(label),
        labelStyle: TextStyle(color: mutedText),
        filled: true,
        fillColor: card2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _dropDown({
    required String value,
    required List<String> items,
    required IconData icon,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: card2,
        borderRadius: BorderRadius.circular(18),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: card,
          iconEnabledColor: orange,
          style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
          items: items
              .map((e) => DropdownMenuItem(value: e, child: Text(dxLabel(e))))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Future<void> deleteEntry(DailyMoneyEntry item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card,
        title: Text(
          ui('Move to Deleted History?', 'ডিলিট হিস্ট্রিতে রাখবেন?'),
          style: TextStyle(color: mainText),
        ),
        content: Text(
          'This record will be removed from the main list, but you can restore it later from Deleted History.',
          style: TextStyle(color: mutedText),
        ),
        actions: [
          TextButton(
            onPressed: toggleLanguage,
            child: Text(
              banglaUi ? 'EN' : 'বাংলা',
              style: TextStyle(color: orange, fontWeight: FontWeight.w900),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ui('Cancel', 'বাতিল')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ui('Move to Trash', 'ডিলিটে রাখুন')),
          ),
        ],
      ),
    );

    if (ok == true) {
      final deletedItem = DailyMoneyEntry(
        id: item.id,
        type: item.type,
        dateTime: item.dateTime,
        title: item.title,
        category: item.category,
        amount: item.amount,
        paymentMethod: item.paymentMethod,
        note: item.note,
        createdAt: item.createdAt,
        updatedAt: DateTime.now(),
      );

      setState(() {
        entries.removeWhere((e) => e.id == item.id);
        deletedEntries.insert(0, deletedItem);
      });

      await saveEntries();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ui('Moved to Deleted History', 'ডিলিট হিস্ট্রিতে রাখা হয়েছে'),
            ),
            action: SnackBarAction(
              label: 'OPEN',
              onPressed: openDeletedHistory,
            ),
          ),
        );
      }
    }
  }

  Future<void> restoreDeletedEntry(DailyMoneyEntry item) async {
    setState(() {
      deletedEntries.removeWhere((e) => e.id == item.id);
      entries.insert(0, item);
      entries.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    });
    await saveEntries();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ui('Record restored', 'রেকর্ড ফিরিয়ে আনা হয়েছে')),
        ),
      );
    }
  }

  Future<void> permanentlyDeleteEntry(DailyMoneyEntry item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: card,
        title: Text(
          ui('Delete permanently?', 'স্থায়ীভাবে ডিলিট করবেন?'),
          style: TextStyle(color: mainText),
        ),
        content: Text(
          'This cannot be restored again.',
          style: TextStyle(color: mutedText),
        ),
        actions: [
          TextButton(
            onPressed: toggleLanguage,
            child: Text(
              banglaUi ? 'EN' : 'বাংলা',
              style: TextStyle(color: orange, fontWeight: FontWeight.w900),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(ui('Cancel', 'বাতিল')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(ui('Permanent Delete', 'স্থায়ী ডিলিট')),
          ),
        ],
      ),
    );

    if (ok == true) {
      setState(() => deletedEntries.removeWhere((e) => e.id == item.id));
      await saveEntries();
    }
  }

  void openDeletedHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.82,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
              decoration: BoxDecoration(
                color: card,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(
                  color: widget.darkMode
                      ? Colors.white.withOpacity(0.10)
                      : Colors.black.withOpacity(0.06),
                ),
              ),
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.history_rounded, color: orange),
                        const SizedBox(width: 10),
                        Text(
                          ui('Deleted History', 'ডিলিট হিস্ট্রি'),
                          style: TextStyle(
                            color: mainText,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close_rounded, color: mainText),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: deletedEntries.isEmpty
                          ? Center(
                              child: Text(
                                ui(
                                  ui(
                                    'No deleted record found.',
                                    'কোনো ডিলিট রেকর্ড নেই।',
                                  ),
                                  'কোনো ডিলিট রেকর্ড নেই।',
                                ),
                                style: TextStyle(
                                  color: mutedText,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: deletedEntries.length,
                              itemBuilder: (_, index) {
                                final item = deletedEntries[index];
                                final isIncome = item.type == 'Income';
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: card2,
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        height: 46,
                                        width: 46,
                                        decoration: BoxDecoration(
                                          color: (isIncome ? green : red)
                                              .withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        child: Icon(
                                          isIncome
                                              ? Icons.arrow_downward_rounded
                                              : Icons.arrow_upward_rounded,
                                          color: isIncome ? green : red,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '#${index + 1}  ${item.title}',
                                              style: TextStyle(
                                                color: mainText,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${dateText(item.dateTime)}  ${timeText(item.dateTime)}',
                                              style: TextStyle(
                                                color: mutedText,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                            Text(
                                              '${dxLabel(item.category)} • ${dxLabel(item.paymentMethod)}',
                                              style: TextStyle(
                                                color: mutedText,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            money(item.amount),
                                            style: TextStyle(
                                              color: isIncome ? green : red,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                tooltip: 'Restore',
                                                onPressed: () async {
                                                  await restoreDeletedEntry(
                                                    item,
                                                  );
                                                  setSheetState(() {});
                                                },
                                                icon: Icon(
                                                  Icons.restore_rounded,
                                                  color: green,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: ui(
                                                  'Permanent Delete',
                                                  'স্থায়ী ডিলিট',
                                                ),
                                                onPressed: () async {
                                                  await permanentlyDeleteEntry(
                                                    item,
                                                  );
                                                  setSheetState(() {});
                                                },
                                                icon: Icon(
                                                  Icons.delete_forever_rounded,
                                                  color: red,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> exportPdf() async {
    final list = rangeEntries;
    final income = totalOf(list, 'Income');
    final expense = totalOf(list, 'Expense');
    final balance = income - expense;
    final title = fromDate != null && toDate != null
        ? 'Report ${dateText(fromDate!)} to ${dateText(toDate!)}'
        : 'Monthly Report ${selectedMonth.month}-${selectedMonth.year}';

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageTheme: const pw.PageTheme(margin: pw.EdgeInsets.all(22)),
        build: (_) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#0C1C2E'),
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Daily Expense Report',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  title,
                  style: const pw.TextStyle(
                    color: PdfColors.orange,
                    fontSize: 12,
                  ),
                ),
                pw.Text(
                  'Generated: ${DateTime.now()}',
                  style: const pw.TextStyle(
                    color: PdfColors.grey300,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 16),
          pw.Text(
            'Summary',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Text('Total Income: ${money(income)}'),
          pw.Text('Total Expense: ${money(expense)}'),
          pw.Text('Balance: ${money(balance)}'),
          pw.SizedBox(height: 14),
          pw.Text(
            'Expense Category Summary',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          ...categorySummary(
            list,
            'Expense',
          ).entries.map((e) => pw.Text('${e.key}: ${money(e.value)}')),
          pw.SizedBox(height: 14),
          pw.Text(
            'All Records',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.Table.fromTextArray(
            headers: [
              'Date',
              'Time',
              'Type',
              'Title',
              'Category',
              'Payment',
              'Amount',
            ],
            data: list
                .map(
                  (e) => [
                    dateText(e.dateTime),
                    timeText(e.dateTime),
                    e.type,
                    e.title,
                    e.category,
                    e.paymentMethod,
                    money(e.amount),
                  ],
                )
                .toList(),
            cellStyle: const pw.TextStyle(fontSize: 8),
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'daily_expense_report.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = rangeEntries;
    final income = totalOf(list, 'Income');
    final expense = totalOf(list, 'Expense');
    final balance = income - expense;
    final expSummary = categorySummary(list, 'Expense');

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        iconTheme: IconThemeData(color: mainText),
        title: Text(
          dxLabel('Daily Expense'),
          style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
        ),
        actions: [
          TextButton(
            onPressed: toggleLanguage,
            child: Text(
              banglaUi ? 'EN' : 'বাংলা',
              style: TextStyle(color: orange, fontWeight: FontWeight.w900),
            ),
          ),
          IconButton(
            onPressed: exportPdf,
            icon: Icon(Icons.picture_as_pdf_rounded, color: orange),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: orange,
        foregroundColor: Colors.white,
        onPressed: () => openEntrySheet(),
        icon: const Icon(Icons.add_rounded),
        label: Text(
          dxLabel('Add'),
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Center(
        child: Container(
          width: MediaQuery.of(context).size.width > 700
              ? 460
              : double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
          child: ListView(
            children: [
              _summaryCard(income: income, expense: expense, balance: balance),
              const SizedBox(height: 12),
              _filterCard(),
              const SizedBox(height: 12),
              Text(
                ' ()',
                style: TextStyle(
                  color: mainText,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              if (list.isEmpty)
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Text(
                    ui(
                      dxLabel(
                        'No record found. Tap Add to save your expense or income.',
                      ),
                      'কোনো রেকর্ড নেই। যোগ করুন চাপুন।',
                    ),
                    style: TextStyle(
                      color: mutedText,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else
                ...list.asMap().entries.map(
                  (row) => _entryCard(row.value, row.key + 1),
                ),
              if (expSummary.isNotEmpty) const SizedBox(height: 12),
              if (expSummary.isNotEmpty) _categoryCard(expSummary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryCard({
    required double income,
    required double expense,
    required double balance,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFA31A), Color(0xFFFF7C00)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: orange.withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dxLabel('Money Summary'),
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _summaryMini(
                  dxLabel('Income'),
                  money(income),
                  Icons.trending_up_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _summaryMini(
                  dxLabel('Expense'),
                  money(expense),
                  Icons.trending_down_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _summaryMini(
            dxLabel('Balance'),
            money(balance),
            Icons.account_balance_wallet_rounded,
            full: true,
          ),
        ],
      ),
    );
  }

  Widget _summaryMini(
    String label,
    String value,
    IconData icon, {
    bool full = false,
  }) {
    return Container(
      width: full ? double.infinity : null,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: pickMonth,
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: Text(
                    "${dxLabel('Month')} ${selectedMonth.month}-${selectedMonth.year}",
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                onPressed: () => setState(() {
                  fromDate = null;
                  toDate = null;
                }),
                icon: Icon(Icons.refresh_rounded, color: orange),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => pickRange(true),
                  child: Text(
                    fromDate == null
                        ? dxLabel('From Date')
                        : dateText(fromDate!),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => pickRange(false),
                  child: Text(
                    toDate == null ? dxLabel('To Date') : dateText(toDate!),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              onPressed: openDeletedHistory,
              icon: Icon(Icons.history_rounded, color: red),
              label: Text(
                "${dxLabel('Deleted History')} (${deletedEntries.length})",
                style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: red.withOpacity(0.45)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryCard(Map<String, double> summary) {
    final rows = summary.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dxLabel('Expense by Category'),
            style: TextStyle(
              color: mainText,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          ...rows.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.key,
                      style: TextStyle(
                        color: mainText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    money(e.value),
                    style: TextStyle(
                      color: orange,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryCard(DailyMoneyEntry item, int serial) {
    final isIncome = item.type == 'Income';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              color: (isIncome ? green : red).withOpacity(0.15),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              isIncome
                  ? Icons.arrow_downward_rounded
                  : Icons.arrow_upward_rounded,
              color: isIncome ? green : red,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '#$serial  ${item.title}',
                  style: TextStyle(
                    color: mainText,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${dateText(item.dateTime)}  ${timeText(item.dateTime)}',
                  style: TextStyle(
                    color: mutedText,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${dxLabel(item.category)} • ${dxLabel(item.paymentMethod)}${item.note.isEmpty ? '' : ' • ${item.note}'}',
                  style: TextStyle(
                    color: mutedText,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                money(item.amount),
                style: TextStyle(
                  color: isIncome ? green : red,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () => openEntrySheet(editItem: item),
                    icon: Icon(Icons.edit_rounded, color: orange, size: 20),
                  ),
                  IconButton(
                    onPressed: () => deleteEntry(item),
                    icon: Icon(Icons.delete_rounded, color: red, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
