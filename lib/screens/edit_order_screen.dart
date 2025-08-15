// lib/screens/edit_order_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import '../widgets/bills/bill_layout_widget.dart';
import '../services/printing_service.dart';
import '../services/ticket_generator_service.dart';
import '../models/printer_config.dart';
import '../services/cache_service.dart';
import '../services/user_session.dart';
import '../models/menu_item.dart' as AppMenuItemModel;
import '../models/menu_item_variant.dart';
import '../services/api_service.dart';
import '../services/order_service.dart';
import '../services/pager_service.dart';
import '../widgets/add_order_item_dialog.dart';
import '../widgets/editable_order_item_card.dart';
import '../widgets/payment_modal.dart';
import 'pager_assignment_screen.dart';
import '../services/connectivity_service.dart';
import '../models/order.dart' as AppOrder;
import '../models/order_item.dart';
import '../utils/currency_formatter.dart';

class EditOrderScreen extends StatefulWidget {
  final String token;
  final dynamic order;
  final List<AppMenuItemModel.MenuItem> allMenuItems;
  final int businessId;

  const EditOrderScreen({
    Key? key,
    required this.token,
    required this.order,
    required this.allMenuItems,
    required this.businessId,
  }) : super(key: key);

  @override
  _EditOrderScreenState createState() => _EditOrderScreenState();
}

class _EditOrderScreenState extends State<EditOrderScreen> {
  late AppOrder.Order currentOrder;
  List<AppMenuItemModel.MenuItem> menuItems = [];
  List<dynamic> categories = [];
  bool isLoading = true;
  String errorMessage = '';
  String message = '';
  bool _isProcessingAction = false;
  bool _isMounted = false;
  late String _fetchedBusinessName;
  bool _didFetchData = false;

  String? _assignedPagerSystemId;
  String? _assignedPagerDeviceId;
  String? _assignedPagerName;

  final PagerService _pagerService = PagerService.instance;

  @override
  void initState() {
    super.initState();
    _isMounted = true;
    _fetchedBusinessName = "İşletmeniz";
    _updateCurrentOrder(AppOrder.Order.fromJson(widget.order as Map<String, dynamic>));

    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[EditOrderScreen] 📡 Global refresh received: ${data['event_type']}');
      if (_isMounted && mounted) {
        final refreshKey = 'edit_order_screen_${currentOrder.id ?? "unknown"}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _refreshOrderDetails();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[EditOrderScreen] 📱 Screen became active notification received');
      if (_isMounted && mounted) {
        final refreshKey = 'edit_order_screen_active_${currentOrder.id ?? "unknown"}';
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
      fetchInitialData();
      _didFetchData = true;
    }
  }

