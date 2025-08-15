// lib/services/global_notification_handler.dart

import '../services/notification_center.dart';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:another_flushbar/flushbar.dart';

import '../main.dart';
import '../utils/notifiers.dart';
import '../services/user_session.dart';
import '../models/notification_event_types.dart';
import '../widgets/notifications/notification_ui_helper.dart';

class GlobalNotificationHandler {
  static final GlobalNotificationHandler _instance =
      GlobalNotificationHandler._internal();
  factory GlobalNotificationHandler() => _instance;
  GlobalNotificationHandler._internal();
  static GlobalNotificationHandler get instance => _instance;

  final Queue<Map<String, dynamic>> _notificationQueue =
      Queue<Map<String, dynamic>>();
  final Set<String> _processedBannerIds = <String>{};

  bool _isProcessing = false;
  bool _isBannerShowing = false;
  Timer? _processingTimer;

  bool _isSoundPlaying = false;
  Timer? _soundCooldownTimer;
  static const Duration _soundCooldown = Duration(seconds: 3);

  // App lifecycle tracking
  static bool _isAppInForeground = true;

  // Navigator safety tracking
  static bool _isNavigatorSafe = true;
  static Timer? _navigatorCheckTimer;

  // Global refresh deduplication
  static final Set<String> _pendingRefreshes = <String>{};
  static Timer? _refreshDebounceTimer;

  // 🔥 CRITICAL: Banner timeout protection
  Timer? _bannerTimeoutTimer;
  bool _bannerTimedOut = false;

  static void updateAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
    debugPrint("[GlobalNotificationHandler] App Lifecycle State Updated: $_isAppInForeground");
    
