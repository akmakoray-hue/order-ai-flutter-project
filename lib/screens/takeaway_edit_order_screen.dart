// lib/screens/takeaway_edit_order_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:makarna_app/widgets/takeaway/takeaway_order_item_card.dart';
import '../models/order.dart' as AppOrder;
import '../models/order_item.dart';
import '../services/order_service.dart';
import '../models/menu_item.dart';
import '../models/menu_item_variant.dart';
import '../services/api_service.dart';
import '../services/pager_service.dart';
import '../widgets/add_order_item_dialog.dart';
import '../widgets/takeaway/takeaway_payment_modal.dart';
import 'pager_assignment_screen.dart';
import '../services/connectivity_service.dart';
import '../services/printing_service.dart';
import '../services/ticket_generator_service.dart';
import '../models/printer_config.dart';
import '../services/cache_service.dart';
import '../services/user_session.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../utils/currency_formatter.dart';
import '../widgets/credit_payment_modal.dart';

class TakeawayEditOrderScreen extends StatefulWidget {
  final AppOrder.Order order;
  final String token;
  final List<MenuItem> allMenuItems;
  final List<dynamic> allCategories;

  const TakeawayEditOrderScreen({
    Key? key,
    required this.token,
    required this.order,
    required this.allMenuItems,
    required this.allCategories,
  }) : super(key: key);

  @override
  _TakeawayEditOrderScreenState createState() =>
      _TakeawayEditOrderScreenState();
}

class _TakeawayEditOrderScreenState extends State<TakeawayEditOrderScreen> {
  late AppOrder.Order currentOrder;
  bool isLoading = true;
  String errorMessage = '';
  String message = '';
  bool _isMounted = false;
  bool _isProcessingAction = false;
  String? _fetchedBusinessName;
  bool _didFetchData = false;

  String? _assignedPagerSystemId;
  String? _assignedPagerDeviceId;
  String? _assignedPagerName;

  final PagerService _pagerService = PagerService.instance;

  @override
  void initState() {
    super.initState();
    _isMounted = true;
    _updateCurrentOrderAndPagerInfo(widget.order);

    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[TakeawayEditOrderScreen] 📡 Global refresh received: ${data['event_type']}');
      if (_isMounted && mounted) {
        final refreshKey = 'takeaway_edit_order_screen_${currentOrder.id ?? "unknown"}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _refreshOrderDetails();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[TakeawayEditOrderScreen] 📱 Screen became active notification received');
      if (_isMounted && mounted) {
        final refreshKey = 'takeaway_edit_order_screen_active_${currentOrder.id ?? "unknown"}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _refreshOrderDetails();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didFetchData) {
      final l10n = AppLocalizations.of(context)!;
      _pagerService.init(l10n);
      fetchBusinessName();
      _didFetchData = true;
    }
  }

