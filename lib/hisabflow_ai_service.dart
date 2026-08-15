import 'dart:async';

import 'package:firebase_ai/firebase_ai.dart';

/// HisabFlow Assistant service.
///
/// FAST PATH:
/// - Exact/business calculations are answered locally with no network wait.
///
/// AI PATH:
/// - General questions use Firebase AI chat streaming so text appears while
///   Gemini is generating it instead of waiting for the whole response.
///
/// HISTORY:
/// - The UI stores chats locally.
/// - setConversationHistory(...) restores the selected conversation as Gemini
///   context so follow-up questions can continue naturally.
class HisabFlowAiService {
  HisabFlowAiService._() {
    _model = FirebaseAI.googleAI().generativeModel(
      model: _modelName,
      systemInstruction: Content.system(_systemInstruction),
    );
  }

  static final HisabFlowAiService instance = HisabFlowAiService._();

  static const String _modelName = 'gemini-3.6-flash';
  static const Duration _requestTimeout = Duration(seconds: 30);
  static const int _maxContextMessages = 40;

  late final GenerativeModel _model;

  final List<HisabFlowAiHistoryMessage> _history =
      <HisabFlowAiHistoryMessage>[];

  static const String _systemInstruction = '''
You are HisabFlow Assistant, the intelligent assistant inside the HisabFlow app.

CORE ROLE:
- Help users with everyday calculations, business calculations, explanations,
  writing, finance-related concepts, and general questions.
- Answer naturally like a modern conversational assistant.
- Never pretend that you can see or change private app data unless the app
  explicitly sends that data.
- When a deterministic HisabFlow local calculation result is already shown,
  that local result is authoritative. Never contradict it.

LANGUAGE:
- Understand Bengali (Bangla), English, Banglish, and mixed Bengali-English.
- Understand informal writing, spelling mistakes, phonetic Banglish, short
  messages, and conversational wording.
- Bengali question -> Bengali reply.
- English question -> English reply.
- Banglish question -> natural, simple Banglish reply.
- Mixed language -> respond in the clearest matching style.
- Keep wording easy for ordinary users.

CONVERSATION:
- Use previous turns to understand short follow-up questions.
- If the previous turn calculated a unit price and the user asks "50 kg hole?",
  use the previous context rather than forcing the user to repeat everything.
- Do not invent missing information. If a required value truly cannot be
  inferred from the conversation, ask one short clarification.

CALCULATION SAFETY:
- Financial and numerical accuracy is extremely important.
- Never silently change numbers supplied by the user.
- Never guess quantity, price, percentage, paid amount, due amount, profit,
  loss, discount, VAT, tax, commission, or selling price.
- If required information is missing and cannot be inferred from chat history,
  ask one short clarification.

BUSINESS HELP:
You can help with:
- sales and purchases
- expenses
- profit and loss
- discount
- due and paid amounts
- change/return money
- percentages
- VAT/tax concepts
- commission
- unit prices
- pack/carton/pcs concepts
- stock and cashbook concepts
- invoices and receipts
- customer notes
- basic accounting concepts
- pricing and margin concepts
- business writing
- general questions

APP DATA AND PRIVACY:
- Never claim you can see stored HisabFlow records unless the app explicitly
  provides that data in the current request.
- Never invent customer balances, sales, expenses, payments, stock,
  cloud-backup data, login state, or account information.
- Never request or expose passwords, PINs, recovery codes, API keys,
  authentication tokens, signing keys, or other secrets.

STYLE:
- Friendly, practical, concise, and clear.
- Prefer short paragraphs and simple steps.
- For calculation explanations, show the formula briefly.
- Avoid unnecessary technical jargon.
''';

  Future<HisabFlowAiResult> ask(String question) async {
    final StringBuffer fullText = StringBuffer();
    bool local = false;
    bool success = false;

    await for (final HisabFlowAiStreamChunk chunk in streamAnswer(question)) {
      if (chunk.text.isNotEmpty) {
        fullText.write(chunk.text);
      }
      local = local || chunk.isLocalCalculation;
      if (chunk.done) {
        success = chunk.success;
      }
    }

    return HisabFlowAiResult(
      text: fullText.toString().trim(),
      isLocalCalculation: local,
      success: success,
    );
  }

  Stream<HisabFlowAiStreamChunk> streamAnswer(String question) async* {
    final String cleanedQuestion = question.trim();

    if (cleanedQuestion.isEmpty) {
      yield const HisabFlowAiStreamChunk(
        text: 'একটি প্রশ্ন লিখুন।',
        isLocalCalculation: false,
        success: false,
        done: true,
      );
      return;
    }

    final _ReplyStyle style = HisabFlowExactCalculator.detectReplyStyle(
      cleanedQuestion,
    );

    final HisabFlowLocalCalculation? localResult =
        HisabFlowExactCalculator.tryCalculate(cleanedQuestion);

    if (localResult != null) {
      _appendSuccessfulTurn(cleanedQuestion, localResult.answer);

      yield HisabFlowAiStreamChunk(
        text: localResult.answer,
        isLocalCalculation: true,
        success: true,
        done: true,
      );
      return;
    }

    try {
      final ChatSession chat = _model.startChat(history: _firebaseHistory());

      final Stream<GenerateContentResponse> responseStream = chat
          .sendMessageStream(Content.text(cleanedQuestion))
          .timeout(_requestTimeout);

      final StringBuffer completed = StringBuffer();
      bool emittedAnyText = false;

      await for (final GenerateContentResponse response in responseStream) {
        final String piece = response.text ?? '';
        if (piece.isEmpty) {
          continue;
        }

        emittedAnyText = true;
        completed.write(piece);

        yield HisabFlowAiStreamChunk(
          text: piece,
          isLocalCalculation: false,
          success: true,
          done: false,
        );
      }

      final String finalText = completed.toString().trim();

      if (!emittedAnyText || finalText.isEmpty) {
        final String message = _noResponseMessage(style);
        yield HisabFlowAiStreamChunk(
          text: message,
          isLocalCalculation: false,
          success: false,
          done: true,
        );
        return;
      }

      _appendSuccessfulTurn(cleanedQuestion, finalText);

      yield const HisabFlowAiStreamChunk(
        text: '',
        isLocalCalculation: false,
        success: true,
        done: true,
      );
    } on TimeoutException {
      yield HisabFlowAiStreamChunk(
        text: _timeoutMessage(style),
        isLocalCalculation: false,
        success: false,
        done: true,
      );
    } catch (error) {
      yield HisabFlowAiStreamChunk(
        text: _friendlyErrorMessage(error, style),
        isLocalCalculation: false,
        success: false,
        done: true,
      );
    }
  }

  void resetConversation() {
    _history.clear();
  }

  void setConversationHistory(List<HisabFlowAiHistoryMessage> history) {
    _history
      ..clear()
      ..addAll(
        history.length <= _maxContextMessages
            ? history
            : history.sublist(history.length - _maxContextMessages),
      );
  }

