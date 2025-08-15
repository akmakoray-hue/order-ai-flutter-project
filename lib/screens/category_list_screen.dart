// lib/screens/category_list_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import 'create_category_screen.dart';
import 'edit_category_screen.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/user_session.dart';
import 'subscription_screen.dart';

class CategoryListScreen extends StatefulWidget {
  final String token;
  final int businessId;
  const CategoryListScreen({Key? key, required this.token, required this.businessId})
      : super(key: key);

  @override
  _CategoryListScreenState createState() => _CategoryListScreenState();
}

class _CategoryListScreenState extends State<CategoryListScreen> {
  bool isLoading = true;
  String errorMessage = '';
  List<dynamic> categories = [];

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[CategoryListScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'category_list_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchCategories();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[CategoryListScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'category_list_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchCategories();
        });
      }
    });

    fetchCategories();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> fetchCategories() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
      errorMessage = '';
    });
    try {
      final response = await http.get(
        ApiService.getUrl('/categories/'),
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          categories = jsonDecode(utf8.decode(response.bodyBytes));
        });
      } else {
        setState(() {
          errorMessage = "FETCH_ERROR|${response.statusCode}";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = "GENERAL_ERROR|${e.toString()}";
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> deleteCategory(int categoryId, String categoryName) async {
    final l10n = AppLocalizations.of(context)!;
    bool? confirmDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(l10n.dialogDeleteCategoryTitle),
          content: Text(l10n.dialogDeleteCategoryContent(categoryName)),
          actions: <Widget>[
            TextButton(
              child: Text(l10n.dialogButtonCancel),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: Text(l10n.dialogButtonDeleteConfirm, style: const TextStyle(color: Colors.red)),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (confirmDelete != true) return;

    try {
      await ApiService.deleteCategory(widget.token, categoryId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.infoCategoryDeleted), backgroundColor: Colors.green),
      );
      fetchCategories(); // Listeyi yenile
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorGeneral(e.toString().replaceFirst("Exception: ", "")))),
      );
    }
  }
  
  Widget _buildCategoryCard(dynamic category, AppLocalizations l10n) {
    String? imageUrl;
    if (category['image'] != null && category['image'].toString().isNotEmpty) {
      imageUrl = category['image'].toString();
    }

    return Card(
      color: Colors.white.withOpacity(0.8),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Stack(
        children: [
          InkWell(
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => EditCategoryScreen(
                    token: widget.token,
                    category: category,
                    businessId: widget.businessId,
                    onMenuUpdated: fetchCategories,
                  ),
                ),
              );
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: imageUrl != null
                      ? Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(Icons.broken_image, size: 40, color: Colors.grey),
                        )
                      : Icon(Icons.category, size: 50, color: Colors.grey.shade700),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    category['name'] ?? l10n.unknownCategory,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.delete_forever_outlined, color: Colors.white, size: 22),
                tooltip: l10n.tooltipDelete,
                onPressed: () => deleteCategory(category['id'], category['name']),
                padding: const EdgeInsets.all(6.0),
                constraints: const BoxConstraints(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String displayErrorMessage = '';
    if (errorMessage.isNotEmpty) {
      final parts = errorMessage.split('|');
      if (parts.length == 2) {
        if (parts[0] == 'FETCH_ERROR') {
          displayErrorMessage = l10n.errorFetchingCategories(parts[1]);
        } else if (parts[0] == 'GENERAL_ERROR') {
          displayErrorMessage = l10n.errorGeneral(parts[1]);
        }
      } else {
        displayErrorMessage = errorMessage;
      }
    }
    
    final mainCategories = categories.where((cat) => cat['parent'] == null).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Text(
          l10n.categoryListPageTitle,
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
        actions: [
          // === DEĞİŞİKLİK BURADA: IconButton, ValueListenableBuilder ile sarmalandı ===
          ValueListenableBuilder<SubscriptionLimits>(
            valueListenable: UserSession.limitsNotifier,
            builder: (context, limits, child) {
              // Mevcut kategori sayısı, abonelik limitinden az ise buton aktiftir.
              final bool canAddMore = categories.length < limits.maxCategories;
              return IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: l10n.tooltipAddCategory,
                // Butonun aktif/pasif durumu anlık olarak `canAddMore`'a bağlıdır.
                onPressed: isLoading || !canAddMore ? null : () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CreateCategoryScreen(
                        token: widget.token,
                        businessId: widget.businessId,
                      ),
                    ),
                  );
                  fetchCategories();
                },
              );
            },
          ),
        ],
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
                  ? Center(child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(displayErrorMessage, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16), textAlign: TextAlign.center),
                    ))
                  : mainCategories.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(l10n.noCategoriesAdded, style: const TextStyle(color: Colors.white70, fontSize: 18)),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(0.8),
                                  foregroundColor: Colors.blue.shade900,
                                ),
                                icon: const Icon(Icons.add),
                                label: Text(l10n.buttonAddFirstCategory),
                                onPressed: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CreateCategoryScreen(
                                        token: widget.token,
                                        businessId: widget.businessId,
                                      ),
                                    ),
                                  );
                                  fetchCategories();
                                },
                              )
                            ],
                          )
                        )
                      : RefreshIndicator(
                          onRefresh: fetchCategories,
                          color: Colors.white,
                          backgroundColor: Colors.blue.shade700,
                          child: GridView.builder(
                            padding: const EdgeInsets.all(16),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200,
                              childAspectRatio: 3 / 4,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                            ),
                            itemCount: mainCategories.length,
                            itemBuilder: (BuildContext ctx, index) {
                              return _buildCategoryCard(mainCategories[index], l10n);
                            },
                          ),
                        ),
        ),
      ),
    );
  }
}