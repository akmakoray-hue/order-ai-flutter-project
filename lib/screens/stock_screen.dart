// lib/screens/stock_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../models/stock.dart';
import '../services/api_service.dart';
import '../services/stock_service.dart';
import 'stock_history_screen.dart';

class StockScreen extends StatefulWidget {
  final String token;
  final int businessId;

  const StockScreen({Key? key, required this.token, required this.businessId})
      : super(key: key);

  @override
  _StockScreenState createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  bool _isLoading = true;
  String _errorMessage = '';
  List<Stock> _stocks = [];
  List<dynamic> _allVariantsForNewStock = [];

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[StockScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'stock_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchAllData();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[StockScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'stock_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchAllData();
        });
      }
    });

    _fetchAllData();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> _fetchAllData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    await Future.wait([
      _fetchStocks(),
      _fetchBusinessVariantsForNewStockDialog(),
    ]);

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchStocks() async {
    try {
      final stocksData = await StockService.fetchBusinessStock(widget.token);
      if (mounted) {
        setState(() {
          _stocks = stocksData;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst("Exception: ", "");
        });
      }
    }
  }

  Future<void> _fetchBusinessVariantsForNewStockDialog() async {
    try {
      final variantsData =
          await ApiService.fetchMenuItemsForBusiness(widget.token);
      if (mounted) {
        setState(() {
          _allVariantsForNewStock = variantsData;
        });
      }
    } catch (e) {
      debugPrint("Error fetching variants for new stock: $e");
    }
  }

  Future<void> _showAddStockMovementDialog(Stock stockItem, String movementTypeKey, AppLocalizations l10n, Map<String, String> stockMovementDisplayNames) async {
    final TextEditingController quantityController = TextEditingController();
    final TextEditingController descriptionController = TextEditingController();
    final formKeyDialog = GlobalKey<FormState>();

    String dialogTitle = stockMovementDisplayNames[movementTypeKey] ?? l10n.stockDialogMovementTitle;
    String quantityLabel = l10n.stockDialogQuantityLabel;

    switch (movementTypeKey) {
      case 'ADDITION': quantityLabel = l10n.stockDialogQuantityEntryLabel; break;
      case 'WASTAGE': quantityLabel = l10n.stockDialogQuantityWastageLabel; break;
      case 'ADJUSTMENT_IN': quantityLabel = l10n.stockDialogQuantitySurplusLabel; break;
      case 'ADJUSTMENT_OUT': quantityLabel = l10n.stockDialogQuantityDeficitLabel; break;
    }

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(dialogTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Form(
            key: formKeyDialog,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: quantityController,
                    decoration: InputDecoration(labelText: quantityLabel),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) {
                      if (value == null || value.isEmpty) return l10n.stockDialogErrorEnterQuantity;
                      final intValue = int.tryParse(value);
                      if (intValue == null || intValue <= 0) return l10n.stockDialogErrorPositiveQuantity;
                      if ((movementTypeKey == 'WASTAGE' || movementTypeKey == 'ADJUSTMENT_OUT') && intValue > stockItem.quantity) {
                        return l10n.stockDialogErrorQuantityExceeds(stockItem.quantity.toString());
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: descriptionController,
                    decoration: InputDecoration(labelText: l10n.stockDialogDescriptionLabel),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.dialogButtonCancel),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKeyDialog.currentState!.validate()) {
                  final int quantityChange = int.parse(quantityController.text);
                  final String description = descriptionController.text;
                  Navigator.of(dialogContext).pop();
                  if (!mounted) return;
                  setState(() => _isLoading = true);
                  try {
                    await StockService.adjustStock(
                      token: widget.token,
                      stockId: stockItem.id,
                      movementType: movementTypeKey,
                      quantityChange: quantityChange,
                      description: description,
                    );
                    if (mounted) {
                      final movementName = stockMovementDisplayNames[movementTypeKey] ?? '';
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.stockDialogSuccessMessage(movementName)), backgroundColor: Colors.green));
                      await _fetchStocks();
                      await StockService.checkAndNotifyGlobalStockAlerts(widget.token);
                    }
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.stockDialogErrorMessage(e.toString())), backgroundColor: Colors.red));
                  } finally {
                    if (mounted) setState(() => _isLoading = false);
                  }
                }
              },
              child: Text(l10n.buttonSave),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddNewStockDialog(AppLocalizations l10n) async {
    if (!mounted) return;
    List<int> currentStockedVariantIds = _stocks.map((s) => s.variantId).toList();
    List<dynamic> availableMenuItems = _allVariantsForNewStock.where((v) {
      bool hasVariants = v['variants'] != null && (v['variants'] as List).isNotEmpty;
      if (!hasVariants) return false;
      return (v['variants'] as List).any((variant) => !currentStockedVariantIds.contains(variant['id']));
    }).toList();

    if (availableMenuItems.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.stockDialogErrorNoNewVariant)));
      return;
    }

    dynamic selectedVariant;
    final TextEditingController quantityController = TextEditingController();
    final formKeyDialog = GlobalKey<FormState>();

    List<Map<String, dynamic>> flatVariantList = [];
    for (var item in availableMenuItems) {
      for (var variant in item['variants']) {
        if (!currentStockedVariantIds.contains(variant['id'])) {
          flatVariantList.add({
            ...variant,
            'product_name': item['name'],
          });
        }
      }
    }

    if (flatVariantList.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.stockDialogErrorNoNewVariant)));
      return;
    }

    selectedVariant = flatVariantList.first;

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.stockDialogCreateTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: Form(
            key: formKeyDialog,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<dynamic>(
                    value: selectedVariant,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: l10n.stockDialogSelectVariantLabel, border: const OutlineInputBorder()),
                    items: flatVariantList.map((variant) {
                      String variantName = variant['name'] ?? l10n.unknownVariant;
                      String productName = variant['product_name'] ?? l10n.unknownProduct;
                      return DropdownMenuItem<dynamic>(value: variant, child: Text('$productName - $variantName', overflow: TextOverflow.ellipsis));
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) selectedVariant = value;
                    },
                    validator: (value) => value == null ? l10n.stockDialogErrorSelectVariant : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: quantityController,
                    decoration: InputDecoration(labelText: l10n.stockDialogInitialQuantityLabel, border: const OutlineInputBorder()),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) {
                      if (value == null || value.isEmpty) return l10n.stockDialogErrorEnterQuantity;
                      final intValue = int.tryParse(value);
                      if (intValue == null || intValue < 0) return l10n.stockDialogErrorValidQuantity;
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(l10n.dialogButtonCancel)),
            ElevatedButton(
              onPressed: () async {
                if (formKeyDialog.currentState!.validate()) {
                  final int quantity = int.parse(quantityController.text);
                  final int variantId = selectedVariant['id'];
                  Navigator.of(dialogContext).pop();
                  if (!mounted) return;
                  setState(() => _isLoading = true);
                  try {
                    await StockService.createStock(token: widget.token, variantId: variantId, quantity: quantity);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.stockDialogCreateSuccess)));
                      await _fetchAllData();
                      await StockService.checkAndNotifyGlobalStockAlerts(widget.token);
                    }
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.stockDialogCreateError(e.toString()))));
                  } finally {
                    if (mounted) setState(() => _isLoading = false);
                  }
                }
              },
              child: Text(l10n.createButton),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final Map<String, String> stockMovementDisplayNames = {
      'ADDITION': l10n.stockMovementAddition,
      'WASTAGE': l10n.stockMovementWastage,
      'ADJUSTMENT_IN': l10n.stockMovementAdjustmentIn,
      'ADJUSTMENT_OUT': l10n.stockMovementAdjustmentOut,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.stockScreenTitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.blue.shade900, Colors.blue.shade400], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_business_outlined, color: Colors.white),
            tooltip: l10n.stockScreenTooltipAddNew,
            onPressed: _isLoading ? null : () => _showAddNewStockDialog(l10n),
          ),
        ],
      ),
      // +++ ARKA PLAN DÜZELTMESİ +++
      body: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.blue.shade900.withOpacity(0.9), Colors.blue.shade400.withOpacity(0.8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : _errorMessage.isNotEmpty
                      ? Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text(_errorMessage, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16), textAlign: TextAlign.center)))
                      : RefreshIndicator(
                          onRefresh: _fetchAllData,
                          child: _stocks.isEmpty
                              ? Center(child: Text(l10n.stockScreenNoStockItems, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 16, height: 1.5), textAlign: TextAlign.center))
                              // +++ LİSTELEME WIDGET DEĞİŞİKLİĞİ +++
                              : LayoutBuilder(
                                builder: (context, constraints) {
                                  return SingleChildScrollView(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Wrap(
                                      spacing: 12.0,
                                      runSpacing: 12.0,
                                      children: _stocks.map((stock) {
                                        // Kartların genişliğini ekran boyutuna göre ayarla
                                        double cardWidth = constraints.maxWidth > 840 
                                            ? (constraints.maxWidth / 3) - (12 * (4/3))
                                            : (constraints.maxWidth / 2) - 18;
                                        if (constraints.maxWidth < 500) {
                                          cardWidth = constraints.maxWidth;
                                        }

                                        return SizedBox(
                                          width: cardWidth,
                                          child: StockItemCard(
                                            key: ValueKey(stock.id),
                                            stock: stock,
                                            token: widget.token,
                                            onStockUpdated: _fetchStocks,
                                            onShowMovementDialog: (movementType) => _showAddStockMovementDialog(stock, movementType, l10n, stockMovementDisplayNames),
                                            stockMovementDisplayNames: stockMovementDisplayNames,
                                            l10n: l10n,
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  );
                                },
                              ),
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

class StockItemCard extends StatefulWidget {
  final Stock stock;
  final String token;
  final VoidCallback onStockUpdated;
  final Function(String movementTypeKey) onShowMovementDialog;
  final Map<String, String> stockMovementDisplayNames;
  final AppLocalizations l10n;

  const StockItemCard({
    Key? key,
    required this.stock,
    required this.token,
    required this.onStockUpdated,
    required this.onShowMovementDialog,
    required this.stockMovementDisplayNames,
    required this.l10n,
  }) : super(key: key);

  @override
  _StockItemCardState createState() => _StockItemCardState();
}

class _StockItemCardState extends State<StockItemCard> {
  late bool _trackStock;
  late TextEditingController _thresholdController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _trackStock = widget.stock.trackStock;
    _thresholdController = TextEditingController(text: widget.stock.alertThreshold?.toString() ?? '');
  }

  @override
  void dispose() {
    _thresholdController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    if (!mounted) return;
    setState(() => _isSaving = true);

    int? thresholdValue;
    if (_trackStock && _thresholdController.text.isNotEmpty) {
      thresholdValue = int.tryParse(_thresholdController.text);
    }

    try {
      final response = await StockService.updateStockSettings(
        token: widget.token,
        stockId: widget.stock.id,
        trackStock: _trackStock,
        alertThreshold: thresholdValue,
      );
      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.l10n.stockCardSettingsSaved), backgroundColor: Colors.green));
          widget.onStockUpdated();
          await StockService.checkAndNotifyGlobalStockAlerts(widget.token);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.l10n.errorGeneral(response.statusCode.toString())), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.l10n.errorGeneral(e.toString())), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isAlertActive = widget.stock.trackStock &&
        widget.stock.alertThreshold != null &&
        widget.stock.quantity <= widget.stock.alertThreshold!;
    
    final l10n = widget.l10n;

    return Card(
      color: Colors.white.withOpacity(0.92),
      elevation: 3,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: isAlertActive ? Colors.red.shade400 : Colors.transparent, width: 2)
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        // +++ KART İÇİ DÜZENLEMESİ +++
        child: Column(
          mainAxisSize: MainAxisSize.min, // Dikeyde küçülmeyi sağlar
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isAlertActive)
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Icon(Icons.warning_amber_rounded, color: Colors.red.shade700),
                  ),
                Expanded(
                  child: Text(
                    widget.stock.variantFullName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
                Text(l10n.stockCardCurrentStock(widget.stock.quantity.toString()), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const Divider(),
            // Expanded widget kaldırıldı.
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: Text(l10n.stockCardEnableTracking, style: const TextStyle(fontSize: 14)),
                  value: _trackStock,
                  onChanged: (value) {
                    setState(() => _trackStock = value);
                  },
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                if (_trackStock)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: TextFormField(
                      controller: _thresholdController,
                      decoration: InputDecoration(
                        labelText: l10n.stockCardAlertThresholdLabel,
                        hintText: l10n.stockCardAlertThresholdHint,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        isDense: true,
                        border: const OutlineInputBorder()
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton.icon(
                  icon: _isSaving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(l10n.stockCardSaveSettingsButton),
                  onPressed: _isSaving ? null : _saveSettings,
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: l10n.stockCardOtherActionsTooltip,
                  onSelected: (value) {
                    if (value == 'history') {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => StockHistoryScreen(
                          token: widget.token,
                          stockId: widget.stock.id,
                          variantFullName: widget.stock.variantFullName,
                        )
                      ));
                    } else {
                      widget.onShowMovementDialog(value);
                    }
                  },
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'history',
                      child: Row(children: [const Icon(Icons.history, color: Colors.black54), const SizedBox(width: 8), Text(l10n.stockCardHistoryButton)]),
                    ),
                    const PopupMenuDivider(),
                    ...widget.stockMovementDisplayNames.entries.map((entry) {
                      return PopupMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value),
                      );
                    }).toList(),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}