  List<HisabFlowAiHistoryMessage> get conversationHistory =>
      List<HisabFlowAiHistoryMessage>.unmodifiable(_history);

  List<Content> _firebaseHistory() {
    final List<HisabFlowAiHistoryMessage> source =
        _history.length <= _maxContextMessages
        ? _history
        : _history.sublist(_history.length - _maxContextMessages);

    return source
        .map((HisabFlowAiHistoryMessage message) {
          if (message.fromUser) {
            return Content.text(message.text);
          }
          return Content.model(<Part>[TextPart(message.text)]);
        })
        .toList(growable: false);
  }

  void _appendSuccessfulTurn(String userText, String modelText) {
    _history
      ..add(HisabFlowAiHistoryMessage(text: userText, fromUser: true))
      ..add(HisabFlowAiHistoryMessage(text: modelText, fromUser: false));

    if (_history.length > _maxContextMessages) {
      _history.removeRange(0, _history.length - _maxContextMessages);
    }
  }

  String _noResponseMessage(_ReplyStyle style) {
    switch (style) {
      case _ReplyStyle.bangla:
        return 'এই মুহূর্তে উত্তর পাওয়া যায়নি। আবার চেষ্টা করুন।';
      case _ReplyStyle.banglish:
        return 'Ei muhurte answer pawa jayni. Abar try korun.';
      case _ReplyStyle.english:
        return 'No response was received. Please try again.';
    }
  }

  String _timeoutMessage(_ReplyStyle style) {
    switch (style) {
      case _ReplyStyle.bangla:
        return 'উত্তর আসতে বেশি সময় লাগছে। ইন্টারনেট ঠিক থাকলে আবার চেষ্টা করুন।';
      case _ReplyStyle.banglish:
        return 'Answer aste beshi time lagche. Internet thik thakle abar try korun.';
      case _ReplyStyle.english:
        return 'The response is taking too long. Check your connection and try again.';
    }
  }

  String _friendlyErrorMessage(Object error, _ReplyStyle style) {
    final String raw = error.toString().toLowerCase();

    if (raw.contains('app check') ||
        raw.contains('appcheck') ||
        raw.contains('403') ||
        raw.contains('permission') ||
        raw.contains('unauthorized')) {
      switch (style) {
        case _ReplyStyle.bangla:
          return 'HisabFlow Assistant নিরাপত্তা যাচাই সম্পন্ন করতে পারেনি। '
              'App Check configuration যাচাই করে আবার চেষ্টা করুন।';
        case _ReplyStyle.banglish:
          return 'HisabFlow Assistant security verification complete korte pareni. '
              'App Check configuration check kore abar try korun.';
        case _ReplyStyle.english:
          return 'HisabFlow Assistant could not complete security verification. '
              'Please check App Check and try again.';
      }
    }

    if (raw.contains('network') ||
        raw.contains('socket') ||
        raw.contains('internet') ||
        raw.contains('connection') ||
        raw.contains('host lookup')) {
      switch (style) {
        case _ReplyStyle.bangla:
          return 'ইন্টারনেট সংযোগ পাওয়া যাচ্ছে না। ইন্টারনেট চালু করে আবার চেষ্টা করুন।';
        case _ReplyStyle.banglish:
          return 'Internet connection pawa jacche na. Internet check kore abar try korun.';
        case _ReplyStyle.english:
          return 'No internet connection is available. Check your connection and try again.';
      }
    }

    if (raw.contains('quota') ||
        raw.contains('429') ||
        raw.contains('resource_exhausted') ||
        raw.contains('resource exhausted')) {
      switch (style) {
        case _ReplyStyle.bangla:
          return 'HisabFlow Assistant-এর সাময়িক ব্যবহারের সীমা পূর্ণ হয়েছে। '
              'কিছুক্ষণ পরে আবার চেষ্টা করুন।';
        case _ReplyStyle.banglish:
          return 'HisabFlow Assistant er temporary usage limit full hoye geche. '
              'Kichukhon por abar try korun.';
        case _ReplyStyle.english:
          return 'The temporary HisabFlow Assistant usage limit has been reached. '
              'Please try again later.';
      }
    }

    if (raw.contains('404') ||
        (raw.contains('model') && raw.contains('not found'))) {
      switch (style) {
        case _ReplyStyle.bangla:
          return 'HisabFlow Assistant model এখন পাওয়া যাচ্ছে না। '
              'AI configuration update প্রয়োজন হতে পারে।';
        case _ReplyStyle.banglish:
          return 'HisabFlow Assistant model ekhon pawa jacche na. '
              'AI configuration update lagte pare.';
        case _ReplyStyle.english:
          return 'The HisabFlow Assistant model is currently unavailable. '
              'The AI configuration may need an update.';
      }
    }

    switch (style) {
      case _ReplyStyle.bangla:
        return 'HisabFlow Assistant এখন উত্তর দিতে পারছে না। '
            'কিছুক্ষণ পরে আবার চেষ্টা করুন।';
      case _ReplyStyle.banglish:
        return 'HisabFlow Assistant ekhon answer dite parche na. '
            'Kichukhon por abar try korun.';
      case _ReplyStyle.english:
        return 'HisabFlow Assistant cannot respond right now. '
            'Please try again shortly.';
    }
  }
}

class HisabFlowAiHistoryMessage {
  final String text;
  final bool fromUser;

  const HisabFlowAiHistoryMessage({required this.text, required this.fromUser});
}

class HisabFlowAiStreamChunk {
  final String text;
  final bool isLocalCalculation;
  final bool success;
  final bool done;

  const HisabFlowAiStreamChunk({
    required this.text,
    required this.isLocalCalculation,
    required this.success,
    required this.done,
  });
}

// =============================================================================
// RESULT MODELS
// =============================================================================

class HisabFlowAiResult {
  final String text;
  final bool isLocalCalculation;
  final bool success;

  const HisabFlowAiResult({
    required this.text,
    required this.isLocalCalculation,
    required this.success,
  });
}

class HisabFlowLocalCalculation {
  final String answer;

  const HisabFlowLocalCalculation(this.answer);
}

enum _ReplyStyle { bangla, banglish, english }

// =============================================================================
// EXACT CALCULATOR
// =============================================================================

class HisabFlowExactCalculator {
  HisabFlowExactCalculator._();

