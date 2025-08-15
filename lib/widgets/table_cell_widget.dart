// lib/widgets/table_cell_widget.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../services/order_service.dart';
import '../services/notification_center.dart';
import '../models/menu_item.dart';
// *** YENİ: Yerelleştirme yardımcısı import edildi ***
import '../../utils/localization_helper.dart';

class TableCellWidget extends StatefulWidget {
  final dynamic table;
  final bool isOccupied;
  final dynamic pendingOrder;
  final String token;
  final List<MenuItem> allMenuItems;
  final VoidCallback onTap;
  final VoidCallback onTransfer;
  final VoidCallback onCancel;
  final VoidCallback onOrderUpdated;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onAddItem;

  const TableCellWidget({
    Key? key,
    required this.table,
    required this.isOccupied,
    this.pendingOrder,
    required this.token,
    required this.allMenuItems,
    required this.onTap,
    required this.onTransfer,
    required this.onCancel,
    required this.onOrderUpdated,
    required this.onApprove,
    required this.onReject,
    required this.onAddItem,
  }) : super(key: key);

  @override
  _TableCellWidgetState createState() => _TableCellWidgetState();
}

class _TableCellWidgetState extends State<TableCellWidget> {
  Timer? _timer;
  int _elapsedSeconds = 0;
  bool _isProcessingAction = false;

  // 🔥 YENİ: NotificationCenter callback'leri
  late Function(Map<String, dynamic>) _kdsUpdateCallback;
  late Function(Map<String, dynamic>) _screenActiveCallback;

  // Bu sabitler aynı kalıyor
  static const String STATUS_PENDING_APPROVAL = 'pending_approval';
  static const String STATUS_PENDING_SYNC = 'pending_sync';
  static const String STATUS_APPROVED = 'approved';
  static const String STATUS_PREPARING = 'preparing';
  static const String STATUS_READY_FOR_PICKUP = 'ready_for_pickup';
  static const String STATUS_READY_FOR_DELIVERY = 'ready_for_delivery';
  static const String STATUS_COMPLETED = 'completed';
  static const String STATUS_CANCELLED = 'cancelled';
  static const String STATUS_REJECTED = 'rejected';

  static const String KDS_ITEM_STATUS_PENDING = 'pending_kds';
  static const String KDS_ITEM_STATUS_PREPARING = 'preparing_kds';
  static const String KDS_ITEM_STATUS_READY = 'ready_kds';
  static const String KDS_ITEM_STATUS_PICKED_UP = 'picked_up_kds';

  // 🔥 YENİ: KDS event'leri
  static const Set<String> _kdsEvents = {
    'order_preparing_update',
    'order_ready_for_pickup_update',
    'order_item_picked_up',
    'order_fully_delivered',
  };

  @override
  void initState() {
    super.initState();
    _startTimerIfNeeded();
    
    // 🔥 YENİ: NotificationCenter listener'ları setup
    _setupNotificationListeners();
  }

  @override
  void didUpdateWidget(covariant TableCellWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pendingOrder != oldWidget.pendingOrder) {
      _timer?.cancel();
      _startTimerIfNeeded();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    
    // 🔥 YENİ: NotificationCenter listener'ları temizle
    _cleanupNotificationListeners();
    
    super.dispose();
  }

  // 🔥 YENİ: NotificationCenter listener'ları kurulum
  void _setupNotificationListeners() {
    _kdsUpdateCallback = (data) {
      if (!mounted) return;
      
      final eventType = data['event_type'] as String?;
      final orderId = data['order_id'];
      
      // Bu widget'ın sipariş ID'si ile eşleşip eşleşmediğini kontrol et
      if (widget.pendingOrder != null && 
          orderId != null && 
          (widget.pendingOrder['id'] == orderId || 
           widget.pendingOrder['temp_id'] == orderId.toString())) {
        
        debugPrint('[TableCellWidget] 🔥 KDS priority update for order #$orderId: $eventType');
        
        // KDS güncellemesi için anında refresh tetikle
        widget.onOrderUpdated();
        
        // Görsel feedback için kısa animasyon
        _showKdsUpdateFeedback(eventType);
      }
    };

    _screenActiveCallback = (data) {
      if (!mounted) return;
      
      debugPrint('[TableCellWidget] 📱 Screen became active notification received');
      // Ekran aktif olduğunda timer'ı yeniden başlat
      _startTimerIfNeeded();
    };

    // Listener'ları kaydet
    NotificationCenter.instance.addObserver('kds_priority_update', _kdsUpdateCallback);
    NotificationCenter.instance.addObserver('screen_became_active', _screenActiveCallback);
    
    debugPrint('[TableCellWidget] 🎯 KDS listeners registered for table ${widget.table['table_number']}');
  }

