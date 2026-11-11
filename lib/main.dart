import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

/// Inicializa o banco e inicia o servidor HTTP da API.
Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final databasePath = Platform.environment['DATABASE_PATH'] ?? 'habits.db';
  await File(databasePath).parent.create(recursive: true);
  final database = HabitDatabase(databasePath);
  final router = createRouter(database);

  // 0.0.0.0 permite que outros dispositivos da rede local, como o celular,
  // acessem a API durante o desenvolvimento.
  final server = await shelf_io.serve(
    const Pipeline()
        .addMiddleware(errorMiddleware())
        .addMiddleware(logRequests())
        .addMiddleware(corsMiddleware())
        .addHandler(router),
    InternetAddress.anyIPv4,
    port,
  );

  print('API disponível em http://${server.address.host}:${server.port}');
  print('Banco de dados: $databasePath');
}

/// Monta e devolve as rotas públicas da API.
Router createRouter(HabitDatabase database) {
  final router = Router();

  router.get('/health', (Request request) {
    return jsonResponse({'status': 'ok', 'message': 'API de hábitos funcionando'});
  });

  router.get('/habits', (Request request) {
    final includeInactive = request.url.queryParameters['includeInactive'] == 'true';
    return jsonResponse(database.listHabits(includeInactive: includeInactive));
  });

  router.post('/habits', (Request request) async {
    final body = await readJsonBody(request);
    final name = requiredString(body, 'name');
    final description = optionalString(body, 'description') ?? '';
    final targetDays = optionalInt(body, 'targetDaysPerWeek') ?? 7;

    if (targetDays < 1 || targetDays > 7) {
      throw ApiException(400, 'targetDaysPerWeek deve estar entre 1 e 7.');
    }

    final habit = database.createHabit(
      name: name,
      description: description,
      targetDaysPerWeek: targetDays,
    );
    return jsonResponse(habit, statusCode: 201);
  });

  router.get('/habits/<id>', (Request request, String id) {
    return jsonResponse(database.getHabit(parseId(id)));
  });

  router.put('/habits/<id>', (Request request, String id) async {
    final body = await readJsonBody(request);
    final name = requiredString(body, 'name');
    final description = optionalString(body, 'description') ?? '';
    final targetDays = optionalInt(body, 'targetDaysPerWeek') ?? 7;

    if (targetDays < 1 || targetDays > 7) {
      throw ApiException(400, 'targetDaysPerWeek deve estar entre 1 e 7.');
    }

    return jsonResponse(database.updateHabit(
      id: parseId(id),
      name: name,
      description: description,
      targetDaysPerWeek: targetDays,
    ));
  });

  router.delete('/habits/<id>', (Request request, String id) {
    database.deleteHabit(parseId(id));
    return Response(204);
  });

  router.post('/habits/<id>/completions', (Request request, String id) async {
    final body = await readJsonBody(request);
    final date = optionalString(body, 'date') ?? todayAsIsoDate();
    validateDate(date);
    return jsonResponse(
      database.recordCompletion(habitId: parseId(id), date: date),
      statusCode: 201,
    );
  });

  router.get('/habits/<id>/completions', (Request request, String id) {
    final habitId = parseId(id);
    database.getHabit(habitId); // Garante que o hábito existe.
    final from = request.url.queryParameters['from'];
    final to = request.url.queryParameters['to'];
    if (from != null) validateDate(from);
    if (to != null) validateDate(to);
    if (from != null && to != null && from.compareTo(to) > 0) {
      throw ApiException(400, 'O parâmetro from não pode ser posterior a to.');
    }
    return jsonResponse(database.listCompletions(habitId, from: from, to: to));
  });

  router.delete('/habits/<id>/completions/<date>', (Request request, String id, String date) {
    validateDate(date);
    database.deleteCompletion(habitId: parseId(id), date: date);
    return Response(204);
  });

  router.get('/habits/<id>/stats', (Request request, String id) {
    final habitId = parseId(id);
    database.getHabit(habitId); // Garante que o hábito existe.
    final from = request.url.queryParameters['from'] ?? firstDayOfCurrentMonth();
    final to = request.url.queryParameters['to'] ?? todayAsIsoDate();
    validateDate(from);
    validateDate(to);
    if (from.compareTo(to) > 0) {
      throw ApiException(400, 'O parâmetro from não pode ser posterior a to.');
    }
    return jsonResponse(database.getStats(habitId, from: from, to: to));
  });

  // Retorna erros da aplicação em JSON e converte caminhos desconhecidos em 404.
  router.all('/<ignored|.*>', (Request request) {
    throw ApiException(404, 'Rota não encontrada.');
  });

  return router;
}