  Future<void> fetchBusinessName() async {
    if (!_isMounted) return;
    setState(() => isLoading = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      final businessId = widget.order.business;
      final businessDetails = await ApiService.fetchBusinessDetails(widget.token, businessId);
      if (mounted) {
        _fetchedBusinessName = businessDetails['name'] ?? l10n.yourBusiness;
      }
    } catch (e) {
      if (mounted) {
        errorMessage = "İşletme bilgisi alınamadı: ${e.toString().replaceFirst("Exception: ", "")}";
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _updateCurrentOrderAndPagerInfo(AppOrder.Order orderData) {
    if (!_isMounted) return;
    setState(() {
      currentOrder = orderData;
      final pagerInfo = orderData.payment as Map<String, dynamic>?;
      if (pagerInfo != null) {
        _assignedPagerSystemId = pagerInfo['id']?.toString();
        _assignedPagerDeviceId = pagerInfo['device_id'] as String?;
        _assignedPagerName = pagerInfo['name'] as String?;
      } else {
        _assignedPagerSystemId = null;
        _assignedPagerDeviceId = null;
        _assignedPagerName = null;
      }
    });
  }

  @override
  void dispose() {
    _isMounted = false;
    super.dispose();
  }

  Future<void> _refreshOrderDetails() async {
    if (!_isMounted || !ConnectivityService.instance.isOnlineNotifier.value) return;
    setState(() {
      isLoading = true;
      message = '';
    });
    try {
      final updatedOrderData = await OrderService.fetchOrderDetails(
        token: widget.token,
        orderId: currentOrder.id!,
      );
      if (_isMounted) {
        if (updatedOrderData != null) {
          _updateCurrentOrderAndPagerInfo(AppOrder.Order.fromJson(updatedOrderData));
        } else {
          setState(() {
            message = AppLocalizations.of(context)!.errorOrderDetailsNotFound;
          });
        }
      }
    } catch (e) {
      if (_isMounted) setState(() => message = AppLocalizations.of(context)!.errorOrderDetailsUpdate(e.toString()));
    } finally {
      if (_isMounted) setState(() => isLoading = false);
    }
  }

  Future<void> _handleAddNewOrderItem({
    required MenuItem item,
    MenuItemVariant? variant,
    List<MenuItemVariant>? extras,
    String? tableUser,
    required int quantity,
  }) async {
    if (!_isMounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      isLoading = true;
      message = l10n.infoAddingProduct;
    });

    try {
      final response = await OrderService.addNewOrderItem(
        token: widget.token,
        orderId: currentOrder.syncId,
        item: item,
        variant: variant,
        extras: extras,
        tableUser: tableUser,
        quantity: quantity,
      );

      if (!_isMounted) return;

      final Map<String, dynamic> responseBody = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 201 || response.statusCode == 200) {
        if (responseBody['offline'] == true) {
          final updatedOrder = AppOrder.Order.fromJson(responseBody['data']);
          _updateCurrentOrderAndPagerInfo(updatedOrder);
        } else {
          await _refreshOrderDetails();
        }

        if (_isMounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.infoProductAdded), backgroundColor: Colors.green),
          );
        }
      } else {
        if (_isMounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.errorAddingProduct(response.statusCode.toString(), responseBody['detail'] ?? 'Bilinmeyen hata')), backgroundColor: Colors.redAccent),
          );
        }
      }
    } catch (e) {
      if (_isMounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorAddingProductGeneral(e.toString())), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (_isMounted) {
        setState(() {
          isLoading = false;
          message = '';
        });
      }
    }
  }

  Future<void> _handleDeleteOrderItem(OrderItem item) async {
   if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    bool? confirm = await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.dialogDeleteItemTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Text(l10n.dialogDeleteItemContent),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("İptal")),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(context, true), child: Text(l10n.dialogButtonDelete, style: const TextStyle(color: Colors.white))),
          ],
        );
      },
    );
    if (confirm != true || !mounted) return;
    setState(() => isLoading = true);
    try {
      final response = await OrderService.deleteOrderItem(token: widget.token, orderItemId: item.id!);
      if (mounted) {
        if (response.statusCode == 204) {
          await _refreshOrderDetails();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.infoProductDeleted), backgroundColor: Colors.green));
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorDeletingProduct(response.statusCode.toString(), utf8.decode(response.bodyBytes))), backgroundColor: Colors.redAccent));
        }
      }
    } catch (e) {
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorDeletingProductGeneral(e.toString())), backgroundColor: Colors.redAccent)); }
    } finally {
      if (mounted) { setState(() => isLoading = false); }
    }
  }

  Future<void> _handleDeliverOrderItem(OrderItem item) async {
    if(!mounted || _isProcessingAction || currentOrder.id == null || item.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isProcessingAction = true);
    try {
      final resp = await OrderService.markOrderItemDelivered(token: widget.token, orderId: currentOrder.id!, orderItemId: item.id!);
      if (mounted) {
        if (resp.statusCode == 200) {
          await _refreshOrderDetails();
          if(mounted) setState(() => message = l10n.infoItemDelivered);
          Future.delayed(const Duration(seconds: 2), () { if(mounted && message == l10n.infoItemDelivered) setState(() => message = ''); });
        } else {
          setState(() => message = l10n.errorDeliveringItem(resp.statusCode.toString()));
        }
      }
    } catch (e) {
      if (mounted) setState(() => message = l10n.errorDeliveringItemGeneral(e.toString()));
    } finally {
      if (mounted) setState(() => _isProcessingAction = false);
    }
  }

  Future<void> _showAddItemModal() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AddOrderItemDialog(
        token: widget.token,
        allMenuItems: widget.allMenuItems,
        categories: widget.allCategories,
        tableUsers: const [],
        onItemsAdded: (item, variant, extras, tableUser) {
          _handleAddNewOrderItem(
            item: item,
            variant: variant,
            extras: extras,
            tableUser: tableUser,
            quantity: 1,
          );
        },
      ),
    );
  }

  void _showPaymentScreenModal() async {
    if (!mounted) return;
    double totalAmount = _orderTotal();

    final dynamic paymentResult = await showModalBottomSheet<dynamic>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return TakeawayPaymentModal(
          token: widget.token,
          order: currentOrder,
          amount: totalAmount,
          onSuccess: () {
            if (mounted) {
              Navigator.of(context).pop(true);
            }
          },
        );
      },
    );

    if (!mounted) return;

    if (paymentResult == true || paymentResult == 'credit_success') {
      Navigator.pop(context, true);
    }
  }

  Future<void> _cancelOrder() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.dialogCancelOrderTitle),
        content: Text(l10n.takeawayDialogCancelContent),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(l10n.dialogButtonNo)),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(l10n.dialogButtonYesCancel, style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => isLoading = true);
    final String? pagerSystemIdToUpdate = _assignedPagerSystemId;
    try {
      final response = await OrderService.cancelOrder(widget.token, currentOrder.id!);
      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 204) {
        if (pagerSystemIdToUpdate != null) {
          try { await _pagerService.updatePager(widget.token, pagerSystemIdToUpdate, status: 'available'); } catch (e) { debugPrint("Pager durumu güncellenirken hata (iptal): $e"); }
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.infoOrderCancelled), backgroundColor: Colors.green));
        Navigator.pop(context, true);
      } else {
        if(mounted) setState(() => message = l10n.errorCancellingOrder(response.statusCode.toString(), utf8.decode(response.bodyBytes)));
      }
    } catch (e) {
      if (mounted) setState(() => message = l10n.errorCancellingOrderGeneral(e.toString()));
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _openPagerAssignmentScreenAndAssign() async {
    if (!_isMounted) return;
    final l10n = AppLocalizations.of(context)!;
    final String? selectedBluetoothDeviceId = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const PagerAssignmentScreen()));
    if (selectedBluetoothDeviceId != null && selectedBluetoothDeviceId.isNotEmpty && mounted) {
      setState(() => isLoading = true);
      try {
        final response = await OrderService.updateOrder(widget.token, currentOrder.id!, {'pager_device_id_to_assign': selectedBluetoothDeviceId});
        if (mounted) {
          if (response.statusCode == 200) {
            await _refreshOrderDetails();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.infoPagerAssigned), backgroundColor: Colors.green));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorAssigningPager(response.statusCode.toString())), backgroundColor: Colors.redAccent));
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorAssigningPagerGeneral(e.toString())), backgroundColor: Colors.redAccent));
        }
      } finally {
        if (mounted) setState(() => isLoading = false);
      }
    }
  }

  void _showQrDialog() {
    final l10n = AppLocalizations.of(context)!;
    final String? orderUuid = currentOrder.uuid;
    if (orderUuid == null || orderUuid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorNoQrLink)));
      return;
    }
    final uri = Uri.parse(ApiService.baseUrl.replaceAll('/api', ''));
    final guestLink = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/guest/takeaway/$orderUuid/';

    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.dialogQrTitle(currentOrder.id.toString()), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 250, height: 300,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                QrImageView(data: guestLink, version: QrVersions.auto, size: 200.0),
                const SizedBox(height: 10),
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(l10n.infoLinkCopied),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: guestLink));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.infoLinkCopied)));
                  },
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: <Widget>[
            TextButton(child: Text(l10n.dialogButtonClose), onPressed: () => Navigator.of(dialogContext).pop()),
          ],
        );
      },
    );
  }

  Future<void> _showPrintOptions() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;

    final List<PrinterConfig> allPrinters = CacheService.instance.getPrinters();
    final List<PrinterConfig> kitchenPrinters = allPrinters.where((p) => p.printerTypeEnum == PrinterType.kitchen).toList();
    final List<PrinterConfig> receiptPrinters = allPrinters.where((p) => p.printerTypeEnum == PrinterType.receipt).toList();

    if (kitchenPrinters.isEmpty && receiptPrinters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorNoPrinters), backgroundColor: Colors.orangeAccent),
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              if (receiptPrinters.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.receipt_long),
                  title: Text(l10n.infoPrintingCustomerReceipt.replaceAll("...", "")),
                  onTap: () async {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.infoPrintingCustomerReceipt)));
                    try {
                      final ticketBytes = await TicketGeneratorService.generateCustomerReceipt(currentOrder, _fetchedBusinessName ?? l10n.yourBusiness);
                      await PrintingService.printTicket(ticketBytes, receiptPrinters.first);
                    } catch (e) {
                      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorPrintingReceipt(e.toString())), backgroundColor: Colors.redAccent));
                    }
                  },
                ),
              if (kitchenPrinters.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.kitchen),
                  title: Text(l10n.infoPrintingKitchenTicket.replaceAll("...", "")),
                  onTap: () async {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.infoPrintingKitchenTicket)));
                    try {
                      final ticketBytes = await TicketGeneratorService.generateKitchenTicket(currentOrder);
                      await PrintingService.printTicket(ticketBytes, kitchenPrinters.first);
                    } catch (e) {
                      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorPrintingKitchenTicket(e.toString())), backgroundColor: Colors.redAccent));
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  double _orderTotal() {
    double sum = 0.0;
    if (currentOrder.orderItems.isNotEmpty) {
      for (var item in currentOrder.orderItems) {
        sum += item.price * item.quantity;
      }
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (isLoading && _fetchedBusinessName == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.blueGrey.shade800, Colors.blueGrey.shade900], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
          child: const Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }
   
    final double orderTotalAmount = _orderTotal();
    final bool isPaid = currentOrder.isPaid;
    final bool isCancelled = currentOrder.orderStatusEnum == AppOrder.OrderStatus.cancelled;
    final bool isCompleted = currentOrder.orderStatusEnum == AppOrder.OrderStatus.completed;
    final bool isRejected = currentOrder.orderStatusEnum == AppOrder.OrderStatus.rejected;

    String appBarTitle = l10n.takeawayOrderTitle(currentOrder.customerName ?? l10n.guestCustomerName);
    if (isPaid) {
      appBarTitle += ' ${l10n.orderStatusPaid}';
    } else if (isCancelled) {
      appBarTitle += ' ${l10n.orderStatusCancelled}';
    } else if (isRejected) {
      appBarTitle += ' ${l10n.orderStatusRejected}';
    }

    final bool canShowActions = !isPaid && !isCancelled && !isCompleted && !isRejected;

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, true);
        return false;
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: Text(
            appBarTitle,
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            overflow: TextOverflow.ellipsis,
          ),
          flexibleSpace: Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF283593), Color(0xFF455A64)], begin: Alignment.topLeft, end: Alignment.bottomRight))),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              Navigator.pop(context, true);
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.print_outlined, color: Colors.white),
              tooltip: l10n.tooltipPrintReceipt,
              onPressed: isLoading ? null : _showPrintOptions,
            ),
            if (canShowActions && currentOrder.uuid != null)
              IconButton(icon: const Icon(Icons.qr_code_2, color: Colors.white), tooltip: l10n.tooltipShowQr, onPressed: _showQrDialog),
            if (canShowActions)
              IconButton(icon: const Icon(Icons.add_shopping_cart_outlined, color: Colors.white), tooltip: l10n.editOrderTooltipAddProduct, onPressed: isLoading ? null : _showAddItemModal),
            if (canShowActions)
              IconButton(icon: const Icon(Icons.cancel_outlined, color: Colors.white), tooltip: l10n.tooltipCancelOrder, onPressed: isLoading ? null : _cancelOrder),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.blue.shade900.withOpacity(0.9), Colors.blue.shade400.withOpacity(0.8)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
          child: SafeArea(
            child: Column(
              children: [
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(message, textAlign: TextAlign.center, style: TextStyle(color: message.contains("hata") ? Colors.orangeAccent : Colors.lightGreenAccent, fontWeight: FontWeight.bold)),
                  ),
                
                // +++ DEĞİŞİKLİK BURADA BAŞLIYOR +++
                Expanded(
                  child: isLoading && currentOrder.orderItems.isEmpty
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : currentOrder.orderItems.isEmpty && !isLoading
                          ? Center(child: Text(l10n.errorNoOrderItems, style: const TextStyle(color: Colors.white, fontSize: 16)))
                          : RefreshIndicator(
                              onRefresh: _refreshOrderDetails,
                              child: GridView.builder(
                                padding: const EdgeInsets.all(12.0),
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 350.0, // Her bir öğenin maksimum genişliği
                                  mainAxisSpacing: 10.0,
                                  crossAxisSpacing: 10.0,
                                  childAspectRatio: 1.6, // En/boy oranı
                                ),
                                itemCount: currentOrder.orderItems.length,
                                itemBuilder: (ctx, i) {
                                  final item = currentOrder.orderItems[i];
                                  return TakeawayOrderItemCard(
                                    item: item,
                                    token: widget.token,
                                    allMenuItems: widget.allMenuItems,
                                    isLoading: _isProcessingAction,
                                    onDelete: () => _handleDeleteOrderItem(item),
                                    onDeliver: () => _handleDeliverOrderItem(item),
                                    onAddExtra: () => _showAddItemModal(),
                                  );
                                },
                              ),
                            ),
                ),
                // +++ DEĞİŞİKLİK BURADA BİTİYOR +++

                Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[200]?.withOpacity(0.9),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), spreadRadius: 0, blurRadius: 5, offset: const Offset(0, -3))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            Expanded(child: Text(
                              l10n.newOrderBasketTotalLabel(CurrencyFormatter.format(orderTotalAmount)),
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87))),
                            if (canShowActions)
                              IconButton(
                                icon: const Icon(Icons.add_box, color: Colors.blueAccent, size: 30),
                                tooltip: l10n.editOrderTooltipAddProduct,
                                onPressed: isLoading ? null : _showAddItemModal,
                              ),
                          ],
                        ),
                      ),
                      if (canShowActions)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple.shade400, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 5),
                            onPressed: isLoading || currentOrder.orderItems.isEmpty ? null : _showPaymentScreenModal,
                            icon: const Icon(Icons.payment),
                            label: Text(l10n.buttonPaymentScreen, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(
                            isPaid ? l10n.statusPaidFull : (isCancelled ? l10n.statusCancelledFull : l10n.statusRejectedFull),
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isPaid ? Colors.green.shade700 : Colors.red.shade700)
                          ),
                        )
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}