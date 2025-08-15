// lib/services/notification_center.dart

import 'dart:async';
import 'package:flutter/foundation.dart';

typedef NotificationCallback = void Function(Map<String, dynamic> data);

class NotificationCenter {
  static NotificationCenter? _instance;
  static NotificationCenter get instance => _instance ??= NotificationCenter._();
  
  NotificationCenter._();

  final Map<String, List<NotificationCallback>> _observers = {};
  
  // 🔥 YENİ: Performance tracking ve debug info
  final Map<String, int> _eventCounts = {};
  final Map<String, DateTime> _lastEventTimes = {};
  final Map<String, Duration> _totalProcessingTimes = {};
  final List<Map<String, dynamic>> _recentEvents = [];
  
  // 🔥 YENİ: Configuration
  static const int _maxRecentEvents = 50;
  static const bool _enableDetailedLogging = true;
  static const bool _enablePerformanceTracking = true;

  /// Bildirim dinleyicisi ekle
  void addObserver(String eventType, NotificationCallback callback) {
    if (!_observers.containsKey(eventType)) {
      _observers[eventType] = [];
    }
    _observers[eventType]!.add(callback);
    
    if (_enableDetailedLogging) {
      debugPrint('[NotificationCenter] 👂 Observer added for: $eventType (${_observers[eventType]!.length} total)');
    }
  }

  /// Bildirim dinleyicisi kaldır
  void removeObserver(String eventType, NotificationCallback callback) {
    if (_observers.containsKey(eventType)) {
      _observers[eventType]!.remove(callback);
      if (_observers[eventType]!.isEmpty) {
        _observers.remove(eventType);
      }
      
      if (_enableDetailedLogging) {
        debugPrint('[NotificationCenter] 🗑️ Observer removed for: $eventType (${_observers[eventType]?.length ?? 0} remaining)');
      }
    }
  }

  /// 🔥 DÜZELTME: Safe type getter helper metodları
  String _getSafeEventType(Map<String, dynamic> data) {
    final eventType = data['event_type'] ?? data['eventType'];
    if (eventType == null) return 'unknown';
    return eventType.toString(); // Her durumda String'e çevir
  }

  String _getSafeOrderId(Map<String, dynamic> data) {
    final orderId = data['order_id'] ?? data['orderId'];
    if (orderId == null) return '';
    return orderId.toString(); // Her durumda String'e çevir
  }

  /// 🔥 DÜZELTME: Enhanced bildirim gönder - POST metodu
  void post(String eventType, Map<String, dynamic> data) {
    final observers = _observers[eventType];
    final observerCount = observers?.length ?? 0;
    
    // Performance tracking başlat
    final startTime = _enablePerformanceTracking ? DateTime.now() : null;
    
    // Event sayacını artır
    _eventCounts[eventType] = (_eventCounts[eventType] ?? 0) + 1;
    _lastEventTimes[eventType] = DateTime.now();
    
    // 🔥 DÜZELTME: Type-safe logging
    if (_enableDetailedLogging) {
      final eventData = _getSafeEventType(data);
      final orderId = _getSafeOrderId(data);
      final orderIdStr = orderId.isNotEmpty ? ' for order $orderId' : '';
      
      debugPrint('[NotificationCenter] 🔔 Broadcasting: "$eventType" to $observerCount observers');
      debugPrint('[NotificationCenter] 📦 Event data: $eventData$orderIdStr');
    }
    
    if (observers != null && observers.isNotEmpty) {
      // Copy the list to avoid modification during iteration
      final callbacks = List<NotificationCallback>.from(observers);
      
      int successCount = 0;
      int errorCount = 0;
      
      for (int i = 0; i < callbacks.length; i++) {
        try {
          callbacks[i](data);
          successCount++;
        } catch (e, stackTrace) {
          errorCount++;
          debugPrint('[NotificationCenter] ❌ Error in observer #$i for "$eventType": $e');
          if (_enableDetailedLogging) {
            debugPrint('[NotificationCenter] 📚 Stack trace: $stackTrace');
          }
        }
      }
      
      // Performance tracking bitir
      if (_enablePerformanceTracking && startTime != null) {
        final duration = DateTime.now().difference(startTime);
        _totalProcessingTimes[eventType] = 
            (_totalProcessingTimes[eventType] ?? Duration.zero) + duration;
        
        if (_enableDetailedLogging) {
          debugPrint('[NotificationCenter] ⏱️ Broadcast completed in ${duration.inMilliseconds}ms (✅$successCount ❌$errorCount)');
        }
        
        // Slow event warning
        if (duration.inMilliseconds > 100) {
          debugPrint('[NotificationCenter] ⚠️ Slow event detected: "$eventType" took ${duration.inMilliseconds}ms');
        }
      }
    } else {
      if (_enableDetailedLogging) {
        debugPrint('[NotificationCenter] 📭 No observers for: "$eventType"');
      }
    }
    
    // Recent events tracking
    _addToRecentEvents(eventType, data, observerCount);
  }

