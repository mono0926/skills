import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  print('--- Bambu Lab Purchase Tracker (Final Match) ---');

  final queries = [
    'from:bambulab.com "JP" after:2024/01/01',
    '"Bambu Japan"', // Broadened from PayPal specific
    'from:amazon.co.jp "Bambu Lab" "フィラメント"',
  ];

  final allMessages = <String, Map<String, dynamic>>{};

  for (final q in queries) {
    final result = await runGws([
      'gmail',
      'users',
      'messages',
      'list',
      '--params',
      jsonEncode({'userId': 'me', 'q': q}),
    ]);
    if (result != null && result['messages'] != null) {
      for (final msg in result['messages']) {
        allMessages[msg['id']] = msg;
      }
    }
  }

  print('Found ${allMessages.length} potential messages. Analyzing...\n');

  final payments = <String, Map<String, dynamic>>{};
  final amazonOrders = <String, Map<String, dynamic>>{};

  for (final msgId in allMessages.keys) {
    final msg = await runGws([
      'gmail',
      'users',
      'messages',
      'get',
      '--params',
      jsonEncode({'userId': 'me', 'id': msgId, 'format': 'full'}),
    ]);
    if (msg == null) continue;

    final snippet = msg['snippet'] as String? ?? '';
    final headers = (msg['payload']?['headers'] as List?) ?? [];

    String? subject;
    String? date;
    for (final header in headers) {
      if (header['name'] == 'Subject') subject = header['value'];
      if (header['name'] == 'Date') date = header['value'];
    }

    final body = getBody(msg['payload']);
    final content = '$snippet $body'.replaceAll(
      '\u200b',
      '',
    ); // Remove zero-width spaces

    // 1. Payment Detection (PayPal/PayPay/Store)
    if (content.contains('Bambu Japan')) {
      // Look for amount: ¥19800, ¥19,800, \19800 etc.
      final amountMatches = RegExp(
        r'[¥\\](\d{1,3}(,\d{3})*|\d+)\s*JPY?',
      ).allMatches(content);
      for (final match in amountMatches) {
        final amountStr = match.group(1)!.replaceAll(',', '');
        final amount = int.parse(amountStr);
        if (amount < 1000) continue; // Skip small irrelevant numbers

        final key = '${date}_$amount';
        if (!payments.containsKey(key)) {
          payments[key] = {
            'date': date,
            'amount': amount,
            'type': amount > 50000 ? 'Machine/Big' : 'Filament/Parts',
          };
        }
      }
    }

    // 2. Amazon Detection
    if (subject?.contains('Amazon') == true || content.contains('Amazon')) {
      if (content.contains('Bambu Lab') && content.contains('フィラメント')) {
        amazonOrders[msgId] = {
          'date': date,
          'items': 'Bambu Filament (via Amazon)',
        };
      }
    }
  }

  print('\n### Bambu Lab Purchase Summary\n');
  print('| Date | Source | Type | Amount |');
  print('|---|---|---|---|');

  int filamentTotal = 0;
  int machineTotal = 0;

  final sortedPayments = payments.values.toList()
    ..sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));

  for (final p in sortedPayments) {
    final amount = p['amount'] as int;
    if (p['type'] == 'Machine/Big') {
      machineTotal += amount;
    } else {
      filamentTotal += amount;
    }
    print('| ${p['date']} | Store/PayPal | ${p['type']} | ¥$amount |');
  }

  for (final p in amazonOrders.values) {
    print('| ${p['date']} | Amazon | Filament | (Check App) |');
  }

  print('\n**Total Spent (Filament/Parts): ¥$filamentTotal**');
  if (machineTotal > 0) {
    print('**Total Spent (Machines/Big Orders): ¥$machineTotal**');
  }
}

String getBody(Map<String, dynamic>? payload) {
  if (payload == null) return '';
  final body = payload['body']?['data'] as String?;
  if (body != null && body.isNotEmpty) {
    try {
      return utf8.decode(base64Url.decode(body));
    } catch (_) {}
  }
  final parts = payload['parts'] as List?;
  if (parts != null) {
    for (final part in parts) {
      final partBody = getBody(part);
      if (partBody.isNotEmpty) return partBody;
    }
  }
  return '';
}

Future<Map<String, dynamic>?> runGws(List<String> args) async {
  final result = await Process.run('gws', args);
  if (result.exitCode != 0) return null;
  try {
    final out = result.stdout as String;
    final jsonStart = out.indexOf('{');
    if (jsonStart == -1) return null;
    return jsonDecode(out.substring(jsonStart));
  } catch (_) {
    return null;
  }
}
