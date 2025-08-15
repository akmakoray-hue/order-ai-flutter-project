import 'package:flutter/material.dart';

class OverlayHelper {
  static OverlayEntry? _currentOverlay;
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static void showNotificationBanner(String message, String eventType) {
    // Önceki banner'ı kaldır
    _currentOverlay?.remove();
    _currentOverlay = null;

    final context = navigatorKey.currentContext;
    if (context == null) return;

    // Event type'a göre renk belirle
    Color backgroundColor;
    IconData icon;
    
    switch (eventType) {
      case 'order_approved_for_kitchen':
        backgroundColor = Colors.blue;
        icon = Icons.check_circle;
        break;
      case 'order_preparing_update':
        backgroundColor = Colors.orange;
        icon = Icons.restaurant;
        break;
      case 'order_ready_for_pickup_update':
        backgroundColor = Colors.green;
        icon = Icons.done_all;
        break;
      default:
        backgroundColor = Colors.grey;
        icon = Icons.notifications;
    }

    _currentOverlay = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 16,
        right: 16,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: Colors.white,
                  size: 24,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context)?.insert(_currentOverlay!);

    // 3 saniye sonra kaldır
    Future.delayed(Duration(seconds: 3), () {
      _currentOverlay?.remove();
      _currentOverlay = null;
    });
  }

  static void hideNotificationBanner() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}