/// Acrescenta cabeçalhos CORS para permitir chamadas durante o desenvolvimento
/// a partir do aplicativo Flutter, inclusive em outro dispositivo da rede.
Middleware corsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      const headers = {
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'access-control-allow-headers': 'Origin, Content-Type, Accept, Authorization',
      };

      if (request.method == 'OPTIONS') {
        return Response(204, headers: headers);
      }

      final response = await innerHandler(request);
      return response.change(headers: {...response.headers, ...headers});
    };
  };
}

/// Converte exceções conhecidas em respostas HTTP JSON.
Middleware errorMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      try {
        return await innerHandler(request);
      } on ApiException catch (error) {
        return jsonResponse({'error': error.message}, statusCode: error.statusCode);
      } on FormatException {
        return jsonResponse({'error': 'JSON inválido.'}, statusCode: 400);
      } catch (error, stackTrace) {
        stderr.writeln('Erro interno: $error\n$stackTrace');
        return jsonResponse({'error': 'Erro interno do servidor.'}, statusCode: 500);
      }
    };
  };
}

/// Lê o corpo da requisição e exige que ele seja um objeto JSON.
Future<Map<String, dynamic>> readJsonBody(Request request) async {
  try {
    final decoded = jsonDecode(await request.readAsString());
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    throw ApiException(400, 'Envie um objeto JSON válido no corpo da requisição.');
  }
  throw ApiException(400, 'O corpo da requisição precisa ser um objeto JSON.');
}

Response jsonResponse(Object? data, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: jsonEncode(data),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

String requiredString(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value is! String || value.trim().isEmpty) {
    throw ApiException(400, 'O campo "$key" é obrigatório e deve ser texto.');
  }
  return value.trim();
}

String? optionalString(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is! String) throw ApiException(400, 'O campo "$key" deve ser texto.');
  return value.trim();
}

int? optionalInt(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value == null) return null;
  if (value is! int) throw ApiException(400, 'O campo "$key" deve ser um número inteiro.');
  return value;
}

int parseId(String value) {
  final id = int.tryParse(value);
  if (id == null || id < 1) throw ApiException(400, 'ID inválido.');
  return id;
}

String todayAsIsoDate() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

String firstDayOfCurrentMonth() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-01';
}

/// Valida o formato de data ISO e confirma que o dia existe no calendário.
void validateDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    throw ApiException(400, 'Data inválida. Use o formato YYYY-MM-DD.');
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;
}

