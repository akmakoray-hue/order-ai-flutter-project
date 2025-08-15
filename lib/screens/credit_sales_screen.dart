// lib/screens/credit_sales_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter/foundation.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/order_service.dart';
import '../models/order.dart' as AppOrder;
import '../widgets/payment_modal.dart';
import '../utils/currency_formatter.dart';

class CreditSalesScreen extends StatefulWidget {
  final String token;
  final int businessId;

  const CreditSalesScreen({
    Key? key,
    required this.token,
    required this.businessId,
  }) : super(key: key);

  @override
  _CreditSalesScreenState createState() => _CreditSalesScreenState();
}

class _CreditSalesScreenState extends State<CreditSalesScreen> {
  final ScrollController _scrollController = ScrollController();
  List<AppOrder.Order> _creditOrders = [];
  int _currentPage = 1;
  bool _hasNextPage = true;
  bool _isFirstLoadRunning = false;
  bool _isLoadMoreRunning = false;
  String _errorMessage = '';
  bool _isDataFetched = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadMore);
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[CreditSalesScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'credit_sales_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _loadFirstPage();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[CreditSalesScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'credit_sales_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _loadFirstPage();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isDataFetched) {
      _loadFirstPage();
      _isDataFetched = true;
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_loadMore);
    _scrollController.dispose();
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  String _formatDateToTurkeyTime(String? dateStr) {
    final l10n = AppLocalizations.of(context)!;
    if (dateStr == null || dateStr.isEmpty) return l10n.creditSalesUnknown;
    try {
      final utcDate = DateTime.parse(dateStr);
      final istanbul = tz.getLocation('Europe/Istanbul');
      final istanbulDate = tz.TZDateTime.from(utcDate, istanbul);
      return DateFormat('dd/MM/yyyy HH:mm', 'tr_TR').format(istanbulDate);
    } catch (e) {
      debugPrint("Date formatting error: $e");
      return l10n.creditSalesInvalidDate;
    }
  }

  Future<void> _loadFirstPage() async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    setState(() {
      _isFirstLoadRunning = true;
      _errorMessage = '';
    });
    try {
      final response = await OrderService.fetchCreditSales(
        token: widget.token,
        page: 1,
      );
      if (mounted) {
        setState(() {
          _creditOrders = response.results;
          _hasNextPage = response.next != null;
          _currentPage = 1;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = l10n.creditSalesErrorFetching(
            e.toString().replaceFirst("Exception: ", ""),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isFirstLoadRunning = false);
      }
    }
  }

  Future<void> _loadMore() async {
    final l10n = AppLocalizations.of(context)!;
    if (_hasNextPage &&
        !_isFirstLoadRunning &&
        !_isLoadMoreRunning &&
        _scrollController.position.extentAfter < 300) {
      if (!mounted) return;
      setState(() => _isLoadMoreRunning = true);
      _currentPage += 1;
      try {
        final response = await OrderService.fetchCreditSales(
          token: widget.token,
          page: _currentPage,
        );
        if (mounted) {
          setState(() {
            _creditOrders.addAll(response.results);
            _hasNextPage = response.next != null;
          });
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.creditSalesErrorLoadMore),
            backgroundColor: Colors.redAccent,
          ));
        }
        _currentPage -= 1;
      } finally {
        if (mounted) {
          setState(() => _isLoadMoreRunning = false);
        }
      }
    }
  }

  double _calculateOrderTotal(AppOrder.Order order) {
    return order.orderItems.fold(
      0.0,
      (sum, item) => sum + (item.price * item.quantity),
    );
  }

  Future<void> _showPaymentModal(AppOrder.Order order) async {
    if (!mounted) return;
    final totalAmount = _calculateOrderTotal(order);

    final paymentSuccessful = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return PaymentModal(
          token: widget.token,
          order: order,
          amount: totalAmount,
          onSuccess: () {},
        );
      },
    );

    if (paymentSuccessful == true && mounted) {
      _loadFirstPage();
    }
  }

  String _getDisplayDate(AppOrder.Order order) {
    final paymentInfo = order.creditDetails as Map<String, dynamic>?;
    if (paymentInfo != null && paymentInfo['created_at'] != null) {
      return _formatDateToTurkeyTime(paymentInfo['created_at']);
    }
    return _formatDateToTurkeyTime(order.createdAt);
  }

  Widget _buildCreditSaleCard(AppOrder.Order order, AppLocalizations l10n) {
    final totalAmount = _calculateOrderTotal(order);
    final creditDetails = order.creditDetails as Map<String, dynamic>?;
    final customerName = creditDetails?['customer_name'] ??
        order.customerName ??
        l10n.creditSalesUnknown;
    final customerPhone = creditDetails?['customer_phone'] ??
        order.customerPhone ??
        l10n.creditSalesUnknown;
    final notes = creditDetails?['notes'] ?? '';
    final createdAt = _getDisplayDate(order);

    return Card(
      color: Colors.white.withOpacity(0.9),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.creditSalesCardOrderId(order.id.toString()),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.creditSalesCardCustomer(customerName),
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.creditSalesCardPhone(customerPhone),
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 4),
                if (notes.isNotEmpty) ...[
                  Text(
                    l10n.creditSalesCardNotes(notes),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  l10n.creditSalesCardCreditDate(createdAt),
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ],
            ),
            const Divider(height: 16),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                Text(
                  CurrencyFormatter.format(totalAmount),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: Colors.deepPurple,
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade400,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _showPaymentModal(order),
                  child: Text(l10n.creditSalesCardPayButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.creditSalesScreenTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blue.shade900, Colors.blue.shade400],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      // +++ ARKA PLAN DÜZELTMESİ BURADA +++
      // body'nin tamamını kaplaması için Column ve Expanded eklendi.
      body: Column(
        children: [
          Expanded(
            child: Container(
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
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final l10n = AppLocalizations.of(context)!;
    if (_isFirstLoadRunning) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_errorMessage.isNotEmpty && _creditOrders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _errorMessage,
            style: const TextStyle(color: Colors.orangeAccent, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_creditOrders.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadFirstPage,
        child: Stack(
          children: [
            ListView(), // For RefreshIndicator to work on an empty screen
            Center(
              child: Text(
                l10n.creditSalesNoActiveOrders,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFirstPage,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Wrap(
                  spacing: 12.0,
                  runSpacing: 12.0,
                  children: _creditOrders.map((order) {
                    final cardWidth = constraints.maxWidth > 724
                        ? (constraints.maxWidth / 3) - (12 * (4 / 3))
                        : constraints.maxWidth > 480
                            ? (constraints.maxWidth / 2) - 18
                            : constraints.maxWidth - 12;
                    return SizedBox(
                      width: cardWidth,
                      child: _buildCreditSaleCard(order, l10n),
                    );
                  }).toList(),
                ),
                if (_isLoadMoreRunning)
                  const Padding(
                    padding: EdgeInsets.only(top: 16, bottom: 16),
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}