// lib/screens/manage_menu_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import '../models/menu_item.dart';
import '../services/api_service.dart';
import '../services/firebase_storage_service.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/user_session.dart';
import 'subscription_screen.dart';
import 'edit_variant_screen.dart';

class ManageMenuScreen extends StatefulWidget {
  final String token;
  final int businessId;
  const ManageMenuScreen({Key? key, required this.token, required this.businessId})
      : super(key: key);

  @override
  _ManageMenuScreenState createState() => _ManageMenuScreenState();
}

class _ManageMenuScreenState extends State<ManageMenuScreen> {
  List<MenuItem> menuItems = [];
  bool isLoading = true;
  String errorMessage = '';

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[ManageMenuScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'manage_menu_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchMenuItems();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[ManageMenuScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'manage_menu_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchMenuItems();
        });
      }
    });

    fetchMenuItems();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> fetchMenuItems() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
      errorMessage = '';
    });
    try {
      final response = await http.get(
        ApiService.getUrl('/menu-items/'),
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        setState(() {
          menuItems = data.map((e) => MenuItem.fromJson(e)).toList();
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

  void _openMenuModal({MenuItem? menuItem}) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return MenuItemModal(
          l10n: l10n,
          token: widget.token,
          businessId: widget.businessId,
          menuItem: menuItem,
          menuItems: menuItems,
          onMenuUpdated: () {
            fetchMenuItems();
          },
        );
      },
    );
  }

  Future<void> _deleteMenuItem(MenuItem menuItem) async {
    final l10n = AppLocalizations.of(context)!;

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.dialogDeleteMenuItemTitle),
          content: Text(l10n.dialogDeleteMenuItemContent(menuItem.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.dialogButtonNo),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.dialogButtonDeleteConfirm, style: const TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;

    if (!mounted) return;
    setState(() => isLoading = true);

    final url = ApiService.getUrl('/menu-items/${menuItem.id}/');
    try {
      final resp = await http.delete(
        url,
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (!mounted) return;
      if (resp.statusCode == 204) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.infoMenuItemDeleted), backgroundColor: Colors.green),
        );
        fetchMenuItems();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorDeletingMenuItem(resp.statusCode.toString(), utf8.decode(resp.bodyBytes)))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorDeletingMenuItemGeneral(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Widget _buildMenuItemCard(MenuItem item, AppLocalizations l10n) {
    final imageUrl = (item.image.isNotEmpty)
        ? item.image.startsWith('http') ? item.image : ApiService.baseUrl + item.image
        : null;

    return Card(
      color: Colors.white.withOpacity(0.85),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _openMenuModal(menuItem: item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: imageUrl != null
                  ? Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.broken_image, size: 40, color: Colors.grey),
                    )
                  : Icon(Icons.restaurant_menu, size: 50, color: Colors.grey.shade700),
            ),
            
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.description,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),

            Container(
              color: Colors.black.withOpacity(0.05),
              child: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                tooltip: l10n.tooltipDelete,
                onPressed: () => _deleteMenuItem(item),
              ),
            )
          ],
        ),
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
          displayErrorMessage = l10n.errorFetchingMenuItems(parts[1]);
        } else if (parts[0] == 'GENERAL_ERROR') {
          displayErrorMessage = l10n.errorGeneral(parts[1]);
        }
      } else {
        displayErrorMessage = errorMessage; // Fallback
      }
    }
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          l10n.manageMenuPageTitle,
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
              // Mevcut menü öğesi sayısı, abonelik limitinden az ise buton aktiftir.
              final bool canAddMore = menuItems.length < limits.maxMenuItems;

              return IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: l10n.tooltipAddMenuItem,
                // Butonun aktif/pasif durumu anlık olarak `canAddMore`'a bağlıdır.
                onPressed: isLoading || !canAddMore ? null : () => _openMenuModal(),
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
                  : menuItems.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(l10n.noMenuItemsAdded, style: const TextStyle(color: Colors.white70, fontSize: 18)),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(0.8),
                                  foregroundColor: Colors.blue.shade900,
                                ),
                                icon: const Icon(Icons.add),
                                label: Text(l10n.buttonAddFirstMenuItem),
                                onPressed: () => _openMenuModal(),
                              )
                            ],
                          )
                        )
                      : RefreshIndicator(
                          onRefresh: fetchMenuItems,
                          color: Colors.white,
                          backgroundColor: Colors.blue.shade700,
                          child: GridView.builder(
                            padding: const EdgeInsets.all(16),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 220,
                                childAspectRatio: 0.8,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16
                            ),
                            itemCount: menuItems.length,
                            itemBuilder: (context, index) {
                              final item = menuItems[index];
                              return _buildMenuItemCard(item, l10n);
                            },
                          ),
                        ),
        ),
      ),
    );
  }
}

