import 'dart:convert';
import 'dart:io';

class FilamentItem {
  final String date;
  final String orderId;
  final String type;
  final String color;
  final int quantity;
  final int price;
  final String source;

  FilamentItem({
    required this.date,
    required this.orderId,
    required this.type,
    required this.color,
    required this.quantity,
    required this.price,
    required this.source,
  });

  @override
  String toString() => '$type ($color) x $quantity @ ¥$price';

  int get priority {
    final t = type.toLowerCase();
    if (t.contains('pla')) return 1;
    if (t.contains('petg')) return 2;
    if (t.contains('tpu')) return 3;
    if (t.contains('abs')) return 4;
    if (t.contains('asa')) return 5;
    if (t.contains('サポート') || t.contains('support')) return 6;
    return 10;
  }
}

Future<void> main() async {
  print('--- Bambu Lab Filament Tracker (v2.3) ---');

  final queries = [
    'from:bambulab.com "ご注文確認"',
    'from:bambulab.com "出荷状況更新"',
    'from:bambulab.com "キャンセル"',
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
  final cancelledOrderIds = <String>{};

  // First pass: detect cancellations
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

    final body = getBody(msg['payload']);
    final content = body.replaceAll('\u200b', '');

    if (content.contains('ご注文がキャンセルされました') || content.contains('Order Canceled')) {
      final orderIdMatch = RegExp(r'JP\d+').firstMatch(content);
      if (orderIdMatch != null) {
        cancelledOrderIds.add(orderIdMatch.group(0)!);
      }
    }
  }

  if (cancelledOrderIds.isNotEmpty) {
    print('Detected cancelled orders: ${cancelledOrderIds.join(', ')}\n');
  }

  // Second pass: extract items
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
    final subject = headers.firstWhere((h) => h['name'] == 'Subject', orElse: () => {'value': ''})['value'] as String;

    // Extract Order ID
    final orderIdMatch = RegExp(r'JP\d+').firstMatch(content) ?? RegExp(r'JP\d+').firstMatch(subject);
    final orderId = orderIdMatch?.group(0) ?? 'Unknown';

    if (cancelledOrderIds.contains(orderId)) continue;
    if (processedOrderIds.contains(orderId) && orderId != 'Unknown') continue;
    processedOrderIds.add(orderId);

    // Parse Bambu Store Items
    final isBambuStore = content.contains('Bambu Lab ストア') || content.contains('Bambu Lab Japan');
    final isConfirmation = subject.contains('ご注文確認') || subject.contains('注文') || content.contains('ご注文頂きありがとうございました') || content.contains('配送中');

    if (isBambuStore && isConfirmation) {
      final itemMatches = RegExp(r'([^\n]+) × (\d+)').allMatches(content);
      final matchesList = itemMatches.toList();
      
      for (int i = 0; i < matchesList.length; i++) {
        final match = matchesList[i];
        final itemName = match.group(1)!.trim();
        if (itemName.contains('小計') || itemName.contains('合計')) continue;
        
        final quantity = int.parse(match.group(2)!);
        
        final start = match.end;
        final end = (i + 1 < matchesList.length) ? matchesList[i+1].start : content.indexOf('小計', start);
        final block = content.substring(start, (end != -1 ? end : start + 300).clamp(0, content.length));
        
        final colorMatch = RegExp(r'([^\n/]+)\s*(\(\d+\))? /').firstMatch(block);
        final color = colorMatch?.group(1)?.trim() ?? 'N/A';
        
        final priceMatches = RegExp(r'¥(\d{1,3}(,\d{3})*|\d+)').allMatches(block);
        int price = 0;
        if (priceMatches.isNotEmpty) {
          final lastPriceStr = priceMatches.last.group(1)!.replaceAll(',', '');
          price = int.parse(lastPriceStr);
        }

        if (isFilament(itemName)) {
          items.add(FilamentItem(
            date: date ?? 'N/A',
            orderId: orderId,
            type: itemName,
            color: color,
            quantity: quantity,
            price: price,
            source: 'Store',
          ));
        }
      }
    } 
    else if (content.contains('Amazon')) {
      final itemMatches = RegExp(r'\*\s+([^\n]+)\n\s+数量: (\d+)').allMatches(content);
      for (final match in itemMatches) {
        final itemName = match.group(1)!.trim();
        final quantity = int.parse(match.group(2)!);
        
        final start = match.end;
        final nextBlock = content.substring(start, (start + 100).clamp(0, content.length));
        final priceMatch = RegExp(r'(\d+)\s*JPY').firstMatch(nextBlock);
        final price = int.parse(priceMatch?.group(1) ?? '0');
        
        if (itemName.contains('Bambu') || itemName.contains('フィラメント')) {
          items.add(FilamentItem(
            date: date ?? 'N/A',
            orderId: orderId,
            type: 'Amazon Item',
            color: itemName,
            quantity: quantity,
            price: price,
            source: 'Amazon',
          ));
        }
      }
    }
  }

  items.sort((a, b) {
    if (a.priority != b.priority) return a.priority.compareTo(b.priority);
    final typeComp = a.type.compareTo(b.type);
    if (typeComp != 0) return typeComp;
    return a.color.compareTo(b.color);
  });

  print('\n### Detailed Purchase History (Full)\n');
  print('| Date | Order ID | Filament Type | Color | Qty | Price | Source |');
  print('|---|---|---|---|---|---|---|');
  int grandTotalPrice = 0;
  for (final item in items) {
    print('| ${item.date} | ${item.orderId} | ${item.type} | ${item.color} | ${item.quantity} | ¥${item.price} | ${item.source} |');
    grandTotalPrice += item.price;
  }

  print('\n### Summary by Filament Type & Color (Grouped)\n');
  final groupedSummary = <String, Map<String, int>>{};
  for (final item in items) {
    final key = '${item.type}|${item.color}|${item.priority}';
    if (!groupedSummary.containsKey(key)) {
      groupedSummary[key] = {'qty': 0, 'price': 0};
    }
    groupedSummary[key]!['qty'] = groupedSummary[key]!['qty']! + item.quantity;
    groupedSummary[key]!['price'] = groupedSummary[key]!['price']! + item.price;
  }

  print('| Filament Type | Color | Total Qty | Total Price |');
  print('|---|---|---|---|');
  
  final sortedGroupKeys = groupedSummary.keys.toList()..sort((a, b) {
    final ap = int.parse(a.split('|')[2]);
    final bp = int.parse(b.split('|')[2]);
    if (ap != bp) return ap.compareTo(bp);
    return a.compareTo(b);
  });

  for (final key in sortedGroupKeys) {
    final parts = key.split('|');
    final data = groupedSummary[key]!;
    print('| ${parts[0]} | ${parts[1]} | ${data['qty']} | ¥${data['price']} |');
  }
  
  print('\n**Grand Total: ${items.fold(0, (sum, i) => sum + i.quantity)} rolls**');
  print('**Total Spent: ¥$grandTotalPrice**');
}

bool isFilament(String name) {
  final lower = name.toLowerCase();
  return lower.contains('pla') || lower.contains('petg') || lower.contains('tpu') || lower.contains('abs') || lower.contains('asa') || lower.contains('cf') || lower.contains('gf') || lower.contains('フィラメント') || lower.contains('サポート') || lower.contains('support');
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
