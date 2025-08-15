// lib/services/socket_service.dart

import 'notification_center.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/widgets.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:intl/intl.dart';

import 'api_service.dart';
import 'user_session.dart';
import '../utils/notifiers.dart';
import '../models/notification_event_types.dart';

class SocketService extends ChangeNotifier {
  SocketService._privateConstructor();
  static final SocketService instance = SocketService._privateConstructor();

  IO.Socket? _socket;
  final ValueNotifier<String> connectionStatusNotifier =
      ValueNotifier('Bağlantı bekleniyor...');
  final ValueNotifier<List<Map<String, String>>> notificationHistoryNotifier =
      ValueNotifier([]);

  String? _currentKdsRoomSlug;
  bool _isDisposed = false;

  // 🔧 HEARTBEAT SİSTEMİ - HEROKU BAĞLANTI KONTROLÜ
  Timer? _heartbeatTimer;
  int _missedHeartbeats = 0;
  int _maxMissedHeartbeats = 3;
  bool _isHerokuEnv = false; // ApiService.baseUrl'den çıkarılacak
  
  // 🔧 ENHANCED DUPLICATE CONTROL & BACKGROUND QUEUE
  final Set<String> _processedNotificationIds = <String>{};
  final Map<String, DateTime> _lastEventTimes = <String, DateTime>{};
  final List<Map<String, dynamic>> _backgroundEventQueue = <Map<String, dynamic>>[];
  
  // 🔥 YENİ: KDS Priority Queue için ayrı queue
  final List<Map<String, dynamic>> _priorityKdsEventQueue = <Map<String, dynamic>>[];
  
  // 🎯 ULTRA FAST COOLDOWN FOR CRITICAL EVENTS - UPDATED
  static const Map<String, Duration> _eventCooldowns = {
    NotificationEventTypes.orderApprovedForKitchen: Duration(milliseconds: 50),    // Daha da hızlı
    NotificationEventTypes.orderReadyForPickupUpdate: Duration(milliseconds: 50),  // Daha da hızlı
    NotificationEventTypes.orderItemAdded: Duration(milliseconds: 200),             // Hızlandırıldı
    NotificationEventTypes.orderPreparingUpdate: Duration(milliseconds: 500),       // Hızlandırıldı
    NotificationEventTypes.orderCancelledUpdate: Duration(seconds: 1),              // Normal
    NotificationEventTypes.guestOrderPendingApproval: Duration(milliseconds: 100),  // Hızlandırıldı
    NotificationEventTypes.existingOrderNeedsReapproval: Duration(milliseconds: 100), // Hızlandırıldı
  };
  
  // 🔥 YENİ: KDS event'leri için daha da hızlı cooldown
  static const Map<String, Duration> _kdsEventCooldowns = {
    'order_preparing_update': Duration(milliseconds: 25),      // Çok hızlı
    'order_ready_for_pickup_update': Duration(milliseconds: 25), // Çok hızlı  
    'order_item_picked_up': Duration(milliseconds: 50),        // Hızlı
    'order_fully_delivered': Duration(milliseconds: 100),     // Hızlı
  };
  
  static const Duration _defaultCooldown = Duration(seconds: 2);

  IO.Socket? get socket => _socket;
  bool get isConnected => _socket?.connected ?? false;

  // Loud notification events
  static const Set<String> _loudNotificationEvents = {
    NotificationEventTypes.guestOrderPendingApproval,
    NotificationEventTypes.existingOrderNeedsReapproval,
    NotificationEventTypes.orderApprovedForKitchen,
    NotificationEventTypes.orderReadyForPickupUpdate,
    NotificationEventTypes.orderItemAdded,
    NotificationEventTypes.orderPreparingUpdate,
  };

  static const Set<String> _infoNotificationEvents = {
    NotificationEventTypes.waitingCustomerAdded,
    'secondary_info_update',
  };
  
  // 🔥 YENİ: KDS priority event'leri
  static const Set<String> _kdsHighPriorityEvents = {
    'order_preparing_update',
    'order_ready_for_pickup_update', 
    'order_item_picked_up',
    'order_fully_delivered',
  };

