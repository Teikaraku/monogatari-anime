import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/broadcast_slot.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';

/// Broadcast times by Bangumi subject id. Fetched once per app session; a
/// failed fetch is retried on the next call.
class AirtimeApi {
  AirtimeApi._();

  static Map<int, BroadcastSlot>? _cache;
  static Future<Map<int, BroadcastSlot>>? _pending;

  static Future<Map<int, BroadcastSlot>> load() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _pending ??= _load().whenComplete(() => _pending = null);
  }

  static Future<Map<int, BroadcastSlot>> _load() async {
    if (!ApiEndpoints.hasPublicCatalog) return {};
    try {
      final response = await DioFactory.apiDio.get<dynamic>(
        ApiEndpoints.bangumiAirtime,
      );
      final data = response.data;
      final index = parseAirtimeIndex(data is String ? jsonDecode(data) : data);
      if (index.isNotEmpty) _cache = index;
      return index;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
