import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hisabflow_ai_service.dart';

class HisabFlowAiPage extends StatefulWidget {
  const HisabFlowAiPage({super.key});

  @override
  State<HisabFlowAiPage> createState() => _HisabFlowAiPageState();
}

class _HisabFlowAiPageState extends State<HisabFlowAiPage> {
  static const String _historyPrefsKey = 'hisabflow_assistant_chats_v2';
  static const int _maxSavedChats = 30;

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  final List<_AiMessage> _messages = <_AiMessage>[];
  final List<_SavedChat> _savedChats = <_SavedChat>[];

  String _currentChatId = '';
  bool _sending = false;
  bool _loadingHistory = true;

  static const List<String> _quickPrompts = <String>[
    '25 kg er dam 1570 taka hole 1 kg koto?',
    'মোট ৮০০০ টাকা, ৩৫০০ টাকা পরিশোধ করেছি, বাকি কত?',
    '5000 takar 20% koto?',
    'Sales 12500, expense 3200, profit koto?',
    'Profit ar revenue er moddhe difference ki?',
  ];

  @override
  void initState() {
    super.initState();
    _createFreshConversationInMemory();
    _loadSavedChats();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  _AiMessage _greetingMessage({bool fresh = false}) {
    return _AiMessage(
      text: fresh
          ? 'নতুন conversation শুরু হয়েছে ✨\n\n'
                'বাংলা, English বা Banglish—যেভাবে চান প্রশ্ন করুন।'
          : 'Assalamu Alaikum 👋\n\n'
                'আমি HisabFlow Assistant। বাংলা, English বা Banglish—যেভাবে সহজ লাগে সেভাবেই লিখুন। '
                'হিসাব, ব্যবসা, দাম, লাভ-ক্ষতি, বাকি, শতাংশ বা সাধারণ প্রশ্ন করতে পারেন।',
      fromUser: false,
      isExactCalculation: false,
      success: true,
      isGreeting: true,
    );
  }

  void _createFreshConversationInMemory({bool showFreshGreeting = false}) {
    _currentChatId = DateTime.now().microsecondsSinceEpoch.toString();
    _messages
      ..clear()
      ..add(_greetingMessage(fresh: showFreshGreeting));
    HisabFlowAiService.instance.resetConversation();
  }

  Future<void> _loadSavedChats() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String raw = prefs.getString(_historyPrefsKey) ?? '';

      if (raw.isNotEmpty) {
        final dynamic decoded = jsonDecode(raw);

        if (decoded is List) {
          final List<_SavedChat> loaded = decoded
              .whereType<Map>()
              .map(
                (Map item) =>
                    _SavedChat.fromJson(Map<String, dynamic>.from(item)),
              )
              .where((_SavedChat chat) => chat.messages.isNotEmpty)
              .toList();

          loaded.sort(
            (_SavedChat a, _SavedChat b) => b.updatedAt.compareTo(a.updatedAt),
          );

          _savedChats
            ..clear()
            ..addAll(loaded.take(_maxSavedChats));

          if (_savedChats.isNotEmpty) {
            final _SavedChat latest = _savedChats.first;
            _currentChatId = latest.id;
            _messages
              ..clear()
              ..addAll(latest.messages.map((_AiMessage m) => m.copy()));

            if (_messages.isEmpty || !_messages.first.isGreeting) {
              _messages.insert(0, _greetingMessage());
            }

            _syncServiceHistory();
          }
        }
      }
    } catch (_) {
      // A damaged local history must never prevent the assistant from opening.
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
      } else {
        _loadingHistory = false;
      }
    }
  }

  List<HisabFlowAiHistoryMessage> _serviceHistoryFromMessages() {
    final List<HisabFlowAiHistoryMessage> result =
        <HisabFlowAiHistoryMessage>[];

    for (int i = 0; i < _messages.length - 1; i++) {
      final _AiMessage current = _messages[i];
      final _AiMessage next = _messages[i + 1];

      if (current.fromUser &&
          !next.fromUser &&
          !next.isGreeting &&
          next.success &&
          next.text.trim().isNotEmpty) {
        result
          ..add(HisabFlowAiHistoryMessage(text: current.text, fromUser: true))
          ..add(HisabFlowAiHistoryMessage(text: next.text, fromUser: false));
        i++;
      }
    }

    return result;
  }

  void _syncServiceHistory() {
    HisabFlowAiService.instance.setConversationHistory(
      _serviceHistoryFromMessages(),
    );
  }

  bool get _hasRealConversation =>
      _messages.any((_AiMessage message) => message.fromUser);

  String _makeChatTitle() {
    _AiMessage? firstUser;
    for (final _AiMessage message in _messages) {
      if (message.fromUser) {
        firstUser = message;
        break;
      }
    }

    if (firstUser == null) {
      return 'New chat';
    }

    final String cleaned = firstUser.text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (cleaned.length <= 42) {
      return cleaned;
    }

    return '${cleaned.substring(0, 42)}…';
  }

  Future<void> _saveCurrentChat() async {
    if (!_hasRealConversation) {
      return;
    }

    final DateTime now = DateTime.now();
    final int existingIndex = _savedChats.indexWhere(
      (_SavedChat chat) => chat.id == _currentChatId,
    );

    final _SavedChat chat = _SavedChat(
      id: _currentChatId,
      title: existingIndex >= 0
          ? _savedChats[existingIndex].title
          : _makeChatTitle(),
      createdAt: existingIndex >= 0
          ? _savedChats[existingIndex].createdAt
          : now,
      updatedAt: now,
      messages: _messages
          .where((_AiMessage message) => !message.isStreaming)
          .map((_AiMessage message) => message.copy())
          .toList(),
    );

    if (existingIndex >= 0) {
      _savedChats[existingIndex] = chat;
    } else {
      _savedChats.add(chat);
    }

    _savedChats.sort(
      (_SavedChat a, _SavedChat b) => b.updatedAt.compareTo(a.updatedAt),
    );

    if (_savedChats.length > _maxSavedChats) {
      _savedChats.removeRange(_maxSavedChats, _savedChats.length);
    }

    await _persistSavedChats();
  }

  Future<void> _persistSavedChats() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(
      _savedChats.map((_SavedChat chat) => chat.toJson()).toList(),
    );
    await prefs.setString(_historyPrefsKey, encoded);
  }

  Future<void> _send({String? quickText}) async {
    if (_sending || _loadingHistory) {
      return;
    }

    final String text = (quickText ?? _controller.text).trim();
    if (text.isEmpty) {
      return;
    }

    HapticFeedback.selectionClick();
    _controller.clear();
    _focusNode.requestFocus();

    final _AiMessage assistantMessage = _AiMessage(
      text: '',
      fromUser: false,
      isExactCalculation: false,
      success: true,
      isStreaming: true,
    );

    setState(() {
      _messages
        ..add(
          _AiMessage(
            text: text,
            fromUser: true,
            isExactCalculation: false,
            success: true,
          ),
        )
        ..add(assistantMessage);
      _sending = true;
    });

    _jumpToBottomSoon();

    final StringBuffer streamedText = StringBuffer();
    DateTime lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
    DateTime lastScroll = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      await for (final HisabFlowAiStreamChunk chunk
          in HisabFlowAiService.instance.streamAnswer(text)) {
        if (!mounted) {
          return;
        }

        if (chunk.text.isNotEmpty) {
          streamedText.write(chunk.text);
        }

        assistantMessage
          ..text = streamedText.toString()
          ..isExactCalculation = chunk.isLocalCalculation
          ..success = chunk.success;

        final DateTime now = DateTime.now();
        final bool shouldPaint =
            chunk.done || now.difference(lastPaint).inMilliseconds >= 45;

        if (shouldPaint) {
          lastPaint = now;
          setState(() {});

          if (now.difference(lastScroll).inMilliseconds >= 120 || chunk.done) {
            lastScroll = now;
            _jumpToBottomSoon();
          }
        }

        if (chunk.done) {
          assistantMessage.isStreaming = false;
        }
      }

      if (assistantMessage.text.trim().isEmpty) {
        assistantMessage
          ..text = 'কোনো উত্তর পাওয়া যায়নি। আবার চেষ্টা করুন।'
          ..success = false
          ..isStreaming = false;
      }
    } catch (_) {
      assistantMessage
        ..text =
            'HisabFlow Assistant এখন উত্তর দিতে পারছে না। Internet connection দেখে আবার চেষ্টা করুন।'
        ..success = false
        ..isStreaming = false;
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          assistantMessage.isStreaming = false;
        });
        _jumpToBottomSoon();
      } else {
        _sending = false;
        assistantMessage.isStreaming = false;
      }

      await _saveCurrentChat();
    }
  }

  Future<void> _newConversation() async {
    if (_sending) {
      return;
    }

    HapticFeedback.lightImpact();
    await _saveCurrentChat();

    if (!mounted) {
      return;
    }

    setState(() {
      _createFreshConversationInMemory(showFreshGreeting: true);
      _controller.clear();
    });

    _focusNode.requestFocus();
    _jumpToBottomSoon();
  }

  Future<void> _openSavedChat(_SavedChat chat) async {
    if (_sending) {
      return;
    }

    await _saveCurrentChat();

    if (!mounted) {
      return;
    }

    setState(() {
      _currentChatId = chat.id;
      _messages
        ..clear()
        ..addAll(chat.messages.map((_AiMessage message) => message.copy()));

      if (_messages.isEmpty || !_messages.first.isGreeting) {
        _messages.insert(0, _greetingMessage());
      }
    });

    _syncServiceHistory();
    _jumpToBottomSoon();
  }

  Future<void> _deleteChat(String chatId) async {
    _savedChats.removeWhere((_SavedChat chat) => chat.id == chatId);

    if (chatId == _currentChatId) {
      if (mounted) {
        setState(() {
          _createFreshConversationInMemory(showFreshGreeting: true);
        });
      } else {
        _createFreshConversationInMemory(showFreshGreeting: true);
      }
    }

    await _persistSavedChats();
  }

  Future<void> _renameChat(_SavedChat chat) async {
    final TextEditingController renameController = TextEditingController(
      text: chat.title,
    );

    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Rename chat'),
          content: TextField(
            controller: renameController,
            autofocus: true,
            maxLength: 50,
            decoration: const InputDecoration(hintText: 'Chat name'),
            onSubmitted: (String value) {
              Navigator.pop(dialogContext, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, renameController.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    renameController.dispose();

    if (newName == null || newName.isEmpty) {
      return;
    }

    final int index = _savedChats.indexWhere(
      (_SavedChat item) => item.id == chat.id,
    );

    if (index < 0) {
      return;
    }

    _savedChats[index] = _savedChats[index].copyWith(
      title: newName,
      updatedAt: DateTime.now(),
    );

    await _persistSavedChats();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _clearAllChats() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Clear chat history?'),
          content: const Text(
            'Saved HisabFlow Assistant conversations on this phone will be removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Clear all'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    _savedChats.clear();
    await _persistSavedChats();

    if (!mounted) {
      return;
    }

    setState(() {
      _createFreshConversationInMemory(showFreshGreeting: true);
    });
  }

  Future<void> _showChatHistory() async {
    await _saveCurrentChat();

    if (!mounted) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setSheetState) {
            final bool dark = Theme.of(context).brightness == Brightness.dark;

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.78,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 10, 10),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Chat History',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (_savedChats.isNotEmpty)
                            TextButton(
                              onPressed: () async {
                                Navigator.pop(sheetContext);
                                await _clearAllChats();
                              },
                              child: const Text('Clear all'),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _savedChats.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'No saved chats yet.\nYour conversations will appear here automatically.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                12,
                                24,
                              ),
                              itemCount: _savedChats.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (BuildContext context, int index) {
                                final _SavedChat chat = _savedChats[index];
                                final bool selected = chat.id == _currentChatId;

                                return Material(
                                  color: selected
                                      ? const Color(
                                          0xFF2563EB,
                                        ).withValues(alpha: 0.12)
                                      : (dark
                                            ? const Color(0xFF17181B)
                                            : const Color(0xFFF2F5F9)),
                                  borderRadius: BorderRadius.circular(16),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(16),
                                    onTap: () async {
                                      Navigator.pop(sheetContext);
                                      await _openSavedChat(chat);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        10,
                                        4,
                                        10,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            height: 38,
                                            width: 38,
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFF2563EB,
                                              ).withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: const Icon(
                                              Icons.chat_bubble_outline_rounded,
                                              color: Color(0xFF3B82F6),
                                              size: 19,
                                            ),
                                          ),
                                          const SizedBox(width: 11),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  chat.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                const SizedBox(height: 3),
                                                Text(
                                                  _formatChatTime(
                                                    chat.updatedAt,
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.color,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            onSelected: (String action) async {
                                              if (action == 'rename') {
                                                await _renameChat(chat);
                                                setSheetState(() {});
                                              } else if (action == 'delete') {
                                                await _deleteChat(chat.id);
                                                setSheetState(() {});
                                              }
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(
                                                value: 'rename',
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons.edit_rounded,
                                                      size: 18,
                                                    ),
                                                    SizedBox(width: 9),
                                                    Text('Rename'),
                                                  ],
                                                ),
                                              ),
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons
                                                          .delete_outline_rounded,
                                                      size: 18,
                                                    ),
                                                    SizedBox(width: 9),
                                                    Text('Delete'),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
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

  String _formatChatTime(DateTime time) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime day = DateTime(time.year, time.month, time.day);
    final int difference = today.difference(day).inDays;

    if (difference == 0) {
      final int hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
      final String minute = time.minute.toString().padLeft(2, '0');
      final String period = time.hour >= 12 ? 'PM' : 'AM';
      return 'Today • $hour:$minute $period';
    }

    if (difference == 1) {
      return 'Yesterday';
    }

    return '${time.day}/${time.month}/${time.year}';
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied'),
        duration: Duration(milliseconds: 900),
      ),
    );
  }

  void _jumpToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  bool get _showQuickPrompts =>
      !_messages.any((_AiMessage message) => message.fromUser);

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final MediaQueryData media = MediaQuery.of(context);
    final double screenWidth = media.size.width;
    final double textScale = media.textScaler.scale(1);
    final bool compact = screenWidth < 370 || textScale > 1.15;

    final Color background = dark
        ? const Color(0xFF050506)
        : const Color(0xFFF4F7FB);
    final Color surface = dark ? const Color(0xFF111214) : Colors.white;
    final Color surface2 = dark
        ? const Color(0xFF1B1C20)
        : const Color(0xFFEAF1FA);
    final Color primaryText = dark ? Colors.white : const Color(0xFF071323);
    final Color secondaryText = dark ? Colors.white70 : const Color(0xFF5C6470);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: background,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: background,
        foregroundColor: primaryText,
        titleSpacing: 4,
        title: Row(
          children: [
            Container(
              height: 38,
              width: 38,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF8B5CF6), Color(0xFF22D3EE)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                color: Colors.white,
                size: 21,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'HisabFlow Assistant',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: primaryText,
                      fontSize: compact ? 17 : 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    'Fast local math • Live AI answers',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: secondaryText,
                      fontSize: compact ? 9.5 : 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Chat history',
            onPressed: _sending ? null : _showChatHistory,
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            tooltip: 'New chat',
            onPressed: _sending ? null : _newConversation,
            icon: const Icon(Icons.add_comment_rounded),
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double contentWidth = constraints.maxWidth > 760
                ? 720
                : constraints.maxWidth;

            return Center(
              child: SizedBox(
                width: contentWidth,
                height: constraints.maxHeight,
                child: Column(
                  children: [
                    _statusBanner(
                      surface: surface,
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                      compact: compact,
                    ),
                    if (_showQuickPrompts)
                      _quickPromptArea(
                        surface: surface,
                        surface2: surface2,
                        primaryText: primaryText,
                        secondaryText: secondaryText,
                        compact: compact,
                      ),
                    Expanded(
                      child: _messageList(
                        dark: dark,
                        surface: surface,
                        primaryText: primaryText,
                        secondaryText: secondaryText,
                        compact: compact,
                      ),
                    ),
                    if (_sending &&
                        _messages.isNotEmpty &&
                        _messages.last.text.isEmpty)
                      _typingRow(
                        surface: surface,
                        secondaryText: secondaryText,
                      ),
                    _composer(
                      dark: dark,
                      surface: surface,
                      surface2: surface2,
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                      compact: compact,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _statusBanner({
    required Color surface,
    required Color primaryText,
    required Color secondaryText,
    required bool compact,
  }) {
    return Container(
      margin: EdgeInsets.fromLTRB(compact ? 10 : 14, 8, compact ? 10 : 14, 8),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 11 : 14,
        vertical: compact ? 9 : 11,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFF0EA5E9).withValues(alpha: 0.16),
        ),
      ),
      child: Row(
        children: [
          Container(
            height: 34,
            width: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: Color(0xFF30C96B),
              size: 19,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _loadingHistory
                  ? 'Chat history loading...'
                  : 'Local হিসাব instant • AI answer আসতে আসতেই screen-এ দেখাবে।',
              style: TextStyle(
                color: primaryText,
                fontSize: compact ? 10.5 : 12,
                height: 1.3,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.shield_rounded, color: secondaryText, size: 18),
        ],
      ),
    );
  }

  Widget _quickPromptArea({
    required Color surface,
    required Color surface2,
    required Color primaryText,
    required Color secondaryText,
    required bool compact,
  }) {
    return Container(
      margin: EdgeInsets.fromLTRB(compact ? 10 : 14, 2, compact ? 10 : 14, 6),
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.bolt_rounded,
                color: Color(0xFFFFA31A),
                size: 19,
              ),
              const SizedBox(width: 6),
              Text(
                'Quick questions',
                style: TextStyle(
                  color: primaryText,
                  fontSize: compact ? 13 : 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                'Tap to ask',
                style: TextStyle(
                  color: secondaryText,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: compact ? 38 : 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: _quickPrompts.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int index) {
                final String prompt = _quickPrompts[index];

                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _sending || _loadingHistory
                      ? null
                      : () => _send(quickText: prompt),
                  child: Container(
                    constraints: BoxConstraints(maxWidth: compact ? 210 : 250),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: surface2,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      prompt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: primaryText,
                        fontSize: compact ? 10.5 : 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageList({
    required bool dark,
    required Color surface,
    required Color primaryText,
    required Color secondaryText,
    required bool compact,
  }) {
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(compact ? 10 : 14, 8, compact ? 10 : 14, 14),
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _messages.length,
      itemBuilder: (BuildContext context, int index) {
        final _AiMessage message = _messages[index];

        if (message.isStreaming && message.text.isEmpty) {
          return const SizedBox.shrink();
        }

        return _messageBubble(
          message,
          dark: dark,
          surface: surface,
          primaryText: primaryText,
          secondaryText: secondaryText,
          compact: compact,
        );
      },
    );
  }

  Widget _messageBubble(
    _AiMessage message, {
    required bool dark,
    required Color surface,
    required Color primaryText,
    required Color secondaryText,
    required bool compact,
  }) {
    final bool user = message.fromUser;

    final Color bubbleColor = user
        ? const Color(0xFF2563EB)
        : message.success
        ? surface
        : dark
        ? const Color(0xFF21191A)
        : const Color(0xFFFFF4F4);

    final Color textColor = user ? Colors.white : primaryText;

    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: compact ? MediaQuery.of(context).size.width * 0.88 : 620,
        ),
        margin: const EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 14,
          compact ? 10 : 12,
          compact ? 10 : 12,
          compact ? 8 : 10,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(user ? 20 : 6),
            bottomRight: Radius.circular(user ? 6 : 20),
          ),
          border: user
              ? null
              : Border.all(
                  color: message.isExactCalculation
                      ? const Color(0xFF16A34A).withValues(alpha: 0.28)
                      : (dark ? Colors.white10 : Colors.black12),
                ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!user)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      message.isExactCalculation
                          ? Icons.calculate_rounded
                          : Icons.auto_awesome_rounded,
                      color: message.isExactCalculation
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF0EA5E9),
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      message.isExactCalculation
                          ? 'Exact calculation'
                          : 'HisabFlow',
                      style: TextStyle(
                        color: message.isExactCalculation
                            ? const Color(0xFF16A34A)
                            : secondaryText,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (message.isStreaming) ...[
                      const SizedBox(width: 7),
                      const SizedBox(
                        height: 10,
                        width: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.7,
                          color: Color(0xFF22D3EE),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            SelectableText(
              message.text,
              style: TextStyle(
                color: textColor,
                fontSize: compact ? 13 : 14.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (!user && !message.isStreaming)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _copy(message.text),
                  icon: Icon(
                    Icons.copy_rounded,
                    size: 16,
                    color: secondaryText,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _typingRow({required Color surface, required Color secondaryText}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
      child: Row(
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const SizedBox(
                  height: 14,
                  width: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF22D3EE),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  'Thinking...',
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 11,
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

  Widget _composer({
    required bool dark,
    required Color surface,
    required Color surface2,
    required Color primaryText,
    required Color secondaryText,
    required bool compact,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 10 : 14, 8, compact ? 10 : 14, 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF09090A) : const Color(0xFFF7F9FC),
        border: Border(
          top: BorderSide(color: dark ? Colors.white10 : Colors.black12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48, maxHeight: 132),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _focusNode.hasFocus
                      ? const Color(0xFF3B82F6)
                      : (dark ? Colors.white12 : Colors.black12),
                ),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: !_loadingHistory,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 1,
                maxLines: 5,
                onTap: () {
                  if (mounted) {
                    setState(() {});
                  }
                },
                style: TextStyle(
                  color: primaryText,
                  fontSize: compact ? 13 : 14,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  hintText: 'বাংলা / English / Banglish এ প্রশ্ন করুন...',
                  hintStyle: TextStyle(
                    color: secondaryText,
                    fontWeight: FontWeight.w600,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 13,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 48,
            width: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: _sending || _loadingHistory
                    ? surface2
                    : const Color(0xFF2563EB),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _sending || _loadingHistory ? null : () => _send(),
              child: _sending
                  ? const SizedBox(
                      height: 17,
                      width: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiMessage {
  String text;
  final bool fromUser;
  bool isExactCalculation;
  bool success;
  final bool isGreeting;
  bool isStreaming;

  _AiMessage({
    required this.text,
    required this.fromUser,
    required this.isExactCalculation,
    required this.success,
    this.isGreeting = false,
    this.isStreaming = false,
  });

  _AiMessage copy() {
    return _AiMessage(
      text: text,
      fromUser: fromUser,
      isExactCalculation: isExactCalculation,
      success: success,
      isGreeting: isGreeting,
      isStreaming: false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'text': text,
      'fromUser': fromUser,
      'isExactCalculation': isExactCalculation,
      'success': success,
      'isGreeting': isGreeting,
    };
  }

  factory _AiMessage.fromJson(Map<String, dynamic> json) {
    return _AiMessage(
      text: (json['text'] ?? '').toString(),
      fromUser: json['fromUser'] == true,
      isExactCalculation: json['isExactCalculation'] == true,
      success: json['success'] != false,
      isGreeting: json['isGreeting'] == true,
    );
  }
}

class _SavedChat {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<_AiMessage> messages;

  const _SavedChat({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  _SavedChat copyWith({String? title, DateTime? updatedAt}) {
    return _SavedChat(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'messages': messages
          .map((_AiMessage message) => message.toJson())
          .toList(),
    };
  }

  factory _SavedChat.fromJson(Map<String, dynamic> json) {
    final dynamic rawMessages = json['messages'];
    final List<_AiMessage> messages = rawMessages is List
        ? rawMessages
              .whereType<Map>()
              .map(
                (Map item) =>
                    _AiMessage.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : <_AiMessage>[];

    final DateTime now = DateTime.now();

    return _SavedChat(
      id: (json['id'] ?? now.microsecondsSinceEpoch.toString()).toString(),
      title: (json['title'] ?? 'Saved chat').toString(),
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ?? now,
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ?? now,
      messages: messages,
    );
  }
}
