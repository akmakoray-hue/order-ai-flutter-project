// lib/screens/pending_orders_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'payment_processing_screen.dart';

class PendingOrdersScreen extends StatefulWidget {
  final String token;
  final int businessId;
  const PendingOrdersScreen({
    Key? key,
    required this.token,
    required this.businessId,
  }) : super(key: key);

  @override
  _PendingOrdersScreenState createState() => _PendingOrdersScreenState();
}

class _PendingOrdersScreenState extends State<PendingOrdersScreen> {
  bool isLoading = true;
  String errorMessage = '';
  List<dynamic> orders = [];

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[PendingOrdersScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'pending_orders_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchPendingOrders();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[PendingOrdersScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'pending_orders_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchPendingOrders();
        });
      }
    });
    
    fetchPendingOrders();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  /// Fetches pending (unpaid) orders from the API.
  Future<void> fetchPendingOrders() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
      errorMessage = '';
    });
    try {
      final url = ApiService.getUrl('/orders/').replace(queryParameters: {
        'is_paid': 'false',
      });

      final response = await http.get(
        url,
        headers: {"Authorization": "Bearer ${widget.token}"},
      );

      if (!mounted) return;
      
      if (response.statusCode == 200) {
        List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        setState(() {
          orders = data;
        });
      } else {
        // Use a generic error key for API failures.
        setState(() {
          errorMessage = "FETCH_ERROR";
        });
      }
    } catch (e) {
      if (mounted) {
        // Use a generic error key with details for other exceptions.
        setState(() {
          errorMessage = "GENERAL_ERROR|${e.toString()}";
        });
      }
    } finally {
        if(mounted) {
            setState(() {
                isLoading = false;
            });
        }
    }
  }

  /// Calculates the total amount for a given order.
  double calculateTotalAmount(dynamic order) {
    double total = 0;
    if (order['order_items'] != null) {
      for (var item in order['order_items']) {
        double price;
        try {
          price = double.parse(item['price'].toString());
        } catch (_) {
          price = 0;
        }
        int quantity = item['quantity'] ?? 0;
        total += price * quantity;
      }
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    // Get the localization instance.
    final l10n = AppLocalizations.of(context)!;
    
    // Map error keys to localized, user-friendly messages.
    String displayErrorMessage = '';
    if(errorMessage.isNotEmpty) {
        final parts = errorMessage.split('|');
        if(parts[0] == 'FETCH_ERROR') {
            displayErrorMessage = l10n.errorFetchingPendingOrders;
        } else if(parts[0] == 'GENERAL_ERROR' && parts.length > 1) {
            displayErrorMessage = l10n.errorGeneral(parts[1]);
        } else {
            // Fallback for any other error format.
            displayErrorMessage = l10n.errorGeneral(errorMessage);
        }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          // Use localized title.
          l10n.pendingOrdersPageTitle,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xFF283593),
                Color(0xFF455A64),
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
          child: isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : errorMessage.isNotEmpty
                  ? Center(child: Text(displayErrorMessage, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16)))
                  : orders.isEmpty
                      // Use localized text for no data.
                      ? Center(child: Text(l10n.noPendingOrdersFound, style: const TextStyle(color: Colors.white70, fontSize: 18)))
                      : RefreshIndicator(
                          onRefresh: fetchPendingOrders,
                          color: Colors.white,
                          backgroundColor: Colors.blue.shade700,
                          child: ListView.builder(
                            itemCount: orders.length,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemBuilder: (context, index) {
                              var order = orders[index];
                              double totalAmount = calculateTotalAmount(order);
                              final tableNumber = order['table'];
                              // Use localized strings for card titles.
                              final cardTitle = tableNumber != null
                                  ? l10n.pendingOrderCardTitleTable(tableNumber.toString())
                                  : l10n.pendingOrderCardTitleTakeaway;

                              return Card(
                                color: Colors.white.withOpacity(0.8),
                                elevation: 4,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: ListTile(
                                  title: Text(cardTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
                                  // Use the localized subtitle. The currency symbol (TL/USD) will come from the .arb file.
                                  subtitle: Text(l10n.pendingOrderCardSubtitle(totalAmount.toStringAsFixed(2))),
                                  trailing: const Icon(Icons.keyboard_arrow_right),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PaymentProcessingScreen(
                                          token: widget.token,
                                          order: order,
                                          amount: totalAmount,
                                        ),
                                      ),
                                    ).then((paymentSuccessful) {
                                      // If payment was successful, refresh the list.
                                      if (paymentSuccessful == true) {
                                        fetchPendingOrders();
                                      }
                                    });
                                  },
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ),
    );
  }
}