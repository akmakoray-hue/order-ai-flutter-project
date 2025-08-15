// lib/services/refresh_manager.dart

import 'dart:async';
import 'package:flutter/foundation.dart';

class RefreshManager {
  static final Map<String, DateTime> _lastRefreshTimes = {};
  
  // KDS güncellemeleri için daha kısa throttle süresi
  static const Duration _kdsThrottleDuration = Duration(seconds: 1);
  static const Duration _defaultThrottleDuration = Duration(milliseconds: 800);

  /// Throttled refresh - aynı key için belirli süre içinde sadece bir kez çalışır
  /// isKdsUpdate: true ise KDS güncellemeleri için daha hızlı refresh yapılır
  static Future<void> throttledRefresh(
    String key, 
    Future<void> Function() refreshFunction,
    {bool isKdsUpdate = false}
  ) async {
    final now = DateTime.now();
    final lastRefresh = _lastRefreshTimes[key];
    final throttleDuration = isKdsUpdate ? _kdsThrottleDuration : _defaultThrottleDuration;
    
    if (lastRefresh == null || now.difference(lastRefresh) > throttleDuration) {
      print('[RefreshManager] ✅ Executing refresh for key: $key ${isKdsUpdate ? "(KDS Priority)" : ""}');
      _lastRefreshTimes[key] = now;
      
      try {
        await refreshFunction();
      } catch (e) {
        print('[RefreshManager] ❌ Error during refresh for key $key: $e');
      }
    } else {
      final remaining = throttleDuration - now.difference(lastRefresh);
      print('[RefreshManager] 🚫 Throttled refresh for key: $key (${remaining.inMilliseconds}ms remaining) ${isKdsUpdate ? "[KDS]" : ""}');
    }
  }

  /// Belirli bir key'in throttle durumunu temizle
  static void clearThrottle(String key) {
    _lastRefreshTimes.remove(key);
    print('[RefreshManager] 🗑️ Cleared throttle for key: $key');
  }

  /// Tüm throttle durumlarını temizle
  static void clearAllThrottles() {
    _lastRefreshTimes.clear();
    print('[RefreshManager] 🗑️ Cleared all throttles');
  }

  /// Belirli bir key'in throttle edilip edilmediğini kontrol et
  static bool isThrottled(String key, {bool isKdsUpdate = false}) {
    final lastTime = _lastRefreshTimes[key];
    if (lastTime == null) return false;
    
    final now = DateTime.now();
    final throttleDuration = isKdsUpdate ? _kdsThrottleDuration : _defaultThrottleDuration;
    return now.difference(lastTime) <= throttleDuration;
  }

  /// KDS güncellemeleri için özel hızlı refresh metodu
  static Future<void> kdsRefresh(String key, Future<void> Function() refreshFunction) async {
    await throttledRefresh(key, refreshFunction, isKdsUpdate: true);
  }

  /// Debug için: Aktif throttle durumlarını listele
  static void logActiveThrottles() {
    final now = DateTime.now();
    print('[RefreshManager] 📊 Active throttles (${_lastRefreshTimes.length}):');
    _lastRefreshTimes.forEach((key, time) {
      final elapsed = now.difference(time);
      print('  - $key: ${elapsed.inMilliseconds}ms ago');
    });
  }
}