// lib/services/order_screen_service.dart

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/menu_item.dart';
import 'api_service.dart';
import 'connectivity_service.dart';
import 'cache_service.dart';
import 'order_service.dart';

/// CreateOrderScreen için özel API çağrılarını ve veri işleme mantığını yönetir.
class OrderScreenService {
  // 🔥 YENİ: İn-memory cache ve timestamp'ler
  static final Map<String, dynamic> _memoryCache = {};
  static final Map<String, DateTime> _cacheTimestamps = {};
  
  // Cache süresi konfigürasyonları
  static const Duration _defaultCacheExpiry = Duration(seconds: 10);
  static const Duration _shortCacheExpiry = Duration(seconds: 5);
  static const Duration _longCacheExpiry = Duration(seconds: 30);
  
  // Cache anahtarları
  static const String _categoriesCacheKey = 'categories_memory';
  static const String _menuItemsCacheKey = 'menu_items_memory';
  static const String _tablesCacheKey = 'tables_memory';
  static const String _pendingOrdersCacheKey = 'pending_orders_memory';
  static const String _waitingCountCacheKey = 'waiting_count_memory';

  /// 🔥 YENİ: Cache'den veri al (varsa ve fresh ise)
  static T? _getCachedData<T>(String cacheKey, {Duration? customExpiry}) {
    final now = DateTime.now();
    final timestamp = _cacheTimestamps[cacheKey];
    final expiry = customExpiry ?? _defaultCacheExpiry;
    
    if (timestamp != null && 
        _memoryCache.containsKey(cacheKey) && 
        now.difference(timestamp) < expiry) {
      debugPrint('[OrderScreenService] 📦 Cache hit for: $cacheKey');
      return _memoryCache[cacheKey] as T;
    }
    
    return null;
  }
  
  /// 🔥 YENİ: Cache'e veri kaydet
  static void _setCachedData<T>(String cacheKey, T data) {
    _memoryCache[cacheKey] = data;
    _cacheTimestamps[cacheKey] = DateTime.now();
    debugPrint('[OrderScreenService] 💾 Cached data for: $cacheKey');
  }
  
  /// 🔥 YENİ: Cache temizleme
  static void clearCache() {
    _memoryCache.clear();
    _cacheTimestamps.clear();
    debugPrint('[OrderScreenService] 🗑️ Memory cache cleared');
  }
  
  /// 🔥 YENİ: Belirli cache anahtarını temizle
  static void invalidateCache(String cacheKey) {
    _memoryCache.remove(cacheKey);
    _cacheTimestamps.remove(cacheKey);
    debugPrint('[OrderScreenService] 🗑️ Invalidated cache for: $cacheKey');
  }

  /// 🔥 YENİ: Cache'li kategoriler
  static Future<List<dynamic>> getCachedCategories(String token) async {
    // Cache kontrolü
    final cached = _getCachedData<List<dynamic>>(_categoriesCacheKey, 
        customExpiry: _longCacheExpiry);
    if (cached != null) return cached;
    
    // Fresh data çek
    debugPrint('[OrderScreenService] 🌐 Fetching fresh categories');
    final data = await OrderService.fetchCategories(token);
    // Null safety kontrolü
    final safeData = data ?? <dynamic>[];
    _setCachedData(_categoriesCacheKey, safeData);
    return safeData;
  }
  
  /// 🔥 YENİ: Cache'li menü öğeleri
  static Future<List<dynamic>> getCachedMenuItems(String token) async {
    // Cache kontrolü
    final cached = _getCachedData<List<dynamic>>(_menuItemsCacheKey, 
        customExpiry: _longCacheExpiry);
    if (cached != null) return cached;
    
    // Fresh data çek
    debugPrint('[OrderScreenService] 🌐 Fetching fresh menu items');
    final data = await OrderService.fetchMenuItems(token);
    // Null safety kontrolü
    final safeData = data ?? <dynamic>[];
    _setCachedData(_menuItemsCacheKey, safeData);
    return safeData;
  }
  
  /// 🔥 YENİ: Cache'li masalar
  static Future<List<dynamic>> getCachedTables(String token) async {
    // Cache kontrolü
    final cached = _getCachedData<List<dynamic>>(_tablesCacheKey, 
        customExpiry: _shortCacheExpiry);
    if (cached != null) return cached;
    
    // Fresh data çek
    debugPrint('[OrderScreenService] 🌐 Fetching fresh tables');
    final data = await _fetchAndCacheTables(token);
    _setCachedData(_tablesCacheKey, data);
    return data; // _fetchAndCacheTables zaten non-null List<dynamic> döner
  }
  