  void _updateCurrentOrder(AppOrder.Order orderData) {
    if (!_isMounted) return;
    setState(() {
      currentOrder = orderData;
      final paymentData = currentOrder.payment;
      if (paymentData is Map<String, dynamic> && paymentData.containsKey('device_id')) {
        _assignedPagerSystemId = paymentData['id']?.toString();
        _assignedPagerDeviceId = paymentData['device_id'] as String?;
        _assignedPagerName = paymentData['name'] as String?;
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

  Future<void> fetchInitialData() async {
    if (!_isMounted) return;
    setState(() => isLoading = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      final businessId = widget.order['business'];
      final results = await Future.wait([
        OrderService.fetchMenuItems(widget.token),
        OrderService.fetchCategories(widget.token),
        ApiService.fetchBusinessDetails(widget.token, businessId),
      ]);
      if (mounted) {
        menuItems = (results[0] as List).map((e) => AppMenuItemModel.MenuItem.fromJson(e)).toList();
        categories = results[1] as List<dynamic>;
        _fetchedBusinessName = (results[2] as Map<String, dynamic>)['name'] ?? l10n.yourBusiness;
      }
    } catch (e) {
      if (mounted) {
        errorMessage = "Veriler yüklenirken hata: ${e.toString().replaceFirst("Exception: ", "")}";
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _refreshOrderDetails() async {
    if (!_isMounted || !ConnectivityService.instance.isOnlineNotifier.value || currentOrder.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() { isLoading = true; message = ''; });
    try {
      final updatedOrderData = await OrderService.fetchOrderDetails(
        token: widget.token,
        orderId: currentOrder.id!,
      );
      if (_isMounted) {
        if (updatedOrderData != null) {
          _updateCurrentOrder(AppOrder.Order.fromJson(updatedOrderData));
        } else {
          setState(() {
            message = l10n.errorOrderDetailsNotFound;
          });
        }
      }
    } catch (e) {
      if (_isMounted) setState(() => message = l10n.errorOrderDetailsUpdate(e.toString()));
    } finally {
      if (_isMounted) setState(() => isLoading = false);
    }
  }

  Future<void> _handleAddNewOrderItem({
    required AppMenuItemModel.MenuItem item,
    MenuItemVariant? variant,
    List<MenuItemVariant>? extras,
    String? tableUser,
    required int quantity,
  }) async {
    if (!_isMounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() { isLoading = true; message = l10n.infoAddingProduct; });
    String currentMessageInfo = '';

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
        currentMessageInfo = l10n.infoProductAdded;
       
        if (responseBody['offline'] == true) {
          _updateCurrentOrder(AppOrder.Order.fromJson(responseBody['data']));
        } else {
          await _refreshOrderDetails();
        }

        if (_isMounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(currentMessageInfo), backgroundColor: Colors.green),
          );
        }
      } else {
        currentMessageInfo = l10n.editOrderErrorAddingProductWithStatus(response.statusCode.toString(), responseBody['detail'] ?? l10n.unknown);
        if (_isMounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(currentMessageInfo), backgroundColor: Colors.redAccent),
          );
        }
      }
    } catch (e) {
      currentMessageInfo = l10n.errorAddingProductGeneral(e.toString());
      if (_isMounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(currentMessageInfo), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (_isMounted) {
        setState(() {
          isLoading = false;
          message = currentMessageInfo.contains("hata") || currentMessageInfo.contains("Error") ? currentMessageInfo : '';
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
        final dialogL10n = AppLocalizations.of(context)!;
        return AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(dialogL10n.dialogDeleteItemTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Text(dialogL10n.dialogDeleteItemContent),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(dialogL10n.dialogButtonCancel)),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () => Navigator.pop(context, true), child: Text(dialogL10n.dialogButtonDelete, style: const TextStyle(color: Colors.white))),
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
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorGeneral(e.toString())), backgroundColor: Colors.redAccent)); }
    } finally {
      if (mounted) { setState(() => isLoading = false); }
    }
  }

