// lib/screens/new_order_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../models/menu_item.dart';
import '../models/menu_item_variant.dart';
import '../models/order.dart';
import '../models/order_item.dart';
import '../models/order_item_extra.dart';
import '../services/order_service.dart';
import '../utils/notifiers.dart';
import '../main.dart';
import 'package:flutter/foundation.dart'; // debugPrint için
import '../controllers/new_order_controller.dart';
import '../widgets/new_order/dialogs/new_order_dialogs.dart';
import '../widgets/categorized_menu_list_view.dart';
import '../widgets/new_order_basket_view.dart';


class NewOrderScreen extends StatefulWidget {
  final String token;
  final dynamic table;
  final int businessId;

  const NewOrderScreen({Key? key, required this.token, required this.table, required this.businessId}) : super(key: key);

  @override
  _NewOrderScreenState createState() => _NewOrderScreenState();
}

class _NewOrderScreenState extends State<NewOrderScreen> {
  late NewOrderController _controller;
  late AppLocalizations _l10n;
  bool _didChangeDependenciesRun = false; // State içinde doğru değişken tanımı

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[NewOrderScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted && _didChangeDependenciesRun) {
        final refreshKey = 'new_order_screen_${widget.table['id']}_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          // Menü verilerini yenile
          await _refreshMenuData();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[NewOrderScreen] 📱 Screen became active notification received');
      if (mounted && _didChangeDependenciesRun) {
        final refreshKey = 'new_order_screen_active_${widget.table['id']}_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          // Menü verilerini yenile
          await _refreshMenuData();
        });
      }
    });

    // Controller ve l10n, context gerektirdiği için didChangeDependencies içinde başlatılacak.
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // Bu bloğun sadece bir kez çalışmasını sağla
    if (!_didChangeDependenciesRun) {
      _l10n = AppLocalizations.of(context)!;
      _controller = NewOrderController(
        token: widget.token,
        businessId: widget.businessId,
        table: widget.table,
        onStateUpdate: (VoidCallback fn) {
            if (mounted) {
              setState(fn);
            }
        },
        showSnackBarCallback: (String message, {bool isError = false}) {
            if (mounted) {
              ScaffoldMessenger.of(context).removeCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(message),
                  backgroundColor: isError ? Colors.redAccent : Colors.green,
                  duration: Duration(seconds: isError ? 3 : 2),
                ),
              );
            }
        },
        popScreenCallback: (bool success) {
            if (mounted) {
              Navigator.of(context).pop(success);
            }
        },
      );

      _controller.initializeScreen().then((success) {
          if (mounted && success && _controller.isSplitTable == null) {
            _promptTableType();
          } else if (mounted && !success){
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(_controller.errorMessage.isNotEmpty ? _controller.errorMessage : _l10n.newOrderLoadingInitialData)),
              );
          }
      });
      _didChangeDependenciesRun = true; // Bayrağı ayarla
    }
  }

  // 🆕 Menü verilerini yenileme metodu
  Future<void> _refreshMenuData() async {
    if (_controller != null && mounted) {
      try {
        await _controller.initializeScreen();
        if (mounted) setState(() {});
      } catch (e) {
        debugPrint('[NewOrderScreen] Menu refresh error: $e');
      }
    }
  }

  void _promptTableType() {
    NewOrderDialogs.promptTableType(
      context: context,
      // l10n parametresi dialogun tanımında olmadığı için kaldırıldı.
      // Dialog içindeki metinlerin yerelleştirilmesi dialog widget'ının kendi içinde yapılmalıdır.
      onSelected: (isSplit, owners) {
          _controller.handleTableTypeSelected(isSplit, owners);
      },
      onCancel: () {
        if (mounted && _controller.isSplitTable == null) {
          Navigator.of(context).pop();
        }
      }
    );
  }

  void _promptTableOwners() {
    NewOrderDialogs.promptTableOwners(
      context: context,
       // l10n parametresi dialogun tanımında olmadığı için kaldırıldı.
      initialOwners: _controller.tableOwners,
      onConfirm: _controller.handleTableOwnersUpdated,
    );
  }

  Future<void> _handleCreateOrder() async {
    if (_controller.basket.isEmpty) {
      _controller.showSnackBarCallback(_l10n.newOrderErrorAddAtLeastOneProduct, isError: true);
      return;
    }
    if (_controller.isSplitTable == true && _controller.tableOwners.where((name) => name.trim().isNotEmpty).length < 2) {
      _controller.showSnackBarCallback(_l10n.newOrderErrorMinOwnersForSplit, isError: true);
      return;
    }

    _controller.isLoading = true;
    _controller.errorMessage = '';
    if (mounted) setState(() {});

    Order newOrder = Order(
      table: widget.table['id'],
      business: widget.businessId,
      orderItems: _controller.basket,
      tableUsers: (_controller.isSplitTable == true && _controller.tableOwners.isNotEmpty)
          ? _controller.tableOwners.map((name) => {'name': name}).toList()
          : null,
      customerName: null,
      customerPhone: null,
      orderType: 'table',
      isSplitTable: _controller.isSplitTable ?? false,
    );
    
    debugPrint('NewOrderScreen: handleCreateOrder - Sipariş gönderiliyor: ${jsonEncode(newOrder.toJson())}');

    try {
      final response = await OrderService.createOrder(
        token: _controller.token,
        order: newOrder,
        offlineTableData: widget.table,
      );
      
      final decodedString = utf8.decode(response.bodyBytes);
      
      if (response.statusCode == 201) {
        String successMessage = _l10n.newOrderSuccess;
        
        try {
          final decodedBody = jsonDecode(decodedString);
          if(decodedBody is Map && decodedBody['offline'] == true) {
            successMessage = decodedBody['detail'] ?? _l10n.newOrderSuccessOffline;
          }
        } catch(jsonError) {
          debugPrint("[Controller] UYARI: Offline yanıtı parse edilemedi, ancak devam ediliyor. Hata: $jsonError");
        }
        
        _controller.showSnackBarCallback(successMessage, isError: false);
        await Future.delayed(const Duration(milliseconds: 500));
        _controller.popScreenCallback(true);

      } else {
        _controller.errorMessage = _l10n.newOrderErrorGeneric(response.statusCode.toString(), decodedString);
        _controller.showSnackBarCallback(_controller.errorMessage, isError: true);
      }
    } catch (e, s) {
      debugPrint("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
      debugPrint("[Controller] KRİTİK HATA: _handleCreateOrder CATCH bloğuna düşüldü.");
      debugPrint("Hata Türü: ${e.runtimeType}");
      debugPrint("Hata Mesajı: $e");
      debugPrint("Stack Trace:\n$s");
      debugPrint("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
      _controller.errorMessage = _l10n.newOrderErrorCatch(e.toString());
      _controller.showSnackBarCallback(_controller.errorMessage, isError: true);
    } finally {
      if(mounted) {
        _controller.isLoading = false;
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
      if (!_didChangeDependenciesRun) {
          return Scaffold(
              backgroundColor: Colors.blue.shade900,
              body: const Center(child: CircularProgressIndicator(color: Colors.white))
          );
      }

      if (_controller.isLoading && _controller.isSplitTable == null) {
        return _buildLoadingOrErrorScaffold(_l10n.newOrderLoadingData);
      } else if (_controller.errorMessage.isNotEmpty && _controller.isSplitTable == null) {
        return _buildLoadingOrErrorScaffold(_controller.errorMessage);
      } else if (_controller.isSplitTable == null && !_controller.isLoading) {
        return _buildLoadingOrErrorScaffold(_l10n.newOrderWaitingForTableType);
      }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          _l10n.newOrderTitle(widget.table['table_number'].toString()),
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: Icon(_controller.isSplitTable! ? Icons.people : Icons.person),
            label: Text(_controller.isSplitTable! ? _l10n.newOrderTableTypeSplit : _l10n.newOrderTableTypeSingle),
            onPressed: () {
                _controller.isSplitTable = null;
                _controller.tableOwners = [];
                _controller.basket.clear();
                _controller.onStateUpdate(() {});
                _promptTableType();
            },
          )
        ],
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF283593), Color(0xFF455A64), Color(0xFF455A64)],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
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
              if (_controller.errorMessage.isNotEmpty && _controller.isSplitTable != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_controller.errorMessage, style: const TextStyle(color: Colors.redAccent)),
                ),
              if (_controller.isSplitTable == true)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _controller.tableOwners.where((o) => o.isNotEmpty).isEmpty 
                            ? _l10n.newOrderNoOwnersEntered 
                            : _l10n.newOrderOwnersList(_controller.tableOwners.join(', ')),
                          style: TextStyle(fontWeight: FontWeight.bold, color: _controller.tableOwners.where((o) => o.isNotEmpty).isEmpty ? Colors.orangeAccent : Colors.white70),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.white70, size: 20,),
                        tooltip: _l10n.newOrderEditOwnersTooltip,
                        onPressed: _promptTableOwners,
                      )
                    ],
                  ),
                ),
              Expanded(
                child: CategorizedMenuListView(
                  menuItems: _controller.menuItems,
                  categories: _controller.categories,
                  tableUsers: _controller.tableOwners,
                  onItemSelected: _controller.addToBasket,
                ),
              ),
              const Divider(color: Colors.white70),
              NewOrderBasketView(
                basket: _controller.basket,
                allMenuItems: _controller.menuItems,
                onRemoveItem: (item) => _controller.removeFromBasket(item),
                totalAmount: _controller.basketTotal,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.8),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      disabledBackgroundColor: Colors.grey.withOpacity(0.5)
                    ),
                    onPressed: _controller.isLoading || _controller.basket.isEmpty || (_controller.isSplitTable == true && _controller.tableOwners.where((o) => o.isNotEmpty).length < 2)
                        ? null
                        : _handleCreateOrder,
                    child: _controller.isLoading
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black))
                        : Text(_l10n.newOrderCreateOrderButton, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOrErrorScaffold(String message) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
          title: Text(
            l10n.newOrderTitle(widget.table['table_number'].toString()),
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          centerTitle: true,
          flexibleSpace: Container(
           decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [ Color(0xFF283593), Color(0xFF455A64), Color(0xFF455A64)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
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
        child: Center(
          child: (message == l10n.newOrderLoadingData || message == l10n.newOrderWaitingForTableType)
              ? const CircularProgressIndicator(color: Colors.white)
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    message,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      ),
    );
  }
}