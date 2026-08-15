import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hisabflow_theme.dart';

class PackPriceCalculatorPage extends StatefulWidget {
  final bool darkMode;

  const PackPriceCalculatorPage({super.key, required this.darkMode});

  @override
  State<PackPriceCalculatorPage> createState() =>
      _PackPriceCalculatorPageState();
}

class _PackPriceCalculatorPageState extends State<PackPriceCalculatorPage> {
  static const String _languageKey = 'pack_price_bangla_ui_v1';
  final TextEditingController boxPriceCtrl = TextEditingController();
  final TextEditingController totalPcsCtrl = TextEditingController();
  final TextEditingController pcsPerStripCtrl = TextEditingController();
  final TextEditingController profitCtrl = TextEditingController();

  bool bangla = false;

  Color get bg => widget.darkMode
      ? HisabFlowColors.darkBackground
      : HisabFlowColors.lightBackground;
  Color get card => widget.darkMode
      ? HisabFlowColors.darkSurface
      : HisabFlowColors.lightSurface;
  Color get field => widget.darkMode
      ? HisabFlowColors.darkSurface2
      : HisabFlowColors.lightSurface2;
  Color get mainText =>
      widget.darkMode ? HisabFlowColors.darkText : HisabFlowColors.lightText;
  Color get mutedText =>
      widget.darkMode ? HisabFlowColors.darkMuted : HisabFlowColors.lightMuted;
  Color get orange => HisabFlowColors.orange;
  Color get green => HisabFlowColors.green;
  Color get red => HisabFlowColors.red;
  Color get cyan => HisabFlowColors.cyan;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
    pcsPerStripCtrl.text = '10';
    boxPriceCtrl.addListener(_refresh);
    totalPcsCtrl.addListener(_refresh);
    pcsPerStripCtrl.addListener(_refresh);
    profitCtrl.addListener(_refresh);
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_languageKey) ?? false;
    if (!mounted || saved == bangla) return;
    setState(() => bangla = saved);
  }

  Future<void> _toggleLanguage() async {
    HapticFeedback.selectionClick();
    final next = !bangla;
    setState(() => bangla = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_languageKey, next);
  }

  @override
  void dispose() {
    boxPriceCtrl.dispose();
    totalPcsCtrl.dispose();
    pcsPerStripCtrl.dispose();
    profitCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String t(String en, String bn) => bangla ? bn : en;

  double valueOf(String text) {
    final clean = text.replaceAll(',', '').trim();
    return double.tryParse(clean) ?? 0;
  }

  String money(double value) {
    final suffix = bangla ? 'টাকা' : 'Taka';
    if (value.isNaN || value.isInfinite) return '0 $suffix';
    if (value % 1 == 0) return '${value.toInt()} $suffix';
    return '${value.toStringAsFixed(2)} $suffix';
  }

  String number(double value) {
    if (value.isNaN || value.isInfinite) return '0';
    if (value % 1 == 0) return value.toInt().toString();
    return value.toStringAsFixed(2);
  }

  double get boxPrice => valueOf(boxPriceCtrl.text);
  double get totalPcs => valueOf(totalPcsCtrl.text);
  double get pcsPerStrip => valueOf(pcsPerStripCtrl.text);
  double get profitPercent => valueOf(profitCtrl.text);

  bool get hasBasicInput => boxPrice > 0 && totalPcs > 0;

  double get pcsCost => hasBasicInput ? boxPrice / totalPcs : 0;
  double get stripCost =>
      hasBasicInput && pcsPerStrip > 0 ? pcsCost * pcsPerStrip : 0;
  double get totalStrip =>
      hasBasicInput && pcsPerStrip > 0 ? totalPcs / pcsPerStrip : 0;
  double get salePcsPrice => pcsCost + (pcsCost * profitPercent / 100);
  double get saleStripPrice => stripCost + (stripCost * profitPercent / 100);

  Future<void> copyResult() async {
    final text =
        '''
${t('Pack / Box Price Calculator', 'প্যাকেট / বক্স হিসাব')}

${t('Box Price', 'বক্স/প্যাকেট দাম')}: ${money(boxPrice)}
${t('Total Pcs', 'মোট পিস')}: ${number(totalPcs)}
${t('Pcs per Strip/Pata', '১ পাতা/স্ট্রিপে পিস')}: ${number(pcsPerStrip)}

${t('1 Pcs Cost', '১ পিস দাম')}: ${money(pcsCost)}
${t('1 Strip/Pata Cost', '১ পাতা/স্ট্রিপ দাম')}: ${money(stripCost)}
${t('Total Strip/Pata', 'মোট পাতা/স্ট্রিপ')}: ${number(totalStrip)}

${t('Profit', 'লাভ')}: ${number(profitPercent)}%
${t('1 Pcs Sale Price', '১ পিস বিক্রয় দাম')}: ${money(salePcsPrice)}
${t('1 Strip/Pata Sale Price', '১ পাতা/স্ট্রিপ বিক্রয় দাম')}: ${money(saleStripPrice)}
''';

    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Result copied', 'হিসাব কপি হয়েছে'))),
      );
    }
  }

  void clearAll() {
    boxPriceCtrl.clear();
    totalPcsCtrl.clear();
    pcsPerStripCtrl.text = '10';
    profitCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        iconTheme: IconThemeData(color: mainText),
        title: Text(
          t('Pack Price', 'প্যাকেট হিসাব'),
          style: TextStyle(color: mainText, fontWeight: FontWeight.w900),
        ),
        actions: [
          TextButton(
            onPressed: _toggleLanguage,
            child: Text(
              bangla ? 'EN' : 'বাংলা',
              style: TextStyle(color: orange, fontWeight: FontWeight.w900),
            ),
          ),
          IconButton(
            tooltip: t('Clear', 'ক্লিয়ার'),
            onPressed: clearAll,
            icon: Icon(Icons.refresh_rounded, color: orange),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              HisabFlowResponsive.horizontalPadding(context),
              8,
              HisabFlowResponsive.horizontalPadding(context),
              24,
            ),
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                _topInfoCard(),
                const SizedBox(height: 14),
                _inputCard(),
                const SizedBox(height: 14),
                _resultCard(),
                const SizedBox(height: 14),
                _exampleCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: HisabFlowColors.brandGradient,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: orange.withValues(alpha: 0.25),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            height: 54,
            width: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.inventory_2_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('Box, Pata & Pcs Calculator', 'বক্স, পাতা ও পিস হিসাব'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  t(
                    'Find 1 pcs and 1 strip price quickly.',
                    'পুরো প্যাকেট দাম দিলেই ১ পিস ও ১ পাতার দাম বের হবে।',
                  ),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inputCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: widget.darkMode
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Column(
        children: [
          _input(
            controller: boxPriceCtrl,
            label: t('Full Box / Packet Price', 'পুরো বক্স / প্যাকেট দাম'),
            icon: Icons.payments_rounded,
          ),
          const SizedBox(height: 10),
          _input(
            controller: totalPcsCtrl,
            label: t('Total Pcs in Box', 'বক্সে মোট পিস'),
            icon: Icons.numbers_rounded,
          ),
          const SizedBox(height: 10),
          _input(
            controller: pcsPerStripCtrl,
            label: t('Pcs per Pata / Strip', '১ পাতা / স্ট্রিপে কয় পিস'),
            icon: Icons.view_module_rounded,
          ),
          const SizedBox(height: 10),
          _input(
            controller: profitCtrl,
            label: t('Profit % optional', 'লাভ % (ঐচ্ছিক)'),
            icon: Icons.trending_up_rounded,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              t('Quick profit', 'দ্রুত লাভ %'),
              style: TextStyle(
                color: mutedText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [0, 5, 10, 15, 20].map((percent) {
              final selected = profitPercent == percent;
              return ChoiceChip(
                selected: selected,
                label: Text(percent == 0 ? t('None', 'নেই') : '$percent%'),
                onSelected: (_) {
                  HapticFeedback.selectionClick();
                  profitCtrl.text = percent == 0 ? '' : percent.toString();
                },
                selectedColor: HisabFlowColors.primary.withValues(alpha: 0.18),
                side: BorderSide(
                  color: selected
                      ? HisabFlowColors.primary.withValues(alpha: 0.45)
                      : mutedText.withValues(alpha: 0.18),
                ),
                labelStyle: TextStyle(
                  color: selected ? HisabFlowColors.primaryLight : mainText,
                  fontWeight: FontWeight.w800,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _input({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: HisabFlowColors.primary),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: t('Clear', 'মুছুন'),
                onPressed: controller.clear,
                icon: Icon(Icons.close_rounded, color: mutedText, size: 18),
              ),
        labelText: label,
        labelStyle: TextStyle(color: mutedText),
        filled: true,
        fillColor: field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _resultCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: hasBasicInput
              ? green.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('Result', 'রেজাল্ট'),
            style: TextStyle(
              color: mainText,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          _resultRow(
            icon: Icons.looks_one_rounded,
            title: t('1 Pcs Cost', '১ পিস দাম'),
            value: hasBasicInput ? money(pcsCost) : '-',
            color: cyan,
          ),
          _resultRow(
            icon: Icons.view_week_rounded,
            title: t('1 Pata / Strip Cost', '১ পাতা / স্ট্রিপ দাম'),
            value: hasBasicInput && pcsPerStrip > 0 ? money(stripCost) : '-',
            color: orange,
          ),
          _resultRow(
            icon: Icons.inventory_rounded,
            title: t('Total Pata / Strip', 'মোট পাতা / স্ট্রিপ'),
            value: hasBasicInput && pcsPerStrip > 0 ? number(totalStrip) : '-',
            color: green,
          ),
          if (profitPercent > 0) ...[
            const SizedBox(height: 8),
            Divider(color: mutedText.withValues(alpha: 0.25)),
            _resultRow(
              icon: Icons.sell_rounded,
              title: t('1 Pcs Sale Price', '১ পিস বিক্রয় দাম'),
              value: money(salePcsPrice),
              color: green,
            ),
            _resultRow(
              icon: Icons.shopping_bag_rounded,
              title: t(
                '1 Pata / Strip Sale Price',
                '১ পাতা / স্ট্রিপ বিক্রয় দাম',
              ),
              value: money(saleStripPrice),
              color: green,
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: HisabFlowColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              onPressed: hasBasicInput ? copyResult : null,
              icon: const Icon(Icons.copy_rounded),
              label: Text(
                t('Copy Result', 'রেজাল্ট কপি'),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultRow({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: field,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: mainText, fontWeight: FontWeight.w800),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _exampleCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('Example', 'উদাহরণ'),
            style: TextStyle(
              color: mainText,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t(
              'Box price 450, total 150 pcs, 10 pcs per strip = 1 pcs 3 Taka, 1 strip 30 Taka.',
              'বক্স দাম 450, মোট 150 পিস, ১ পাতায় 10 পিস = ১ পিস 3 টাকা, ১ পাতা 30 টাকা।',
            ),
            style: TextStyle(
              color: mutedText,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
