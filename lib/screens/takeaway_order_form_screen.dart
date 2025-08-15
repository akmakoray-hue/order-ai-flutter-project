// lib/screens/takeaway_order_form_screen.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../models/menu_item.dart';
import '../models/menu_item_variant.dart';
import '../models/order.dart';
import '../models/order_item.dart';
import '../models/order_item_extra.dart';
import '../services/order_service.dart';
import '../widgets/categorized_menu_list_view.dart';
import '../widgets/new_order_basket_view.dart';

class TakeawayOrderFormScreen extends StatefulWidget {
  final String token;
  final int businessId;

  const TakeawayOrderFormScreen({
    Key? key,
    required this.token,
    required this.businessId,
  }) : super(key: key);

  @override
  _TakeawayOrderFormScreenState createState() =>
      _TakeawayOrderFormScreenState();
}

class _TakeawayOrderFormScreenState extends State<TakeawayOrderFormScreen> {
  List<MenuItem> menuItems = [];
  List<dynamic> categories = [];
  List<OrderItem> basket = [];
  bool isLoading = true;
  String errorMessage = '';
  bool _isDataFetched = false;
  
  // Navigasyon güvenliği için flag ekledik
  bool _isNavigating = false;

  final TextEditingController _customerNameController = TextEditingController();
  final TextEditingController _customerPhoneController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    super.dispose();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isDataFetched) {
      fetchInitialData();
      _isDataFetched = true;
    }
  }

  Future<void> fetchInitialData() async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    setState(() {
      isLoading = true;
      errorMessage = '';
    });
    try {
      final results = await Future.wait([
        OrderService.fetchMenuItems(widget.token),
        OrderService.fetchCategories(widget.token),
      ]);

      if (mounted) {
        menuItems = (results[0] as List).map((e) => MenuItem.fromJson(e)).toList();
        categories = results[1] as List<dynamic>;
      }
    } catch (e) {
      if (mounted) {
        errorMessage = l10n.takeawayOrderFormErrorLoadingData(e.toString().replaceFirst("Exception: ", ""));
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _handleMenuItemSelected(
    MenuItem item,
    MenuItemVariant? variant,
    List<MenuItemVariant> extras,
    String? tableUser,
    int quantity,
  ) {
    addToBasket(item: item, variant: variant, extras: extras, quantity: quantity);
  }

  void addToBasket({
    required MenuItem item,
    MenuItemVariant? variant,
    List<MenuItemVariant>? extras,
    required int quantity,
  }) {
    if(!mounted) return;

    double effectiveUnitPrice;
    List<OrderItemExtra> orderItemExtras = [];
    MenuItemVariant? finalVariant = variant;

    if (item.isCampaignBundle) {
      effectiveUnitPrice = item.price ?? 0.0;
      finalVariant = null;
    } else {
      effectiveUnitPrice = variant?.price ?? 0.0;
      if (extras != null) {
        for (var extraVariant in extras) {
          effectiveUnitPrice += extraVariant.price;
          orderItemExtras.add(OrderItemExtra(
            id: 0,
            variant: extraVariant.id,
            name: extraVariant.name,
            price: extraVariant.price,
            quantity: 1,
          ));
        }
      }
    }

    final index = basket.indexWhere((orderItem) {
      bool sameItem = orderItem.menuItem.id == item.id;
      bool sameVariantLogic;
      if (item.isCampaignBundle) {
        sameVariantLogic = orderItem.menuItem.isCampaignBundle;
      } else {
        sameVariantLogic = (finalVariant?.id == orderItem.variant?.id);
      }
      bool sameExtrasLogic = true;
      if (!item.isCampaignBundle) {
        List<Map<String, dynamic>> existingExtrasMap = (orderItem.extras ?? []).map((e) => {'variant': e.variant, 'quantity': e.quantity}).toList();
        existingExtrasMap.sort((a, b) => (a['variant'] as int).compareTo(b['variant'] as int));
        List<Map<String, dynamic>> newExtrasMap = orderItemExtras.map((e) => {'variant': e.variant, 'quantity': e.quantity}).toList();
        newExtrasMap.sort((a, b) => (a['variant'] as int).compareTo(b['variant'] as int));
        sameExtrasLogic = const DeepCollectionEquality().equals(existingExtrasMap, newExtrasMap);
      }
      return sameItem && sameVariantLogic && sameExtrasLogic;
    });

    setState(() {
      if (index != -1) {
        basket[index].quantity += quantity;
      } else {
        basket.add(OrderItem(
          menuItem: item,
          variant: finalVariant,
          price: effectiveUnitPrice,
          quantity: quantity,
          extras: item.isCampaignBundle ? [] : orderItemExtras,
          tableUser: null,
        ));
      }
    });
  }

  void _handleRemoveItemFromBasket(OrderItem item) {
    if(!mounted) return;
    setState(() {
      basket.remove(item);
    });
  }

  double calculateBasketTotal() {
    double total = 0;
    for (var orderItem in basket) {
      total += orderItem.price * orderItem.quantity;
    }
    return total;
  }

  // GÜNCELLENEN FONKSİYON - Navigasyon güvenliği eklendi
  Future<void> _handleCreateOrder() async {
    final l10n = AppLocalizations.of(context)!;
    
    // Zaten navigasyon yapılıyorsa çık
    if (_isNavigating) return;
    
    if (!_formKey.currentState!.validate()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.takeawayOrderFormErrorCustomerInfo), backgroundColor: Colors.orangeAccent),
        );
      }
      return;
    }
    
    if (basket.isEmpty) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.takeawayOrderFormErrorAddProduct), backgroundColor: Colors.orangeAccent),
        );
      }
      return;
    }

    if(!mounted) return;
    
    setState(() {
      isLoading = true;
      errorMessage = '';
      _isNavigating = true; // Navigasyon flag'ini ayarla
    });

    Order newOrder = Order(
      table: null,
      business: widget.businessId,
      orderItems: basket,
      tableUsers: null,
      customerName: _customerNameController.text.trim(),
      customerPhone: _customerPhoneController.text.trim(),
      orderType: 'takeaway',
    );

    debugPrint('TakeawayOrderFormScreen: handleCreateOrder - Sending Order: ${jsonEncode(newOrder.toJson())}');

    try {
      final response = await OrderService.createOrder(
        token: widget.token,
        order: newOrder,
        offlineTableData: null,
      );

      if (!mounted) return; // Async işlem sonrası mounted kontrolü

      final decodedString = utf8.decode(response.bodyBytes);

      if (response.statusCode == 201) {
        String successMessage = l10n.takeawayOrderFormSuccess;
        try {
          final decodedBody = jsonDecode(decodedString);
          if(decodedBody is Map && decodedBody['offline'] == true) {
            successMessage = l10n.takeawayOrderFormSuccessOffline;
          }
        } catch(_) {}

        // Başarı mesajını göster
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMessage), backgroundColor: Colors.green),
        );
        
        // Güvenli navigasyon
        _safelyNavigateBack(true);

      } else {
        String errorMsg;
        try {
          final decodedError = jsonDecode(decodedString);
          if (decodedError is Map && decodedError['detail'] != null) {
            errorMsg = decodedError['detail'];
          } else {
            errorMsg = decodedString;
          }
        } catch (_) {
          errorMsg = l10n.takeawayOrderFormErrorCreatingWithCode(response.statusCode.toString());
        }
        
        setState(() {
          errorMessage = errorMsg;
          _isNavigating = false; // Hata durumunda flag'i sıfırla
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = l10n.takeawayOrderFormErrorCreatingGeneric(e.toString());
          _isNavigating = false; // Hata durumunda flag'i sıfırla
        });
      }
    } finally {
      if (mounted && !_isNavigating) {
        setState(() => isLoading = false);
      }
    }
  }

  // GÜVENLİ NAVİGASYON FONKSİYONU
  void _safelyNavigateBack([bool? result]) {
    if (!mounted || _isNavigating == false) return;
    
    try {
      if (Navigator.canPop(context)) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      debugPrint('Navigation error: $e');
      // Eğer pop başarısız olursa, alternatif olarak pushReplacement kullanabilirsiniz
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    double basketTotalAmount = calculateBasketTotal();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.takeawayOrderFormTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          // GÜNCELLENEN BACK BUTTON - Güvenli navigasyon
          onPressed: () => _safelyNavigateBack(),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xFF283593),
                Color(0xFF455A64),
                Color(0xFF455A64),
              ],
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
          child: (isLoading && menuItems.isEmpty)
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _customerNameController,
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  labelText: l10n.takeawayOrderFormCustomerNameLabel,
                                  labelStyle: const TextStyle(color: Colors.white70),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.1),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                  enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white54), borderRadius: BorderRadius.circular(8)),
                                  focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white), borderRadius: BorderRadius.circular(8)),
                                ),
                                validator: (value) => (value == null || value.trim().isEmpty) ? l10n.takeawayOrderFormCustomerNameValidator : null,
                              ),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _customerPhoneController,
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  labelText: l10n.takeawayOrderFormCustomerPhoneLabel,
                                  labelStyle: const TextStyle(color: Colors.white70),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.1),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                  enabledBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white54), borderRadius: BorderRadius.circular(8)),
                                  focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white), borderRadius: BorderRadius.circular(8)),
                                ),
                                keyboardType: TextInputType.phone,
                                validator: (value) => (value == null || value.trim().isEmpty) ? l10n.takeawayOrderFormCustomerPhoneValidator : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (errorMessage.isNotEmpty && !isLoading)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(errorMessage, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                        ),
                      const Divider(color: Colors.white30, height: 1, indent: 16, endIndent: 16),
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.4,
                        child: CategorizedMenuListView(
                          menuItems: menuItems,
                          categories: categories,
                          tableUsers: const [],
                          onItemSelected: _handleMenuItemSelected,
                        ),
                      ),
                      const Divider(color: Colors.white70),
                      NewOrderBasketView(
                        basket: basket,
                        allMenuItems: menuItems,
                        onRemoveItem: (itemToRemove) => _handleRemoveItemFromBasket(itemToRemove),
                        totalAmount: basketTotalAmount,
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
                            ),
                            // GÜNCELLENEN BUTTON - Navigasyon flag kontrolü eklendi
                            onPressed: (isLoading || basket.isEmpty || _isNavigating)
                                ? null
                                : _handleCreateOrder,
                            child: isLoading
                                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.black87))
                                : Text(
                                    l10n.takeawayOrderFormCreateButton,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                                  ),
                          ),
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