import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final path = join(await getDatabasesPath(), 'tongyilite.db');
    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 数据库版本升级迁移。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2：messages 表新增 inferenceStats 列（回复性能统计 JSON）。
      await db.execute(
        "ALTER TABLE messages ADD COLUMN inferenceStats TEXT",
      );
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '新对话',
        modelId TEXT DEFAULT 'qwen3.5-2b-mtp-ud-q4_k_xl',
        messageCount INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversationId TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        imagePath TEXT,
        createdAt INTEGER NOT NULL,
        isStreaming INTEGER DEFAULT 0,
        inferenceStats TEXT,
        FOREIGN KEY (conversationId) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_messages_conv_time ON messages(conversationId, createdAt)',
    );
  }

  // ----- Conversations -----

  Future<Conversation> createConversation({String title = '新对话'}) async {
    final db = await database;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('conversations', {
      'id': id,
      'title': title,
      'modelId': 'qwen3.5-2b-mtp-ud-q4_k_xl',
      'messageCount': 0,
      'createdAt': now,
      'updatedAt': now,
    });
    return Conversation(id: id, title: title);
  }

  Future<List<Conversation>> getAllConversations() async {
    final db = await database;
    final rows = await db.query(
      'conversations',
      orderBy: 'updatedAt DESC',
    );
    return rows.map((r) => Conversation(
      id: r['id'] as String,
      title: r['title'] as String,
      modelId: r['modelId'] as String? ?? 'qwen3.5-2b-mtp-ud-q4_k_xl',
      messageCount: r['messageCount'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updatedAt'] as int),
    )).toList();
  }

  Future<void> deleteConversation(String id) async {
    final db = await database;
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  /// 更新会话元信息：标题 / 消息条数 / 更新时间。
  /// 只更新传入的非空字段；updatedAt 始终刷新为当前时间。
  Future<void> updateConversation({
    required String id,
    String? title,
    int? messageCount,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (title != null) updates['title'] = title;
    if (messageCount != null) updates['messageCount'] = messageCount;
    await db.update('conversations', updates, where: 'id = ?', whereArgs: [id]);
  }

  // ----- Messages -----

  Future<List<ChatMessage>> getMessages(String conversationId, {int limit = 200}) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
      limit: limit,
    );
    return rows.map((r) {
      final statsJson = r['inferenceStats'] as String?;
      return ChatMessage(
        id: r['id'] as String,
        conversationId: r['conversationId'] as String,
        role: MessageRole.values.where((e) => e.name == r['role']).first,
        content: r['content'] as String,
        imagePath: r['imagePath'] as String?,
        timestamp: DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int),
        isStreaming: (r['isStreaming'] as int?) == 1,
        inferenceStats: statsJson != null && statsJson.isNotEmpty
            ? InferenceStats.fromMap(jsonDecode(statsJson) as Map<String, dynamic>)
            : null,
      );
    }).toList();
  }

  Future<void> saveMessage(ChatMessage msg) async {
    final db = await database;
    // Remove streaming flag on the last message
    await db.update(
      'messages',
      {'isStreaming': 0},
      where: 'conversationId = ? AND isStreaming = 1',
      whereArgs: [msg.conversationId],
    );
    await db.insert('messages', {
      'id': msg.id,
      'conversationId': msg.conversationId,
      'role': msg.role.name,
      'content': msg.content,
      'imagePath': msg.imagePath,
      'createdAt': msg.timestamp.millisecondsSinceEpoch,
      'isStreaming': msg.isStreaming ? 1 : 0,
      'inferenceStats': msg.inferenceStats != null
          ? jsonEncode(msg.inferenceStats!.toMap())
          : null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ChatMessage>> getAllMessages(String conversationId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
    );
    return rows.map((r) {
      final statsJson = r['inferenceStats'] as String?;
      return ChatMessage(
        id: r['id'] as String,
        conversationId: r['conversationId'] as String,
        role: MessageRole.values.where((e) => e.name == r['role']).first,
        content: r['content'] as String,
        imagePath: r['imagePath'] as String?,
        timestamp: DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int),
        isStreaming: (r['isStreaming'] as int?) == 1,
        inferenceStats: statsJson != null && statsJson.isNotEmpty
            ? InferenceStats.fromMap(jsonDecode(statsJson) as Map<String, dynamic>)
            : null,
      );
    }).toList();
  }

  Future<void> clearConversation(String conversationId) async {
    final db = await database;
    await db.delete('messages', where: 'conversationId = ?', whereArgs: [conversationId]);
  }

  // ----- Storage stats -----

  Future<Map<String, int>> getStorageStats() async {
    final db = await database;
    final result = await db.rawQuery('SELECT SUM(LENGTH(content)) as total FROM messages');
    final historyBytes = (result.first['total'] as int?) ?? 0;

    return {
      'conversations': (await db.query('conversations')).length,
      'messages': (await db.query('messages')).length,
      'historyBytes': historyBytes,
    };
  }
}