  /// 🔥 DÜZELTILMIŞ: Cache'li bekleyen siparişler
  static Future<List<dynamic>> getCachedPendingOrders(String token, int businessId) async {
    // Cache kontrolü
    final cached = _getCachedData<List<dynamic>>(_pendingOrdersCacheKey, 
        customExpiry: _shortCacheExpiry);
    if (cached != null) return cached;
    
    // Fresh data çek
    debugPrint('[OrderScreenService] 🌐 Fetching fresh pending orders');
    final data = await OrderService.fetchPendingOrdersOnly(token, businessId);
    // Null safety kontrolü
    final safeData = data ?? <dynamic>[];
    _setCachedData(_pendingOrdersCacheKey, safeData);
    return safeData;
  }
  
  /// 🔥 DÜZELTILMIŞ: Cache'li bekleyen müşteri sayısı
  static Future<int> getCachedWaitingCount(String token) async {
    // Cache kontrolü
    final cached = _getCachedData<int>(_waitingCountCacheKey, 
        customExpiry: _defaultCacheExpiry);
    if (cached != null) return cached;
    
    // Fresh data çek
    debugPrint('[OrderScreenService] 🌐 Fetching fresh waiting count');
    final data = await OrderService.fetchWaitingCountOnly(token);
    // Null safety kontrolü
    final safeData = data ?? 0;
    _setCachedData(_waitingCountCacheKey, safeData);
    return safeData;
  }

  /// Çevrimdışı ve çevrimiçi modları destekleyen merkezi veri çekme fonksiyonu.
  static Future<Map<String, dynamic>> fetchInitialData(String token, int businessId) async {
    if (ConnectivityService.instance.isOnlineNotifier.value) {
      return _fetchDataFromApi(token, businessId);
    } else {
      return _fetchDataFromCache();
    }
  }

  /// 🔥 GÜNCELLENEN: Çevrimiçiyken API'den tüm verileri çeker ve önbelleğe alır.
  static Future<Map<String, dynamic>> _fetchDataFromApi(String token, int businessId) async {
    debugPrint("[OrderScreenService] (Online) Başlangıç verileri API'den çekiliyor...");
    String overallErrorMessage = '';

    try {
      // 🔥 YENİ: Cache'li fonksiyonları kullan
      final results = await Future.wait([
        getCachedTables(token).catchError((e) {
          debugPrint("Hata (getCachedTables): $e");
          overallErrorMessage += "Masa verileri alınamadı. ";
          return <dynamic>[];
        }),
        getCachedCategories(token).catchError((e) {
          debugPrint("Hata (getCachedCategories): $e");
          overallErrorMessage += "Kategori verileri alınamadı. ";
          return <dynamic>[];
        }),
        getCachedMenuItems(token).catchError((e) {
          debugPrint("Hata (getCachedMenuItems): $e");
          overallErrorMessage += "Menü verileri alınamadı. ";
          return <dynamic>[];
        }),
        getCachedPendingOrders(token, businessId).catchError((e) {
          debugPrint("Hata (getCachedPendingOrders): $e");
          return <dynamic>[];
        }),
        getCachedWaitingCount(token).catchError((e) {
          debugPrint("Hata (getCachedWaitingCount): $e");
          return 0;
        }),
      ]);

      final tables = results[0] as List<dynamic>;
      final categories = results[1] as List<dynamic>;
      final menuItemsData = results[2] as List<dynamic>;
      final menuItems = menuItemsData.map((e) => MenuItem.fromJson(e)).toList();
      final pendingOrders = results[3] as List<dynamic>;
      final waitingCount = results[4] as int;

      debugPrint('[OrderScreenService] 📊 Fetched data summary: Tables: ${tables.length}, Categories: ${categories.length}, MenuItems: ${menuItems.length}, Orders: ${pendingOrders.length}, Waiting: $waitingCount');

      return {
        'tables': tables,
        'pendingOrders': pendingOrders,
        'menuItems': menuItems,
        'waitingCount': waitingCount,
        'errorMessage': overallErrorMessage.trim().isNotEmpty ? overallErrorMessage.trim() : null,
        'success': overallErrorMessage.trim().isEmpty,
      };
    } catch (e) {
      overallErrorMessage = "Veriler alınırken genel bir hata oluştu: $e";
      debugPrint('❌ [OrderScreenService] Genel hata: $e');
      return {
        'tables': [], 'pendingOrders': [], 'menuItems': [], 'waitingCount': 0,
        'errorMessage': overallErrorMessage, 'success': false,
      };
    }
  }