  Future<void> _handleDeliverOrderItem(OrderItem item) async {
    if(!mounted || isLoading || currentOrder.id == null || item.id == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => isLoading = true);
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
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> _showAddItemModal() async {
    if (!mounted) return;
    List<dynamic>? tableUsersRaw = currentOrder.tableUsers;
    List<String> tableUserNames = (tableUsersRaw?.map((user) => user['name'].toString()).toList()) ?? [];

    await showDialog(
      context: context,
      builder: (_) => AddOrderItemDialog(
        token: widget.token,
        allMenuItems: widget.allMenuItems,
        categories: categories,
        tableUsers: tableUserNames,
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
    final l10n = AppLocalizations.of(context)!;
    double totalAmount = _orderTotal();
    final String? pagerSystemIdToUpdate = _assignedPagerSystemId;

    final paymentSuccessful = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return PaymentModal(
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

    if (paymentSuccessful == true && mounted) {
      if (pagerSystemIdToUpdate != null) {
        setState(() => isLoading = true);
        try {
          await _pagerService.updatePager(
              widget.token,
              pagerSystemIdToUpdate,
              status: 'available',
              orderIdToAssign: null
          );
        } catch (e) {
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.editOrderErrorUpdatingPagerStatus(e.toString())), backgroundColor: Colors.orangeAccent));
        }
      }
      Navigator.pop(context, true);
    } else if (mounted){
      setState(() => isLoading = false);
    }
  }

  Future<void> _cancelOrder() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext)!;
        return AlertDialog(
          title: Text(dialogL10n.dialogCancelOrderTitle),
          content: Text(dialogL10n.dialogCancelOrderContent),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(dialogL10n.dialogButtonNo)),
            TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(dialogL10n.dialogButtonYesCancel, style: const TextStyle(color: Colors.red))),
          ],
        );
      },
    );
    if (confirm != true || !mounted) return;
    setState(() => isLoading = true);
    final String? pagerSystemIdToUpdate = _assignedPagerSystemId;
    try {
      final response = await OrderService.cancelOrder(widget.token, currentOrder.id!);
      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 204) {
        if (pagerSystemIdToUpdate != null) {
          try { await _pagerService.updatePager(widget.token, pagerSystemIdToUpdate, status: 'available'); } catch (e) { debugPrint(l10n.editOrderErrorUpdatingPagerOnCancel(e.toString())); }
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
      String currentMessageInfo = '';
      try {
        final response = await OrderService.updateOrder(widget.token, currentOrder.id!, {'pager_device_id_to_assign': selectedBluetoothDeviceId});
        if (mounted) {
          if (response.statusCode == 200) {
            await _refreshOrderDetails();
            currentMessageInfo = l10n.infoPagerAssigned;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(currentMessageInfo), backgroundColor: Colors.green));
          } else {
            currentMessageInfo = l10n.errorAssigningPager(response.statusCode.toString());
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$currentMessageInfo - ${utf8.decode(response.bodyBytes)}"), backgroundColor: Colors.redAccent));
          }
          if(mounted) setState(() => message = currentMessageInfo.contains("hata") || currentMessageInfo.contains("Error") ? currentMessageInfo: '');
        }
      } catch (e) {
        if (mounted) {
          currentMessageInfo = l10n.errorAssigningPagerGeneral(e.toString());
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(currentMessageInfo), backgroundColor: Colors.redAccent));
          setState(() => message = currentMessageInfo);
        }
      } finally {
        if (mounted) setState(() => isLoading = false);
      }
    }
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
        final dialogL10n = AppLocalizations.of(ctx)!;
        return SafeArea(
          child: Wrap(
            children: [
              if (receiptPrinters.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.receipt_long),
                  title: Text(dialogL10n.editOrderPrintCustomerReceipt),
                  onTap: () async {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(dialogL10n.infoPrintingCustomerReceipt)));
                    try {
                      final ticketBytes = await TicketGeneratorService.generateCustomerReceipt(currentOrder, _fetchedBusinessName ?? "İşletmeniz");
                      await PrintingService.printTicket(ticketBytes, receiptPrinters.first);
                    } catch (e) {
                      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(dialogL10n.errorPrintingReceipt(e.toString())), backgroundColor: Colors.redAccent));
                    }
                  },
                ),
              if (kitchenPrinters.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.kitchen),
                  title: Text(dialogL10n.editOrderPrintKitchenTicket),
                  onTap: () async {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(dialogL10n.infoPrintingKitchenTicket)));
                    try {
                      final ticketBytes = await TicketGeneratorService.generateKitchenTicket(currentOrder);
                      await PrintingService.printTicket(ticketBytes, kitchenPrinters.first);
                    } catch (e) {
                      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(dialogL10n.errorPrintingKitchenTicket(e.toString())), backgroundColor: Colors.redAccent));
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
    if (isLoading && currentOrder.id == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.blueGrey.shade800, Colors.blueGrey.shade900], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
          child: const Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }
   
    final double orderTotalAmount = _orderTotal();
    final bool isCreditOrder = currentOrder.creditDetails != null;
    final bool isPaid = currentOrder.isPaid;
    final bool isCancelled = currentOrder.orderStatusEnum == AppOrder.OrderStatus.cancelled;
    final bool isCompleted = currentOrder.orderStatusEnum == AppOrder.OrderStatus.completed;
    final bool isRejected = currentOrder.orderStatusEnum == AppOrder.OrderStatus.rejected;

    String appBarTitle;
    if(currentOrder.orderType == 'takeaway'){
      appBarTitle = l10n.editOrderTitleTakeaway(currentOrder.customerName ?? l10n.guestCustomerName);
    } else {
        final tableNum = currentOrder.table;
        appBarTitle = l10n.editOrderTitleTable(tableNum?.toString() ?? '');
    }

    if (isCreditOrder && (currentOrder.creditDetails as Map?)?['paid_at'] == null) {
      appBarTitle += l10n.editOrderStatusCreditUnpaid;
    } else if (isCreditOrder && (currentOrder.creditDetails as Map?)?['paid_at'] != null) {
      appBarTitle += l10n.editOrderStatusCreditPaid;
    } else if (isPaid && !isCreditOrder) {
      appBarTitle += l10n.orderStatusPaid;
    } else if (isCancelled) {
      appBarTitle += l10n.orderStatusCancelled;
    } else if (isRejected) {
      appBarTitle += l10n.orderStatusRejected;
    }

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
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF283593), Color(0xFF455A64)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
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
            if (!isPaid && !isCreditOrder && !isCancelled && !isCompleted && !isRejected)
              IconButton(
                icon: const Icon(Icons.cancel_outlined, color: Colors.white),
                tooltip: l10n.tooltipCancelOrder,
                onPressed: isLoading ? null : _cancelOrder,
              ),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.blueGrey.shade800,
                Colors.blueGrey.shade900,
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                if (currentOrder.orderType != 'takeaway' && !isPaid && !isCreditOrder && !isCancelled && !isCompleted && !isRejected)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            _assignedPagerDeviceId != null && _assignedPagerDeviceId!.isNotEmpty
                                ? l10n.editOrderPagerAssigned(_assignedPagerName ?? (_assignedPagerDeviceId!.length > 8 ? '...${_assignedPagerDeviceId!.substring(_assignedPagerDeviceId!.length - 5)}' : _assignedPagerDeviceId!))
                                : l10n.editOrderPagerNotAssigned,
                            style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ElevatedButton.icon(
                          icon: Icon(_assignedPagerDeviceId != null && _assignedPagerDeviceId!.isNotEmpty ? Icons.edit_notifications_outlined : Icons.add_alert_outlined, size: 18),
                          label: Text(_assignedPagerDeviceId != null && _assignedPagerDeviceId!.isNotEmpty ? l10n.buttonChange : l10n.buttonAssign),
                          onPressed: isLoading ? null : _openPagerAssignmentScreenAndAssign,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.tealAccent.withOpacity(0.8),
                            foregroundColor: Colors.black87,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (currentOrder.orderType != 'takeaway' && !isPaid && !isCreditOrder && !isCancelled && !isCompleted && !isRejected)
                  const Divider(color: Colors.white24, height: 1),
                if (isCreditOrder && (currentOrder.creditDetails as Map?)?['notes'] != null && (currentOrder.creditDetails as Map)['notes'].isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Card(
                      color: Colors.orangeAccent.withOpacity(0.8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          l10n.editOrderCreditNote((currentOrder.creditDetails as Map)['notes']),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                if (message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: message.contains("hata") || message.contains("sorun") || message.contains("Error")
                                ? Colors.orangeAccent
                                : Colors.lightGreenAccent,
                            fontWeight: FontWeight.bold)),
                  ),
                
                // +++ DEĞİŞİKLİK BURADA BAŞLIYOR +++
                Expanded(
                  child: isLoading && currentOrder.orderItems.isEmpty
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : currentOrder.orderItems.isEmpty && !isLoading
                          ? Center(
                              child: Text(
                                l10n.errorNoOrderItems,
                                style: const TextStyle(color: Colors.white),
                              ),
                            )
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
                                  return EditableOrderItemCard(
                                    item: item,
                                    token: widget.token,
                                    allMenuItems: widget.allMenuItems,
                                    isLoading: _isProcessingAction,
                                    onDelete: () => _handleDeleteOrderItem(item),
                                    onDeliver: () => _handleDeliverOrderItem(item),
                                    onAddExtra: () {}, // Bu ekran için geçici olarak boş
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
                              l10n.editOrderTotal(CurrencyFormatter.format(orderTotalAmount)),
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87)
                            )),
                            if (!isPaid && !isCreditOrder && !isCancelled && !isCompleted && !isRejected)
                              IconButton(
                                icon: const Icon(Icons.add_box, color: Colors.blueAccent, size: 30),
                                tooltip: l10n.editOrderTooltipAddProduct,
                                onPressed: isLoading ? null : _showAddItemModal,
                              ),
                          ],
                        ),
                      ),
                      if (!isPaid && !isCreditOrder && !isCancelled && !isCompleted && !isRejected)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple.shade400, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 5),
                            onPressed: isLoading || currentOrder.orderItems.isEmpty ? null : _showPaymentScreenModal,
                            icon: const Icon(Icons.payment),
                            label: Text(
                              l10n.buttonPaymentScreen,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                        )
                      else if (isPaid && !isCreditOrder)
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(l10n.statusPaidFull, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green.shade700)),
                        )
                      else if (isCreditOrder && (currentOrder.creditDetails as Map?)?['paid_at'] == null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.price_check_outlined),
                            label: Text(l10n.editOrderButtonCloseCreditPayment, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            onPressed: isLoading ? null : _showPaymentScreenModal,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade600, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
                          ),
                        )
                      else if (isCreditOrder && (currentOrder.creditDetails as Map?)?['paid_at'] != null)
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(l10n.editOrderStatusCreditPaymentReceived, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green.shade700)),
                        )
                      else if (isCancelled)
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(l10n.statusCancelledFull, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red.shade700)),
                        )
                      else if (isRejected)
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(l10n.statusRejectedFull, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red.shade700)),
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