  // 🔥 YENİ: NotificationCenter listener'ları temizleme
  void _cleanupNotificationListeners() {
    NotificationCenter.instance.removeObserver('kds_priority_update', _kdsUpdateCallback);
    NotificationCenter.instance.removeObserver('screen_became_active', _screenActiveCallback);
    
    debugPrint('[TableCellWidget] 🗑️ KDS listeners cleaned up for table ${widget.table['table_number']}');
  }

  // 🔥 YENİ: KDS güncellemesi için görsel feedback
  void _showKdsUpdateFeedback(String? eventType) {
    if (!mounted || eventType == null) return;
    
    Color feedbackColor;
    IconData feedbackIcon;
    String feedbackMessage;
    
    switch (eventType) {
      case 'order_preparing_update':
        feedbackColor = Colors.orange;
        feedbackIcon = Icons.whatshot;
        feedbackMessage = '🔥 Hazırlanıyor';
        break;
      case 'order_ready_for_pickup_update':
        feedbackColor = Colors.teal;
        feedbackIcon = Icons.restaurant_menu;
        feedbackMessage = '✅ Hazır';
        break;
      case 'order_item_picked_up':
        feedbackColor = Colors.purple;
        feedbackIcon = Icons.pan_tool_alt;
        feedbackMessage = '👐 Alındı';
        break;
      case 'order_fully_delivered':
        feedbackColor = Colors.green;
        feedbackIcon = Icons.check_circle;
        feedbackMessage = '🎉 Teslim';
        break;
      default:
        return; // Bilinmeyen event tipi için feedback yok
    }

    // Snackbar yerine daha subtle overlay feedback
    if (mounted) {
      _showOverlayFeedback(feedbackColor, feedbackIcon, feedbackMessage);
    }
  }

  // 🔥 YENİ: Overlay feedback gösterimi
  void _showOverlayFeedback(Color color, IconData icon, String message) {
    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;
    
    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).size.height * 0.1,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutBack,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(overlayEntry);
    
    // 2 saniye sonra kaldır
    Timer(const Duration(seconds: 2), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }

