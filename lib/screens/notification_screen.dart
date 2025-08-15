// lib/screens/notification_screen.dart
import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../models/notification_event_types.dart';
import '../services/socket_service.dart';

class NotificationScreen extends StatefulWidget {
  // GÜNCELLEME: socket parametresi kaldırıldı.
  final String token;
  final int businessId;
  final VoidCallback? onGoHome;

  const NotificationScreen({
    Key? key,
    required this.token,
    required this.businessId,
    this.onGoHome,
  }) : super(key: key);

  @override
  _NotificationScreenState createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  // GÜNCELLEME: SocketService'in singleton örneği alınıyor.
  final SocketService _socketService = SocketService.instance;

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[NotificationScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'notification_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          // Notification ekranı için özel refresh gerekiyorsa burada yapılır
          // Şu an için sadece bildirimlerin görünümü güncellenecek
          setState(() {});
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[NotificationScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'notification_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          // Screen active olduğunda notification listesini güncelle
          setState(() {});
        });
      }
    });
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  // GÜNCELLEME: Bu metotlar artık burada gerekli değil, silindi.
  // @override
  // void initState() { ... }
  // @override
  // void dispose() { ... }
  // void _registerSocketListeners() { ... }
  // void _removeSocketListeners() { ... }
  // void _addNotification(...) { ... }
  // ve tüm _handle... metotları silindi.
  
  // GÖRSEL YARDIMCI METOTLAR (DEĞİŞİKLİK YOK)
  IconData _getIconForNotificationType(String? eventType) {
    switch (eventType) {
      case NotificationEventTypes.guestOrderPendingApproval:
      case NotificationEventTypes.orderPendingApproval:
      case NotificationEventTypes.existingOrderNeedsReapproval:
        return Icons.hourglass_top_rounded;
      case NotificationEventTypes.newApprovedOrder:
      case NotificationEventTypes.orderApprovedForKitchen:
        return Icons.restaurant_menu_outlined;
      case NotificationEventTypes.orderPreparingUpdate:
        return Icons.outdoor_grill_outlined;
      case NotificationEventTypes.orderReadyForPickupUpdate:
        return Icons.ramen_dining_outlined;
      case NotificationEventTypes.orderPickedUpByWaiter:
      case NotificationEventTypes.orderOutForDeliveryUpdate:
        return Icons.room_service_outlined;
      case NotificationEventTypes.orderItemDelivered:
      case NotificationEventTypes.orderFullyDelivered:
        return Icons.delivery_dining_rounded;
      case NotificationEventTypes.orderCompletedUpdate:
        return Icons.check_circle_outline_rounded;
      case NotificationEventTypes.orderCancelledUpdate:
        return Icons.cancel_presentation_rounded;
      case NotificationEventTypes.orderRejectedUpdate:
        return Icons.do_not_disturb_on_outlined;
      case NotificationEventTypes.orderItemAdded:
        return Icons.add_shopping_cart_rounded;
      case NotificationEventTypes.orderItemRemoved:
        return Icons.remove_shopping_cart_outlined;
      case NotificationEventTypes.orderItemUpdated:
        return Icons.edit_note_rounded;
      case NotificationEventTypes.orderTransferred:
        return Icons.swap_horizontal_circle_outlined;
      case NotificationEventTypes.waitingCustomerAdded:
        return Icons.person_add_alt_outlined;
      case NotificationEventTypes.waitingCustomerUpdated:
        return Icons.group_work_outlined;
      case NotificationEventTypes.waitingCustomerRemoved:
        return Icons.person_remove_alt_1_outlined;
      case NotificationEventTypes.stockAdjusted:
        return Icons.inventory_2_outlined;
      case NotificationEventTypes.pagerStatusUpdated:
        return Icons.vibration;
      case 'system_connect':
        return Icons.wifi_rounded;
      case 'system_disconnect':
        return Icons.wifi_off_rounded;
      case 'system_error':
      case 'system_connect_error':
        return Icons.error_outline_rounded;
      case NotificationEventTypes.orderUpdated:
      default:
        return Icons.notifications_active;
    }
  }

  Color _getIconColorForNotificationType(String? eventType) {
    switch (eventType) {
      case NotificationEventTypes.guestOrderPendingApproval:
      case NotificationEventTypes.orderPendingApproval:
      case NotificationEventTypes.existingOrderNeedsReapproval:
        return Colors.orange.shade700;
      case NotificationEventTypes.newApprovedOrder:
      case NotificationEventTypes.orderApprovedForKitchen:
        return Colors.green.shade600;
      case NotificationEventTypes.orderPreparingUpdate:
        return Colors.amber.shade700;
      case NotificationEventTypes.orderReadyForPickupUpdate:
        return Colors.teal.shade600;
      case NotificationEventTypes.orderPickedUpByWaiter:
      case NotificationEventTypes.orderOutForDeliveryUpdate:
        return Colors.blue.shade600;
      case NotificationEventTypes.orderItemDelivered:
      case NotificationEventTypes.orderFullyDelivered:
        return Colors.lightGreen.shade700;
      case NotificationEventTypes.orderCompletedUpdate:
        return Colors.indigo.shade600;
      case NotificationEventTypes.orderCancelledUpdate:
      case NotificationEventTypes.orderRejectedUpdate:
        return Colors.red.shade700;
      case NotificationEventTypes.waitingCustomerAdded:
      case NotificationEventTypes.waitingCustomerUpdated:
      case NotificationEventTypes.waitingCustomerRemoved:
        return Colors.purple.shade600;
      case NotificationEventTypes.stockAdjusted:
        return Colors.brown.shade600;
      case NotificationEventTypes.pagerStatusUpdated:
        return Colors.indigo.shade400;
      case 'system_connect':
        return Colors.lightBlue.shade300;
      case 'system_disconnect':
      case 'system_error':
      case 'system_connect_error':
        return Colors.red.shade300;
      default:
        return Colors.blueAccent.shade100;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: widget.onGoHome != null
            ? IconButton(
                icon: const Icon(Icons.home, color: Colors.white),
                tooltip: l10n.tooltipGoToHome,
                onPressed: widget.onGoHome,
              )
            : (Navigator.canPop(context)
                ? IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  )
                : null),
        title: Text(
          l10n.notificationsPageTitle,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.blue.shade900.withOpacity(0.9),
                Colors.blue.shade400.withOpacity(0.8),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.blue.shade900.withOpacity(0.9),
              Colors.blue.shade400.withOpacity(0.8),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              ValueListenableBuilder<String>(
                valueListenable: _socketService.connectionStatusNotifier,
                builder: (context, status, child) {
                  return Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Text(
                      status,
                      style: const TextStyle(
                          color: Colors.white70, fontStyle: FontStyle.italic),
                    ),
                  );
                },
              ),
              Expanded(
                child: ValueListenableBuilder<List<Map<String, String>>>(
                  valueListenable: _socketService.notificationHistoryNotifier,
                  builder: (context, notifications, child) {
                    if (notifications.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.notifications_none, size: 70, color: Colors.white.withOpacity(0.5)),
                            const SizedBox(height: 10),
                            Text(
                              l10n.notificationsNoNotifications,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: notifications.length,
                      itemBuilder: (context, index) {
                        final notificationMap = notifications[index];
                        final String message = notificationMap['message']!;
                        final String? eventType = notificationMap['eventType'];
                        bool isSystemMessage = eventType?.startsWith('system_') ?? false;

                        return Card(
                          color: isSystemMessage
                              ? Colors.blueGrey.withOpacity(0.6)
                              : Colors.white.withOpacity(0.85),
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: ListTile(
                            leading: Icon(
                              _getIconForNotificationType(eventType),
                              color: isSystemMessage
                                  ? Colors.white70
                                  : _getIconColorForNotificationType(eventType),
                              size: 28,
                            ),
                            title: Text(
                              message,
                              style: TextStyle(
                                  color: isSystemMessage
                                      ? Colors.white
                                      : Colors.black87,
                                  fontSize: 14),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}