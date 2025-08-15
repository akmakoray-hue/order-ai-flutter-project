// lib/screens/business_owner_home.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:jwt_decoder/jwt_decoder.dart';
import 'package:makarna_app/services/stock_service.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:collection/collection.dart';

// Servisler
import '../services/user_session.dart';
import '../services/socket_service.dart';
import '../services/order_service.dart';
import '../services/kds_service.dart';
import '../services/kds_management_service.dart';
import '../services/connectivity_service.dart';
import '../services/global_notification_handler.dart' as globalHandler;
import '../services/connection_manager.dart';

// Modeller
import '../models/kds_screen_model.dart';
import '../models/notification_event_types.dart';
import '../models/staff_permission_keys.dart';

// Ekranlar
import 'create_order_screen.dart';
import 'takeaway_order_screen.dart';
import 'kds_screen.dart';
import 'notification_screen.dart';
import 'manage_kds_screens_screen.dart';
import 'login_screen.dart';

// Widget'lar
import '../widgets/home/business_owner_home_content.dart';
import '../widgets/home/user_profile_avatar.dart';
import '../widgets/shared/offline_banner.dart';
import '../widgets/shared/sync_status_indicator.dart';

// Diğerleri
import '../utils/notifiers.dart';
import '../main.dart';

class BusinessOwnerHome extends StatefulWidget {
    final String token;
    final int businessId;
    const BusinessOwnerHome(
        {Key? key, required this.token, required this.businessId})
        : super(key: key);

    @override
    _BusinessOwnerHomeState createState() => _BusinessOwnerHomeState();
}