  // Bu metotlarda bir değişiklik yok, aynı kalıyorlar
  void _startTimerIfNeeded() {
    final bool isOrderFinalized = widget.pendingOrder != null &&
        [STATUS_COMPLETED, STATUS_CANCELLED, STATUS_REJECTED, STATUS_PENDING_SYNC]
            .contains(widget.pendingOrder!['status']);

    if (widget.isOccupied && !isOrderFinalized && widget.pendingOrder?['created_at'] != null) {
      try {
        DateTime createdAt = DateTime.parse(widget.pendingOrder!['created_at']);
        _timer?.cancel();
        _updateElapsedSeconds(createdAt);
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          _updateElapsedSeconds(createdAt);
          final currentOverallStatus = widget.pendingOrder?['status'] ?? 'unknown';
          if (currentOverallStatus == STATUS_READY_FOR_PICKUP ||
              currentOverallStatus == STATUS_COMPLETED ||
              currentOverallStatus == STATUS_CANCELLED ||
              currentOverallStatus == STATUS_REJECTED ||
              widget.pendingOrder['kitchen_completed_at'] != null) {
            timer.cancel();
          }
        });
      } catch (e) {
        debugPrint("TableCellWidget - Timer start error: $e");
        if (mounted) setState(() => _elapsedSeconds = 0);
      }
    } else {
      _timer?.cancel();
    }
  }

  void _updateElapsedSeconds(DateTime startTime) {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() => _elapsedSeconds = now.difference(startTime).inSeconds);
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds < 0) totalSeconds = 0;
    final duration = Duration(seconds: totalSeconds);
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$minutes:$seconds";
    }
    return "$minutes:$seconds";
  }

  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.redAccent));
  }

  // 🔥 GÜNCELLENEN: KDS feedback ile enhanced
  Future<void> _handleItemPickup(int orderItemId, AppLocalizations l10n) async {
    if (!mounted || _isProcessingAction) return;
    setState(() => _isProcessingAction = true);
    
    // Optimistic UI update feedback
    _showOverlayFeedback(Colors.purple, Icons.pan_tool_alt, '👐 İşleniyor...');
    
    try {
      final response = await OrderService.markItemPickedUpByWaiter(token: widget.token, orderItemId: orderItemId);
      if (mounted) {
        if (response.statusCode == 200) {
          debugPrint('[TableCellWidget] 🎯 Item pickup successful, triggering update');
          widget.onOrderUpdated();
        } else {
          _showErrorSnackbar(l10n.tableCellItemPickupErrorWithDetails(response.statusCode.toString(), utf8.decode(response.bodyBytes)));
        }
      }
    } catch(e) {
      _showErrorSnackbar(l10n.tableCellItemPickupErrorGeneric(e.toString()));
    } finally {
      if(mounted) setState(() => _isProcessingAction = false);
    }
  }

  // 🔥 GÜNCELLENEN: KDS feedback ile enhanced
  Future<void> _handleDeliverOrderItem(int orderItemId, AppLocalizations l10n) async {
    if (!mounted || _isProcessingAction) return;
    setState(() => _isProcessingAction = true);
    
    // Optimistic UI update feedback
    _showOverlayFeedback(Colors.green, Icons.check_circle, '🎉 Teslim ediliyor...');
    
    try {
      final response = await OrderService.markOrderItemDelivered(
          token: widget.token, orderId: widget.pendingOrder['id'], orderItemId: orderItemId);
      if (mounted) {
        if (response.statusCode == 200) {
          debugPrint('[TableCellWidget] 🎯 Item delivery successful, triggering update');
          widget.onOrderUpdated();
        } else {
          _showErrorSnackbar(l10n.tableCellDeliverErrorWithStatus(response.statusCode.toString()));
        }
      }
    } catch (e) {
      _showErrorSnackbar(l10n.tableCellDeliverErrorGeneric(e.toString()));
    } finally {
      if (mounted) setState(() => _isProcessingAction = false);
    }
  }

  // *** GÜNCELLENEN METOT ***
  Widget _buildStatusHeader(AppLocalizations l10n) {
    String statusText; // Değişkeni başta tanımla
    Color statusColor = Colors.black87;

    if (widget.isOccupied && widget.pendingOrder != null) {
      // ESKİ YÖNTEM (backend'den gelen metni kullanıyordu):
      // statusText = widget.pendingOrder!['status_display'] ?? l10n.unknown;

      // YENİ YÖNTEM (anahtarı kullanarak yerelleştirilmiş metni alır):
      statusText = getLocalizedOrderStatus(context, widget.pendingOrder!['status']);

      switch(widget.pendingOrder!['status']) {
        case STATUS_PENDING_SYNC: statusColor = Colors.grey.shade800; break;
        case STATUS_PENDING_APPROVAL: statusColor = Colors.purple.shade800; break;
        case STATUS_APPROVED: statusColor = Colors.blue.shade800; break;
        case STATUS_PREPARING: statusColor = Colors.deepOrange.shade700; break;
        case STATUS_READY_FOR_PICKUP: statusColor = Colors.teal.shade600; break;
        case STATUS_READY_FOR_DELIVERY: statusColor = Colors.indigo.shade700; break;
        default: statusColor = Colors.grey.shade800;
      }
    } else {
       statusText = l10n.tableCellDefaultTitle(widget.table['table_number'].toString());
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              // 🔥 YENİ: KDS status indicator
              if (widget.isOccupied && widget.pendingOrder != null)
                _buildKdsStatusIndicator(),
              Expanded(
                child: Text(
                  "#${widget.pendingOrder?['temp_id']?.toString().substring(0, 5) ?? widget.pendingOrder?['id'] ?? widget.table['table_number']} - $statusText",
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        ),
        Text(
          _formatDuration(_elapsedSeconds),
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: statusColor),
        ),
      ],
    );
  }

  // 🔥 YENİ: KDS durumu göstergesi
  Widget _buildKdsStatusIndicator() {
    if (widget.pendingOrder == null) return const SizedBox.shrink();
    
    final orderItems = widget.pendingOrder['order_items'] as List?;
    if (orderItems == null || orderItems.isEmpty) return const SizedBox.shrink();
    
    // KDS item durumlarını analiz et
    bool hasPreparingItems = false;
    bool hasReadyItems = false;
    bool hasPickedUpItems = false;
    
    for (final item in orderItems) {
      final kdsStatus = item['kds_status'] as String?;
      switch (kdsStatus) {
        case KDS_ITEM_STATUS_PREPARING:
          hasPreparingItems = true;
          break;
        case KDS_ITEM_STATUS_READY:
          hasReadyItems = true;
          break;
        case KDS_ITEM_STATUS_PICKED_UP:
          hasPickedUpItems = true;
          break;
      }
    }
    
    // Öncelik sırasına göre indicator göster
    if (hasReadyItems) {
      return Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.teal.shade600,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.restaurant_menu,
          color: Colors.white,
          size: 16,
        ),
      );
    } else if (hasPreparingItems) {
      return Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.orange.shade600,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.whatshot,
          color: Colors.white,
          size: 16,
        ),
      );
    } else if (hasPickedUpItems) {
      return Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.purple.shade600,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          Icons.pan_tool_alt,
          color: Colors.white,
          size: 16,
        ),
      );
    }
    
    return const SizedBox.shrink();
  }

  // 🔥 GÜNCELLENEN: Enhanced KDS status display
  Widget _buildItemRow(Map<String, dynamic> item, AppLocalizations l10n) {
    final bool isDelivered = item['delivered'] == true;
    final String kdsStatus = item['kds_status'] ?? KDS_ITEM_STATUS_PENDING;
    final bool isAwaitingApproval = item['is_awaiting_staff_approval'] == true;
    Widget actionWidget;

    if (isDelivered) {
      actionWidget = Tooltip(
        message: l10n.tableCellTooltipDeliveredToCustomer,
        child: Icon(Icons.check_circle, size: 28, color: Colors.green.shade600),
      );
    } else if (kdsStatus == KDS_ITEM_STATUS_READY) {
      actionWidget = IconButton(
        icon: const Icon(Icons.pan_tool_alt_outlined, size: 28), 
        color: Colors.purple.shade600, 
        padding: EdgeInsets.zero, 
        constraints: const BoxConstraints(), 
        tooltip: l10n.tableCellTooltipMarkAsPickedUpByWaiter, 
        onPressed: _isProcessingAction ? null : () => _handleItemPickup(item['id'], l10n),
      );
    } else if (kdsStatus == KDS_ITEM_STATUS_PICKED_UP) {
      actionWidget = IconButton(
        icon: const Icon(Icons.room_service_outlined, size: 28), 
        color: Colors.blue.shade600, 
        padding: EdgeInsets.zero, 
        constraints: const BoxConstraints(), 
        tooltip: l10n.tableCellTooltipDeliverToCustomer, 
        onPressed: _isProcessingAction ? null : () => _handleDeliverOrderItem(item['id'], l10n),
      );
    } else if (kdsStatus == KDS_ITEM_STATUS_PREPARING) {
      actionWidget = Tooltip(
        message: l10n.kdsStatusPreparing, 
        child: Icon(Icons.whatshot, size: 24, color: Colors.orange.shade800)
      );
    } else { // pending_kds
      actionWidget = Tooltip(
        message: l10n.tableCellTooltipWaitingForKitchen, 
        child: Icon(Icons.hourglass_empty, size: 22, color: Colors.grey.shade600)
      );
    }

    final String productName = item['menu_item']?['name'] ?? l10n.unknownProduct;
    final String? variantName = item['variant']?['name'];
    final String variantNameDisplay = (variantName != null && variantName.isNotEmpty) ? ' ($variantName)' : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Opacity(
              opacity: isDelivered ? 0.6 : 1.0,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: "${item['quantity']}x $productName$variantNameDisplay",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        decoration: isDelivered ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    if (isAwaitingApproval)
                      TextSpan(
                        text: l10n.newItemSuffix,
                        style: TextStyle(
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          actionWidget,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!widget.isOccupied) {
      return InkWell(
        onTap: widget.onTap,
        child: Card(
          color: Colors.white.withOpacity(0.6),
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Center(
            child: Text(
              l10n.tableCellDefaultTitle(widget.table['table_number'].toString()),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black54),
            ),
          ),
        ),
      );
    }

    final bool isPendingApproval = widget.pendingOrder['status'] == STATUS_PENDING_APPROVAL;
    final bool isPendingSync = widget.pendingOrder['status'] == STATUS_PENDING_SYNC;

    Color cardColor;
    Color borderColor;

    if (isPendingSync) {
      cardColor = Colors.grey.shade400.withOpacity(0.95);
      borderColor = Colors.grey.shade700;
    } else if (isPendingApproval) {
      cardColor = Colors.purple.shade100.withOpacity(0.95);
      borderColor = Colors.purple.shade600;
    } else if (widget.pendingOrder!['status'] == STATUS_READY_FOR_PICKUP || widget.pendingOrder!['status'] == 'ready_for_delivery') {
      cardColor = Colors.teal.shade300.withOpacity(0.9);
      borderColor = Colors.teal.shade600;
    } else if (widget.pendingOrder!['status'] == STATUS_PREPARING) {
      cardColor = Colors.orange.shade100.withOpacity(0.95);
      borderColor = Colors.orange.shade700;
    } else if (widget.pendingOrder!['status'] == STATUS_APPROVED) {
      cardColor = Colors.blue.shade100.withOpacity(0.95);
      borderColor = Colors.blue.shade600;
    } else {
      cardColor = Colors.blueGrey.shade100.withOpacity(0.95);
      borderColor = Colors.blueGrey.shade600;
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: Card(
        color: cardColor,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor, width: 2)
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12.0, 12.0, 12.0, 42.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusHeader(l10n),
                  const Divider(),
                  if (_isProcessingAction)
                    const Expanded(child: Center(child: LinearProgressIndicator()))
                  else
                    Expanded(
                      child: widget.pendingOrder['order_items'] == null || (widget.pendingOrder['order_items'] as List).isEmpty
                          ? Center(child: Text(l10n.tableCellNoOrderItems))
                          : ListView.builder(
                              padding: EdgeInsets.zero,
                              itemCount: widget.pendingOrder['order_items'].length,
                              itemBuilder: (context, index) {
                                return _buildItemRow(widget.pendingOrder['order_items'][index], l10n);
                              },
                            ),
                    ),
                ],
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.1),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                ),
                child: isPendingSync
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.add_shopping_cart, size: 18),
                              label: Text(l10n.addOrEditButton),
                              onPressed: widget.onTap,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap
                              ),
                            ),
                          ),
                        ],
                      )
                    : isPendingApproval
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              Expanded(child: ElevatedButton.icon(icon: const Icon(Icons.check_circle, size: 18), label: Text(l10n.buttonApprove), onPressed: widget.onApprove, style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 8), tapTargetSize: MaterialTapTargetSize.shrinkWrap))),
                              const SizedBox(width: 8),
                              Expanded(child: ElevatedButton.icon(icon: const Icon(Icons.cancel, size: 18), label: Text(l10n.buttonReject), onPressed: widget.onReject, style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 8), tapTargetSize: MaterialTapTargetSize.shrinkWrap))),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline),
                                iconSize: 24,
                                color: Colors.green.shade800,
                                tooltip: l10n.addProductOrEditTooltip,
                                onPressed: widget.onAddItem,
                              ),
                              PopupMenuButton<String>(
                                icon: Icon(Icons.more_vert, color: Colors.blueGrey.shade800),
                                tooltip: l10n.otherActionsTooltip,
                                onSelected: (value) {
                                  if (value == 'transfer') {
                                    widget.onTransfer();
                                  } else if (value == 'cancel') {
                                    widget.onCancel();
                                  }
                                },
                                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                                  PopupMenuItem<String>(
                                    value: 'transfer',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.swap_horiz_rounded, color: Colors.blue),
                                        const SizedBox(width: 8),
                                        Text(l10n.transferTableMenuItem),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'cancel',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.cancel_outlined, color: Colors.red),
                                        const SizedBox(width: 8),
                                        Text(l10n.cancelOrderMenuItem),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}