  bool checkConnection() {
    return _socket?.connected ?? false;
  }

  // 🔥 HEARTBEAT SİSTEMİ BAŞLATMA
  void _startHeartbeat() {
    _stopHeartbeat(); // Mevcut timer'ı temizle
    
    // Heroku ortamını tespit et
    _isHerokuEnv = ApiService.baseUrl.contains('herokuapp.com') || 
                   ApiService.baseUrl.contains('heroku');
    
    final heartbeatInterval = _isHerokuEnv ? Duration(seconds: 10) : Duration(seconds: 20);
    
    debugPrint('[SocketService] 💓 Heartbeat başlatılıyor - Interval: ${heartbeatInterval.inSeconds}s (Heroku: $_isHerokuEnv)');
    
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      if (_socket?.connected == true) {
        _missedHeartbeats++;
        debugPrint('[SocketService] 💓 Heartbeat gönderiliyor (Kaçırılan: $_missedHeartbeats/$_maxMissedHeartbeats)');
        _socket!.emit('heartbeat', {'timestamp': DateTime.now().millisecondsSinceEpoch});
        
        // Çok fazla heartbeat kaçırılmışsa bağlantıyı yeniden kur
        if (_missedHeartbeats >= _maxMissedHeartbeats) {
          debugPrint('[SocketService] 💔 Çok fazla heartbeat kaçırıldı ($_missedHeartbeats), bağlantı yenileniyor...');
          _forceReconnect();
        }
      } else {
        debugPrint('[SocketService] 💔 Heartbeat için socket bağlı değil');
      }
    });
  }

  // 🔥 HEARTBEAT SİSTEMİ DURDURMA
  void _stopHeartbeat() {
    if (_heartbeatTimer != null) {
      _heartbeatTimer!.cancel();
      _heartbeatTimer = null;
      debugPrint('[SocketService] 💓 Heartbeat durduruldu');
    }
  }

  // 🔥 ZORLA YENİDEN BAĞLANMA
  void _forceReconnect() {
    debugPrint('[SocketService] 🔄 Zorla yeniden bağlanma başlatılıyor...');
    
    _stopHeartbeat();
    _missedHeartbeats = 0;
    
    if (_socket != null) {
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
    }
    
    // Biraz bekleyip yeniden bağlan
    Future.delayed(Duration(seconds: 2), () {
      if (!_isDisposed) {
        connectAndListen();
      }
    });
  }

  // 🔥 YENİ: KDS event kontrolü
  bool _isKdsEvent(String? eventType) {
    if (eventType == null) return false;
    
    return _kdsHighPriorityEvents.contains(eventType) ||
           eventType.contains('preparing') || 
           eventType.contains('ready_for_pickup') ||
           eventType.contains('picked_up') ||
           eventType.contains('kds');
  }

  // 🔧 ULTRA-SMART NOTIFICATION CONTROL - Enhanced for KDS
  bool _shouldProcessNotification(String? notificationId, String? eventType) {
    final now = DateTime.now();
    
    // 🔥 YENİ: KDS event'leri için farklı cooldown stratejisi
    final isKdsEvent = _isKdsEvent(eventType);
    
    // 🎯 ENHANCED DUPLICATE CHECK - More lenient for KDS events
    if (notificationId != null) {
      // KDS event'leri için daha kısa duplicate timeout
      final duplicateTimeout = isKdsEvent ? 10 : 30;
      
      final existingTime = _processedNotificationIds.contains(notificationId) 
          ? _lastEventTimes[notificationId] 
          : null;
      
      if (existingTime != null && now.difference(existingTime).inSeconds < duplicateTimeout) {
        debugPrint('📨 [SocketService] Recent duplicate engellendi: $notificationId ${isKdsEvent ? "[KDS]" : ""}');
        return false;
      }
      
      _processedNotificationIds.add(notificationId);
      _lastEventTimes[notificationId] = now;
    }
    
    // 🚀 EVENT-SPECIFIC COOLDOWN - Ultra fast for KDS events
    if (eventType != null) {
      final cooldownKey = '${eventType}_cooldown';
      final lastTime = _lastEventTimes[cooldownKey];
      
      // KDS event'leri için özel cooldown süreleri
      Duration cooldownDuration;
      if (isKdsEvent && _kdsEventCooldowns.containsKey(eventType)) {
        cooldownDuration = _kdsEventCooldowns[eventType]!;
      } else {
        cooldownDuration = _eventCooldowns[eventType] ?? _defaultCooldown;
      }
      
      if (lastTime != null && now.difference(lastTime) < cooldownDuration) {
        final remainingMs = cooldownDuration.inMilliseconds - now.difference(lastTime).inMilliseconds;
        debugPrint('📨 [SocketService] Event cooldown: $eventType (${remainingMs}ms kaldı) ${isKdsEvent ? "[KDS]" : ""}');
        return false;
      }
      
      _lastEventTimes[cooldownKey] = now;
    }
    
    // 🔧 AGGRESSIVE CLEANUP - Keep only recent entries
    if (_processedNotificationIds.length > 50) { // KDS için daha büyük buffer
      final oldEntries = _processedNotificationIds.take(25).toList();
      _processedNotificationIds.removeAll(oldEntries);
      oldEntries.forEach(_lastEventTimes.remove);
      debugPrint('📨 [SocketService] ${oldEntries.length} eski ID temizlendi');
    }
    
    // Event cooldown cleanup - 3 minutes for KDS, 5 for others
    final cleanupTimeout = isKdsEvent ? Duration(minutes: 3) : Duration(minutes: 5);
    final cooldownKeysToRemove = <String>[];
    for (final entry in _lastEventTimes.entries) {
      if (entry.key.endsWith('_cooldown') && now.difference(entry.value) > cleanupTimeout) {
        cooldownKeysToRemove.add(entry.key);
      }
    }
    cooldownKeysToRemove.forEach(_lastEventTimes.remove);
    
    debugPrint('📨 [SocketService] ✅ Event kabul edildi: ${notificationId ?? 'ID_YOK'} - $eventType ${isKdsEvent ? "🔥[KDS]" : ""}');
    return true;
  }

  // 🔥 YENİ: Priority KDS queue işleme
  void _processPriorityKdsQueue() {
    if (_priorityKdsEventQueue.isEmpty) return;
    
    debugPrint('📨 [SocketService] 🔥 Priority KDS queue işleniyor: ${_priorityKdsEventQueue.length} events');
    
    final eventsToProcess = List<Map<String, dynamic>>.from(_priorityKdsEventQueue);
    _priorityKdsEventQueue.clear();
    
    for (final event in eventsToProcess) {
      debugPrint('📨 [SocketService] 🔥 Priority KDS event işleniyor: ${event['event_type']}');
      _processEventData(event, isBackgroundProcessing: true, isPriorityKds: true);
    }
  }

  // 🔄 PROCESS BACKGROUND QUEUE WHEN SCREEN BECOMES ACTIVE - Enhanced
  void _processBackgroundQueue() {
    // Önce priority KDS event'leri işle
    _processPriorityKdsQueue();
    
    if (_backgroundEventQueue.isEmpty) return;
    
    debugPrint('📨 [SocketService] 🔄 Background queue işleniyor: ${_backgroundEventQueue.length} events');
    
    final eventsToProcess = List<Map<String, dynamic>>.from(_backgroundEventQueue);
    _backgroundEventQueue.clear();
    
    for (final event in eventsToProcess) {
      debugPrint('📨 [SocketService] Background event işleniyor: ${event['event_type']}');
      _processEventData(event, isBackgroundProcessing: true);
    }
  }

  void _processEventData(Map<String, dynamic> data, {bool isBackgroundProcessing = false, bool isPriorityKds = false}) {
    final String? eventType = data['event_type'] as String?;
    
    if (eventType == null) return;

    // 🔥 YENİ: KDS event'leri için özel işlem
    final isKdsEvent = _isKdsEvent(eventType);
    
    if (isPriorityKds || isKdsEvent) {
      debugPrint('📨 [SocketService] 🔥 KDS Priority event processing: $eventType');
      // KDS için önce priority notification gönder
      NotificationCenter.instance.postNotification(
        'kds_priority_update',
        data
      );
    }

    final String? kdsSlug = data['kds_slug'] as String?;
    if (kdsSlug != null) {
      kdsUpdateNotifier.value = Map<String, dynamic>.from(data);
    } else {
      orderStatusUpdateNotifier.value = Map<String, dynamic>.from(data);
    }

    if (!isBackgroundProcessing) {
      shouldRefreshTablesNotifier.value = true;
      
      // 🆕 YENI: NotificationCenter üzerinden global refresh tetikle
      _triggerGlobalRefresh(eventType, data, isKdsEvent: isKdsEvent);
    }

    // 🔧 NULL SAFETY FIX: eventType null kontrolü eklendi
    if (eventType != null && UserSession.hasNotificationPermission(eventType)) {
      debugPrint("[SocketService] Bildirim izni var: $eventType ${isKdsEvent ? '🔥[KDS]' : ''}");
      _addNotificationToHistory(data['message'] ?? 'Güncelleme', eventType);

      // 🔧 SEND TO NOTIFICATION HANDLER
      if (_loudNotificationEvents.contains(eventType)) {
        debugPrint("[SocketService] 🎯 Loud event - GlobalNotificationHandler'a gönderiliyor: $eventType");
        newOrderNotificationDataNotifier.value = Map<String, dynamic>.from(data);
      } else if (_infoNotificationEvents.contains(eventType)) {
        informationalNotificationNotifier.value = Map<String, dynamic>.from(data);
      }
    } else {
      debugPrint("[SocketService] Bildirim izni yok: $eventType");
    }
  }

  // 🆕 YENI: Global refresh tetikleyici - Enhanced for KDS
  void _triggerGlobalRefresh(String eventType, Map<String, dynamic> data, {bool isKdsEvent = false}) {
    if (isKdsEvent) {
      // KDS event'leri için önce priority notification
      NotificationCenter.instance.postNotification(
        'kds_priority_update',
        data
      );
      debugPrint("[SocketService] 🔥 KDS Priority refresh tetiklendi: $eventType");
    }
    
    // Sonra normal global refresh
    NotificationCenter.instance.postNotification(
      'refresh_all_screens',
      {'eventType': eventType, 'data': data}
    );
    debugPrint("[SocketService] 📡 Global refresh tetiklendi: $eventType ${isKdsEvent ? '🔥[KDS]' : ''}");
  }

  void connectAndListen() {
    if (_isDisposed) {
      debugPrint("[SocketService] Dispose edilmiş servis yeniden canlandırılıyor.");
      _isDisposed = false;
    }

    if (_socket != null && _socket!.connected) {
      debugPrint("[SocketService] Zaten bağlı.");
      if (_currentKdsRoomSlug != null && UserSession.token.isNotEmpty) {
        joinKdsRoom(_currentKdsRoomSlug!);
      }
      return;
    }

    if (UserSession.token.isEmpty) {
      debugPrint("[SocketService] Token bulunamadığı için socket bağlantısı kurulmuyor.");
      connectionStatusNotifier.value = 'Bağlantı için token gerekli.';
      return;
    }

    String baseSocketUrl = ApiService.baseUrl.replaceAll('/api', '');
    if (baseSocketUrl.endsWith('/')) {
      baseSocketUrl = baseSocketUrl.substring(0, baseSocketUrl.length - 1);
    }

    _socket = IO.io(
      baseSocketUrl,
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setPath('/socket.io/')
          .setAuth({'token': UserSession.token})
          .disableAutoConnect()
          .setTimeout(20000)
          .setReconnectionAttempts(5)
          .setReconnectionDelay(3000)
          .build(),
    );

    _registerListeners();
    if (_socket?.connected == false) {
      _socket!.connect();
    }
    debugPrint("[SocketService] Socket bağlantısı deneniyor: $baseSocketUrl");
  }

  void _registerListeners() {
    if (_socket == null) return;
    _socket!.clearListeners();

    _socket!.onConnect((_) {
      debugPrint("🔌 [SocketService] Fiziksel bağlantı kuruldu. SID: ${_socket?.id}");
      connectionStatusNotifier.value = 'Sunucu onayı bekleniyor...';
      _missedHeartbeats = 0; // Reset heartbeat counter
    });

    _socket!.on('connected_and_ready', (_) {
      debugPrint("✅ [SocketService] 'connected_and_ready' onayı alındı.");
      connectionStatusNotifier.value = 'Bağlandı';
      
      // 🔥 HEARTBEAT SİSTEMİNİ BAŞLAT
      _startHeartbeat();

      if (_currentKdsRoomSlug != null && UserSession.token.isNotEmpty) {
        joinKdsRoom(_currentKdsRoomSlug!);
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        shouldRefreshTablesNotifier.value = true;
        shouldRefreshWaitingCountNotifier.value = true;
        
        // 🔄 Process any queued background events (priority first)
        _processBackgroundQueue();
      });
      _addNotificationToHistory("Bağlantı başarılı.", "system_connect");
    });

    // 🔥 HEARTBEAT RESPONSE DİNLEYİCİSİ
    _socket!.on('heartbeat_response', (_) {
      _missedHeartbeats = 0; // Reset counter on successful heartbeat response
      debugPrint('[SocketService] 💚 Heartbeat response alındı (Kaçırılan: $_missedHeartbeats)');
    });

    _socket!.onDisconnect((reason) {
      debugPrint("🔌 [SocketService] Bağlantı koptu. Sebep: $reason");
      connectionStatusNotifier.value = 'Bağlantı koptu. Tekrar deneniyor...';
      _addNotificationToHistory("Bağlantı koptu.", "system_disconnect");
      
      // 🔥 HEARTBEAT DURDUR
      _stopHeartbeat();

      Future.delayed(Duration(seconds: 2 + Random().nextInt(3)), () {
        if (!_isDisposed && (_socket == null || !_socket!.connected)) {
          debugPrint("[SocketService] Otomatik yeniden bağlanma deneniyor...");
          connectAndListen();
        }
      });
    });

    _socket!.onConnectError((data) {
      debugPrint("❌ [SocketService] Bağlantı Hatası: $data");
      connectionStatusNotifier.value = 'Bağlantı hatası.';
      _addNotificationToHistory("Bağlantı hatası.", "system_connect_error");
      _stopHeartbeat(); // Heartbeat'i durdur
    });

    _socket!.onError((data) {
      debugPrint("❗ [SocketService] Genel Hata: $data");
      _addNotificationToHistory("Sistem hatası.", "system_error");
    });

    // 🔧 ENHANCED NOTIFICATION HANDLER - Priority KDS support
    _socket!.on('order_status_update', (data) {
      if (data is! Map<String, dynamic>) return;

      final String? notificationId = data['notification_id'] as String?;
      final String? eventType = data['event_type'] as String?;
      
      debugPrint("📨 [SocketService] Event alındı: $eventType, ID: $notificationId");

      if (!_shouldProcessNotification(notificationId, eventType)) {
        return;
      }

      debugPrint("📨 [SocketService] ✅ İşleniyor: $eventType");

      // 🔥 YENİ: KDS event kontrolü
      final isKdsEvent = _isKdsEvent(eventType);
      
      // 🔧 CHECK IF MAIN SCREEN IS ACTIVE
      final isMainScreenActive = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      
      if (!isMainScreenActive) {
        if (isKdsEvent) {
          debugPrint("📨 [SocketService] 🔥 KDS event - priority queue'ya ekleniyor: $eventType");
          _priorityKdsEventQueue.add(Map<String, dynamic>.from(data));
        } else {
          debugPrint("📨 [SocketService] 📱 Ekran aktif değil, background queue'ya ekleniyor: $eventType");
          _backgroundEventQueue.add(Map<String, dynamic>.from(data));
        }
        
        // Still process critical events immediately for notifications
        if (eventType != null && _loudNotificationEvents.contains(eventType) && UserSession.hasNotificationPermission(eventType)) {
          debugPrint("[SocketService] 🚨 Critical event - immediate notification: $eventType");
          newOrderNotificationDataNotifier.value = Map<String, dynamic>.from(data);
        }
        return;
      }

      _processEventData(data, isPriorityKds: isKdsEvent);
    });

    // Waiting list - unchanged
    _socket!.on('waiting_list_update', (data) {
      debugPrint("📨 [SocketService] 'waiting_list_update' alındı: $data");
      if (data is! Map<String, dynamic>) return;

      final String? eventType = data['event_type'] as String?;
      // 🔧 NULL SAFETY FIX: eventType null kontrolü eklendi
      if (eventType == null || !UserSession.hasNotificationPermission(eventType)) {
        return;
      }

      _addNotificationToHistory(data['message'] ?? 'Bekleme listesi güncellendi.', eventType);
      waitingListChangeNotifier.value = Map<String, dynamic>.from(data);
      shouldRefreshWaitingCountNotifier.value = true;

      if (eventType == NotificationEventTypes.waitingCustomerAdded) {
        if (!kIsWeb) {
          try {
            FlutterRingtonePlayer().playNotification();
          } catch (e) {
            debugPrint("Ringtone error (waiting): $e");
          }
        }
      }
    });

    _socket!.on('pager_event', (data) {
      debugPrint("📨 [SocketService] 'pager_event' alındı: $data");
      if (data is Map<String, dynamic> && data['event_type'] == 'pager_status_updated') {
        _addNotificationToHistory(data['message'] ?? 'Pager durumu güncellendi.', 'pager_status_updated');
        pagerStatusUpdateNotifier.value = Map<String, dynamic>.from(data);
      }
    });

    _socket!.on('stock_alert', (data) {
      debugPrint("📨 [SocketService] 'stock_alert' alındı: $data");
      if (data is Map<String, dynamic> && data['alert'] is bool) {
        _addNotificationToHistory(data['message'] ?? 'Stok durumu güncellendi.', 'stock_adjusted');
        stockAlertNotifier.value = data['alert'];
      }
    });

    debugPrint("[SocketService] Tüm socket listener'ları kaydedildi.");
  }

  void _addNotificationToHistory(String message, String eventType) {
    final timeStampedMessage = '[${DateFormat('HH:mm:ss').format(DateTime.now())}] $message';
    final currentHistory = List<Map<String, String>>.from(notificationHistoryNotifier.value);
    currentHistory.insert(0, {'message': timeStampedMessage, 'eventType': eventType});
    if (currentHistory.length > 100) {
      currentHistory.removeLast();
    }
    notificationHistoryNotifier.value = currentHistory;
  }

  void joinKdsRoom(String kdsSlug) {
    if (_socket != null && _socket!.connected) {
      if (UserSession.token.isEmpty) {
        debugPrint("[SocketService] KDS odasına katılmak için token gerekli, ancak token yok.");
        return;
      }

      final payload = {'token': UserSession.token, 'kds_slug': kdsSlug};
      debugPrint("[SocketService] 'join_kds_room' eventi gönderiliyor. Slug: $kdsSlug");
      _socket!.emit('join_kds_room', payload);
      _currentKdsRoomSlug = kdsSlug;
    } else {
      _currentKdsRoomSlug = kdsSlug;
      debugPrint("[SocketService] Socket bağlı değil. KDS odasına katılım isteği bağlantı kurulunca yapılacak.");
      if (_socket?.connected == false && UserSession.token.isNotEmpty) {
        _socket?.connect();
      }
    }
  }

  void reset() {
    if (_socket != null && _socket!.connected) {
      debugPrint("[SocketService] Bağlantı resetleniyor...");
      _socket!.disconnect();
    }
    _socket?.clearListeners();
    _socket?.dispose();
    _socket = null;
    _currentKdsRoomSlug = null;
    connectionStatusNotifier.value = 'Bağlantı bekleniyor...';
    
    // 🔥 HEARTBEAT DURDUR
    _stopHeartbeat();
    _missedHeartbeats = 0;
    
    // Cleanup - Enhanced for KDS
    _processedNotificationIds.clear();
    _lastEventTimes.clear();
    _backgroundEventQueue.clear();
    _priorityKdsEventQueue.clear(); // 🔥 YENİ
    
    debugPrint("[SocketService] Servis durumu sıfırlandı.");
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    debugPrint("[SocketService] Dispose ediliyor...");
    _stopHeartbeat(); // 🔥 HEARTBEAT DURDUR
    reset();
    super.dispose();
    debugPrint("[SocketService] Dispose tamamlandı.");
  }

  // 🔧 PUBLIC METHODS FOR BACKGROUND PROCESSING - ENHANCED for KDS
  void onScreenBecameActive() {
    debugPrint("[SocketService] 📱 Ekran aktif oldu, background queue işleniyor");
    _processBackgroundQueue(); // Priority KDS queue da işlenir
    
    // NotificationCenter üzerinden tüm ekranları bilgilendir
    NotificationCenter.instance.postNotification(
      'screen_became_active',
      {'timestamp': DateTime.now().toIso8601String()}
    );
  }

  // 🔥 YENİ: KDS event'leri için özel debug
  void debugPrintKdsStatus() {
    debugPrint('[SocketService] 🔥 KDS Status:');
    debugPrint('  - Priority KDS queue: ${_priorityKdsEventQueue.length} events');
    debugPrint('  - Current KDS room: $_currentKdsRoomSlug');
    debugPrint('  - KDS events processed: ${_lastEventTimes.keys.where((k) => k.contains('kds') || _kdsHighPriorityEvents.any((e) => k.contains(e))).length}');
  }

  // Debug methods - Enhanced
  void debugPrintCooldownStatus() {
    final now = DateTime.now();
    debugPrint('[SocketService] 📊 Cooldown Status:');
    
    // KDS events önce
    debugPrint('  🔥 KDS Events:');
    for (final kdsEvent in _kdsHighPriorityEvents) {
      final cooldownKey = '${kdsEvent}_cooldown';
      final lastTime = _lastEventTimes[cooldownKey];
      if (lastTime != null) {
        final cooldown = _kdsEventCooldowns[kdsEvent] ?? Duration(milliseconds: 100);
        final remaining = cooldown.inMilliseconds - now.difference(lastTime).inMilliseconds;
        debugPrint('    - $kdsEvent: ${remaining > 0 ? "${remaining}ms kaldı" : "✅ Hazır"}');
      }
    }
    
    // Diğer events
    debugPrint('  📋 Other Events:');
    for (final entry in _lastEventTimes.entries) {
      if (entry.key.endsWith('_cooldown') && !_kdsHighPriorityEvents.any((e) => entry.key.contains(e))) {
        final eventType = entry.key.replaceAll('_cooldown', '');
        final cooldown = _eventCooldowns[eventType] ?? _defaultCooldown;
        final remaining = cooldown.inMilliseconds - now.difference(entry.value).inMilliseconds;
        debugPrint('    - $eventType: ${remaining > 0 ? "${remaining}ms kaldı" : "✅ Hazır"}');
      }
    }
    
    debugPrint('  📊 Queues:');
    debugPrint('    - Priority KDS queue: ${_priorityKdsEventQueue.length} events');
    debugPrint('    - Background queue: ${_backgroundEventQueue.length} events');
    debugPrint('    - Processed IDs: ${_processedNotificationIds.length}');
    debugPrint('  💓 Heartbeat Status:');
    debugPrint('    - Heroku Environment: $_isHerokuEnv');
    debugPrint('    - Missed Heartbeats: $_missedHeartbeats/$_maxMissedHeartbeats');
    debugPrint('    - Heartbeat Active: ${_heartbeatTimer?.isActive ?? false}');
  }
}