// 🔥 3. ADIM - Event Throttling & Performance Optimization
class _BusinessOwnerHomeState extends State<BusinessOwnerHome>
    with RouteAware, WidgetsBindingObserver {
    
    int _currentIndex = 0;
    bool _isInitialLoadComplete = false;
    
    // Screen state tracking
    bool _isCurrent = true;
    bool _isAppInForeground = true;

    List<Widget> _activeTabPages = [];
    List<BottomNavigationBarItem> _activeNavBarItems = [];

    final SocketService _socketService = SocketService.instance;
    final ConnectivityService _connectivityService = ConnectivityService.instance;

    final ValueNotifier<int> _activeTableOrderCountNotifier = ValueNotifier(0);
    final ValueNotifier<int> _activeTakeawayOrderCountNotifier = ValueNotifier(0);
    final ValueNotifier<int> _activeKdsOrderCountNotifier = ValueNotifier(0);

    Timer? _orderCountRefreshTimer;
    DateTime? _lastRefreshTime;

    List<KdsScreenModel> _availableKdsScreensForUser = [];
    bool _isLoadingKdsScreens = true;
    String? _currentKdsRoomSlugForSocketService;
    
    bool _hasStockAlerts = false;

    // 🔥 YENİ: Event throttling ve deduplication
    static final Map<String, Timer> _eventThrottlers = {};
    static final Set<String> _processingEvents = {};
    static Timer? _batchEventTimer;
    static final Set<String> _pendingEventTypes = {};

    // NotificationCenter callbacks
    late Function(Map<String, dynamic>) _refreshAllScreensCallback;
    late Function(Map<String, dynamic>) _screenBecameActiveCallback;
    late Function(Map<String, dynamic>) _kdsUpdateCallback;

    @override
    void initState() {
        super.initState();
        debugPrint("[${DateTime.now()}] _BusinessOwnerHomeState: initState. User: ${UserSession.username}, Type: ${UserSession.userType}");
        
        WidgetsBinding.instance.addObserver(this);
        _setupNotificationCenterListeners();
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
            _initializeAsyncDependencies();
        });
        
        _addSocketServiceAndNotifierListeners();
    }

    @override
    void dispose() {
        debugPrint("[${DateTime.now()}] _BusinessOwnerHomeState: dispose.");
        
        routeObserver.unsubscribe(this);
        WidgetsBinding.instance.removeObserver(this);
        
        _cleanupNotificationCenterListeners();
        _removeSocketServiceAndNotifierListeners();
        _orderCountRefreshTimer?.cancel();
        
        // 🔥 Event throttler cleanup
        _eventThrottlers.values.forEach((timer) => timer.cancel());
        _eventThrottlers.clear();
        _batchEventTimer?.cancel();
        _processingEvents.clear();
        _pendingEventTypes.clear();
        
        _activeTableOrderCountNotifier.dispose();
        _activeTakeawayOrderCountNotifier.dispose();
        _activeKdsOrderCountNotifier.dispose();
        
        super.dispose();
    }

    // 🔥 GELİŞTİRİLMİŞ: Event throttling ve batching
    void _setupNotificationCenterListeners() {
        _refreshAllScreensCallback = (data) {
            if (!mounted || !_shouldProcessUpdate()) return;
            
            final eventType = data['eventType'] as String?;
            final eventData = data['data'] as Map<String, dynamic>?;
            
            // 🔥 Batched refresh handling
            if (data['batchRefresh'] == true) {
                final eventTypes = data['eventTypes'] as List<String>? ?? [];
                debugPrint("[BusinessOwnerHome] 📡 Batch refresh received: ${eventTypes.join(', ')}");
                
                bool shouldRefresh = eventTypes.any((type) => _shouldRefreshForEvent(type));
                if (shouldRefresh) {
                    _throttledEventProcessor('batch_refresh', () async {
                        await _fetchActiveOrderCounts();
                        await _checkStockAlerts();
                    });
                }
                return;
            }
            
            debugPrint("[BusinessOwnerHome] 📡 Global refresh received: $eventType");
            
            if (_shouldRefreshForEvent(eventType)) {
                _throttledEventProcessor('global_refresh_$eventType', () async {
                    await _fetchActiveOrderCounts();
                    await _checkStockAlerts();
                });
            }
        };

        _screenBecameActiveCallback = (data) {
            if (!mounted || !_shouldProcessUpdate()) return;
            
            debugPrint("[BusinessOwnerHome] 📱 Screen became active notification received");
            _throttledEventProcessor('screen_active', () async {
                await _fetchActiveOrderCounts();
                await _checkStockAlerts();
            });
        };

        _kdsUpdateCallback = (data) {
            if (!mounted || !_shouldProcessUpdate()) return;
            
            final eventType = data['event_type'] as String?;
            debugPrint("[BusinessOwnerHome] 🔥 KDS update detected: $eventType");
            
            if (_isKdsEvent(eventType)) {
                // 🔥 KDS events get immediate processing (no throttling for critical events)
                _immediateEventProcessor('kds_update_$eventType', () async {
                    await _fetchActiveOrderCounts();
                    await _checkStockAlerts();
                });
            }
        };

        NotificationCenter.instance.addObserver('refresh_all_screens', _refreshAllScreensCallback);
        NotificationCenter.instance.addObserver('screen_became_active', _screenBecameActiveCallback);
        NotificationCenter.instance.addObserver('order_status_update', _kdsUpdateCallback);
    }

    // 🔥 YENİ: Throttled event processor - Normal events için
    void _throttledEventProcessor(String eventKey, Future<void> Function() processor) {
        // Duplicate event check
        if (_processingEvents.contains(eventKey)) {
            debugPrint("[BusinessOwnerHome] 🚫 Event $eventKey already processing, skipping...");
            return;
        }

        // Cancel existing throttler for this event
        _eventThrottlers[eventKey]?.cancel();
        
        // Set new throttled timer - 800ms delay
        _eventThrottlers[eventKey] = Timer(Duration(milliseconds: 800), () async {
            if (!mounted || !_shouldProcessUpdate()) return;
            
            _processingEvents.add(eventKey);
            debugPrint("[BusinessOwnerHome] 🟡 Processing throttled event: $eventKey");
            
            try {
                await processor();
                debugPrint("[BusinessOwnerHome] ✅ Completed throttled event: $eventKey");
            } catch (e) {
                debugPrint("[BusinessOwnerHome] ❌ Error in throttled event $eventKey: $e");
            } finally {
                _processingEvents.remove(eventKey);
                _eventThrottlers.remove(eventKey);
            }
        });
        
        debugPrint("[BusinessOwnerHome] ⏱️ Throttled event scheduled: $eventKey");
    }

    // 🔥 YENİ: Immediate event processor - KDS critical events için
    void _immediateEventProcessor(String eventKey, Future<void> Function() processor) {
        // Duplicate event check
        if (_processingEvents.contains(eventKey)) {
            debugPrint("[BusinessOwnerHome] 🚫 Critical event $eventKey already processing, skipping...");
            return;
        }

        _processingEvents.add(eventKey);
        debugPrint("[BusinessOwnerHome] 🔥 Processing immediate event: $eventKey");
        
        // Execute immediately
        processor().then((_) {
            debugPrint("[BusinessOwnerHome] ✅ Completed immediate event: $eventKey");
        }).catchError((e) {
            debugPrint("[BusinessOwnerHome] ❌ Error in immediate event $eventKey: $e");
        }).whenComplete(() {
            _processingEvents.remove(eventKey);
        });
    }

    void _cleanupNotificationCenterListeners() {
        NotificationCenter.instance.removeObserver('refresh_all_screens', _refreshAllScreensCallback);
        NotificationCenter.instance.removeObserver('screen_became_active', _screenBecameActiveCallback);
        NotificationCenter.instance.removeObserver('order_status_update', _kdsUpdateCallback);
    }

    bool _isKdsEvent(String? eventType) {
        if (eventType == null) return false;
        
        const kdsEvents = {
            'order_preparing_update',
            'order_ready_for_pickup_update',
            'order_item_picked_up',
            'order_fully_delivered',
        };
        
        return kdsEvents.contains(eventType) ||
               eventType.contains('preparing') || 
               eventType.contains('ready_for_pickup') ||
               eventType.contains('picked_up');
    }

    bool _shouldRefreshForEvent(String? eventType) {
        if (eventType == null) return false;
        
        const countAffectingEvents = {
            NotificationEventTypes.guestOrderPendingApproval,
            NotificationEventTypes.orderCancelledUpdate,
            NotificationEventTypes.orderApprovedForKitchen,
            NotificationEventTypes.orderPreparingUpdate,
            NotificationEventTypes.orderReadyForPickupUpdate,
            NotificationEventTypes.orderCompletedUpdate,
            NotificationEventTypes.orderItemAdded,
            NotificationEventTypes.orderItemRemoved,
        };
        
        return countAffectingEvents.contains(eventType);
    }

    // Route observer methods
    @override
    void didChangeDependencies() {
        super.didChangeDependencies();
        final route = ModalRoute.of(context);
        if (route is PageRoute) {
            routeObserver.subscribe(this, route);
        }
        
        if (ModalRoute.of(context)?.isCurrent == true && !_isInitialLoadComplete) {
            _safeRefreshDataAsync().then((_) {
                if (mounted) {
                    setState(() { _isInitialLoadComplete = true; });
                }
            });
        }
    }

    @override
    void didPush() {
        _isCurrent = true;
        debugPrint('BusinessOwnerHome: didPush - Ana ekran aktif oldu.');
    }

    @override
    void didPopNext() {
        _isCurrent = true;
        debugPrint("BusinessOwnerHome: didPopNext - Ana ekrana dönüldü, background events işleniyor.");
        
        SocketService.instance.onScreenBecameActive();
        _safeRefreshDataWithThrottling();
        _checkAndReconnectIfNeeded();
    }

    @override
    void didPushNext() {
        _isCurrent = false;
        debugPrint("BusinessOwnerHome: didPushNext - Ana ekran arka plana gitti.");
    }

    @override
    void didPop() {
        _isCurrent = false;
        debugPrint("BusinessOwnerHome: didPop - Ana ekran kapatıldı.");
    }

    @override
    void didChangeAppLifecycleState(AppLifecycleState state) {
        super.didChangeAppLifecycleState(state);
        _isAppInForeground = state == AppLifecycleState.resumed;
        
        if (_isAppInForeground && _isCurrent) {
            debugPrint('BusinessOwnerHome: App foreground\'a geldi, veriler yenileniyor.');
            _safeRefreshDataWithThrottling();
        }
    }

    bool _shouldProcessUpdate() {
        return mounted && _isCurrent && _isAppInForeground;
    }

    // 🔥 UPDATED: Custom throttling implementation
    void _safeRefreshDataWithThrottling() {
        if (!_shouldProcessUpdate()) return;
        
        // 🔥 Kendi throttling implementasyonumuz
        _throttledEventProcessor('business_owner_home_refresh', () async {
            await _fetchActiveOrderCounts();
            await _checkStockAlerts();
        });
    }

    void _safeRefreshData() {
        _safeRefreshDataWithThrottling();
    }

    Future<void> _safeRefreshDataAsync() async {
        if (!_shouldProcessUpdate()) return;
        
        // Direct call for async version - no throttling on initial load
        await _fetchActiveOrderCounts();
        await _checkStockAlerts();
    }

    void _checkAndReconnectIfNeeded() {
        if (!mounted) return;
        
        try {
            if (!_socketService.isConnected && UserSession.token.isNotEmpty) {
                debugPrint('[BusinessOwnerHome] Socket bağlantısı kopuk, yeniden bağlanılıyor...');
                _socketService.connectAndListen();
                
                if (!ConnectionManager().isMonitoring) {
                    ConnectionManager().startMonitoring();
                } else {
                    ConnectionManager().forceReconnect();
                }
            }
        } catch (e) {
            debugPrint('❌ [BusinessOwnerHome] Connection check hatası: $e');
        }
    }

    void _addSocketServiceAndNotifierListeners() {
        _connectivityService.isOnlineNotifier.addListener(_onConnectivityChanged);
        _socketService.connectionStatusNotifier.addListener(_updateSocketStatusFromService);
        
        // 🔥 OPTIMIZED: Throttled notifier listeners
        orderStatusUpdateNotifier.addListener(_handleSilentOrderUpdatesThrottled);
        shouldRefreshWaitingCountNotifier.addListener(_handleWaitingCountRefreshThrottled);
        shouldRefreshTablesNotifier.addListener(_handleTablesRefreshThrottled);
        syncStatusMessageNotifier.addListener(_handleSyncStatusMessage);
        stockAlertNotifier.addListener(_onStockAlertUpdate);
        
        debugPrint("[BusinessOwnerHome] Notifier listener'ları eklendi.");
    }

    void _removeSocketServiceAndNotifierListeners() {
        _connectivityService.isOnlineNotifier.removeListener(_onConnectivityChanged);
        _socketService.connectionStatusNotifier.removeListener(_updateSocketStatusFromService);
        
        orderStatusUpdateNotifier.removeListener(_handleSilentOrderUpdatesThrottled);
        shouldRefreshWaitingCountNotifier.removeListener(_handleWaitingCountRefreshThrottled);
        shouldRefreshTablesNotifier.removeListener(_handleTablesRefreshThrottled);
        syncStatusMessageNotifier.removeListener(_handleSyncStatusMessage);
        stockAlertNotifier.removeListener(_onStockAlertUpdate);
        debugPrint("[BusinessOwnerHome] Tüm notifier listener'ları kaldırıldı.");
    }

    // 🔥 THROTTLED: Optimized notifier handlers
    void _handleTablesRefreshThrottled() {
        if (!_shouldProcessUpdate()) {
            debugPrint('[BusinessOwnerHome] Ekran aktif değil, tables refresh atlandı.');
            return;
        }
        
        _throttledEventProcessor('tables_refresh', () async {
            debugPrint('[BusinessOwnerHome] Enhanced notification tables refresh tetiklendi');
            await _fetchActiveOrderCounts();
            await _checkStockAlerts();
        });
    }

    void _handleWaitingCountRefreshThrottled() {
        if (!_shouldProcessUpdate()) {
            debugPrint('[BusinessOwnerHome] Ekran aktif değil, waiting count refresh atlandı.');
            return;
        }
        
        _throttledEventProcessor('waiting_count_refresh', () async {
            debugPrint('[BusinessOwnerHome] Waiting count refresh tetiklendi');
            await _fetchActiveOrderCounts();
        });
    }

    void _handleSilentOrderUpdatesThrottled() {
        final notificationData = orderStatusUpdateNotifier.value;
        
        if (notificationData == null || !_shouldProcessUpdate()) {
            if (notificationData != null) {
                debugPrint("[BusinessOwnerHome] Ekran aktif değil, bildirim atlandı: ${notificationData['event_type']}");
            }
            return;
        }
        
        final eventType = notificationData['event_type'] as String?;
        debugPrint("[BusinessOwnerHome] Anlık güncelleme alındı: $eventType");
        
        // 🔥 KDS events get immediate processing
        if (_isKdsEvent(eventType)) {
            debugPrint("[BusinessOwnerHome] 🔥 KDS event detected, using priority refresh: $eventType");
            _immediateEventProcessor('kds_direct_$eventType', () async {
                await _fetchActiveOrderCounts();
                await _checkStockAlerts();
            });
            return;
        }
        
        // Regular events get throttled
        if (_shouldRefreshForEvent(eventType) || notificationData['is_paid_update'] == true) {
            _throttledEventProcessor('order_update_$eventType', () async {
                debugPrint("[BusinessOwnerHome] Sayaçları etkileyen bir olay geldi, sayılar yenileniyor.");
                await _fetchActiveOrderCounts();
                await _checkStockAlerts();
            });
        } else {
            debugPrint("[BusinessOwnerHome] Sayaçları etkilemeyen olay, atlandı: $eventType");
        }
    }

    void _onStockAlertUpdate() {
        if (!_shouldProcessUpdate()) return;
        
        if (_hasStockAlerts != stockAlertNotifier.value) {
            debugPrint("[BusinessOwnerHome] Stok uyarısı durumu güncellendi: ${stockAlertNotifier.value}");
            setState(() {
                _hasStockAlerts = stockAlertNotifier.value;
            });
        }
    }
    
    void _handleSyncStatusMessage() {
        final message = syncStatusMessageNotifier.value;
        if (message != null && _shouldProcessUpdate()) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(message),
                    backgroundColor: Colors.teal.shade700,
                ),
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
                syncStatusMessageNotifier.value = null;
            });
        }
    }
    
    void _onConnectivityChanged() {
        if(_shouldProcessUpdate()) {
            setState(() {
                debugPrint("BusinessOwnerHome: Connectivity changed. Rebuilding UI.");
            });
            if (_connectivityService.isOnlineNotifier.value) {
                _socketService.connectAndListen();
            }
        }
    }
    
    Future<void> _logout() async {
        debugPrint('[BusinessOwnerHome] Logout işlemi başlatılıyor...');
        
        try {
            ConnectionManager().stopMonitoring();
            globalHandler.GlobalNotificationHandler.cleanup();
        } catch (e) {
            debugPrint('❌ [BusinessOwnerHome] Logout cleanup hatası: $e');
        }
        
        _socketService.reset();
        UserSession.clearSession();
        if (mounted) {
            navigatorKey.currentState?.pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const LoginScreen()),
                (Route<dynamic> route) => false,
            );
        }
    }
    
    Future<void> _initializeAsyncDependencies() async {
        await _loadUserSessionIfNeeded();
        _socketService.connectAndListen();
        await _fetchUserAccessibleKdsScreens();
        _buildAndSetActiveTabs();
        await _fetchActiveOrderCounts();
        _startOrderCountRefreshTimer();
        await _checkStockAlerts();
        
        if (!ConnectionManager().isMonitoring) {
            ConnectionManager().startMonitoring();
            debugPrint('[BusinessOwnerHome] Connection manager başlatıldı');
        }
    }
    
    Future<void> _loadUserSessionIfNeeded() async {
        if (UserSession.token.isEmpty && widget.token.isNotEmpty) {
            debugPrint("BusinessOwnerHome: UserSession boş, widget.token ile dolduruluyor.");
            try {
                Map<String, dynamic> decodedToken = JwtDecoder.decode(widget.token);
                UserSession.storeLoginData({'access': widget.token, ...decodedToken});
            } catch (e) {
                debugPrint("BusinessOwnerHome: Token decode error: $e");
                UserSession.clearSession();
                if (mounted) _logout();
            }
        }
    }
    
    Future<void> _checkStockAlerts() async {
        if (!mounted || !UserSession.hasPagePermission(PermissionKeys.manageStock)) {
            if (mounted && _hasStockAlerts) setState(() => _hasStockAlerts = false);
            return;
        }
        
        try {
            final stocks = await StockService.fetchBusinessStock(widget.token);
            bool alertFound = false;
            for (final stock in stocks) {
                if (stock.trackStock && stock.alertThreshold != null && stock.quantity <= stock.alertThreshold!) {
                    alertFound = true;
                    break;
                }
            }
            if (mounted && _hasStockAlerts != alertFound) {
                setState(() => _hasStockAlerts = alertFound);
            }
        } catch (e) {
            debugPrint("Stok uyarıları kontrol edilirken hata: $e");
            if (mounted && _hasStockAlerts) {
                setState(() => _hasStockAlerts = false);
            }
        }
    }
    
    Future<void> _fetchUserAccessibleKdsScreens() async {
        if (!mounted || UserSession.businessId == null) {
            if (mounted) setState(() => _isLoadingKdsScreens = false);
            return;
        }
        if (UserSession.userType == 'customer' || UserSession.userType == 'admin') {
            _availableKdsScreensForUser = [];
            if (mounted) setState(() => _isLoadingKdsScreens = false);
            return;
        }
        if (mounted) setState(() => _isLoadingKdsScreens = true);
        List<KdsScreenModel> kdsToDisplay = [];
        try {
            if (UserSession.userType == 'business_owner') {
                final allKdsScreensForBusiness = await KdsManagementService.fetchKdsScreens(UserSession.token, UserSession.businessId!);
                kdsToDisplay = allKdsScreensForBusiness.where((kds) => kds.isActive).toList();
            } else if (UserSession.userType == 'staff' || UserSession.userType == 'kitchen_staff') {
                kdsToDisplay = UserSession.userAccessibleKdsScreens.where((kds) => kds.isActive).toList();
            }
            
            if (mounted) {
                setState(() => _availableKdsScreensForUser = kdsToDisplay);
                debugPrint("BusinessOwnerHome: Kullanıcı için gösterilecek KDS ekranları (${_availableKdsScreensForUser.length} adet) belirlendi.");
            }
        } catch (e) {
            if (mounted) {
                debugPrint("BusinessOwnerHome: Kullanıcının erişebileceği KDS ekranları işlenirken hata: $e");
                _availableKdsScreensForUser = [];
            }
        } finally {
            if (mounted) setState(() => _isLoadingKdsScreens = false);
        }
    }
    
    void _startOrderCountRefreshTimer() {
        _orderCountRefreshTimer?.cancel();
        _orderCountRefreshTimer = Timer.periodic(const Duration(seconds: 45), (timer) {
            if (_shouldProcessUpdate()) {
                _safeRefreshDataWithThrottling();
                _checkAndReconnectIfNeeded();
            }
        });
    }
    
    Future<void> _fetchActiveOrderCounts() async {
        if (!mounted) return;
        try {
            int kdsCount = 0;
            if (!_isLoadingKdsScreens && _availableKdsScreensForUser.isNotEmpty) {
                kdsCount = await KdsService.fetchActiveKdsOrderCount(widget.token, _availableKdsScreensForUser.first.slug);
            } else {
                kdsCount = 0;
            }

            final results = await Future.wait([
                OrderService.fetchActiveTableOrderCount(widget.token, widget.businessId),
                OrderService.fetchActiveTakeawayOrderCount(widget.token, widget.businessId),
                Future.value(kdsCount)
            ]);

            if (mounted) {
                _activeTableOrderCountNotifier.value = results[0] as int;
                _activeTakeawayOrderCountNotifier.value = results[1] as int;
                _activeKdsOrderCountNotifier.value = results[2] as int;
                
                debugPrint("[BusinessOwnerHome] Order counts updated - Table: ${results[0]}, Takeaway: ${results[1]}, KDS: ${results[2]}");
            }
        } catch (e) {
            debugPrint("❌ [BusinessOwnerHome] Aktif sipariş sayıları çekilirken hata: $e");
        }
    }
    
    void _updateSocketStatusFromService() {
        if (_shouldProcessUpdate()) {
            final connectionStatus = _socketService.connectionStatusNotifier.value;
            debugPrint("[BusinessOwnerHome] SocketService bağlantı durumu: $connectionStatus");
            
            if (connectionStatus == 'Bağlandı' && 
                _currentKdsRoomSlugForSocketService != null && 
                UserSession.token.isNotEmpty) {
                _socketService.joinKdsRoom(_currentKdsRoomSlugForSocketService!);
            }
            
            if (connectionStatus == 'Bağlandı') {
                Future.delayed(Duration(seconds: 1), () {
                    if (_shouldProcessUpdate()) {
                        _safeRefreshDataWithThrottling();
                    }
                });
            }
        }
    }

    bool _canAccessTab(String permissionKey) {
        if (UserSession.userType == 'business_owner') return true;
        if (permissionKey == PermissionKeys.manageKds ||
            permissionKey == PermissionKeys.managePagers ||
            permissionKey == PermissionKeys.manageCampaigns ||
            permissionKey == PermissionKeys.manageKdsScreens) {
            return UserSession.userType == 'business_owner' || UserSession.hasPagePermission(permissionKey);
        }
        return UserSession.hasPagePermission(permissionKey);
    }
    
    Widget _buildIconWithBadge(IconData defaultIcon, IconData activeIcon, ValueNotifier<int> countNotifier) {
        return ValueListenableBuilder<int>(
            valueListenable: countNotifier,
            builder: (context, count, child) {
                bool isSelected = (_currentIndex == 1 && defaultIcon == Icons.table_chart_outlined) ||
                                  (_currentIndex == 2 && defaultIcon == Icons.delivery_dining_outlined) ||
                                  (_activeNavBarItems.length > 3 && _currentIndex == 3 && _activeNavBarItems[3].label == AppLocalizations.of(context)!.kitchenTabLabel && defaultIcon == Icons.kitchen_outlined);

                return Badge(
                    label: Text(count > 99 ? '99+' : count.toString()),
                    isLabelVisible: count > 0,
                    backgroundColor: Colors.redAccent,
                    child: Icon(isSelected ? activeIcon : defaultIcon),
                );
            },
        );
    }
    
    void _navigateToKdsScreen(BuildContext context) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;

        if (_isLoadingKdsScreens) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.infoKdsScreensLoading), duration: const Duration(seconds: 1)),
            );
            return;
        }

        if (_availableKdsScreensForUser.isEmpty) {
            if (UserSession.userType == 'business_owner') {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.infoCreateKdsScreenFirst)),
                );
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ManageKdsScreensScreen(token: widget.token, businessId: widget.businessId),
                    ),
                ).then((_) => _fetchUserAccessibleKdsScreens().then((__) {
                    if (mounted) _buildAndSetActiveTabs();
                }));
            } else {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.infoNoActiveKdsAvailable)),
                );
            }
            return;
        }

        if (_availableKdsScreensForUser.length == 1) {
            final kds = _availableKdsScreensForUser.first;
            _currentKdsRoomSlugForSocketService = kds.slug;
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => KdsScreen(
                        token: widget.token,
                        businessId: widget.businessId,
                        kdsScreenSlug: kds.slug,
                        kdsScreenName: kds.name,
                        onGoHome: () => _onNavBarTapped(0),
                        socketService: _socketService,
                    ),
                ),
            );
        } else {
            showDialog(
                context: context,
                builder: (BuildContext dialogContext) {
                    return AlertDialog(
                        backgroundColor: Colors.transparent,
                        contentPadding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        content: Container(
                            padding: const EdgeInsets.all(16.0),
                            decoration: BoxDecoration(
                                gradient: LinearGradient(
                                colors: [
                                    Colors.blue.shade900.withOpacity(0.95),
                                    Colors.blue.shade500.withOpacity(0.9),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: const [
                                    BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))
                                ]
                            ),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                    Text(
                                        l10n.dialogSelectKdsScreenTitle,
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                        ),
                                    ),
                                    const SizedBox(height: 12),
                                    const Divider(color: Colors.white30),
                                    SizedBox(
                                        width: double.maxFinite,
                                        height: MediaQuery.of(context).size.height * 0.3,
                                        child: ListView.builder(
                                            shrinkWrap: true,
                                            itemCount: _availableKdsScreensForUser.length,
                                            itemBuilder: (BuildContext ctx, int index) {
                                                final kds = _availableKdsScreensForUser[index];
                                                return ListTile(
                                                    leading: Icon(Icons.desktop_windows_rounded, color: Colors.white70),
                                                    title: Text(kds.name, style: const TextStyle(color: Colors.white)),
                                                    onTap: () {
                                                        Navigator.of(dialogContext).pop();
                                                        _currentKdsRoomSlugForSocketService = kds.slug;
                                                        Navigator.push(
                                                            context,
                                                            MaterialPageRoute(
                                                                builder: (_) => KdsScreen(
                                                                    token: widget.token,
                                                                    businessId: widget.businessId,
                                                                    kdsScreenSlug: kds.slug,
                                                                    kdsScreenName: kds.name,
                                                                    onGoHome: () => _onNavBarTapped(0),
                                                                    socketService: _socketService,
                                                                ),
                                                            ),
                                                        );
                                                    },
                                                );
                                            },
                                        ),
                                    ),
                                    Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                            child: Text(l10n.dialogButtonCancel, style: const TextStyle(color: Colors.white70)),
                                            onPressed: () {
                                                Navigator.of(dialogContext).pop();
                                            },
                                        ),
                                    ),
                                ],
                            ),
                        ),
                    );
                },
            );
        }
    }
    
    void _buildAndSetActiveTabs() {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;

        final List<Widget> pages = [];
        final List<BottomNavigationBarItem> navBarItems = [];

        pages.add(BusinessOwnerHomeContent(
            token: widget.token,
            businessId: widget.businessId,
            onTabChange: _onNavBarTapped,
            onNavigateToKds: () => _navigateToKdsScreen(context),
            hasStockAlerts: _hasStockAlerts,
        ));
        navBarItems.add(BottomNavigationBarItem(
            icon: const Icon(Icons.home_outlined),
            activeIcon: const Icon(Icons.home),
            label: l10n.homeTabLabel));

        if (_canAccessTab(PermissionKeys.takeOrders)) {
            pages.add(CreateOrderScreen(
                token: widget.token,
                businessId: widget.businessId,
                onGoHome: () => _onNavBarTapped(0),
            ));
            navBarItems.add(BottomNavigationBarItem(
                icon: _buildIconWithBadge(Icons.table_chart_outlined, Icons.table_chart, _activeTableOrderCountNotifier),
                label: l10n.tableTabLabel));

            pages.add(TakeawayOrderScreen(
                token: widget.token,
                businessId: widget.businessId,
                onGoHome: () => _onNavBarTapped(0),
            ));
            navBarItems.add(BottomNavigationBarItem(
                icon: _buildIconWithBadge(Icons.delivery_dining_outlined, Icons.delivery_dining, _activeTakeawayOrderCountNotifier),
                label: l10n.takeawayTabLabel));
        }

        bool showKdsTab = false;
        bool showKdsSetupTab = false;

        if (!_isLoadingKdsScreens) {
            bool hasGeneralKdsPermission = UserSession.userType == 'business_owner' ||
                UserSession.hasPagePermission(PermissionKeys.manageKds);

            if (hasGeneralKdsPermission) {
                if (_availableKdsScreensForUser.isNotEmpty) {
                    showKdsTab = true;
                } else if (UserSession.userType == 'business_owner') {
                    showKdsSetupTab = true;
                }
            }
        }
        
        if (showKdsTab) {
            pages.add(Container(alignment: Alignment.center, child: Text(l10n.infoKdsSelectionPending, style: const TextStyle(color: Colors.white70))));
            navBarItems.add(BottomNavigationBarItem(
                icon: _buildIconWithBadge(Icons.kitchen_outlined, Icons.kitchen, _activeKdsOrderCountNotifier),
                label: l10n.kitchenTabLabel));
        } else if (showKdsSetupTab) {
            pages.add(Center(child: ElevatedButton(onPressed: (){
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ManageKdsScreensScreen(token: widget.token, businessId: widget.businessId),
                    ),
                ).then((_) => _fetchUserAccessibleKdsScreens().then((__) {
                    if(mounted) _buildAndSetActiveTabs();
                }));
            }, child: Text(l10n.buttonCreateKdsScreen))));
            navBarItems.add(BottomNavigationBarItem(
                icon: const Icon(Icons.add_to_queue_outlined),
                activeIcon: const Icon(Icons.add_to_queue),
                label: l10n.kdsSetupTabLabel));
        }

        pages.add(NotificationScreen(
            token: widget.token,
            businessId: widget.businessId,
            onGoHome: () => _onNavBarTapped(0),
        ));
        navBarItems.add(BottomNavigationBarItem(
            icon: const Icon(Icons.notifications_outlined),
            activeIcon: const Icon(Icons.notifications),
            label: l10n.notificationsTabLabel));

        if (!listEquals(_activeTabPages, pages) || !listEquals(_activeNavBarItems, navBarItems)) {
            setState(() {
                _activeTabPages = pages;
                _activeNavBarItems = navBarItems;
            });
        }
        
        int newCurrentIndex = _currentIndex;
        if (newCurrentIndex >= pages.length && pages.isNotEmpty) {
            newCurrentIndex = 0;
        }
        if (_currentIndex != newCurrentIndex){
            setState(() {
                _currentIndex = newCurrentIndex;
            });
        }
    }

    void _onNavBarTapped(int index) {
        if (!mounted) return;

        String? tappedLabel;
        if (index >= 0 && index < _activeNavBarItems.length) {
            tappedLabel = _activeNavBarItems[index].label;
        }
        
        final l10n = AppLocalizations.of(context)!;
        if (tappedLabel == l10n.kitchenTabLabel) {
            _navigateToKdsScreen(context);
            return;  
        } else if (tappedLabel == l10n.kdsSetupTabLabel) {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ManageKdsScreensScreen(token: widget.token, businessId: widget.businessId),
                ),
            ).then((_) => _fetchUserAccessibleKdsScreens().then((__) {
                if(mounted) _buildAndSetActiveTabs();
            }));
            return;
        }

        if (index >= 0 && index < _activeTabPages.length) {
            if (_currentIndex == index && index != 0) return;  
            setState(() {
                _currentIndex = index;
            });
        } else if (_currentIndex != 0) {  
            setState(() {
                _currentIndex = 0;
            });
        }
    }
    
    String _getAppBarTitle(AppLocalizations l10n) {
        switch (UserSession.userType) {
            case 'kitchen_staff':
                return l10n.homePageTitleKitchenStaff;
            case 'staff':
                return l10n.homePageTitleStaff;
            case 'business_owner':
            default:
                return l10n.homePageTitleBusinessOwner;
        }
    }

    Widget _buildConnectionStatusIndicator() {
        return ValueListenableBuilder<String>(
            valueListenable: _socketService.connectionStatusNotifier,
            builder: (context, status, child) {
                Color indicatorColor;
                IconData indicatorIcon;
                
                if (status == 'Bağlandı') {
                    indicatorColor = Colors.green;
                    indicatorIcon = Icons.wifi;
                } else if (status.contains('bekleniyor') || status.contains('deneniyor')) {
                    indicatorColor = Colors.orange;
                    indicatorIcon = Icons.wifi_tethering;
                } else {
                    indicatorColor = Colors.red;
                    indicatorIcon = Icons.wifi_off;
                }
                
                return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: GestureDetector(
                        onTap: _checkAndReconnectIfNeeded,
                        child: Container(
                            padding: EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: indicatorColor.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                            ),
                            child: Icon(
                                indicatorIcon,
                                color: indicatorColor,
                                size: 16,
                            ),
                        ),
                    ),
                );
            },
        );
    }

    @override
    Widget build(BuildContext context) {
        final l10n = AppLocalizations.of(context)!;

        if (_activeTabPages.isEmpty &&
                !(UserSession.userType == 'customer' ||
                    UserSession.userType == 'admin')) {
            return Scaffold(
                appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    centerTitle: true,
                    title: Text(
                        _getAppBarTitle(l10n),
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    flexibleSpace: Container(
                        decoration: const BoxDecoration(
                            gradient: LinearGradient(
                                colors: [Color(0xFF283593), Color(0xFF455A64)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight))),
                    actions: [
                        _buildConnectionStatusIndicator(),
                        UserProfileAvatar(onLogout: _logout),
                    ],
                ),
                body: Container(
                    decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: [
                                Colors.blue.shade900.withOpacity(0.9),
                                Colors.blue.shade400.withOpacity(0.8)
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight)),
                    child: const Center(child: CircularProgressIndicator(color: Colors.white))),
            );
        }

        int safeCurrentIndex = _currentIndex;
        if (_currentIndex >= _activeTabPages.length && _activeTabPages.isNotEmpty) {
            safeCurrentIndex = 0;
            WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _currentIndex != safeCurrentIndex) {
                    setState(() => _currentIndex = safeCurrentIndex);
                }
            });
        } else if (_activeTabPages.isEmpty &&
            _currentIndex != 0 &&
            (UserSession.userType != 'customer' &&
                UserSession.userType != 'admin')) {
            safeCurrentIndex = 0;
            WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _currentIndex != safeCurrentIndex) {
                    setState(() => _currentIndex = safeCurrentIndex);
                }
            });
        }

        return Scaffold(
            appBar: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                centerTitle: true,
                title: Text(
                    _getAppBarTitle(l10n),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white),
                ),
                flexibleSpace: Container(
                    decoration: const BoxDecoration(
                        gradient: LinearGradient(
                            colors: [Color(0xFF283593), Color(0xFF455A64)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight),
                    ),
                ),
                leading: (_activeTabPages.isNotEmpty && safeCurrentIndex < _activeTabPages.length && _activeTabPages[safeCurrentIndex] is! BusinessOwnerHomeContent) && 
                    (_activeNavBarItems.isNotEmpty && safeCurrentIndex < _activeNavBarItems.length && _activeNavBarItems[safeCurrentIndex].label != l10n.kitchenTabLabel && _activeNavBarItems[safeCurrentIndex].label != l10n.kdsSetupTabLabel)
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        tooltip: l10n.tooltipGoToHome,
                        onPressed: () => _onNavBarTapped(0),
                    )
                    : null,
                actions: [
                    _buildConnectionStatusIndicator(),
                    UserProfileAvatar(onLogout: _logout),
                ],
            ),
            body: Column(
                children: [
                    const OfflineBanner(),
                    const SyncStatusIndicator(),
                    Expanded(
                        child: Container(
                            decoration: BoxDecoration(
                                gradient: LinearGradient(
                                    colors: [
                                        Colors.blue.shade900.withOpacity(0.9),
                                        Colors.blue.shade400.withOpacity(0.8)
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight)),
                            child: SafeArea(
                                top: false,
                                child: _activeTabPages.isEmpty
                                    ? Center(child: Text(l10n.infoContentLoading, style: const TextStyle(color: Colors.white)))
                                    : IndexedStack(
                                        index: safeCurrentIndex,
                                        children: _activeTabPages,
                                    ),
                            ),
                        ),
                    ),
                ],
            ),
            bottomNavigationBar: _activeNavBarItems.length > 1
                ? Container(
                    decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: [
                                Colors.deepPurple.shade700,
                                Colors.blue.shade800,
                                Colors.teal.shade700
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight),
                        boxShadow: [
                            BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 6,
                                offset: const Offset(0, -1))
                        ],
                    ),
                    child: BottomNavigationBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        currentIndex: safeCurrentIndex,
                        onTap: _onNavBarTapped,
                        type: BottomNavigationBarType.fixed,
                        selectedItemColor: Colors.white,
                        unselectedItemColor: Colors.white.withOpacity(0.65),
                        selectedLabelStyle:
                            const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
                        unselectedLabelStyle: const TextStyle(fontSize: 10),
                        items: _activeNavBarItems,
                    ),
                )
                : null,
        );
    }
}