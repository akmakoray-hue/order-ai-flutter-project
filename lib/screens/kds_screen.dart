// lib/screens/kds_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:collection/collection.dart';

import '../services/kds_service.dart';
import '../services/socket_service.dart';
import '../services/user_session.dart';
import '../widgets/kds/kds_order_card.dart';
import '../widgets/dialogs/order_approved_for_kitchen_dialog.dart';
import '../widgets/dialogs/order_ready_for_pickup_dialog.dart';
import '../utils/notifiers.dart';
import '../models/notification_event_types.dart';
import '../models/kds_screen_model.dart';
import '../main.dart';
import 'package:flutter/foundation.dart';

class KdsScreen extends StatefulWidget {
  final String token;
  final int businessId;
  final String kdsScreenSlug;
  final String kdsScreenName;
  final VoidCallback? onGoHome;
  final SocketService socketService;

  const KdsScreen({
    Key? key,
    required this.token,
    required this.businessId,
    required this.kdsScreenSlug,
    required this.kdsScreenName,
    this.onGoHome,
    required this.socketService,
  }) : super(key: key);

  @override
  _KdsScreenState createState() => _KdsScreenState();
}

class _KdsScreenState extends State<KdsScreen> 
    with RouteAware, WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  
  List<dynamic> _kdsOrders = [];
  bool _isLoading = true;
  String _errorMessage = '';
  Timer? _refreshTimer;
  bool _isInitialLoadComplete = false;
  bool _isDialogShowing = false;

  // Ekran durumu takibi
  bool _isCurrent = false;
  bool _isAppInForeground = true;
  bool _isJoinedToRoom = false;
  bool _isDisposed = false;
  bool _isNavigationInProgress = false;
  DateTime? _lastRefreshTime;

  // Pending notifications store
  List<Map<String, dynamic>> _pendingNotifications = [];

  // Dialog yönetimi için kontroller
  bool _dialogBlocked = false;
  Timer? _dialogBlockTimer;
  final Set<String> _activeDialogs = <String>{};
  
  // 🚨 Multi-Strategy Recovery System
  Timer? _immediateRecoveryTimer;
  Timer? _shortDelayRecoveryTimer;
  Timer? _mediumDelayRecoveryTimer;
  Timer? _forceRecoveryTimer;
  Timer? _roomStabilityTimer;
  bool _isProcessingPending = false;
  bool _recoveryInProgress = false;
  
  // App resume tracking with stability
  DateTime? _lastBackgroundTime;
  DateTime? _lastRoomJoinTime;
  bool _needsDataRefreshOnResume = false;
  bool _roomConnectionStable = false;
  int _roomJoinAttempts = 0;

  // 🆕 YENI: NotificationCenter callback function'ları
  late Function(Map<String, dynamic>) _refreshAllScreensCallback;
  late Function(Map<String, dynamic>) _screenBecameActiveCallback;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 🚀 initState with Multi-Strategy Recovery & NotificationCenter");
    
    WidgetsBinding.instance.addObserver(this);
    
    // Notifier listeners
    orderStatusUpdateNotifier.addListener(_handleSocketOrderUpdate);
    newOrderNotificationDataNotifier.addListener(_handleLoudNotification);

    // 🆕 YENI: NotificationCenter listener'ları ekle
    _refreshAllScreensCallback = (data) {
      if (!_isDisposed && mounted && _shouldProcessUpdate()) {
        final eventType = data['eventType'] as String?;
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 📡 Global refresh received: $eventType");
        _safeRefreshDataWithThrottling();
      }
    };

    _screenBecameActiveCallback = (data) {
      if (!_isDisposed && mounted && _isCurrent) {
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 📱 Screen became active notification received");
        _processPendingNotifications();
      }
    };

    NotificationCenter.instance.addObserver('refresh_all_screens', _refreshAllScreensCallback);
    NotificationCenter.instance.addObserver('screen_became_active', _screenBecameActiveCallback);

    // Initial setup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] PostFrameCallback - Initialization completed.");
        _joinKdsRoomWithStability();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] RouteObserver subscribed.');
    }
    
    if (!_isInitialLoadComplete) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] didChangeDependencies - Initial data fetch.');
      _fetchKdsOrdersWithLoadingIndicator();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 🔄 dispose with cleanup");
    
    _cleanupDialogs();
    
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    
    // 🚨 Tüm recovery timer'larını iptal et
    _cancelAllRecoveryTimers();
    _refreshTimer?.cancel();
    _dialogBlockTimer?.cancel();
    _roomStabilityTimer?.cancel();
    
    orderStatusUpdateNotifier.removeListener(_handleSocketOrderUpdate);
    newOrderNotificationDataNotifier.removeListener(_handleLoudNotification);
    
    // 🆕 YENI: NotificationCenter listener'ları kaldır
    NotificationCenter.instance.removeObserver('refresh_all_screens', _refreshAllScreensCallback);
    NotificationCenter.instance.removeObserver('screen_became_active', _screenBecameActiveCallback);
    
    _leaveKdsRoom();
    
    super.dispose();
  }

  // 🚨 Recovery timer'larını iptal et
  void _cancelAllRecoveryTimers() {
    _immediateRecoveryTimer?.cancel();
    _shortDelayRecoveryTimer?.cancel();
    _mediumDelayRecoveryTimer?.cancel();
    _forceRecoveryTimer?.cancel();
  }

  void _cleanupDialogs() {
    _dialogBlocked = true;
    _isDialogShowing = false;
    _activeDialogs.clear();
    
    NavigatorSafeZone.markBusy('dialog_cleanup');
    
    final context = navigatorKey.currentContext;
    if (context != null) {
      try {
        Navigator.of(context).popUntil((route) {
          return route is! DialogRoute;
        });
      } catch (e) {
        debugPrint('[KdsScreen] Dialog cleanup error: $e');
      }
    }
    
    Timer(Duration(milliseconds: 300), () {
      NavigatorSafeZone.markFree('dialog_cleanup');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
        _lastBackgroundTime = DateTime.now();
        _needsDataRefreshOnResume = true;
        _roomConnectionStable = false;
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ⏸️ App paused at ${_lastBackgroundTime}');
        
        // 🔧 Smart delayed emergency stop - hızlı geçişleri filtrele
        Timer(const Duration(milliseconds: 800), () {
          if (!mounted || _isDisposed) return;
          if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
            _emergencyStopAllOperations();
            debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🛑 Emergency stop executed after delay');
          }
        });
        break;
        
      case AppLifecycleState.resumed:
        _isAppInForeground = true;
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ▶️ App resumed - smart recovery starting');
        
        // 🚨 Smart recovery with multiple strategies
        _smartMultiRecovery();
        break;
        
      case AppLifecycleState.hidden:
        _lastBackgroundTime = DateTime.now();
        _needsDataRefreshOnResume = true;
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 👁️ App hidden - light mode');
        break;
        
      case AppLifecycleState.inactive:
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 💤 App inactive - ignored');
        break;
        
      default:
        break;
    }
  }

  // 🚨 Smart Multi Recovery System
  void _smartMultiRecovery() {
    if (_isDisposed || !mounted || _recoveryInProgress) return;
    
    _recoveryInProgress = true;
    _cancelAllRecoveryTimers();
    
    // Background duration analizi
    final backgroundDuration = _lastBackgroundTime != null 
        ? DateTime.now().difference(_lastBackgroundTime!) 
        : Duration.zero;
        
    final isLongBackground = backgroundDuration.inSeconds > 30;
    final isShortBackground = backgroundDuration.inSeconds < 2;
    
    debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🧠 Smart Multi Recovery - Background: ${backgroundDuration.inSeconds}s');
    
    if (isShortBackground) {
      // Hızlı geçiş - sadece immediate recovery
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ⚡ Fast transition detected - minimal recovery');
      _immediateRecoveryTimer = Timer(const Duration(milliseconds: 50), () {
        _attemptRecovery('fast_transition');
        _recoveryInProgress = false;
      });
      return;
    }
    
    // Strategy 1: Immediate attempt (100ms delay)
    _immediateRecoveryTimer = Timer(const Duration(milliseconds: 100), () {
      if (!_isDisposed && mounted && _isCurrent) {
        if (_attemptRecovery('immediate')) {
          debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ✅ Immediate recovery successful');
          _recoveryInProgress = false;
          return;
        }
      }
    });
    
    // Strategy 2: Short delay (500ms)
    _shortDelayRecoveryTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_isDisposed && mounted && _isCurrent && _recoveryInProgress) {
        if (_attemptRecovery('short_delay')) {
          debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ✅ Short delay recovery successful');
          _recoveryInProgress = false;
          return;
        }
      }
    });
    
    // Strategy 3: Medium delay (1.5s) - for longer backgrounds
    if (isLongBackground) {
      _mediumDelayRecoveryTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!_isDisposed && mounted && _isCurrent && _recoveryInProgress) {
          if (_attemptRecovery('medium_delay_refresh')) {
            debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ✅ Medium delay recovery with refresh successful');
            _recoveryInProgress = false;
            return;
          }
        }
      });
    }
    
    // Strategy 4: Force recovery (3s) - ignore locks
    _forceRecoveryTimer = Timer(const Duration(seconds: 3), () {
      if (!_isDisposed && mounted && _isCurrent && _recoveryInProgress) {
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🔥 Force recovery attempt - bypassing locks');
        _forceRecovery();
        _recoveryInProgress = false;
      }
    });
  }

  // 🚨 Attempt recovery with different strategies
  bool _attemptRecovery(String strategy) {
    // Lifecycle check
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Recovery blocked - not resumed ($strategy)');
      return false;
    }
    
    // Navigator check (relaxed for immediate/fast strategies)
    final bypassLocks = strategy.contains('immediate') || strategy.contains('fast');
    if (!bypassLocks && (NavigatorSafeZone.isBusy || BuildLockManager.isLocked)) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Recovery blocked - Navigator/Build busy ($strategy)');
      return false;
    }
    
    try {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🔄 Recovery ($strategy) starting...');
      
      _dialogBlocked = false;
      
      // Free locks if not bypassing
      if (!bypassLocks) {
        NavigatorSafeZone.markFree('emergency_stop');
      }
      
      // Smart room join with stability
      _joinKdsRoomWithStability();
      
      // Smart data refresh based on strategy
      if (strategy.contains('refresh') || strategy.contains('medium') || _needsDataRefreshOnResume) {
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🔄 Force refreshing stale data');
        _forceFreshDataRefresh();
      } else if (!strategy.contains('fast')) {
        _safeRefreshDataWithThrottling();
      }
      
      // Process pending notifications with strategy-based delay
      final delay = strategy.contains('immediate') || strategy.contains('fast') 
          ? Duration(milliseconds: 100) 
          : Duration(milliseconds: 400);
          
      Timer(delay, () {
        if (!_isDisposed && mounted) {
          _processPendingNotifications();
        }
      });
      
      _needsDataRefreshOnResume = false;
      
      return true;
    } catch (e) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Recovery ($strategy) failed: $e');
      return false;
    }
  }

  // 🚨 Force recovery - ignore all locks
  void _forceRecovery() {
    try {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🔥 FORCE recovery - ignoring all locks and constraints');
      
      _dialogBlocked = false;
      _isProcessingPending = false;
      
      // Force free all locks
      NavigatorSafeZone.markFree('emergency_stop');
      NavigatorSafeZone.markFree('force_recovery');
      BuildLockManager.unlockBuild('force_recovery');
      
      // Force room join
      _forceJoinKdsRoom();
      
      // Force data refresh
      _forceFreshDataRefresh();
      
      Timer(const Duration(milliseconds: 300), () {
        if (!_isDisposed && mounted) {
          _processPendingNotifications();
        }
      });
      
      _needsDataRefreshOnResume = false;
      
    } catch (e) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Force recovery failed: $e');
    }
  }

  // 🚨 Smart Room Join with Stability
  void _joinKdsRoomWithStability() {
    if (!_isCurrent || _isDisposed || !mounted) return;
    
    // Prevent rapid join/leave cycles
    final now = DateTime.now();
    if (_lastRoomJoinTime != null && now.difference(_lastRoomJoinTime!).inMilliseconds < 1000) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🚫 Room join throttled - too frequent');
      return;
    }
    
    _lastRoomJoinTime = now;
    _roomJoinAttempts++;
    
    if (!widget.socketService.isConnected) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🚫 Socket not connected, scheduling retry');
      // Retry after socket connects
      Timer(const Duration(seconds: 2), () {
        if (!_isDisposed && mounted && widget.socketService.isConnected) {
          _joinKdsRoomWithStability();
        }
      });
      return;
    }
    
    try {
      widget.socketService.joinKdsRoom(widget.kdsScreenSlug);
      _isJoinedToRoom = true;
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ✅ Joined KDS room (attempt: $_roomJoinAttempts)');
      
      // Mark as stable after successful join
      _roomStabilityTimer?.cancel();
      _roomStabilityTimer = Timer(const Duration(seconds: 3), () {
        _roomConnectionStable = true;
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🟢 Room connection marked as stable');
      });
      
    } catch (e) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ❌ Room join failed: $e');
      _isJoinedToRoom = false;
    }
  }

  // 🚨 Force Room Join (bypasses all checks)
  void _forceJoinKdsRoom() {
    try {
      if (widget.socketService.isConnected) {
        widget.socketService.joinKdsRoom(widget.kdsScreenSlug);
        _isJoinedToRoom = true;
        _roomConnectionStable = true;
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🔥 FORCE joined KDS room');
      }
    } catch (e) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Force room join failed: $e');
    }
  }

  // Force data refresh
  void _forceFreshDataRefresh() {
    if (_isDisposed || !mounted) return;
    
    // Throttling'i bypass et
    _lastRefreshTime = null;
    
    debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 💪 Force fresh data refresh');
    _fetchKdsOrders();
  }

  // 🆕 YENI: Throttled refresh using RefreshManager
  void _safeRefreshDataWithThrottling() {
    if (_isNavigationInProgress || _isDisposed || !mounted) return;
    
    if (_shouldProcessUpdate()) {
      final refreshKey = 'kds_screen_${widget.kdsScreenSlug}';
      RefreshManager.throttledRefresh(refreshKey, () async {
        await _fetchKdsOrders();
      });
    }
  }

  void _emergencyStopAllOperations() {
    _isNavigationInProgress = false;
    _isAppInForeground = false;
    _dialogBlocked = true;
    _isDialogShowing = false;
    _activeDialogs.clear();
    _isProcessingPending = false;
    _recoveryInProgress = false;
    _roomConnectionStable = false;
    
    // Tüm timer'ları durdur
    _cancelAllRecoveryTimers();
    _dialogBlockTimer?.cancel();
    _refreshTimer?.cancel();
    _roomStabilityTimer?.cancel();
    
    NavigatorSafeZone.markBusy('emergency_stop');
    
    debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🛑 Emergency stop - all operations halted');
  }

  void _blockDialogsTemporarily() {
    _dialogBlocked = true;
    _dialogBlockTimer?.cancel();
    
    _dialogBlockTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_isDisposed) {
        _dialogBlocked = false;
      }
    });
  }

  void _unblockDialogs() {
    _dialogBlockTimer?.cancel();
    _dialogBlocked = false;
  }

  // RouteAware metodları
  @override
  void didPush() {
    _isCurrent = true;
    debugPrint("[KdsScreen-${widget.kdsScreenSlug}] ➡️ didPush - Screen pushed.");
    _joinKdsRoomWithStability();
    super.didPush();
  }

  @override
  void didPopNext() {
    if (_isDisposed) return;
    _isCurrent = true;
    debugPrint("[KdsScreen-${widget.kdsScreenSlug}] ⬅️ didPopNext - Screen returned to foreground.");
    
    _unblockDialogs();
    
    // PostFrameCallback ile data refresh check
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isDisposed && mounted) {
        if (_roomConnectionStable) {
          // Eğer uzun süre başka ekrandaydık, data refresh yap
          if (_needsDataRefreshOnResume) {
            debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 🔄 didPopNext - refreshing stale data');
            _forceFreshDataRefresh();
            _needsDataRefreshOnResume = false;
          } else {
            _safeRefreshDataWithThrottling();
          }
          _processPendingNotifications();
        } else {
          _joinKdsRoomWithStability();
        }
      }
    });
    super.didPopNext();
  }

  @override
  void didPushNext() {
    if (_isDisposed) return;
    _isCurrent = false;
    debugPrint("[KdsScreen-${widget.kdsScreenSlug}] ⏭️ didPushNext - Screen pushed to background.");
    _isNavigationInProgress = false;
    _blockDialogsTemporarily();
    
    // Navigation background tracking
    _needsDataRefreshOnResume = true;
    
    super.didPushNext();
  }

  @override
  void didPop() {
    if (_isDisposed) return;
    _isCurrent = false;
    debugPrint("[KdsScreen-${widget.kdsScreenSlug}] ⬅️ didPop - Screen is being popped.");
    _leaveKdsRoom();
    _cleanupDialogs();
    super.didPop();
  }

  bool _shouldProcessUpdate() {
    return mounted && _isCurrent && _isAppInForeground && !_isDisposed;
  }

  bool _shouldShowDialog() {
    return _shouldProcessUpdate() && !_dialogBlocked && !_isDialogShowing && 
           !BuildLockManager.isLocked && NavigatorSafeZone.canNavigate();
  }

  // 🔄 UPDATED: Legacy method - now uses throttled version
  void _safeRefreshData() {
    _safeRefreshDataWithThrottling();
  }

  void _joinKdsRoomIfNeeded() {
    // Use the stable version
    _joinKdsRoomWithStability();
  }

  void _leaveKdsRoom() {
    if (_isJoinedToRoom) {
      _isJoinedToRoom = false;
      _roomConnectionStable = false;
      _roomStabilityTimer?.cancel();
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 👋 Left KDS room.');
    }
  }

  void _processPendingNotifications() {
    if (_isProcessingPending || _isDisposed || !mounted) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Pending processing blocked');
      return;
    }
    
    if (_pendingNotifications.isEmpty) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] No pending notifications');
      return;
    }
    
    if (!_shouldProcessUpdate() || _dialogBlocked) {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] Pending processing conditions not met');
      return;
    }
    
    _isProcessingPending = true;
    debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 📨 Processing ${_pendingNotifications.length} pending notifications.');
    
    // İlk bildirimi işle
    if (_pendingNotifications.isNotEmpty) {
      final notification = _pendingNotifications.removeAt(0);
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed && mounted && _shouldShowDialog()) {
          _processNotificationSafely(notification);
        }
        
        // Sonraki notification'ları kısa sürede işle
        if (_pendingNotifications.isNotEmpty && !_isDisposed && mounted) {
          Timer(const Duration(milliseconds: 1500), () {
            _isProcessingPending = false;
            _processPendingNotifications();
          });
        } else {
          _isProcessingPending = false;
        }
      });
    } else {
      _isProcessingPending = false;
    }
  }

  void _processNotificationSafely(Map<String, dynamic> data) {
    if (!_shouldShowDialog()) return;
    
    final String? eventType = data['event_type'] as String?;
    if (eventType == null) return;
    
    _showNotificationDialog(data, eventType);
  }

  void _safeNavigate(VoidCallback navigationAction) {
    if (_isNavigationInProgress || _isDisposed || !mounted || 
        !NavigatorSafeZone.canNavigate() || BuildLockManager.isLocked) {
      print('[KDS] Navigation blocked - system busy');
      return;
    }
    
    _isNavigationInProgress = true;
    NavigatorSafeZone.markBusy('kds_navigation');
    
    try {
      navigationAction();
    } catch (e) {
      debugPrint("Navigation error in KDS: $e");
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _isNavigationInProgress = false;
          NavigatorSafeZone.markFree('kds_navigation');
        }
      });
    }
  }

  void _showNotificationDialog(Map<String, dynamic> data, String eventType) {
    if (!NavigatorSafeZone.canNavigate() || !_shouldShowDialog()) return;
    
    final navigatorState = navigatorKey.currentState;
    if (navigatorState == null || !navigatorState.mounted) return;
    
    try {
      if (navigatorState.userGestureInProgress) {
        debugPrint('[KdsScreen] Navigator busy with user gesture, dialog skipped');
        return;
      }
    } catch (e) {
      debugPrint('[KdsScreen] Navigator state check failed: $e');
      return;
    }
    
    if (_activeDialogs.contains(eventType)) {
      debugPrint("[KdsScreen-${widget.kdsScreenSlug}] Dialog type '$eventType' already active, skipping.");
      return;
    }
    
    final context = navigatorKey.currentContext ?? this.context;
    if (!mounted || context == null) return;
    
    Widget? dialogWidget;
    switch (eventType) {
      case NotificationEventTypes.orderApprovedForKitchen:
        dialogWidget = OrderApprovedForKitchenDialog(notificationData: data, onAcknowledge: () {});  
        break;
      case NotificationEventTypes.orderReadyForPickupUpdate:
        dialogWidget = OrderReadyForPickupDialog(notificationData: data, onAcknowledge: () {});
        break;
      case NotificationEventTypes.orderItemAdded:
        dialogWidget = OrderApprovedForKitchenDialog(notificationData: data, onAcknowledge: () {});
        break;
    }

    if (dialogWidget != null && !_isDisposed && mounted) {
      debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 📱 Bildirim diyalogu gösteriliyor: $eventType");
      
      NavigatorSafeZone.markBusy('dialog_show');
      
      _isDialogShowing = true;
      _activeDialogs.add(eventType);
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => dialogWidget!,
      ).then((_) {
        if (mounted && !_isDisposed) {
          _isDialogShowing = false;
          _activeDialogs.remove(eventType);
          shouldRefreshTablesNotifier.value = true;
          debugPrint("[KdsScreen-${widget.kdsScreenSlug}] ✅ Dialog kapatıldı: $eventType");
        }
        NavigatorSafeZone.markFree('dialog_show');
      }).catchError((error) {
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] ❌ Dialog error: $error");
        if (mounted && !_isDisposed) {
          _isDialogShowing = false;
          _activeDialogs.remove(eventType);
        }
        NavigatorSafeZone.markFree('dialog_show');
      });
    } else {
      NavigatorSafeZone.markFree('dialog_show');
    }
  }

  void _handleLoudNotification() {
    final data = newOrderNotificationDataNotifier.value;
    
    if (data == null || _dialogBlocked || BuildLockManager.isLocked || NavigatorSafeZone.isBusy) {
      if (data != null) newOrderNotificationDataNotifier.value = null;
      return;
    }

    if (!_shouldShowDialog()) {
      if (data != null) {
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] Ekran/dialog durumu uygun değil, bildirim bekletiliyor.");
        _pendingNotifications.add(Map<String, dynamic>.from(data));
      }
      if (data != null) newOrderNotificationDataNotifier.value = null;
      return;
    }

    final String? eventType = data['event_type'] as String?;
    if (eventType == null || !UserSession.hasNotificationPermission(eventType)) {
      newOrderNotificationDataNotifier.value = null;
      return;
    }
    
    final String? kdsSlugInEvent = data['kds_slug'] as String?;
    if (kdsSlugInEvent != null && kdsSlugInEvent != widget.kdsScreenSlug) {
      newOrderNotificationDataNotifier.value = null;
      return;
    }
    
    _showNotificationDialog(data, eventType);
    newOrderNotificationDataNotifier.value = null;
  }

  void _handleSocketOrderUpdate() {
    final data = orderStatusUpdateNotifier.value;
    if (data != null) {
      final String? eventType = data['event_type'] as String?;
      final String? kdsSlugInEvent = data['kds_slug'] as String?;

      if (kdsSlugInEvent == null || kdsSlugInEvent == widget.kdsScreenSlug) {
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 📡 Socket update received: '$eventType'");
        
        if (_shouldProcessUpdate()) {
          debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 🔄 Refreshing data...");
          _safeRefreshDataWithThrottling();
        } else {
          debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 📋 Screen inactive, adding to pending list.");
          _pendingNotifications.add(Map<String, dynamic>.from(data));
        }
      } else {
        debugPrint("[KdsScreen-${widget.kdsScreenSlug}] 🚫 Event for other KDS ('$kdsSlugInEvent'), ignoring.");
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && orderStatusUpdateNotifier.value == data) {
          orderStatusUpdateNotifier.value = null;
        }
      });
    }
  }

  Future<void> _fetchKdsOrdersWithLoadingIndicator() async {
    if (!mounted || _isDisposed) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    await _fetchKdsOrders();
    if (mounted && !_isDisposed) {
      setState(() {
        _isLoading = false;
        if (!_isInitialLoadComplete) _isInitialLoadComplete = true;
      });
    }
  }

  Future<void> _fetchKdsOrders() async {
    if (!mounted || _isDisposed) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      debugPrint('[KdsScreen-${widget.kdsScreenSlug}] 📦 Fetching KDS orders...');
      final orders =
          await KdsService.fetchKDSOrders(widget.token, widget.kdsScreenSlug);
      if (mounted && !_isDisposed) {
        setState(() {
          _kdsOrders = orders;
          _errorMessage = '';
        });
        debugPrint('[KdsScreen-${widget.kdsScreenSlug}] ✅ KDS orders updated (${orders.length} orders)');
      }
    } catch (e) {
      if (mounted && !_isDisposed) {
        setState(() {
          _errorMessage = l10n.kdsScreenErrorFetching(e.toString().replaceFirst("Exception: ", ""));
          _kdsOrders = [];
        });
      }
      debugPrint(
          "[KdsScreen-${widget.kdsScreenSlug}] ❌ Error fetching KDS orders: $_errorMessage");
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    if (_isDisposed) {
      return Scaffold(
        backgroundColor: Colors.blueGrey.shade900,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text(
                'KDS kapatılıyor...',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }
    
    final l10n = AppLocalizations.of(context)!;
    double screenWidth = MediaQuery.of(context).size.width;
    int crossAxisCount;
    if (screenWidth > 1400) {
      crossAxisCount = 5;
    } else if (screenWidth > 1100) {
      crossAxisCount = 4;
    } else if (screenWidth > 800) {
      crossAxisCount = 3;
    } else if (screenWidth > 550) {
      crossAxisCount = 2;
    } else {
      crossAxisCount = 1;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.kdsScreenTitle(widget.kdsScreenName),
            style: const TextStyle(fontSize: 18, color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.blueGrey.shade800,
        leading: widget.onGoHome != null
            ? IconButton(
                icon: const Icon(Icons.home_outlined, color: Colors.white),
                tooltip: l10n.kdsScreenTooltipGoHome,
                onPressed: () {
                  _safeNavigate(() {
                    if (Navigator.canPop(context)) {
                      Navigator.pop(context);
                    }
                    widget.onGoHome!();
                  });
                },
              )
            : (Navigator.canPop(context)
                ? IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    tooltip: l10n.kdsScreenTooltipBack,
                    onPressed: () => _safeNavigate(() => Navigator.pop(context)),
                  )
                : null),
        actions: [
          ValueListenableBuilder<String>(
            valueListenable: widget.socketService.connectionStatusNotifier,
            builder: (context, status, child) {
              Color indicatorColor;
              IconData indicatorIcon;
              
              if (status == 'Bağlandı' && _roomConnectionStable) {
                indicatorColor = Colors.green;
                indicatorIcon = Icons.wifi;
              } else if (status.contains('bekleniyor') || status.contains('deneniyor') || _isJoinedToRoom) {
                indicatorColor = Colors.orange;
                indicatorIcon = Icons.wifi_tethering;
              } else {
                indicatorColor = Colors.red;
                indicatorIcon = Icons.wifi_off;
              }
              
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: GestureDetector(
                  onTap: _joinKdsRoomWithStability,
                  child: Container(
                    padding: EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: indicatorColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Stack(
                      children: [
                        Icon(
                          indicatorIcon,
                          color: indicatorColor,
                          size: 16,
                        ),
                        // Bekleyen bildirim göstergesi
                        if (_pendingNotifications.isNotEmpty)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Colors.orange,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Center(
                                child: Text(
                                  '${_pendingNotifications.length}',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 6,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // Dialog blokaj göstergesi
                        if (_dialogBlocked || BuildLockManager.isLocked || NavigatorSafeZone.isBusy)
                          Positioned(
                            left: 0,
                            bottom: 0,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: Colors.red,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        // Processing göstergesi
                        if (_isProcessingPending)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        // Data staleness göstergesi
                        if (_needsDataRefreshOnResume)
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: Colors.amber,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        // 🚨 Recovery göstergesi
                        if (_recoveryInProgress)
                          Positioned(
                            bottom: 0,
                            right: 4,
                            child: Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.purple,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: l10n.kdsScreenTooltipRefresh,
            onPressed: _isLoading ? null : _fetchKdsOrdersWithLoadingIndicator,
          )
        ],
      ),
      body: Container(
        color: Colors.blueGrey.shade900,
        child: (_isLoading && !_isInitialLoadComplete)
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _errorMessage.isNotEmpty && _kdsOrders.isEmpty
                ? Center(
                    child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline,
                            color: Colors.orangeAccent.shade100, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.kdsScreenButtonRetry),
                          onPressed: _fetchKdsOrdersWithLoadingIndicator,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orangeAccent.shade100,
                              foregroundColor: Colors.black87),
                        )
                      ],
                    ),
                  ))
                : _kdsOrders.isEmpty
                    ? Center(
                        child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.kitchen_outlined,
                              size: 80, color: Colors.grey.shade500),
                          const SizedBox(height: 16),
                          Text(
                            l10n.kdsScreenNoOrders,
                            style: TextStyle(
                                color: Colors.grey.shade400, fontSize: 18),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text(l10n.kdsScreenTooltipRefresh),
                            onPressed: _fetchKdsOrdersWithLoadingIndicator,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueGrey.shade50,
                              foregroundColor: Colors.blueGrey.shade900,
                            ),
                          )
                        ],
                      ))
                    : RefreshIndicator(
                        onRefresh: _fetchKdsOrders,
                        color: Colors.white,
                        backgroundColor: Colors.blueGrey.shade700,
                        child: MasonryGridView.count(
                          padding: const EdgeInsets.all(10),
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          itemCount: _kdsOrders.length,
                          itemBuilder: (context, index) {
                            final order = _kdsOrders[index];
                            return KdsOrderCard(
                              key: ValueKey(order['id']),
                              orderData: order,
                              token: widget.token,
                              isLoadingAction: _isLoading,
                              onOrderUpdated: _fetchKdsOrders,
                            );
                          },
                        ),
                      ),
      ),
    );
  }
}