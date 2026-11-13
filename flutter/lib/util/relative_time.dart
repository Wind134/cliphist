DateTime? parseItemTime(String timestamp) {
  final normalized = timestamp.contains('T')
      ? timestamp
      : timestamp.replaceFirst(' ', 'T');
  return DateTime.tryParse(normalized);
}

String relativeTime(String timestamp, {DateTime? now}) {
  final dt = parseItemTime(timestamp);
  if (dt == null) return timestamp;
  now ??= DateTime.now();
  final diff = now.difference(dt);
  if (diff.inSeconds < 45 || diff.isNegative) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  if (sameDay) return '${diff.inHours} 小时前';
  final yday = DateTime(
    now.year,
    now.month,
    now.day,
  ).subtract(const Duration(days: 1));
  if (dt.year == yday.year && dt.month == yday.month && dt.day == yday.day) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '昨天 $hh:$mm';
  }
  if (dt.year == now.year) return '${dt.month}月${dt.day}日';
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

String groupLabel(String timestamp, {DateTime? now}) {
  final dt = parseItemTime(timestamp);
  if (dt == null) return '更早';
  now ??= DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '今天';
  }
  final yday = DateTime(
    now.year,
    now.month,
    now.day,
  ).subtract(const Duration(days: 1));
  if (dt.year == yday.year && dt.month == yday.month && dt.day == yday.day) {
    return '昨天';
  }
  return '更早';
}