  /// 🔥 DÜZELTME: Recent events tracking - Type safe
  void _addToRecentEvents(String eventType, Map<String, dynamic> data, int observerCount) {
    final eventInfo = {
      'eventType': eventType,
      'timestamp': DateTime.now().toIso8601String(),
      'observerCount': observerCount,
      'eventData': _getSafeEventType(data), // Safe getter kullan
      'orderId': _getSafeOrderId(data),     // Safe getter kullan
    };
    
    _recentEvents.insert(0, eventInfo);
    
    // Keep only recent events
    if (_recentEvents.length > _maxRecentEvents) {
      _recentEvents.removeRange(_maxRecentEvents, _recentEvents.length);
    }
  }

  /// Bildirim gönder - postNotification metodu (backward compatibility)
  void postNotification(String eventType, Map<String, dynamic> data) {
    post(eventType, data);
  }

  /// 🔥 YENİ: Observer'ları notify et (eski interface için uyumluluk)
  void notifyObservers(String eventName, Map<String, dynamic> data) {
    post(eventName, data);
  }

  /// 🔥 YENİ: Performance statistics
  Map<String, dynamic> getPerformanceStats() {
    final stats = <String, dynamic>{};
    
    _eventCounts.forEach((eventType, count) {
      final totalTime = _totalProcessingTimes[eventType] ?? Duration.zero;
      final avgTimeMs = count > 0 ? totalTime.inMilliseconds / count : 0.0;
      
      stats[eventType] = {
        'count': count,
        'totalTimeMs': totalTime.inMilliseconds,
        'avgTimeMs': avgTimeMs.toStringAsFixed(2),
        'lastEvent': _lastEventTimes[eventType]?.toIso8601String() ?? 'never',
        'observers': _observers[eventType]?.length ?? 0,
      };
    });
    
    return stats;
  }

  /// 🔥 YENİ: Recent events getter
  List<Map<String, dynamic>> getRecentEvents({int? limit}) {
    final eventLimit = limit ?? _maxRecentEvents;
    return _recentEvents.take(eventLimit).toList();
  }

  /// 🔥 YENİ: Event count getter
  Map<String, int> getEventCounts() => Map.from(_eventCounts);

  /// 🔥 YENİ: Active observers getter
  Map<String, int> getActiveObservers() {
    final result = <String, int>{};
    _observers.forEach((key, value) {
      result[key] = value.length;
    });
    return result;
  }

  /// 🔥 YENİ: Clear statistics
  void clearStats() {
    _eventCounts.clear();
    _lastEventTimes.clear();
    _totalProcessingTimes.clear();
    _recentEvents.clear();
    debugPrint('[NotificationCenter] 📊 Statistics cleared');
  }

  /// Tüm observer'ları temizle
  void dispose() {
    final observerCount = _observers.values.fold(0, (sum, list) => sum + list.length);
    
    _observers.clear();
    clearStats();
    
    debugPrint('[NotificationCenter] 🧹 All observers cleared ($observerCount total)');
  }

  /// 🔥 ENHANCED: Debug bilgisi için observer sayılarını göster
  void debugInfo() {
    debugPrint('[NotificationCenter] 📊 Current observers:');
    
    if (_observers.isEmpty) {
      debugPrint('  (No active observers)');
      return;
    }
    
    var totalObservers = 0;
    _observers.forEach((key, value) {
      totalObservers += value.length;
      final lastEvent = _lastEventTimes[key];
      final eventCount = _eventCounts[key] ?? 0;
      final avgTime = _getAvgProcessingTime(key);
      
      debugPrint('  📋 $key: ${value.length} observers');
      if (eventCount > 0) {
        debugPrint('    └─ Events: $eventCount, Avg: ${avgTime}ms, Last: ${_formatTimestamp(lastEvent)}');
      }
    });
    
    debugPrint('[NotificationCenter] 📈 Total: $totalObservers observers, ${_eventCounts.length} event types');
  }