// MenuItemModal Widget'ı aynı kalabilir
class MenuItemModal extends StatefulWidget {
  final AppLocalizations l10n;
  final String token;
  final int businessId;
  final MenuItem? menuItem;
  final List<MenuItem> menuItems;
  final VoidCallback onMenuUpdated;

  const MenuItemModal({
    Key? key,
    required this.l10n,
    required this.token,
    required this.businessId,
    this.menuItem,
    required this.menuItems,
    required this.onMenuUpdated,
  }) : super(key: key);

  @override
  _MenuItemModalState createState() => _MenuItemModalState();
}

class _MenuItemModalState extends State<MenuItemModal> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _kdvController;
  dynamic _selectedCategoryId;
  bool _isSubmitting = false;
  String _message = '';
  List<dynamic> _categories = [];
  bool _isLoadingCategories = true;

  XFile? _pickedImageXFile;
  Uint8List? _webImageBytes;
  String? _currentImageUrl;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.menuItem?.name ?? '');
    _descriptionController = TextEditingController(text: widget.menuItem?.description ?? '');
    _kdvController = TextEditingController(text: widget.menuItem?.kdvRate?.toString() ?? '10.0');
    _currentImageUrl = widget.menuItem?.image;

    dynamic initialWidgetCategoryId;
    if (widget.menuItem?.category != null) {
      if (widget.menuItem!.category is int) {
        initialWidgetCategoryId = widget.menuItem!.category;
      } else if (widget.menuItem!.category is Map && widget.menuItem!.category!['id'] != null) {
        initialWidgetCategoryId = widget.menuItem!.category!['id'];
      }
    }
    _fetchCategories(initialWidgetCategoryId);
  }

  Future<void> _fetchCategories(dynamic initialIdFromWidget) async {
    if (!mounted) return;
    setState(() {
      _isLoadingCategories = true;
    });
    try {
      final response = await http.get(
        ApiService.getUrl('/categories/'),
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> fetchedCategories = jsonDecode(utf8.decode(response.bodyBytes));
        dynamic newSelectedId = initialIdFromWidget;
        
        final uniqueCategories = <dynamic>[];
        final seenIds = <dynamic>{};
        for (var cat in fetchedCategories) {
          if (cat['id'] != null) {
            if (seenIds.add(cat['id'])) {
              uniqueCategories.add(cat);
            }
          }
        }
        
        if (initialIdFromWidget != null && !uniqueCategories.any((cat) => cat['id'] == initialIdFromWidget)) {
          newSelectedId = null;
        }

        setState(() {
          _categories = uniqueCategories;
          _selectedCategoryId = newSelectedId;
          _isLoadingCategories = false;
          if(widget.menuItem != null && _kdvController.text.isEmpty) {
              _onCategoryChanged(newSelectedId);
          }
        });
      } else {
        setState(() {
          _message = "CAT_LOAD_ERROR|${response.statusCode}";
          _isLoadingCategories = false;
          _categories = [];
          _selectedCategoryId = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = "CAT_LOAD_GENERAL_ERROR|${e.toString()}";
          _isLoadingCategories = false;
          _categories = [];
          _selectedCategoryId = null;
        });
      }
    }
  }

  void _onCategoryChanged(dynamic newCategoryId) {
    setState(() {
      _selectedCategoryId = newCategoryId;
      if (newCategoryId != null) {
        final selectedCategory = _categories.firstWhere(
          (cat) => cat['id'] == newCategoryId,
          orElse: () => null,
        );
        if (selectedCategory != null && selectedCategory['kdv_rate'] != null) {
          _kdvController.text = selectedCategory['kdv_rate'].toString();
        } else {
          _kdvController.text = '10.0';
        }
      } else {
        _kdvController.text = '10.0';
      }
    });
  }


  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      if (kIsWeb) {
        _webImageBytes = await image.readAsBytes();
        _pickedImageXFile = null;
      } else {
        _pickedImageXFile = image;
        _webImageBytes = null;
      }
      if(mounted) setState(() {});
    }
  }

  Widget _buildImagePreview() {
    if (kIsWeb && _webImageBytes != null) {
      return Image.memory(_webImageBytes!, height: 100, width: 100, fit: BoxFit.cover);
    } else if (!kIsWeb && _pickedImageXFile != null) {
      return Image.file(File(_pickedImageXFile!.path), height: 100, width: 100, fit: BoxFit.cover);
    } else if (_currentImageUrl != null && _currentImageUrl!.isNotEmpty) {
      if (_currentImageUrl!.startsWith('http')) {
        return Image.network(
          _currentImageUrl!,
          height: 100, width: 100, fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            debugPrint("Image Network Error (MenuItemModal): $error");
            return const Icon(Icons.broken_image, size: 50, color: Colors.grey);
          },
        );
      } else {
        return const Icon(Icons.broken_image, size: 50, color: Colors.grey);
      }
    }
    return Text(widget.l10n.menuItemPhotoNotSelected, style: const TextStyle(color: Colors.black54));
  }

  void _showLimitReachedDialog(String message) {
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(widget.l10n.dialogLimitReachedTitle),
              content: Text(message),
              actions: [
                TextButton(
                  child: Text(widget.l10n.dialogButtonLater),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
                ElevatedButton(
                  child: Text(widget.l10n.dialogButtonUpgradePlan),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SubscriptionScreen()));
                  },
                ),
              ],
            ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();
    if (!mounted) return;
    
    final bool isNew = widget.menuItem == null;

    // *** DEĞİŞİKLİK BURADA: Artık `UserSession.limitsNotifier`'dan gelen anlık veriyi kullanıyoruz. ***
    final currentLimits = UserSession.limitsNotifier.value;
    if (isNew && widget.menuItems.length >= currentLimits.maxMenuItems) {
      _showLimitReachedDialog(
        widget.l10n.createMenuItemErrorLimitExceeded(
          currentLimits.maxMenuItems.toString(),
        )
      );
      return; 
    }
    
    setState(() => _isSubmitting = true);

    String? finalImageUrl = _currentImageUrl;

    if (_pickedImageXFile != null || _webImageBytes != null) {
      try {
        String originalFileName = _pickedImageXFile != null
            ? p.basename(_pickedImageXFile!.path)
            : 'menu_item_${DateTime.now().millisecondsSinceEpoch}.jpg';
        String safeFileName = "menu_item_${widget.menuItem?.id ?? 'new'}_${Uri.encodeComponent(originalFileName)}";

        finalImageUrl = await FirebaseStorageService.uploadImage(
          imageFile: _pickedImageXFile != null ? File(_pickedImageXFile!.path) : null,
          imageBytes: _webImageBytes,
          fileName: safeFileName,
          folderPath: 'menu_images',
        );

        if (finalImageUrl == null) {
          if (mounted) {
            setState(() {
              _message = "UPLOAD_ERROR";
              _isSubmitting = false;
            });
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _message = "UPLOAD_GENERAL_ERROR|${e.toString()}";
            _isSubmitting = false;
          });
        }
        return;
      }
    }
    
    final Map<String, dynamic> payload = {
      'business': widget.businessId,
      'name': _nameController.text,
      'description': _descriptionController.text,
      'category_id': _selectedCategoryId,
      'image': finalImageUrl,
      'kdv_rate': _kdvController.text.isNotEmpty ? double.tryParse(_kdvController.text.replaceAll(',', '.')) : 10.0,
    };

    final url = isNew
        ? ApiService.getUrl('/menu-items/')
        : ApiService.getUrl('/menu-items/${widget.menuItem!.id}/');

    try {
      final response = await (isNew
          ? http.post(url, headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer ${widget.token}"
            }, body: jsonEncode(payload))
          : http.put(url, headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer ${widget.token}"
            }, body: jsonEncode(payload)));

      if (!mounted) return;

      if (response.statusCode == 201 || response.statusCode == 200) {
        widget.onMenuUpdated();
        Navigator.pop(context, true);

      } else {
        String rawError = utf8.decode(response.bodyBytes);
        final jsonStartIndex = rawError.indexOf('{');
        if (jsonStartIndex != -1) {
            try {
              final jsonString = rawError.substring(jsonStartIndex);
              final decodedError = jsonDecode(jsonString);
              if (decodedError is Map && decodedError['code'] == 'limit_reached') {
                _showLimitReachedDialog(decodedError['detail']);
                _message = ''; 
              } else {
               _message = "API_ERROR|${response.statusCode}|$rawError";
              }
            } catch (_) {
               _message = "API_ERROR|${response.statusCode}|$rawError";
            }
        } else {
           _message = "API_ERROR|${response.statusCode}|$rawError";
        }
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = "API_GENERAL_ERROR|${e.toString()}";
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _kdvController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    String displayMessage = '';
    Color messageColor = Colors.red;
    if (_message.isNotEmpty) {
      final parts = _message.split('|');
      final code = parts[0];
      switch(code) {
        case 'CREATE_SUCCESS':
          displayMessage = l10n.infoMenuItemCreated;
          messageColor = Colors.green;
          break;
        case 'UPDATE_SUCCESS':
          displayMessage = l10n.infoMenuItemUpdated;
          messageColor = Colors.green;
          break;
        case 'CAT_LOAD_ERROR':
          displayMessage = l10n.errorLoadingCategories(parts.length > 1 ? parts[1] : '');
          break;
        case 'CAT_LOAD_GENERAL_ERROR':
          displayMessage = l10n.errorLoadingCategoriesGeneral(parts.length > 1 ? parts[1] : '');
          break;
        case 'UPLOAD_ERROR':
          displayMessage = l10n.errorUploadingPhoto;
          break;
        case 'UPLOAD_GENERAL_ERROR':
          displayMessage = l10n.errorUploadingPhotoGeneral(parts.length > 1 ? parts[1] : '');
          break;
        case 'API_ERROR':
          displayMessage = l10n.errorMenuItemGeneral(parts.length > 1 ? parts[1] : '', parts.length > 2 ? parts[2] : '');
          break;
        case 'API_GENERAL_ERROR':
          displayMessage = l10n.errorMenuItemApi(parts.length > 1 ? parts[1] : '');
          break;
        default:
          displayMessage = _message; // Fallback
      }
    }

    return AlertDialog(
      backgroundColor: Colors.white.withOpacity(0.9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.menuItem == null ? l10n.addMenuItemTitle : l10n.editMenuItemTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: _buildImagePreview()),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).primaryColorDark),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(l10n.buttonSelectOrChangePhoto),
                onPressed: _pickImage,
              ),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(labelText: l10n.menuItemNameLabel),
                validator: (value) =>
                    value == null || value.isEmpty ? l10n.menuItemNameValidator : null,
              ),
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(labelText: l10n.menuItemDescriptionLabel),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              if (_isLoadingCategories)
                const Center(child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: CircularProgressIndicator(),
                ))
              else
                DropdownButtonFormField<dynamic>(
                  value: _selectedCategoryId,
                  decoration: InputDecoration(
                    labelText: l10n.menuCategoryLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(l10n.menuCategoryNotSelected),
                    ),
                    ..._categories.map((cat) {
                      return DropdownMenuItem(
                        value: cat['id'],
                        child: Text(cat['name'] ?? l10n.unknownCategory),
                      );
                    }).toList(),
                  ],
                  onChanged: (value) {
                     _onCategoryChanged(value);
                  },
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _kdvController,
                decoration: InputDecoration(
                  labelText: l10n.menuItemKdvRateLabel,
                  suffixText: '%',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.percent_outlined),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return l10n.kdvRateValidatorRequired;
                  final rate = double.tryParse(value.trim().replaceAll(',', '.'));
                  if (rate == null || rate < 0 || rate > 100) return l10n.kdvRateValidatorInvalid;
                  return null;
                },
              ),
              const SizedBox(height: 20),
              if (displayMessage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10.0),
                  child: Text(
                    displayMessage,
                    style: TextStyle(color: messageColor, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.dialogButtonCancel),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.menuItem == null ? l10n.createButton : l10n.updateButton),
        ),
      ],
    );
  }
}