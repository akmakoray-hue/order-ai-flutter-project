// lib/screens/takeaway_order_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../controllers/takeaway_order_screen_controller.dart';
import '../services/order_service.dart';
import '../services/pager_service.dart';
import 'takeaway_order_form_screen.dart';
import 'takeaway_edit_order_screen.dart';
import '../utils/notifiers.dart';
import '../main.dart';
import 'pager_assignment_screen.dart';
import '../widgets/takeaway/takeaway_order_card.dart';
import '../models/order.dart' as AppOrder;
import '../widgets/takeaway/takeaway_order_details_modal.dart';

class TakeawayOrderScreen extends StatefulWidget {
  final String token;
  final int businessId;
  final VoidCallback? onGoHome;

  const TakeawayOrderScreen({
    Key? key,
    required this.token,
    required this.businessId,
    this.onGoHome,
  }) : super(key: key);

  @override
  _TakeawayOrderScreenState createState() => _TakeawayOrderScreenState();
}

// 🎯 THUNDERING HERD ÇÖZÜMEİ: RouteAware ve WidgetsBindingObserver eklendi
class _TakeawayOrderScreenState extends State<TakeawayOrderScreen> 
    with RouteAware, WidgetsBindingObserver {
  
  late TakeawayOrderScreenController _controller;
  final ScrollController _scrollController = ScrollController();
  
  final PagerService _pagerService = PagerService.instance;
  bool _isDependenciesInitialized = false;

  // 🎯 THUNDERING HERD ÇÖZÜMEİ: Ekran durumu takibi
  bool _isCurrent = true;
  bool _isAppInForeground = true;

  @override
  void initState() {
    super.initState();
    debugPrint("TakeawayOrderScreen: initState");
    
    // 🎯 THUNDERING HERD ÇÖZÜMEİ: WidgetsBindingObserver eklendi
    WidgetsBinding.instance.addObserver(this);
    
    _controller = TakeawayOrderScreenController(
      token: widget.token,
      businessId: widget.businessId,
      onStateUpdate: () {
        if (mounted) {
          setState(() {});
        }
      },
    );

    _controller.loadFirstPage();
    _scrollController.addListener(() {
      if (_scrollController.position.extentAfter < 300) {
        _controller.loadMore();
      }
    });

    // 🎯 THUNDERING HERD ÇÖZÜMEİ: Notifier listener'lar optimized
    shouldRefreshTablesNotifier.addListener(_handleDataRefreshRequest);
    orderStatusUpdateNotifier.addListener(_handleSpecificOrderStatusUpdate);

    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[TakeawayOrderScreen] 📡 Global refresh received: ${data['event_type']}');
      _safeRefreshData();
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[TakeawayOrderScreen] 📱 Screen became active notification received');
      if (_isCurrent) {
        _safeRefreshData();
      }
    });
  }

  @override
  void dispose() {
    debugPrint("TakeawayOrderScreen: dispose");
    
    // 🎯 THUNDERING HERD ÇÖZÜMEİ: Observer'ları temizle
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    
    _scrollController.dispose();
    shouldRefreshTablesNotifier.removeListener(_handleDataRefreshRequest);
    orderStatusUpdateNotifier.removeListener(_handleSpecificOrderStatusUpdate);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isDependenciesInitialized) {
      _pagerService.init(AppLocalizations.of(context)!);
      
      final route = ModalRoute.of(context);
      if (route is PageRoute) {
        routeObserver.subscribe(this, route);
      }
      _isDependenciesInitialized = true;
    }
  }

  // 🎯 THUNDERING HERD ÇÖZÜMEİ: RouteAware metodları
  @override
  void didPush() {
    _isCurrent = true;
    debugPrint('TakeawayOrderScreen: didPush - Ekran aktif oldu.');
  }

  @override
  void didPopNext() {
    _isCurrent = true;
    debugPrint("TakeawayOrderScreen: didPopNext - Ekran tekrar aktif oldu, veriler yenileniyor.");
    _safeRefreshData();
    super.didPopNext();
  }

  @override
  void didPushNext() {
    _isCurrent = false;
    debugPrint("TakeawayOrderScreen: didPushNext - Ekran arka plana gitti.");
  }

  @override
  void didPop() {
    _isCurrent = false;
    debugPrint("TakeawayOrderScreen: didPop - Ekran kapatıldı.");
  }

  // 🎯 THUNDERING HERD ÇÖZÜMEİ: App lifecycle kontrolü
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _isAppInForeground = state == AppLifecycleState.resumed;
    
    if (_isAppInForeground && _isCurrent) {
      debugPrint('TakeawayOrderScreen: App foreground\'a geldi, veriler yenileniyor.');
      _safeRefreshData();
    }
  }

  // 🎯 THUNDERING HERD ÇÖZÜMEİ: Sadece aktif ekranlar için güncelleme kontrolü
  bool _shouldProcessUpdate() {
    return mounted && _isCurrent && _isAppInForeground;
  }

  // 🎯 RefreshManager ile güvenli veri yenileme
  void _safeRefreshData() {
    if (_shouldProcessUpdate()) {
      final refreshKey = 'takeaway_order_screen_${widget.businessId}';
      RefreshManager.throttledRefresh(refreshKey, () async {
        await _controller.loadFirstPage();
      });
    }
  }

  // 🎯 THUNDERING HERD ÇÖZÜMEİ: Optimized notifier handlers
  void _handleDataRefreshRequest() {
    if (shouldRefreshTablesNotifier.value && _shouldProcessUpdate()) {
      debugPrint("TakeawayOrderScreen: shouldRefreshTablesNotifier tetiklendi, veriler yenileniyor.");
      _safeRefreshData();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) shouldRefreshTablesNotifier.value = false;
      });
    } else if (shouldRefreshTablesNotifier.value) {
      debugPrint("TakeawayOrderScreen: Ekran aktif değil, shouldRefreshTablesNotifier atlandı.");
    }
  }

  void _handleSpecificOrderStatusUpdate() {
    if (orderStatusUpdateNotifier.value != null && _shouldProcessUpdate()) {
      debugPrint("TakeawayOrderScreen: orderStatusUpdateNotifier tetiklendi, veriler yenileniyor.");
      _safeRefreshData();
    } else if (orderStatusUpdateNotifier.value != null) {
      debugPrint("TakeawayOrderScreen: Ekran aktif değil, orderStatusUpdate atlandı.");
    }
  }

  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message), 
        backgroundColor: Colors.redAccent
      )
    );
  }

  Future<void> _approveOrder(AppOrder.Order order) async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    setState(() => _controller.isFirstLoadRunning = true);
    try {
      await OrderService.approveGuestOrder(token: widget.token, orderId: order.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.takeawayOrderApproved), 
            backgroundColor: Colors.green
          ),
        );
        _controller.loadFirstPage();
      }
    } catch (e) {
      _showErrorSnackbar(l10n.takeawayErrorApproving(e.toString()));
    } finally {
      if (mounted) setState(() => _controller.isFirstLoadRunning = false);
    }
  }

  Future<void> _rejectOrder(AppOrder.Order order) async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.takeawayDialogRejectTitle),
        content: Text(l10n.takeawayDialogRejectContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false), 
            child: Text(l10n.dialogButtonNo)
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true), 
            child: Text(
              l10n.takeawayDialogButtonReject, 
              style: const TextStyle(color: Colors.red)
            )
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _controller.isFirstLoadRunning = true);
    try {
      await OrderService.rejectGuestOrder(token: widget.token, orderId: order.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.takeawayOrderRejected), 
            backgroundColor: Colors.orangeAccent
          )
        );
        _controller.loadFirstPage();
      }
    } catch (e) {
      _showErrorSnackbar(l10n.takeawayErrorRejecting(e.toString()));
    } finally {
      if (mounted) setState(() => _controller.isFirstLoadRunning = false);
    }
  }

  Future<void> _cancelOrder(AppOrder.Order order) async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.dialogCancelOrderTitle),
        content: Text(l10n.takeawayDialogCancelContent),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false), 
            child: Text(l10n.dialogButtonNo)
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true), 
            child: Text(
              l10n.dialogButtonYesCancel, 
              style: const TextStyle(color: Colors.red)
            )
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _controller.isFirstLoadRunning = true);
    final String? pagerSystemIdToUpdate = order.payment?['id']?.toString();
    try {
      final response = await OrderService.cancelOrder(widget.token, order.id!);
      if (mounted) {
        if (response.statusCode == 200 || response.statusCode == 204) {
          if (pagerSystemIdToUpdate != null) {
            try { 
              await _pagerService.updatePager(
                widget.token, 
                pagerSystemIdToUpdate, 
                status: 'available'
              ); 
            } catch (e) { 
              debugPrint('TakeawayOrderScreen: Pager güncelleme hatası: $e');
            }
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.infoOrderCancelled), 
              backgroundColor: Colors.green
            )
          );
          _controller.loadFirstPage();
        } else {
          _showErrorSnackbar(l10n.takeawayErrorCancellingWithCode(response.statusCode.toString()));
        }
      }
    } catch (e) {
      _showErrorSnackbar(l10n.errorCancellingOrderGeneral(e.toString()));
    } finally {
      if (mounted) setState(() => _controller.isFirstLoadRunning = false);
    }
  }

  Future<void> _openPagerAssignmentScreenAndAssign(AppOrder.Order order) async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    final String? selectedBluetoothDeviceId = await Navigator.push<String>(
      context, 
      MaterialPageRoute(builder: (_) => const PagerAssignmentScreen())
    );
    if (selectedBluetoothDeviceId != null && selectedBluetoothDeviceId.isNotEmpty && mounted) {
      setState(() => _controller.isFirstLoadRunning = true);
      try {
        final response = await OrderService.updateOrder(
          widget.token, 
          order.id!, 
          {'pager_device_id_to_assign': selectedBluetoothDeviceId}
        );
        if (mounted) {
          if (response.statusCode == 200) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.infoPagerAssigned), 
                backgroundColor: Colors.green
              )
            );
            _controller.loadFirstPage();
          } else {
            _showErrorSnackbar(l10n.takeawayErrorAssigningPagerWithCode(response.statusCode.toString()));
          }
        }
      } catch (e) {
        _showErrorSnackbar(l10n.errorAssigningPagerGeneral(e.toString()));
      } finally {
        if (mounted) setState(() => _controller.isFirstLoadRunning = false);
      }
    }
  }
  
  Future<void> _showOrderDetailsModal(AppOrder.Order order) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) => TakeawayOrderDetailsModal(
        order: order,
        token: widget.token,
        onCancel: () => _cancelOrder(order),
        onAssignPager: () => _openPagerAssignmentScreenAndAssign(order),
        onApprove: () => _approveOrder(order),
        onReject: () => _rejectOrder(order),
        onOrderUpdated: _controller.loadFirstPage,
      ),
    );

    if (result == 'edit_order' && mounted) {
      final refreshNeeded = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TakeawayEditOrderScreen(
            token: widget.token,
            order: order,
            allMenuItems: _controller.menuItems,
            allCategories: _controller.categories,
          ),
        ),
      );
      if (refreshNeeded == true) {
        _controller.loadFirstPage();
      }
    }
  }

  void _navigateToAddTakeawayOrder() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TakeawayOrderFormScreen(
          token: widget.token,
          businessId: widget.businessId,
        ),
      ),
    );
    if (result == true && mounted) {
      _controller.loadFirstPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _buildContent(l10n),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToAddTakeawayOrder,
        tooltip: l10n.takeawayTooltipNewOrder,
        backgroundColor: Colors.blueAccent,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    if (_controller.isFirstLoadRunning) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_controller.errorMessage.isNotEmpty && _controller.takeawayOrders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0), 
          child: Text(
            _controller.errorMessage, 
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 16), 
            textAlign: TextAlign.center
          )
        )
      );
    }
    if (_controller.takeawayOrders.isEmpty) {
      return RefreshIndicator(
        onRefresh: _controller.loadFirstPage,
        color: Colors.white,
        backgroundColor: Colors.blue.shade700,
        child: Stack(
          children: [
            ListView(),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.no_food_outlined, size: 80, color: Colors.white70),
                    const SizedBox(height: 16),
                    Text(
                      l10n.takeawayNoActiveOrders, 
                      textAlign: TextAlign.center, 
                      style: const TextStyle(
                        color: Colors.white70, 
                        fontWeight: FontWeight.bold, 
                        fontSize: 17
                      )
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    
    double screenWidth = MediaQuery.of(context).size.width;
    int crossAxisCount = 2;
    if (screenWidth > 1200) {
      crossAxisCount = 5;
    } else if (screenWidth > 900) {
      crossAxisCount = 4;
    } else if (screenWidth > 600) {
      crossAxisCount = 3;
    }
    
    return RefreshIndicator(
      onRefresh: _controller.loadFirstPage,
      color: Colors.white,
      backgroundColor: Colors.blue.shade700,
      child: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(10.0),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 0.9,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: _controller.takeawayOrders.length + (_controller.isLoadMoreRunning ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _controller.takeawayOrders.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20.0), 
              child: Center(child: CircularProgressIndicator(color: Colors.white))
            );
          }
          final order = _controller.takeawayOrders[index];
          return TakeawayOrderCardWidget(
            key: ValueKey(order.id ?? order.uuid),
            order: order,
            token: widget.token,
            onCancel: () => _cancelOrder(order),
            onOrderUpdated: _controller.loadFirstPage,
            onAssignPager: () => _openPagerAssignmentScreenAndAssign(order),
            onApprove: () => _approveOrder(order),
            onReject: () => _rejectOrder(order),
            onTap: () => _showOrderDetailsModal(order),
          );
        },
      ),
    );
  }
}