    if (_isAppInForeground) {
      _checkNavigatorSafety();
    }
  }

  static void _checkNavigatorSafety() {
    _navigatorCheckTimer?.cancel();
    _navigatorCheckTimer = Timer.periodic(Duration(milliseconds: 100), (timer) {
      final wasSafe = _isNavigatorSafe;
      _isNavigatorSafe = NavigatorSafeZone.canNavigate();
      
      if (!wasSafe && _isNavigatorSafe) {
        debugPrint('[GlobalNotificationHandler] 🟢 Navigator artık güvenli, kuyruk işleniyor');
        instance._processQueue();
      }
      
      // 5 saniye sonra timer'ı durdur
      if (timer.tick > 50) {
        timer.cancel();
      }
    });
  }

  static const Map<String, Duration> _bannerDurations = {
    NotificationEventTypes.orderApprovedForKitchen: Duration(seconds: 5),
    NotificationEventTypes.orderReadyForPickupUpdate: Duration(seconds: 5),
    NotificationEventTypes.orderItemAdded: Duration(seconds: 4),
    NotificationEventTypes.orderPreparingUpdate: Duration(seconds: 3),
    NotificationEventTypes.guestOrderPendingApproval: Duration(seconds: 5),
    NotificationEventTypes.existingOrderNeedsReapproval: Duration(seconds: 5),
  };

  static const Duration _defaultBannerDuration = Duration(seconds: 3);

  static void initialize() {
    debugPrint("[GlobalNotificationHandler] 🚀 Sistem başlatıldı.");
    newOrderNotificationDataNotifier.addListener(_handleNewNotification);
  }

  static void _handleNewNotification() {
    final data = newOrderNotificationDataNotifier.value;
    if (data == null) return;
    newOrderNotificationDataNotifier.value = null;
    instance._addToQueue(data);
  }

  void _addToQueue(Map<String, dynamic> data) {
    final eventType = data['event_type'] as String?;
    final notificationId = data['notification_id'] as String? ??
        '${eventType}_${DateTime.now().millisecondsSinceEpoch}';

    // 🔥 CRITICAL: Always add to queue, even if Navigator busy
    if (_processedBannerIds.contains(notificationId)) {
      debugPrint('📨 [GlobalNotificationHandler] Banner duplicate engellendi: $notificationId');
      return;
    }
    
    _processedBannerIds.add(notificationId);
    if (_processedBannerIds.length > 50) {
      _processedBannerIds.remove(_processedBannerIds.first);
    }

    _notificationQueue.add(data);
    debugPrint('[GlobalNotificationHandler] Kuyruğa eklendi: $eventType. Kuyruk boyutu: ${_notificationQueue.length}');

    _processQueue();
  }

  void processPendingNotifications() {
    debugPrint("[GlobalNotificationHandler] Bekleyen bildirimler işleniyor...");
    _processQueue();
  }

  void _processQueue() async {
    if (_isProcessing || _notificationQueue.isEmpty || _isBannerShowing) {
      return;
    }

    if (!_isAppInForeground) {
      debugPrint('[GlobalNotificationHandler] Uygulama arka planda, banner gösterimi bekletiliyor.');
      return;
    }

    if (!NavigatorSafeZone.canNavigate()) {
      debugPrint('[GlobalNotificationHandler] Navigator güvenli değil, bekletiliyor...');
      Timer(Duration(milliseconds: 200), () => _processQueue());
      return;
    }

    _isProcessing = true;
    
    try {
      while (_notificationQueue.isNotEmpty && 
             _isAppInForeground && 
             !_isBannerShowing && 
             NavigatorSafeZone.canNavigate()) {
        
        final notification = _notificationQueue.removeFirst();
        await _processNotification(notification);
        
        // Debounced global refresh
        _scheduleGlobalRefresh(
          notification['event_type'] ?? '', 
          notification
        );
        
        // Banner arası bekleme
        await Future.delayed(Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('[GlobalNotificationHandler] ❌ Queue processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  static void _scheduleGlobalRefresh(String eventType, Map<String, dynamic> data) {
    _pendingRefreshes.add(eventType);
    
    _refreshDebounceTimer?.cancel();
    
    _refreshDebounceTimer = Timer(Duration(milliseconds: 300), () {
      if (_pendingRefreshes.isNotEmpty) {
        debugPrint("[GlobalNotificationHandler] 📡 Batched refresh: ${_pendingRefreshes.join(', ')}");
        
        NotificationCenter.instance.postNotification(
          'refresh_all_screens',
          {
            'eventTypes': _pendingRefreshes.toList(),
            'batchRefresh': true,
            'timestamp': DateTime.now().millisecondsSinceEpoch
          }
        );
        
        _pendingRefreshes.clear();
      }
    });
  }

  Future<void> _processNotification(Map<String, dynamic> notification) async {
    final eventType = notification['event_type'] as String?;
    final orderId = notification['order_id'];

    if (eventType == null || !UserSession.hasNotificationPermission(eventType)) {
      debugPrint('[GlobalNotificationHandler] Yetki yok: $eventType');
      return;
    }

    debugPrint('[GlobalNotificationHandler] 🎯 Banner gösteriliyor: $eventType (Order: $orderId)');
    
    await _showBanner(eventType, notification);
  }

  // 🔥 COMPLETE FIXED: Banner with timeout protection and proper cleanup
  Future<void> _showBanner(String eventType, Map<String, dynamic> data) async {
    final context = navigatorKey.currentContext;
    
    if (context == null || _isBannerShowing) {
      debugPrint('[GlobalNotificationHandler] ❌ Context null veya banner zaten gösteriliyor');
      return;
    }

    if (!NavigatorSafeZone.canNavigate()) {
      debugPrint('[GlobalNotificationHandler] ❌ Navigator güvenli değil, banner atlandı');
      return;
    }

    // 🔥 Start navigation and banner
    NavigatorSafeZone.setNavigating(true);
    _isBannerShowing = true;
    _bannerTimedOut = false;
    
    _playNotificationSound(eventType);

    final message = _getNotificationMessage(eventType, data);
    final duration = _bannerDurations[eventType] ?? _defaultBannerDuration;

    final completer = Completer<void>();

    // 🔥 TIMEOUT PROTECTION - Force close after 10 seconds
    _bannerTimeoutTimer?.cancel();
    _bannerTimeoutTimer = Timer(Duration(seconds: 10), () {
      if (_isBannerShowing && !_bannerTimedOut) {
        debugPrint('[GlobalNotificationHandler] ⏰ FORCE TIMEOUT - Banner cleanup');
        _bannerTimedOut = true;
        _cleanupBanner();
        
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });

    try {
      Flushbar(
        messageText: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        icon: Icon(
          NotificationUiHelper.getIconForNotificationType(eventType),
          color: NotificationUiHelper.getIconColorForNotificationType(eventType),
          size: 32,
        ),
        duration: duration,
        flushbarPosition: FlushbarPosition.TOP,
        margin: const EdgeInsets.all(8),
        borderRadius: BorderRadius.circular(12),
        backgroundColor: _getBackgroundColorForEvent(eventType),
        boxShadows: const [
          BoxShadow(color: Colors.black45, blurRadius: 12, offset: Offset(0, 5))
        ],
        onStatusChanged: (status) {
          if (status == FlushbarStatus.DISMISSED && !_bannerTimedOut) {
            debugPrint("[GlobalNotificationHandler] ✅ Banner normal dismissal");
            _cleanupBanner();
            
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        },
      ).show(context);
    } catch (e) {
      debugPrint('[GlobalNotificationHandler] ❌ Banner show error: $e');
      _cleanupBanner();
      
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }

    return completer.future;
  }

  // 🔥 CRITICAL FIX: Complete centralized banner cleanup
  void _cleanupBanner() {
    _bannerTimeoutTimer?.cancel();
    _isBannerShowing = false;
    NavigatorSafeZone.setNavigating(false); // 🔥 CRITICAL: Free navigator
    
    debugPrint("[GlobalNotificationHandler] ✅ Banner cleanup - Navigation FREE");
    
    // Trigger refresh
    shouldRefreshTablesNotifier.value = true;
    
    // 🔥 CRITICAL: Process next banner immediately
    Timer(Duration(milliseconds: 100), () {
      _processQueue();
    });
  }

  Color _getBackgroundColorForEvent(String eventType) {
    switch (eventType) {
      case NotificationEventTypes.orderApprovedForKitchen:
        return Colors.green.shade700.withOpacity(0.95);
      case NotificationEventTypes.orderReadyForPickupUpdate:
        return Colors.orange.shade700.withOpacity(0.95);
      case NotificationEventTypes.orderItemAdded:
        return Colors.blue.shade700.withOpacity(0.95);
      case NotificationEventTypes.orderPreparingUpdate:
        return Colors.amber.shade700.withOpacity(0.95);
      default:
        return Colors.blueGrey.shade800.withOpacity(0.95);
    }
  }

  String _getNotificationMessage(String eventType, Map<String, dynamic> data) {
    final orderId = data['order_id'];
    final tableNumber = data['table_number'];
    final tableInfo = tableNumber != null ? ' (Masa $tableNumber)' : '';

    switch (eventType) {
      case NotificationEventTypes.orderApprovedForKitchen:
        return '🍳 Yeni Sipariş #$orderId$tableInfo mutfağa gönderildi!';
      case NotificationEventTypes.orderPreparingUpdate:
        return '⏳ Sipariş #$orderId hazırlanıyor...';
      case NotificationEventTypes.orderReadyForPickupUpdate:
        return '🔔 Sipariş #$orderId hazır - garson bekleniyor!';
      case NotificationEventTypes.orderItemAdded:
        return '➕ Sipariş #$orderId\'e yeni ürün eklendi!';
      case NotificationEventTypes.guestOrderPendingApproval:
        return '⏰ Misafir siparişi onay bekliyor: #$orderId';
      case NotificationEventTypes.existingOrderNeedsReapproval:
        return '🔄 Sipariş #$orderId yeniden onay bekliyor!';
      default:
        return data['message'] ?? '📣 Yeni bildirim!';
    }
  }

  void _playNotificationSound(String eventType) {
    if (_isSoundPlaying || kIsWeb) return;
    if (!_shouldPlaySound(eventType)) return;

    _isSoundPlaying = true;
    debugPrint('🔔 [GlobalNotificationHandler] Ses çalınıyor: $eventType');

    try {
      final isAlarm = _isCriticalEvent(eventType);
      FlutterRingtonePlayer().playNotification(asAlarm: isAlarm);
    } catch (e) {
      debugPrint("Notification ses hatası: $e");
    }

    _soundCooldownTimer?.cancel();
    _soundCooldownTimer = Timer(_soundCooldown, () {
      _isSoundPlaying = false;
      debugPrint('🔔 [GlobalNotificationHandler] Ses cooldown sona erdi');
    });
  }

  bool _shouldPlaySound(String eventType) {
    const soundEvents = {
      NotificationEventTypes.guestOrderPendingApproval,
      NotificationEventTypes.existingOrderNeedsReapproval,
      NotificationEventTypes.orderApprovedForKitchen,
      NotificationEventTypes.orderReadyForPickupUpdate,
      NotificationEventTypes.orderItemAdded,
      NotificationEventTypes.orderPreparingUpdate,
    };
    return soundEvents.contains(eventType);
  }

  bool _isCriticalEvent(String eventType) {
    const criticalEvents = {
      NotificationEventTypes.orderApprovedForKitchen,
      NotificationEventTypes.orderReadyForPickupUpdate,
      NotificationEventTypes.guestOrderPendingApproval,
      NotificationEventTypes.existingOrderNeedsReapproval,
    };
    return criticalEvents.contains(eventType);
  }

  void dispose() {
    _processingTimer?.cancel();
    _soundCooldownTimer?.cancel();
    _navigatorCheckTimer?.cancel();
    _refreshDebounceTimer?.cancel();
    _bannerTimeoutTimer?.cancel();
    
    _notificationQueue.clear();
    _processedBannerIds.clear();
    _pendingRefreshes.clear();
    
    debugPrint("[GlobalNotificationHandler] Sistem dispose edildi.");
  }

  static void cleanup() {
    instance.dispose();
  }
}