/// Responsável pelo esquema e pelas operações SQLite de hábitos e realizações.
class HabitDatabase {
  HabitDatabase(String path) : _database = sqlite3.open(path) {
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS habits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        target_days_per_week INTEGER NOT NULL DEFAULT 7,
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS completions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        habit_id INTEGER NOT NULL REFERENCES habits(id) ON DELETE CASCADE,
        date TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(habit_id, date)
      )
    ''');
  }

  final Database _database;

  List<Map<String, Object?>> listHabits({bool includeInactive = false}) {
    final rows = includeInactive
        ? _database.select('SELECT * FROM habits ORDER BY id DESC')
        : _database.select('SELECT * FROM habits WHERE active = 1 ORDER BY id DESC');
    return rows.map(_habitToJson).toList();
  }

  Map<String, Object?> getHabit(int id) {
    final rows = _database.select('SELECT * FROM habits WHERE id = ?', [id]);
    if (rows.isEmpty) throw ApiException(404, 'Hábito não encontrado.');
    return _habitToJson(rows.first);
  }

  Map<String, Object?> createHabit({
    required String name,
    required String description,
    required int targetDaysPerWeek,
  }) {
    _database.execute(
      'INSERT INTO habits (name, description, target_days_per_week) VALUES (?, ?, ?)',
      [name, description, targetDaysPerWeek],
    );
    return getHabit(_database.lastInsertRowId);
  }

  Map<String, Object?> updateHabit({
    required int id,
    required String name,
    required String description,
    required int targetDaysPerWeek,
  }) {
    if (_database.select('SELECT id FROM habits WHERE id = ?', [id]).isEmpty) {
      throw ApiException(404, 'Hábito não encontrado.');
    }
    _database.execute(
      'UPDATE habits SET name = ?, description = ?, target_days_per_week = ? WHERE id = ?',
      [name, description, targetDaysPerWeek, id],
    );
    return getHabit(id);
  }

  void deleteHabit(int id) {
    _database.execute('DELETE FROM habits WHERE id = ?', [id]);
    if (_database.updatedRows == 0) throw ApiException(404, 'Hábito não encontrado.');
  }

  Map<String, Object?> recordCompletion({required int habitId, required String date}) {
    getHabit(habitId);
    try {
      _database.execute(
        'INSERT INTO completions (habit_id, date) VALUES (?, ?)',
        [habitId, date],
      );
    } on SqliteException {
      throw ApiException(409, 'Este hábito já foi registrado nessa data.');
    }
    final rows = _database.select(
      'SELECT * FROM completions WHERE habit_id = ? AND date = ?',
      [habitId, date],
    );
    return _completionToJson(rows.first);
  }

  List<Map<String, Object?>> listCompletions(int habitId, {String? from, String? to}) {
    final clauses = <String>['habit_id = ?'];
    final parameters = <Object?>[habitId];
    if (from != null) {
      clauses.add('date >= ?');
      parameters.add(from);
    }
    if (to != null) {
      clauses.add('date <= ?');
      parameters.add(to);
    }
    final rows = _database.select(
      'SELECT * FROM completions WHERE ${clauses.join(' AND ')} ORDER BY date DESC',
      parameters,
    );
    return rows.map(_completionToJson).toList();
  }

  void deleteCompletion({required int habitId, required String date}) {
    getHabit(habitId);
    _database.execute('DELETE FROM completions WHERE habit_id = ? AND date = ?', [habitId, date]);
    if (_database.updatedRows == 0) throw ApiException(404, 'Registro de realização não encontrado.');
  }

  Map<String, Object?> getStats(int habitId, {required String from, required String to}) {
    final habit = getHabit(habitId);
    final rows = _database.select(
      'SELECT COUNT(*) AS total FROM completions WHERE habit_id = ? AND date BETWEEN ? AND ?',
      [habitId, from, to],
    );
    final total = rows.first['total'] as int;
    final startDate = DateTime.parse(from);
    final endDate = DateTime.parse(to);
    final daysInPeriod = endDate.difference(startDate).inDays + 1;
    final weeksInPeriod = daysInPeriod / 7;
    final targetDays = habit['targetDaysPerWeek'] as int;
    final expected = weeksInPeriod * targetDays;
    final percentage = expected <= 0 ? 0.0 : (total / expected * 100).clamp(0, 100).toDouble();

    return {
      'habitId': habitId,
      'from': from,
      'to': to,
      'totalCompletions': total,
      'daysInPeriod': daysInPeriod,
      'averagePerWeek': double.parse((total / weeksInPeriod).toStringAsFixed(2)),
      'targetDaysPerWeek': targetDays,
      'targetCompletionPercent': double.parse(percentage.toStringAsFixed(2)),
    };
  }

  Map<String, Object?> _habitToJson(Row row) => {
        'id': row['id'],
        'name': row['name'],
        'description': row['description'],
        'targetDaysPerWeek': row['target_days_per_week'],
        'active': row['active'] == 1,
        'createdAt': row['created_at'],
      };

  Map<String, Object?> _completionToJson(Row row) => {
        'id': row['id'],
        'habitId': row['habit_id'],
        'date': row['date'],
        'createdAt': row['created_at'],
      };
}