  /// 🔥 YENİ: Detailed debug info
  void debugDetailedInfo() {
    debugInfo();
    
    debugPrint('[NotificationCenter] 🔍 Recent Events (last ${_recentEvents.length}):');
    for (int i = 0; i < _recentEvents.length.clamp(0, 10); i++) {
      final event = _recentEvents[i];
      final timestamp = DateTime.parse(event['timestamp'] as String);
      final timeAgo = DateTime.now().difference(timestamp);
      
      debugPrint('  ${i + 1}. ${event['eventType']} (${_formatDuration(timeAgo)} ago)');
      debugPrint('     └─ ${event['observerCount']} observers, Event: ${event['eventData']}');
    }
    
    if (_recentEvents.length > 10) {
      debugPrint('  ... and ${_recentEvents.length - 10} more recent events');
    }
  }

  /// 🔥 YENİ: Performance report
  void debugPerformanceReport() {
    debugPrint('[NotificationCenter] 🏆 Performance Report:');
    
    final stats = getPerformanceStats();
    final sortedStats = stats.entries.toList()
      ..sort((a, b) => (b.value['count'] as int).compareTo(a.value['count'] as int));
    
    for (final entry in sortedStats.take(10)) {
      final eventType = entry.key;
      final stat = entry.value;
      
      debugPrint('  🏅 $eventType:');
      debugPrint('     └─ Count: ${stat['count']}, Avg: ${stat['avgTimeMs']}ms, Observers: ${stat['observers']}');
    }
    
    // Memory usage estimation
    final estimatedMemory = _observers.length * 50 + _recentEvents.length * 200; // rough estimate
    debugPrint('[NotificationCenter] 💾 Estimated memory usage: ~${estimatedMemory}B');
  }

  /// 🔥 YENİ: Health check
  bool healthCheck() {
    final issues = <String>[];
    
    // Check for observers without events
    _observers.forEach((eventType, observers) {
      final eventCount = _eventCounts[eventType] ?? 0;
      if (observers.isNotEmpty && eventCount == 0) {
        issues.add('Event "$eventType" has ${observers.length} observers but no events');
      }
    });
    
    // Check for slow events
    _totalProcessingTimes.forEach((eventType, totalTime) {
      final count = _eventCounts[eventType] ?? 1;
      final avgTime = totalTime.inMilliseconds / count;
      if (avgTime > 50) {
        issues.add('Event "$eventType" averaging ${avgTime.toStringAsFixed(1)}ms (slow)');
      }
    });
    
    if (issues.isNotEmpty) {
      debugPrint('[NotificationCenter] ⚠️ Health Check Issues:');
      for (final issue in issues) {
        debugPrint('  - $issue');
      }
      return false;
    }
    
    debugPrint('[NotificationCenter] ✅ Health Check: All good!');
    return true;
  }

  // 🔧 Helper methods
  double _getAvgProcessingTime(String eventType) {
    final totalTime = _totalProcessingTimes[eventType];
    final count = _eventCounts[eventType] ?? 0;
    if (totalTime == null || count == 0) return 0.0;
    return totalTime.inMilliseconds / count;
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'never';
    final diff = DateTime.now().difference(timestamp);
    return _formatDuration(diff);
  }

  String _formatDuration(Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s ago';
    } else if (duration.inMinutes < 60) {
      return '${duration.inMinutes}m ago';
    } else {
      return '${duration.inHours}h ago';
    }
  }

  /// 🔥 YENİ: Event monitoring (for debugging)
  void startEventMonitoring({Duration interval = const Duration(seconds: 30)}) {
    Timer.periodic(interval, (timer) {
      if (_observers.isEmpty) {
        timer.cancel();
        return;
      }
      
      debugPrint('[NotificationCenter] 🔍 Monitoring Report:');
      debugPrint('  Active observers: ${_observers.length}');
      debugPrint('  Recent events: ${_recentEvents.length}');
      debugPrint('  Total event types processed: ${_eventCounts.length}');
      
      // Show most active events
      final sortedCounts = _eventCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      
      if (sortedCounts.isNotEmpty) {
        debugPrint('  Most active: ${sortedCounts.first.key} (${sortedCounts.first.value} events)');
      }
    });
    
    debugPrint('[NotificationCenter] 🎯 Event monitoring started (${interval.inSeconds}s interval)');
  }
}