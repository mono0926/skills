import 'dart:convert';
import 'dart:io';

class FilamentItem {
  final String date;
  final String orderId;
  final String type;
  final String color;
  final int quantity;
  final String source;

  FilamentItem({
    required this.date,
    required this.orderId,
    required this.type,
    required this.color,
    required this.quantity,
    required this.source,
  });

  @override
  String toString() => '$type ($color) x $quantity';
}

Future<void> main() async {
  print('--- Bambu Lab Filament Tracker (v2.0) ---');

  final queries = [
    'from:bambulab.com "ご注文確認"',
    'from:bambulab.com "出荷状況更新"',
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

  print('Found ${allMessages.length} potential messages. Analyzing details...\n');

  final items = <FilamentItem>[];
  final processedOrderIds = <String>{};

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

    final headers = (msg['payload']?['headers'] as List?) ?? [];
    String? date;
    for (final header in headers) {
      if (header['name'] == 'Date') date = header['value'];
    }

    final body = getBody(msg['payload']);
    final content = body.replaceAll('\u200b', '');

    // Extract Order ID
    final orderIdMatch = RegExp(r'JP\d+').firstMatch(content);
    final orderId = orderIdMatch?.group(0) ?? 'Unknown';

    if (processedOrderIds.contains(orderId) && orderId != 'Unknown') continue;
    processedOrderIds.add(orderId);

    // Parse Bambu Store Items
    if (content.contains('Bambu Lab ストア')) {
      // Look for Item Name × Quantity
      final itemMatches = RegExp(r'([^\n]+) × (\d+)').allMatches(content);
      for (final match in itemMatches) {
        final itemName = match.group(1)!.trim();
        if (itemName.contains('小計') || itemName.contains('合計')) continue;
        
        final quantity = int.parse(match.group(2)!);
        
        // Next lines often contain color info
        final matchEnd = match.end;
        final nextContent = content.substring(matchEnd, (matchEnd + 100).clamp(0, content.length));
        final colorMatch = RegExp(r'([^\n/]+)\s*(\(\d+\))? /').firstMatch(nextContent);
        final color = colorMatch?.group(1)?.trim() ?? 'N/A';

        if (isFilament(itemName)) {
          items.add(FilamentItem(
            date: date ?? 'N/A',
            orderId: orderId,
            type: itemName,
            color: color,
            quantity: quantity,
            source: 'Store',
          ));
        }
      }
    } 
    // Parse Amazon Items
    else if (content.contains('Amazon')) {
      final itemMatches = RegExp(r'\*\s+([^\n]+)\n\s+数量: (\d+)').allMatches(content);
      for (final match in itemMatches) {
        final itemName = match.group(1)!.trim();
        final quantity = int.parse(match.group(2)!);
        
        if (itemName.contains('Bambu') || itemName.contains('フィラメント')) {
          items.add(FilamentItem(
            date: date ?? 'N/A',
            orderId: orderId,
            type: 'Amazon Item',
            color: itemName,
            quantity: quantity,
            source: 'Amazon',
          ));
        }
      }
    }
  }

  print('\n### Detailed Purchase History\n');
  print('| Date | Order ID | Filament Type | Color | Qty | Source |');
  print('|---|---|---|---|---|---|');
  for (final item in items) {
    print('| ${item.date} | ${item.orderId} | ${item.type} | ${item.color} | ${item.quantity} | ${item.source} |');
  }

  print('\n### Summary by Filament Type\n');
  final typeSummary = <String, int>{};
  for (final item in items) {
    typeSummary[item.type] = (typeSummary[item.type] ?? 0) + item.quantity;
  }
  print('| Filament Type | Total Quantity |');
  print('|---|---|');
  final sortedTypes = typeSummary.keys.toList()..sort((a, b) => typeSummary[b]!.compareTo(typeSummary[a]!));
  for (final type in sortedTypes) {
    print('| $type | ${typeSummary[type]} |');
  }

  print('\n### Summary by Color\n');
  final colorSummary = <String, int>{};
  for (final item in items) {
    final key = '${item.type} [${item.color}]';
    colorSummary[key] = (colorSummary[key] ?? 0) + item.quantity;
  }
  print('| Filament [Color] | Total Quantity |');
  print('|---|---|');
  final sortedColors = colorSummary.keys.toList()..sort((a, b) => colorSummary[b]!.compareTo(colorSummary[a]!));
  for (final color in sortedColors) {
    print('| $color | ${colorSummary[color]} |');
  }
  
  print('\n**Grand Total: ${items.fold(0, (sum, i) => sum + i.quantity)} rolls**');
}

bool isFilament(String name) {
  final lower = name.toLowerCase();
  return lower.contains('pla') || lower.contains('petg') || lower.contains('tpu') || lower.contains('abs') || lower.contains('asa') || lower.contains('cf') || lower.contains('gf') || lower.contains('フィラメント');
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