  /// Çevrimdışıyken tüm verileri önbellekten okur.
  static Future<Map<String, dynamic>> _fetchDataFromCache() async {
    debugPrint("[OrderScreenService] (Offline) Başlangıç verileri önbellekten okunuyor...");
    try {
      final tables = CacheService.instance.getCachedData('tables');
      final menuItemsData = CacheService.instance.getCachedData('menu_items');
      final categories = CacheService.instance.getCachedData('categories');

      if (tables == null || menuItemsData == null || categories == null) {
        throw Exception("Çevrimdışı modda çalışabilmek için lütfen en az bir kez internete bağlanın.");
      }

      final temporaryPendingOrders = CacheService.instance.getTemporaryOrders();
      debugPrint("[OrderScreenService] (Offline) Önbellekten ${temporaryPendingOrders.length} adet geçici sipariş okundu.");

      return {
        'tables': tables,
        'pendingOrders': temporaryPendingOrders,
        'menuItems': menuItemsData.map((e) => MenuItem.fromJson(e)).toList(),
        'waitingCount': 0,
        'errorMessage': null,
        'success': true,
      };
    } catch (e) {
      return {
        'tables': [], 'pendingOrders': [], 'menuItems': [], 'waitingCount': 0,
        'errorMessage': e.toString().replaceFirst("Exception: ", ""), 'success': false,
      };
    }
  }
  
  /// Sadece masaları çekip önbelleğe alan yardımcı fonksiyon.
  static Future<List<dynamic>> _fetchAndCacheTables(String token) async {
    final url = ApiService.getUrl('/tables/');
    final response = await http.get(url, headers: {"Authorization": "Bearer $token"});
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      await CacheService.instance.cacheData('tables', data);
      debugPrint("[OrderScreenService] (Online) Masa verileri başarıyla çekildi ve önbelleğe alındı.");
      return data as List<dynamic>; // Type cast ekledik
    } else {
      throw Exception("Masalar alınamadı (${response.statusCode})");
    }
  }

  /// 🔥 YENİ: Sipariş durumu değişikliklerinde ilgili cache'leri temizle
  static void invalidateOrderRelatedCaches() {
    invalidateCache(_pendingOrdersCacheKey);
    invalidateCache(_waitingCountCacheKey);
    debugPrint('[OrderScreenService] 🔄 Order-related caches invalidated');
  }
  
  /// 🔥 YENİ: Masa durumu değişikliklerinde masa cache'ini temizle  
  static void invalidateTableCache() {
    invalidateCache(_tablesCacheKey);
    debugPrint('[OrderScreenService] 🔄 Table cache invalidated');
  }
  
  /// 🔥 YENİ: Menü değişikliklerinde menü cache'lerini temizle
  static void invalidateMenuCaches() {
    invalidateCache(_menuItemsCacheKey);
    invalidateCache(_categoriesCacheKey);
    debugPrint('[OrderScreenService] 🔄 Menu caches invalidated');
  }

  /// Masa transferi API isteğini gönderir.
  static Future<http.Response> transferOrder(String token, int orderId, int newTableId) async {
    final url = ApiService.getUrl('/orders/transfer/');
    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json", "Authorization": "Bearer $token"},
      body: jsonEncode({
        "order": orderId,
        "new_table": newTableId,
      }),
    );
    
    // 🔥 YENİ: Transfer sonrası cache'leri temizle
    if (response.statusCode == 200) {
      invalidateOrderRelatedCaches();
      invalidateTableCache();
    }
    
    return response;
  }

  /// Siparişi iptal etme API isteğini gönderir.
  static Future<http.Response> cancelOrder(String token, int orderId) async {
    final url = ApiService.getUrl('/orders/$orderId/');
    final response = await http.delete(
      url,
      headers: {"Authorization": "Bearer $token"},
    );
    
    // 🔥 YENİ: İptal sonrası cache'leri temizle
    if (response.statusCode == 200) {
      invalidateOrderRelatedCaches();
      invalidateTableCache();
    }
    
    return response;
  }
  
  /// 🔥 YENİ: Debug için cache durumunu logla
  static void logCacheStatus() {
    debugPrint('[OrderScreenService] 📊 Cache Status:');
    _cacheTimestamps.forEach((key, timestamp) {
      final age = DateTime.now().difference(timestamp);
      final hasData = _memoryCache.containsKey(key);
      debugPrint('  - $key: ${hasData ? "✅" : "❌"} (${age.inSeconds}s old)');
    });
  }
  
  /// 🔥 YENİ: Cache istatistikleri
  static Map<String, dynamic> getCacheStats() {
    final stats = <String, dynamic>{};
    final now = DateTime.now();
    
    _cacheTimestamps.forEach((key, timestamp) {
      final age = now.difference(timestamp);
      final hasData = _memoryCache.containsKey(key);
      stats[key] = {
        'hasData': hasData,
        'ageSeconds': age.inSeconds,
        'isValid': hasData && age < _defaultCacheExpiry,
      };
    });
    
    return stats;
  }
}