  static HisabFlowLocalCalculation? tryCalculate(String originalText) {
    final _ReplyStyle style = detectReplyStyle(originalText);
    final String text = _normalize(originalText);

    final List<HisabFlowLocalCalculation? Function(String, _ReplyStyle)>
    calculators = <HisabFlowLocalCalculation? Function(String, _ReplyStyle)>[
      _tryPureExpression,
      _tryUnitPriceCalculation,
      _tryPercentageCalculation,
      _tryDueOrChangeCalculation,
      _trySalesExpenseCalculation,
      _tryProfitLossFromPrices,
      _tryQuantityTimesPrice,
      _tryEqualSplit,
      _tryAverage,
      _tryNaturalArithmetic,
    ];

    for (final calculator in calculators) {
      final HisabFlowLocalCalculation? result = calculator(text, style);

      if (result != null) {
        return result;
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // LANGUAGE
  // ---------------------------------------------------------------------------

  static _ReplyStyle detectReplyStyle(String originalText) {
    if (RegExp(r'[\u0980-\u09FF]').hasMatch(originalText)) {
      return _ReplyStyle.bangla;
    }

    final String text = originalText.toLowerCase();

    const List<String> banglishWords = <String>[
      'taka',
      'takar',
      'takay',
      'tk',
      'koto',
      'hobe',
      'hoy',
      'hole',
      'dam',
      'dame',
      'baki',
      'labh',
      'lav',
      'khoti',
      'hisab',
      'hishab',
      'kore',
      'proti',
      'porishodh',
      'porishod',
      'disi',
      'dichi',
      'diyechi',
      'kena',
      'bikri',
      'bikroy',
      'khoroch',
      'khoroc',
      'mot',
      'lakh',
      'lac',
      'koti',
      'hajar',
      'vag',
      'jon',
      'dile',
      'theke',
      'bad',
      'jog',
    ];

    for (final String word in banglishWords) {
      if (RegExp(
        '\\b${RegExp.escape(word)}\\b',
        caseSensitive: false,
      ).hasMatch(text)) {
        return _ReplyStyle.banglish;
      }
    }

    return _ReplyStyle.english;
  }

  // ---------------------------------------------------------------------------
  // CALCULATION-LIKE INPUT
  // ---------------------------------------------------------------------------

  static bool looksLikeCalculation(String originalText) {
    final String text = _normalize(originalText);

    if (RegExp(r'[+\-*/=%]').hasMatch(text)) {
      return true;
    }

    final int numberCount = RegExp(r'\d+(?:\.\d+)?').allMatches(text).length;

    if (numberCount < 2) {
      return false;
    }

    const List<String> calculationWords = <String>[
      'howmuch',
      'calculate',
      'price',
      'tk',
      'profit',
      'loss',
      'discount',
      'due',
      'paid',
      'total',
      'sales',
      'expense',
      'cost',
      'sell',
      'kg',
      'pcs',
      'piece',
      'card',
      'each',
      'per',
      'lakh',
      'crore',
      'thousand',
      'percent',
      'vat',
      'tax',
      'commission',
      'average',
      'split',
      'person',
      'add',
      'subtract',
      'multiply',
      'divide',
      'from',
    ];

    for (final String word in calculationWords) {
      if (text.contains(word)) {
        return true;
      }
    }

    return false;
  }

  // ---------------------------------------------------------------------------
  // PURE ARITHMETIC
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryPureExpression(
    String text,
    _ReplyStyle style,
  ) {
    String expression = text;

    const List<String> fillerWords = <String>[
      'howmuch',
      'calculate',
      'result',
      'answer',
      'please',
      'tk',
    ];

    for (final String word in fillerWords) {
      expression = expression.replaceAll(word, ' ');
    }

    expression = expression.replaceAll('?', '').replaceAll('=', '').trim();

    if (expression.isEmpty) {
      return null;
    }

    if (!RegExp(r'^[0-9+\-*/().\s]+$').hasMatch(expression)) {
      return null;
    }

    if (!RegExp(r'[+\-*/]').hasMatch(expression)) {
      return null;
    }

    try {
      final double result = _ExpressionParser(expression).parse();

      if (!result.isFinite) {
        return null;
      }

      final String answer = _formatNumber(result);

      switch (style) {
        case _ReplyStyle.bangla:
          return HisabFlowLocalCalculation(
            'হিসাব:\n'
            '${expression.trim()}\n\n'
            'ফলাফল = $answer',
          );
        case _ReplyStyle.banglish:
          return HisabFlowLocalCalculation(
            'Hisab:\n'
            '${expression.trim()}\n\n'
            'Result = $answer',
          );
        case _ReplyStyle.english:
          return HisabFlowLocalCalculation(
            'Calculation:\n'
            '${expression.trim()}\n\n'
            'Result = $answer',
          );
      }
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // UNIT PRICE
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryUnitPriceCalculation(
    String text,
    _ReplyStyle style,
  ) {
    final bool asksPerUnit =
        text.contains('per kg') ||
        text.contains('per pcs') ||
        text.contains('per piece') ||
        text.contains('per card') ||
        text.contains('per unit') ||
        text.contains('unit price') ||
        RegExp(
          r'\b1\s*(kg|pcs|piece|pieces|card|cards|unit|units)\b',
          caseSensitive: false,
        ).hasMatch(text);

    if (!asksPerUnit) {
      return null;
    }

    final RegExp quantityFirst = RegExp(
      r'(\d+(?:\.\d+)?)\s*'
      r'(kg|pcs|piece|pieces|card|cards|unit|units)'
      r'[^0-9]{0,70}'
      r'(\d+(?:\.\d+)?)\s*tk',
      caseSensitive: false,
    );

    final RegExp priceFirst = RegExp(
      r'(\d+(?:\.\d+)?)\s*tk'
      r'[^0-9]{0,70}'
      r'(\d+(?:\.\d+)?)\s*'
      r'(kg|pcs|piece|pieces|card|cards|unit|units)',
      caseSensitive: false,
    );

    double? quantity;
    double? totalPrice;
    String unit = 'unit';

    final RegExpMatch? firstMatch = quantityFirst.firstMatch(text);

    if (firstMatch != null) {
      quantity = double.tryParse(firstMatch.group(1) ?? '');
      unit = firstMatch.group(2) ?? 'unit';
      totalPrice = double.tryParse(firstMatch.group(3) ?? '');
    } else {
      final RegExpMatch? secondMatch = priceFirst.firstMatch(text);

      if (secondMatch != null) {
        totalPrice = double.tryParse(secondMatch.group(1) ?? '');
        quantity = double.tryParse(secondMatch.group(2) ?? '');
        unit = secondMatch.group(3) ?? 'unit';
      } else {
        // Natural Banglish often omits the word "taka", for example:
        // "3002 kg er dam 2000 hole 1kg koto?"
        // Because the user explicitly asks for one unit, the first quantity
        // followed by the next number is safely interpreted as total price.
        final RegExp quantityThenPrice = RegExp(
          r'(\d+(?:\.\d+)?)\s*'
          r'(kg|pcs|piece|pieces|card|cards|unit|units)'
          r'[^0-9]{0,70}'
          r'(\d+(?:\.\d+)?)'
          r'(?=[^0-9]{0,70}(?:1\s*(?:kg|pcs|piece|pieces|card|cards|unit|units)|per\s+(?:kg|pcs|piece|card|unit)))',
          caseSensitive: false,
        );

        final RegExpMatch? naturalMatch = quantityThenPrice.firstMatch(text);

        if (naturalMatch != null) {
          quantity = double.tryParse(naturalMatch.group(1) ?? '');
          unit = naturalMatch.group(2) ?? 'unit';
          totalPrice = double.tryParse(naturalMatch.group(3) ?? '');
        }
      }
    }

    if (quantity == null ||
        totalPrice == null ||
        quantity <= 0 ||
        totalPrice < 0) {
      return null;
    }

    final double unitPrice = totalPrice / quantity;
    final String prettyUnit = _prettyUnit(unit, style);

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          'প্রতি $prettyUnit-এর দাম:\n'
          '${_money(totalPrice, style)} ÷ '
          '${_formatNumber(quantity)} $prettyUnit\n\n'
          '= ${_money(unitPrice, style)} প্রতি $prettyUnit',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          'Per $prettyUnit price:\n'
          '${_money(totalPrice, style)} ÷ '
          '${_formatNumber(quantity)} $prettyUnit\n\n'
          '= ${_money(unitPrice, style)} per $prettyUnit',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          'Price per $prettyUnit:\n'
          '${_money(totalPrice, style)} ÷ '
          '${_formatNumber(quantity)} $prettyUnit\n\n'
          '= ${_money(unitPrice, style)} per $prettyUnit',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // PERCENTAGE / PROFIT / DISCOUNT / LOSS / VAT / TAX / COMMISSION
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryPercentageCalculation(
    String text,
    _ReplyStyle style,
  ) {
    final RegExp percentageRegex = RegExp(
      r'(\d+(?:\.\d+)?)\s*(?:%|percent\b)',
      caseSensitive: false,
    );

    final List<RegExpMatch> matches = percentageRegex.allMatches(text).toList();

    if (matches.length != 1) {
      return null;
    }

    final RegExpMatch match = matches.first;
    final double? percentage = double.tryParse(match.group(1) ?? '');

    if (percentage == null || percentage < 0) {
      return null;
    }

    final String textWithoutPercentage = text.replaceFirst(
      match.group(0) ?? '',
      ' ',
    );

    final List<double> numbers = _extractNumbers(textWithoutPercentage);

    if (numbers.length != 1) {
      return null;
    }

    final double baseAmount = numbers.first;

    if (baseAmount < 0) {
      return null;
    }

    final double percentageAmount = baseAmount * percentage / 100;

    if (text.contains('profit') || text.contains('markup')) {
      return _percentageContextAnswer(
        style: style,
        titleBn: 'লাভের হিসাব',
        titleBanglish: 'Profit hisab',
        titleEn: 'Profit calculation',
        baseAmount: baseAmount,
        percentage: percentage,
        percentageAmount: percentageAmount,
        amountLabelBn: 'লাভ',
        amountLabelBanglish: 'profit',
        amountLabelEn: 'profit',
        finalLabelBn: 'বিক্রয় মূল্য',
        finalLabelBanglish: 'Selling price',
        finalLabelEn: 'Selling price',
        finalAmount: baseAmount + percentageAmount,
      );
    }

    if (text.contains('discount')) {
      final double finalPrice = baseAmount - percentageAmount;

      if (finalPrice < 0) {
        return null;
      }

      return _percentageContextAnswer(
        style: style,
        titleBn: 'Discount হিসাব',
        titleBanglish: 'Discount hisab',
        titleEn: 'Discount calculation',
        baseAmount: baseAmount,
        percentage: percentage,
        percentageAmount: percentageAmount,
        amountLabelBn: 'ছাড়',
        amountLabelBanglish: 'discount',
        amountLabelEn: 'discount',
        finalLabelBn: 'ছাড়ের পর মূল্য',
        finalLabelBanglish: 'Final price',
        finalLabelEn: 'Final price',
        finalAmount: finalPrice,
      );
    }

    if (text.contains('loss')) {
      final double finalPrice = baseAmount - percentageAmount;

      if (finalPrice < 0) {
        return null;
      }

      return _percentageContextAnswer(
        style: style,
        titleBn: 'ক্ষতির হিসাব',
        titleBanglish: 'Loss hisab',
        titleEn: 'Loss calculation',
        baseAmount: baseAmount,
        percentage: percentage,
        percentageAmount: percentageAmount,
        amountLabelBn: 'ক্ষতি',
        amountLabelBanglish: 'loss',
        amountLabelEn: 'loss',
        finalLabelBn: 'বিক্রয় মূল্য',
        finalLabelBanglish: 'Selling price',
        finalLabelEn: 'Selling price',
        finalAmount: finalPrice,
      );
    }

    if (text.contains('vat') || text.contains('tax')) {
      final double totalWithTax = baseAmount + percentageAmount;
      final String label = text.contains('vat') ? 'VAT' : 'Tax';

      switch (style) {
        case _ReplyStyle.bangla:
          return HisabFlowLocalCalculation(
            '$label হিসাব:\n'
            '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n'
            '= ${_money(percentageAmount, style)} $label\n\n'
            '$label সহ মোট = ${_money(totalWithTax, style)}',
          );
        case _ReplyStyle.banglish:
          return HisabFlowLocalCalculation(
            '$label hisab:\n'
            '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n'
            '= ${_money(percentageAmount, style)} $label\n\n'
            'Total with $label = ${_money(totalWithTax, style)}',
          );
        case _ReplyStyle.english:
          return HisabFlowLocalCalculation(
            '$label calculation:\n'
            '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n'
            '= ${_money(percentageAmount, style)} $label\n\n'
            'Total with $label = ${_money(totalWithTax, style)}',
          );
      }
    }

    if (text.contains('commission')) {
      switch (style) {
        case _ReplyStyle.bangla:
          return HisabFlowLocalCalculation(
            'Commission হিসাব:\n'
            '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n\n'
            '= ${_money(percentageAmount, style)} commission',
          );
        case _ReplyStyle.banglish:
          return HisabFlowLocalCalculation(
            'Commission hisab:\n'
            '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n\n'
            '= ${_money(percentageAmount, style)} commission',
          );
        case _ReplyStyle.english:
          return HisabFlowLocalCalculation(
            'Commission calculation:\n'
            '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n\n'
            '= ${_money(percentageAmount, style)} commission',
          );
      }
    }

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          '${_money(baseAmount, style)}-এর '
          '${_formatNumber(percentage)}%\n\n'
          '= ${_money(percentageAmount, style)}',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          '${_money(baseAmount, style)} er '
          '${_formatNumber(percentage)}%\n\n'
          '= ${_money(percentageAmount, style)}',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          '${_formatNumber(percentage)}% of '
          '${_money(baseAmount, style)}\n\n'
          '= ${_money(percentageAmount, style)}',
        );
    }
  }

  static HisabFlowLocalCalculation _percentageContextAnswer({
    required _ReplyStyle style,
    required String titleBn,
    required String titleBanglish,
    required String titleEn,
    required double baseAmount,
    required double percentage,
    required double percentageAmount,
    required String amountLabelBn,
    required String amountLabelBanglish,
    required String amountLabelEn,
    required String finalLabelBn,
    required String finalLabelBanglish,
    required String finalLabelEn,
    required double finalAmount,
  }) {
    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          '$titleBn:\n'
          '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n'
          '= ${_money(percentageAmount, style)} $amountLabelBn\n\n'
          '$finalLabelBn = ${_money(finalAmount, style)}',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          '$titleBanglish:\n'
          '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n'
          '= ${_money(percentageAmount, style)} $amountLabelBanglish\n\n'
          '$finalLabelBanglish = ${_money(finalAmount, style)}',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          '$titleEn:\n'
          '${_money(baseAmount, style)} × ${_formatNumber(percentage)}%\n'
          '= ${_money(percentageAmount, style)} $amountLabelEn\n\n'
          '$finalLabelEn = ${_money(finalAmount, style)}',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // DUE / CHANGE
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryDueOrChangeCalculation(
    String text,
    _ReplyStyle style,
  ) {
    final bool hasPaymentContext =
        text.contains('due') ||
        text.contains('paid') ||
        text.contains('change') ||
        text.contains('return money');

    if (!hasPaymentContext) {
      return null;
    }

    double? total = _findNumberNearKeywords(text, const <String>[
      'total',
      'bill',
      'price',
    ]);

    double? paid = _findNumberNearKeywords(text, const <String>[
      'paid',
      'payment',
    ]);

    final RegExp paidOutOfRegex = RegExp(
      r'paid\s*[:=]?\s*(\d+(?:\.\d+)?)'
      r'[^0-9]{0,30}'
      r'out\s+of\s+'
      r'(\d+(?:\.\d+)?)',
      caseSensitive: false,
    );

    final RegExpMatch? paidOutOfMatch = paidOutOfRegex.firstMatch(text);

    if (paidOutOfMatch != null) {
      paid = double.tryParse(paidOutOfMatch.group(1) ?? '');
      total = double.tryParse(paidOutOfMatch.group(2) ?? '');
    }

    if (total == null || paid == null) {
      final List<double> numbers = _extractNumbers(text);

      if (numbers.length != 2) {
        return null;
      }

      final int paidPosition = text.indexOf('paid');
      final int totalPosition = text.indexOf('total');

      if (paidPosition >= 0 &&
          totalPosition >= 0 &&
          paidPosition < totalPosition) {
        paid = numbers[0];
        total = numbers[1];
      } else {
        total = numbers[0];
        paid = numbers[1];
      }
    }

    if (total == null || paid == null) {
      return null;
    }

    final double finalTotal = total;
    final double finalPaid = paid;

    if (finalTotal < 0 || finalPaid < 0) {
      return null;
    }

    if (finalPaid <= finalTotal) {
      final double dueAmount = finalTotal - finalPaid;

      switch (style) {
        case _ReplyStyle.bangla:
          return HisabFlowLocalCalculation(
            'বাকি হিসাব:\n'
            '${_money(finalTotal, style)} - ${_money(finalPaid, style)}\n\n'
            '= ${_money(dueAmount, style)} বাকি',
          );
        case _ReplyStyle.banglish:
          return HisabFlowLocalCalculation(
            'Baki hisab:\n'
            '${_money(finalTotal, style)} - ${_money(finalPaid, style)}\n\n'
            '= ${_money(dueAmount, style)} baki',
          );
        case _ReplyStyle.english:
          return HisabFlowLocalCalculation(
            'Due calculation:\n'
            '${_money(finalTotal, style)} - ${_money(finalPaid, style)}\n\n'
            '= ${_money(dueAmount, style)} due',
          );
      }
    }

    final double changeAmount = finalPaid - finalTotal;

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          'ফেরত টাকার হিসাব:\n'
          '${_money(finalPaid, style)} - ${_money(finalTotal, style)}\n\n'
          '= ${_money(changeAmount, style)} ফেরত',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          'Ferot taka hisab:\n'
          '${_money(finalPaid, style)} - ${_money(finalTotal, style)}\n\n'
          '= ${_money(changeAmount, style)} ferot',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          'Change calculation:\n'
          '${_money(finalPaid, style)} - ${_money(finalTotal, style)}\n\n'
          '= ${_money(changeAmount, style)} change',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // SALES - EXPENSE
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _trySalesExpenseCalculation(
    String text,
    _ReplyStyle style,
  ) {
    if (!text.contains('sales') || !text.contains('expense')) {
      return null;
    }

    final double? sales = _findNumberNearKeywords(text, const <String>[
      'sales',
    ]);

    final double? expense = _findNumberNearKeywords(text, const <String>[
      'expense',
    ]);

    if (sales == null || expense == null || sales < 0 || expense < 0) {
      return null;
    }

    final double difference = sales - expense;
    final bool isProfit = difference >= 0;
    final double amount = difference.abs();
    final double? ratio = sales > 0 ? amount / sales * 100 : null;

    switch (style) {
      case _ReplyStyle.bangla:
        final String ratioLine = ratio == null
            ? ''
            : '\n${isProfit ? 'Profit margin' : 'Loss ratio'} ≈ '
                  '${_formatNumber(ratio)}%';

        return HisabFlowLocalCalculation(
          'হিসাব:\n'
          'বিক্রি = ${_money(sales, style)}\n'
          'খরচ = ${_money(expense, style)}\n\n'
          '${isProfit ? 'লাভ' : 'ক্ষতি'} = ${_money(amount, style)}'
          '$ratioLine',
        );

      case _ReplyStyle.banglish:
        final String ratioLine = ratio == null
            ? ''
            : '\n${isProfit ? 'Profit margin' : 'Loss ratio'} ≈ '
                  '${_formatNumber(ratio)}%';

        return HisabFlowLocalCalculation(
          'Hisab:\n'
          'Sales = ${_money(sales, style)}\n'
          'Expense = ${_money(expense, style)}\n\n'
          '${isProfit ? 'Profit' : 'Loss'} = ${_money(amount, style)}'
          '$ratioLine',
        );

      case _ReplyStyle.english:
        final String ratioLine = ratio == null
            ? ''
            : '\n${isProfit ? 'Profit margin' : 'Loss ratio'} ≈ '
                  '${_formatNumber(ratio)}%';

        return HisabFlowLocalCalculation(
          'Calculation:\n'
          'Sales = ${_money(sales, style)}\n'
          'Expenses = ${_money(expense, style)}\n\n'
          '${isProfit ? 'Profit' : 'Loss'} = ${_money(amount, style)}'
          '$ratioLine',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // COST vs SELL
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryProfitLossFromPrices(
    String text,
    _ReplyStyle style,
  ) {
    if (!text.contains('cost') || !text.contains('sell')) {
      return null;
    }

    final double? cost = _findNumberNearKeywords(text, const <String>['cost']);

    final double? selling = _findNumberNearKeywords(text, const <String>[
      'sell',
    ]);

    if (cost == null || selling == null || cost < 0 || selling < 0) {
      return null;
    }

    final double difference = selling - cost;
    final bool isProfit = difference >= 0;
    final double amount = difference.abs();
    final double? rate = cost > 0 ? amount / cost * 100 : null;

    switch (style) {
      case _ReplyStyle.bangla:
        final String rateLine = rate == null
            ? ''
            : '\n${isProfit ? 'লাভের হার' : 'ক্ষতির হার'} ≈ '
                  '${_formatNumber(rate)}%';

        return HisabFlowLocalCalculation(
          'হিসাব:\n'
          'ক্রয় মূল্য = ${_money(cost, style)}\n'
          'বিক্রয় মূল্য = ${_money(selling, style)}\n\n'
          '${isProfit ? 'লাভ' : 'ক্ষতি'} = ${_money(amount, style)}'
          '$rateLine',
        );

      case _ReplyStyle.banglish:
        final String rateLine = rate == null
            ? ''
            : '\n${isProfit ? 'Profit rate' : 'Loss rate'} ≈ '
                  '${_formatNumber(rate)}%';

        return HisabFlowLocalCalculation(
          'Hisab:\n'
          'Cost price = ${_money(cost, style)}\n'
          'Selling price = ${_money(selling, style)}\n\n'
          '${isProfit ? 'Profit' : 'Loss'} = ${_money(amount, style)}'
          '$rateLine',
        );

      case _ReplyStyle.english:
        final String rateLine = rate == null
            ? ''
            : '\n${isProfit ? 'Profit rate' : 'Loss rate'} ≈ '
                  '${_formatNumber(rate)}%';

        return HisabFlowLocalCalculation(
          'Calculation:\n'
          'Cost price = ${_money(cost, style)}\n'
          'Selling price = ${_money(selling, style)}\n\n'
          '${isProfit ? 'Profit' : 'Loss'} = ${_money(amount, style)}'
          '$rateLine',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // QUANTITY × PRICE
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryQuantityTimesPrice(
    String text,
    _ReplyStyle style,
  ) {
    final bool hasPricePerUnit =
        text.contains('each') ||
        text.contains('per') ||
        text.contains('unit price');

    final bool hasQuantityContext =
        text.contains('card') ||
        text.contains('pcs') ||
        text.contains('piece') ||
        text.contains('unit') ||
        text.contains('pack') ||
        text.contains('carton') ||
        text.contains('lakh') ||
        text.contains('crore') ||
        text.contains('thousand');

    if (!hasPricePerUnit || !hasQuantityContext) {
      return null;
    }

    final List<RegExpMatch> matches = RegExp(
      r'\d+(?:\.\d+)?',
    ).allMatches(text).toList();

    if (matches.length != 2) {
      return null;
    }

    final double? rawQuantity = double.tryParse(matches[0].group(0) ?? '');

    final double? unitPrice = double.tryParse(matches[1].group(0) ?? '');

    if (rawQuantity == null ||
        unitPrice == null ||
        rawQuantity < 0 ||
        unitPrice < 0) {
      return null;
    }

    final double quantity = _applyScaleToNumber(text, matches[0], rawQuantity);

    final double total = quantity * unitPrice;

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          'মোট হিসাব:\n'
          '${_formatNumber(quantity)} × ${_money(unitPrice, style)}\n\n'
          '= ${_money(total, style)}',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          'Total hisab:\n'
          '${_formatNumber(quantity)} × ${_money(unitPrice, style)}\n\n'
          '= ${_money(total, style)}',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          'Total calculation:\n'
          '${_formatNumber(quantity)} × ${_money(unitPrice, style)}\n\n'
          '= ${_money(total, style)}',
        );
    }
  }

  static double _applyScaleToNumber(
    String text,
    RegExpMatch match,
    double value,
  ) {
    final int candidateEnd = match.end + 20;
    final int lookAheadEnd = candidateEnd < text.length
        ? candidateEnd
        : text.length;

    final String tail = text.substring(match.end, lookAheadEnd);

    if (RegExp(r'^\s*lakh\b').hasMatch(tail)) {
      return value * 100000;
    }

    if (RegExp(r'^\s*crore\b').hasMatch(tail)) {
      return value * 10000000;
    }

    if (RegExp(r'^\s*thousand\b').hasMatch(tail)) {
      return value * 1000;
    }

    return value;
  }

  // ---------------------------------------------------------------------------
  // EQUAL SPLIT
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryEqualSplit(
    String text,
    _ReplyStyle style,
  ) {
    final bool splitContext =
        text.contains('split') ||
        text.contains('divide among') ||
        text.contains('person') ||
        text.contains('people');

    if (!splitContext) {
      return null;
    }

    final List<double> numbers = _extractNumbers(text);

    if (numbers.length != 2) {
      return null;
    }

    final double total = numbers[0];
    final double people = numbers[1];

    if (total < 0 || people <= 0 || people != people.roundToDouble()) {
      return null;
    }

    final double each = total / people;

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          'সমান ভাগের হিসাব:\n'
          '${_money(total, style)} ÷ ${_formatNumber(people)} জন\n\n'
          '= ${_money(each, style)} করে',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          'Vag hisab:\n'
          '${_money(total, style)} ÷ ${_formatNumber(people)} jon\n\n'
          '= ${_money(each, style)} kore',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          'Equal split:\n'
          '${_money(total, style)} ÷ ${_formatNumber(people)} people\n\n'
          '= ${_money(each, style)} each',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // AVERAGE
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryAverage(
    String text,
    _ReplyStyle style,
  ) {
    if (!text.contains('average')) {
      return null;
    }

    final List<double> numbers = _extractNumbers(text);

    if (numbers.length < 2) {
      return null;
    }

    final double total = numbers.fold<double>(
      0,
      (double sum, double item) => sum + item,
    );

    final double average = total / numbers.length;

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          'গড় হিসাব:\n'
          'মোট = ${_formatNumber(total)}\n'
          'সংখ্যা = ${numbers.length}\n\n'
          'গড় = ${_formatNumber(average)}',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          'Average hisab:\n'
          'Total = ${_formatNumber(total)}\n'
          'Count = ${numbers.length}\n\n'
          'Average = ${_formatNumber(average)}',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          'Average calculation:\n'
          'Total = ${_formatNumber(total)}\n'
          'Count = ${numbers.length}\n\n'
          'Average = ${_formatNumber(average)}',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // NATURAL ARITHMETIC
  // ---------------------------------------------------------------------------

  static HisabFlowLocalCalculation? _tryNaturalArithmetic(
    String text,
    _ReplyStyle style,
  ) {
    final List<double> numbers = _extractNumbers(text);

    if (numbers.length != 2) {
      return null;
    }

    final double first = numbers[0];
    final double second = numbers[1];

    double? result;
    String symbol = '';

    if (text.contains('add')) {
      result = first + second;
      symbol = '+';
    } else if (text.contains('subtract') || text.contains('from')) {
      result = first - second;
      symbol = '-';
    } else if (text.contains('multiply')) {
      result = first * second;
      symbol = '×';
    } else if (text.contains('divide')) {
      if (second == 0) {
        return null;
      }

      result = first / second;
      symbol = '÷';
    }

    if (result == null || !result.isFinite) {
      return null;
    }

    switch (style) {
      case _ReplyStyle.bangla:
        return HisabFlowLocalCalculation(
          'হিসাব:\n'
          '${_formatNumber(first)} $symbol ${_formatNumber(second)}\n\n'
          '= ${_formatNumber(result)}',
        );
      case _ReplyStyle.banglish:
        return HisabFlowLocalCalculation(
          'Hisab:\n'
          '${_formatNumber(first)} $symbol ${_formatNumber(second)}\n\n'
          '= ${_formatNumber(result)}',
        );
      case _ReplyStyle.english:
        return HisabFlowLocalCalculation(
          'Calculation:\n'
          '${_formatNumber(first)} $symbol ${_formatNumber(second)}\n\n'
          '= ${_formatNumber(result)}',
        );
    }
  }

  // ---------------------------------------------------------------------------
  // NORMALIZATION
  // ---------------------------------------------------------------------------

  static String _normalize(String input) {
    String value = input.toLowerCase().trim();

    const Map<String, String> banglaDigits = <String, String>{
      '০': '0',
      '১': '1',
      '২': '2',
      '৩': '3',
      '৪': '4',
      '৫': '5',
      '৬': '6',
      '৭': '7',
      '৮': '8',
      '৯': '9',
    };

    for (final MapEntry<String, String> entry in banglaDigits.entries) {
      value = value.replaceAll(entry.key, entry.value);
    }

    value = value
        .replaceAll(',', '')
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('−', '-')
        .replaceAll('–', '-');

    const List<MapEntry<String, String>> banglaReplacements =
        <MapEntry<String, String>>[
          MapEntry('বিক্রয় মূল্য', ' sell '),
          MapEntry('বিক্রয় মূল্য', ' sell '),
          MapEntry('বিক্রয়মূল্য', ' sell '),
          MapEntry('বিক্রয়মূল্য', ' sell '),
          MapEntry('বিক্রির দাম', ' sell '),
          MapEntry('ক্রয় মূল্য', ' cost '),
          MapEntry('ক্রয় মূল্য', ' cost '),
          MapEntry('ক্রয়মূল্য', ' cost '),
          MapEntry('ক্রয়মূল্য', ' cost '),
          MapEntry('কেনা দাম', ' cost '),
          MapEntry('পরিশোধ করেছি', ' paid '),
          MapEntry('পরিশোধ করা', ' paid '),
          MapEntry('পরিশোধ', ' paid '),
          MapEntry('পেমেন্ট', ' paid '),
          MapEntry('দিয়েছি', ' paid '),
          MapEntry('দিয়েছি', ' paid '),
          MapEntry('ফেরত টাকা', ' change '),
          MapEntry('ফেরত', ' change '),
          MapEntry('অবশিষ্ট', ' due '),
          MapEntry('বাকি', ' due '),
          MapEntry('মুনাফা', ' profit '),
          MapEntry('লাভ', ' profit '),
          MapEntry('লোকসান', ' loss '),
          MapEntry('ক্ষতি', ' loss '),
          MapEntry('ডিসকাউন্ট', ' discount '),
          MapEntry('ছাড়', ' discount '),
          MapEntry('ছাড়', ' discount '),
          MapEntry('ভ্যাট', ' vat '),
          MapEntry('ট্যাক্স', ' tax '),
          MapEntry('কমিশন', ' commission '),
          MapEntry('আজকের বিক্রি', ' sales '),
          MapEntry('বিক্রি', ' sales '),
          MapEntry('খরচ', ' expense '),
          MapEntry('মোট বিল', ' total '),
          MapEntry('মোট', ' total '),
          MapEntry('টাকার', ' tk '),
          MapEntry('টাকা', ' tk '),
          MapEntry('দামের', ' price '),
          MapEntry('দাম', ' price '),
          MapEntry('কত', ' howmuch '),
          MapEntry('হিসাব', ' calculate '),
          MapEntry('প্রতি', ' per '),
          MapEntry('করে', ' each '),
          MapEntry('কেজি', ' kg '),
          MapEntry('কিলো', ' kg '),
          MapEntry('পিস', ' pcs '),
          MapEntry('কার্ড', ' card '),
          MapEntry('প্যাক', ' pack '),
          MapEntry('কার্টন', ' carton '),
          MapEntry('লাখ', ' lakh '),
          MapEntry('কোটি', ' crore '),
          MapEntry('হাজার', ' thousand '),
          MapEntry('গড়', ' average '),
          MapEntry('গড়', ' average '),
          MapEntry('জনের মধ্যে', ' people '),
          MapEntry('জন', ' person '),
          MapEntry('ভাগ করে', ' split '),
          MapEntry('ভাগ', ' divide '),
          MapEntry('যোগ', ' add '),
          MapEntry('বিয়োগ', ' subtract '),
          MapEntry('বিয়োগ', ' subtract '),
          MapEntry('বাদ', ' subtract '),
          MapEntry('গুণ', ' multiply '),
          MapEntry('থেকে', ' from '),
        ];

    for (final MapEntry<String, String> entry in banglaReplacements) {
      value = value.replaceAll(entry.key, entry.value);
    }

    const Map<String, String> asciiReplacements = <String, String>{
      'takar': 'tk',
      'takay': 'tk',
      'taka': 'tk',
      'koto': 'howmuch',
      'hisab': 'calculate',
      'hishab': 'calculate',
      'damer': 'price',
      'dame': 'price',
      'dam': 'price',
      'baki': 'due',
      'remaining': 'due',
      'labh': 'profit',
      'lav': 'profit',
      'munafa': 'profit',
      'khoti': 'loss',
      'lokshan': 'loss',
      'chhar': 'discount',
      'porishodh': 'paid',
      'porishod': 'paid',
      'payment': 'paid',
      'disi': 'paid',
      'diyechi': 'paid',
      'dichi': 'paid',
      'ferot': 'change',
      'mot': 'total',
      'khoroch': 'expense',
      'khoroc': 'expense',
      'bikri': 'sales',
      'sale': 'sales',
      'kena': 'cost',
      'buying': 'cost',
      'selling': 'sell',
      'becha': 'sell',
      'bikroy': 'sell',
      'proti': 'per',
      'kore': 'each',
      'kilo': 'kg',
      'kilogram': 'kg',
      'pc': 'pcs',
      'lokkho': 'lakh',
      'lac': 'lakh',
      'koti': 'crore',
      'hajar': 'thousand',
      'percentage': 'percent',
      'avg': 'average',
      'gor': 'average',
      'vag': 'divide',
      'vagkore': 'split',
      'jon': 'person',
      'jog': 'add',
      'bad': 'subtract',
      'biyog': 'subtract',
      'gun': 'multiply',
      'theke': 'from',
    };

    for (final MapEntry<String, String> entry in asciiReplacements.entries) {
      value = value.replaceAll(
        RegExp('\\b${RegExp.escape(entry.key)}\\b', caseSensitive: false),
        ' ${entry.value} ',
      );
    }

    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ---------------------------------------------------------------------------
  // NUMBER HELPERS
  // ---------------------------------------------------------------------------

  static List<double> _extractNumbers(String text) {
    return RegExp(r'\d+(?:\.\d+)?')
        .allMatches(text)
        .map((RegExpMatch match) => double.tryParse(match.group(0) ?? ''))
        .whereType<double>()
        .toList();
  }

  static double? _findNumberNearKeywords(String text, List<String> keywords) {
    for (final String keyword in keywords) {
      final String escaped = RegExp.escape(keyword);

      final RegExp afterKeywordRegex = RegExp(
        '$escaped'
        r'(?:\s+(?:amount|price|bill))?'
        r'\s*[:=]?\s*'
        r'(\d+(?:\.\d+)?)',
        caseSensitive: false,
      );

      final RegExpMatch? afterMatch = afterKeywordRegex.firstMatch(text);

      if (afterMatch != null) {
        final double? number = double.tryParse(afterMatch.group(1) ?? '');

        if (number != null) {
          return number;
        }
      }

      final RegExp beforeKeywordRegex = RegExp(
        r'(\d+(?:\.\d+)?)'
        r'\s*(?:tk)?\s*'
        '$escaped',
        caseSensitive: false,
      );

      final RegExpMatch? beforeMatch = beforeKeywordRegex.firstMatch(text);

      if (beforeMatch != null) {
        final double? number = double.tryParse(beforeMatch.group(1) ?? '');

        if (number != null) {
          return number;
        }
      }
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // DISPLAY
  // ---------------------------------------------------------------------------

  static String _money(double value, _ReplyStyle style) {
    final String number = _formatNumber(value);

    switch (style) {
      case _ReplyStyle.bangla:
        return '$number টাকা';
      case _ReplyStyle.banglish:
        return '$number taka';
      case _ReplyStyle.english:
        return 'Tk $number';
    }
  }

  static String _prettyUnit(String rawUnit, _ReplyStyle style) {
    final String unit = rawUnit.toLowerCase();

    final bool isKg = unit == 'kg';
    final bool isPiece = unit == 'pcs' || unit == 'piece' || unit == 'pieces';
    final bool isCard = unit == 'card' || unit == 'cards';

    switch (style) {
      case _ReplyStyle.bangla:
        if (isKg) return 'কেজি';
        if (isPiece) return 'পিস';
        if (isCard) return 'কার্ড';
        return 'ইউনিট';

      case _ReplyStyle.banglish:
        if (isKg) return 'kg';
        if (isPiece) return 'piece';
        if (isCard) return 'card';
        return 'unit';

      case _ReplyStyle.english:
        if (isKg) return 'kg';
        if (isPiece) return 'piece';
        if (isCard) return 'card';
        return 'unit';
    }
  }

  static String _formatNumber(double value) {
    if (!value.isFinite) {
      return value.toString();
    }

    String raw;

    if (value == value.roundToDouble()) {
      raw = value.toInt().toString();
    } else {
      raw = value.toStringAsFixed(6);

      while (raw.contains('.') && raw.endsWith('0')) {
        raw = raw.substring(0, raw.length - 1);
      }

      if (raw.endsWith('.')) {
        raw = raw.substring(0, raw.length - 1);
      }
    }

    final bool negative = raw.startsWith('-');
    final String unsigned = negative ? raw.substring(1) : raw;
    final List<String> parts = unsigned.split('.');

    final String integerPart = parts[0];
    final String decimalPart = parts.length > 1 ? '.${parts[1]}' : '';

    final StringBuffer grouped = StringBuffer();

    for (int index = 0; index < integerPart.length; index++) {
      final int digitsRemaining = integerPart.length - index;

      grouped.write(integerPart[index]);

      if (digitsRemaining > 1 && digitsRemaining % 3 == 1) {
        grouped.write(',');
      }
    }

    return '${negative ? '-' : ''}${grouped.toString()}$decimalPart';
  }
}

// =============================================================================
// SAFE ARITHMETIC PARSER
// Supports + - * / and parentheses.
// =============================================================================

class _ExpressionParser {
  _ExpressionParser(this.source);

  final String source;
  int _index = 0;

  double parse() {
    final double value = _parseExpression();

    _skipSpaces();

    if (_index != source.length) {
      throw const FormatException('Invalid expression');
    }

    return value;
  }

  double _parseExpression() {
    double value = _parseTerm();

    while (true) {
      _skipSpaces();

      if (_match('+')) {
        value += _parseTerm();
      } else if (_match('-')) {
        value -= _parseTerm();
      } else {
        break;
      }
    }

    return value;
  }

  double _parseTerm() {
    double value = _parseFactor();

    while (true) {
      _skipSpaces();

      if (_match('*')) {
        value *= _parseFactor();
      } else if (_match('/')) {
        final double divisor = _parseFactor();

        if (divisor == 0) {
          throw const FormatException('Division by zero');
        }

        value /= divisor;
      } else {
        break;
      }
    }

    return value;
  }

  double _parseFactor() {
    _skipSpaces();

    if (_match('+')) {
      return _parseFactor();
    }

    if (_match('-')) {
      return -_parseFactor();
    }

    if (_match('(')) {
      final double value = _parseExpression();

      if (!_match(')')) {
        throw const FormatException('Missing closing parenthesis');
      }

      return value;
    }

    return _parseNumber();
  }

  double _parseNumber() {
    _skipSpaces();

    final int start = _index;
    bool hasDecimalPoint = false;

    while (_index < source.length) {
      final String character = source[_index];

      if (_isDigit(character)) {
        _index++;
        continue;
      }

      if (character == '.' && !hasDecimalPoint) {
        hasDecimalPoint = true;
        _index++;
        continue;
      }

      break;
    }

    if (start == _index) {
      throw const FormatException('Number expected');
    }

    final String numberText = source.substring(start, _index);
    final double? value = double.tryParse(numberText);

    if (value == null) {
      throw const FormatException('Invalid number');
    }

    return value;
  }

  bool _match(String expected) {
    _skipSpaces();

    if (_index >= source.length) {
      return false;
    }

    if (source[_index] != expected) {
      return false;
    }

    _index++;
    return true;
  }

  void _skipSpaces() {
    while (_index < source.length && source[_index].trim().isEmpty) {
      _index++;
    }
  }

  bool _isDigit(String value) {
    if (value.length != 1) {
      return false;
    }

    final int code = value.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }
}
