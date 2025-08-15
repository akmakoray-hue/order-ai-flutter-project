// lib/screens/manage_variant_screen.dart
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
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/firebase_storage_service.dart';
import '../models/menu_item_variant.dart';
import 'edit_variant_screen.dart';
import '../services/user_session.dart';
import 'subscription_screen.dart';
import '../utils/currency_formatter.dart';

class ManageVariantScreen extends StatefulWidget {
  final String token;
  final int menuItemId;
  const ManageVariantScreen({Key? key, required this.token, required this.menuItemId})
      : super(key: key);

  @override
  _ManageVariantScreenState createState() => _ManageVariantScreenState();
}

class _ManageVariantScreenState extends State<ManageVariantScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _variantNameController = TextEditingController();
  final TextEditingController _variantPriceController = TextEditingController();
  bool _isSubmitting = false;
  String _messageCode = '';
  bool _isExtra = false;
  List<MenuItemVariant> _variants = [];
  bool _isLoadingVariants = true;

  XFile? _pickedImageXFile;
  Uint8List? _webImageBytes;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[ManageVariantScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'manage_variant_screen_${widget.menuItemId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchVariants();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[ManageVariantScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'manage_variant_screen_active_${widget.menuItemId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchVariants();
        });
      }
    });

    _fetchVariants();
  }

  @override
  void dispose() {
    _variantNameController.dispose();
    _variantPriceController.dispose();
    super.dispose();
  }

  Future<void> _fetchVariants() async {
    if (!mounted) return;
    setState(() {
      _isLoadingVariants = true;
      _messageCode = '';
    });
    try {
      final url = ApiService.getUrl('/menu-item-variants/').replace(
        queryParameters: {'menu_item': widget.menuItemId.toString()},
      );
      final response = await http.get(
        url,
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));
        setState(() {
          _variants = data
              .map((json) => MenuItemVariant.fromJson(json))
              .toList();
        });
      } else {
        setState(() {
          _messageCode = "FETCH_ERROR|${response.statusCode}";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messageCode = "FETCH_GENERAL_ERROR|${e.toString()}";
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingVariants = false;
        });
      }
    }
  }

  Future<void> _pickVariantImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      if (kIsWeb) {
        _webImageBytes = await image.readAsBytes();
        _pickedImageXFile = null;
      } else {
        _pickedImageXFile = image;
        _webImageBytes = null;
      }
      setState(() {});
    }
  }

  Widget _buildImagePreview(AppLocalizations l10n) {
    if (kIsWeb && _webImageBytes != null) {
      return Image.memory(_webImageBytes!, height: 100, width: 100, fit: BoxFit.cover);
    } else if (!kIsWeb && _pickedImageXFile != null) {
      return Image.file(File(_pickedImageXFile!.path), height: 100, width: 100, fit: BoxFit.cover);
    }
    return Text(l10n.variantPhotoNotSelected, style: const TextStyle(color: Colors.black54));
  }

  void _showLimitReachedDialog(String message) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.dialogLimitReachedTitle),
        content: Text(message),
        actions: [
          TextButton(
            child: Text(l10n.dialogButtonLater),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ElevatedButton(
            child: Text(l10n.dialogButtonUpgradePlan),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SubscriptionScreen()));
            },
          ),
        ],
      ),
    );
  }

  Future<void> _addVariant() async {
    if (!_formKey.currentState!.validate()) return;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;

    // *** DEĞİŞİKLİK BURADA: Artık `UserSession.limitsNotifier`'dan gelen anlık veriyi kullanıyoruz. ***
    final currentLimits = UserSession.limitsNotifier.value;
    if (_variants.length >= currentLimits.maxVariants) {
      _showLimitReachedDialog(
        l10n.createVariantErrorLimitExceeded(currentLimits.maxVariants.toString())
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _messageCode = '';
    });

    String? imageUrl;

    if (_pickedImageXFile != null || _webImageBytes != null) {
      try {
        String originalFileName = _pickedImageXFile != null
            ? p.basename(_pickedImageXFile!.path)
            : 'variant_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
        String safeFileName = "menu_${widget.menuItemId}_variant_${DateTime.now().millisecondsSinceEpoch}_${Uri.encodeComponent(originalFileName)}";

        imageUrl = await FirebaseStorageService.uploadImage(
          imageFile: _pickedImageXFile != null ? File(_pickedImageXFile!.path) : null,
          imageBytes: _webImageBytes,
          fileName: safeFileName,
          folderPath: 'variant_images',
        );

        if (imageUrl == null) {
          if (mounted) {
            setState(() {
              _messageCode = "UPLOAD_ERROR";
              _isSubmitting = false;
            });
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _messageCode = "UPLOAD_GENERAL_ERROR|${e.toString()}";
            _isSubmitting = false;
          });
        }
        return;
      }
    }

    try {
      final Map<String, dynamic> payload = {
        'menu_item': widget.menuItemId,
        'name': _variantNameController.text,
        'price': (double.tryParse(_variantPriceController.text.replaceAll(',', '.')) ?? 0.0).toString(),
        'is_extra': _isExtra,
        if (imageUrl != null) 'image': imageUrl,
      };

      final response = await http.post(
        ApiService.getUrl('/menu-item-variants/'),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${widget.token}"
        },
        body: jsonEncode(payload),
      );

      if (mounted) {
        if (response.statusCode == 201) {
          _variantNameController.clear();
          _variantPriceController.clear();
          setState(() {
            _messageCode = "ADD_SUCCESS";
            _isExtra = false;
            _pickedImageXFile = null;
            _webImageBytes = null;
          });
          _fetchVariants();
        } else {
          String rawError = utf8.decode(response.bodyBytes);
          final jsonStartIndex = rawError.indexOf('{');
          if (jsonStartIndex != -1) {
            try {
              final jsonString = rawError.substring(jsonStartIndex);
              final decodedError = jsonDecode(jsonString);
              if (decodedError is Map && decodedError['code'] == 'limit_reached') {
                _showLimitReachedDialog(decodedError['detail']);
                _messageCode = '';
              } else {
                _messageCode = "ADD_API_ERROR|${response.statusCode}|$rawError";
              }
            } catch (_) {
              _messageCode = "ADD_API_ERROR|${response.statusCode}|$rawError";
            }
          } else {
            _messageCode = "ADD_API_ERROR|${response.statusCode}|$rawError";
          }
          setState(() {});
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messageCode = "ADD_GENERAL_ERROR|${e.toString()}";
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _deleteVariant(MenuItemVariant variant) async {
    final l10n = AppLocalizations.of(context)!;
    bool? confirmDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(l10n.dialogDeleteVariantTitle),
          content: Text(l10n.dialogDeleteVariantContent(variant.name)),
          actions: <Widget>[
            TextButton(
              child: Text(l10n.dialogButtonCancel),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: Text(l10n.dialogButtonDelete, style: const TextStyle(color: Colors.red)),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (confirmDelete != true) return;

    if (!mounted) return;
    setState(() => _isSubmitting = true);

    final url = ApiService.getUrl('/menu-item-variants/${variant.id}/');
    try {
      final response = await http.delete(
        url,
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (!mounted) return;
      if (response.statusCode == 204) {
        setState(() {
          _messageCode = "DELETE_SUCCESS";
        });
        _fetchVariants();
      } else {
        setState(() {
          _messageCode = "DELETE_API_ERROR|${response.statusCode}|${utf8.decode(response.bodyBytes)}";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messageCode = "DELETE_GENERAL_ERROR|${e.toString()}";
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Widget _buildVariantCard(MenuItemVariant variant, AppLocalizations l10n) {
    String? imageUrl;
    if (variant.image.isNotEmpty) {
      imageUrl = variant.image.startsWith('http')
          ? variant.image
          : ApiService.baseUrl + variant.image;
    }

    return Card(
      color: Colors.white.withOpacity(0.85),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EditVariantScreen(
                token: widget.token,
                variant: variant,
                onVariantUpdated: _fetchVariants,
              ),
            ),
          );
        },
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
                  : Icon(variant.isExtra ? Icons.add_shopping_cart : Icons.label, size: 50, color: Colors.grey.shade700),
            ),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      variant.name + (variant.isExtra ? l10n.variantExtraSuffix : ""),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      CurrencyFormatter.format(variant.price),
                      style: TextStyle(fontSize: 14, color: Colors.green.shade800, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              color: Colors.black.withOpacity(0.05),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 20),
                    tooltip: l10n.tooltipEdit,
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EditVariantScreen(
                            token: widget.token,
                            variant: variant,
                            onVariantUpdated: _fetchVariants,
                          ),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                    tooltip: l10n.tooltipDelete,
                    onPressed: () => _deleteVariant(variant),
                  ),
                ],
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
    String displayMessage = '';
    Color messageColor = Colors.red.shade300;

    if (_messageCode.isNotEmpty) {
      final parts = _messageCode.split('|');
      final code = parts[0];
      switch(code) {
        case 'FETCH_ERROR':
          displayMessage = l10n.errorFetchingVariants(parts.length > 1 ? parts[1] : '');
          break;
        case 'FETCH_GENERAL_ERROR':
          displayMessage = l10n.errorFetchingVariantsGeneral(parts.length > 1 ? parts[1] : '');
          break;
        case 'ADD_SUCCESS':
          displayMessage = l10n.infoVariantAddedSuccess;
          messageColor = Colors.green.shade300;
          break;
        case 'ADD_API_ERROR':
          displayMessage = l10n.errorAddingVariant(parts.length > 1 ? parts[1] : '', parts.length > 2 ? parts[2] : '');
          break;
        case 'ADD_GENERAL_ERROR':
        case 'UPLOAD_GENERAL_ERROR':
          displayMessage = l10n.errorAddingVariantGeneral(parts.length > 1 ? parts[1] : '');
          break;
        case 'UPLOAD_ERROR':
          displayMessage = l10n.errorUploadingPhoto;
          break;
        case 'DELETE_SUCCESS':
          displayMessage = l10n.infoVariantDeletedSuccess;
          messageColor = Colors.green.shade300;
          break;
        case 'DELETE_API_ERROR':
          displayMessage = l10n.errorDeletingVariant(parts.length > 1 ? parts[1] : '', parts.length > 2 ? parts[2] : '');
          break;
        case 'DELETE_GENERAL_ERROR':
          displayMessage = l10n.errorDeletingVariantGeneral(parts.length > 1 ? parts[1] : '');
          break;
        default:
          displayMessage = _messageCode;
      }
    }
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.manageVariantPageTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
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
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Card(
                  color: Colors.white.withOpacity(0.85),
                  elevation: 8,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _variantNameController,
                            style: const TextStyle(color: Colors.black87),
                            decoration: InputDecoration(
                              labelText: l10n.variantNameLabel,
                              labelStyle: const TextStyle(color: Colors.black54),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.7),
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return l10n.variantNameValidator;
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _variantPriceController,
                            style: const TextStyle(color: Colors.black87),
                            decoration: InputDecoration(
                              labelText: l10n.variantPriceLabel,
                              labelStyle: const TextStyle(color: Colors.black54),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.7),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*[\.,]?\d{0,2}'))],
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return l10n.variantPriceValidator;
                              }
                              if (double.tryParse(value.replaceAll(',', '.')) == null) {
                                return l10n.variantPriceValidatorInvalid;
                              }
                              return null;
                            },
                          ),
                          CheckboxListTile(
                            title: Text(l10n.variantIsExtraLabel, style: const TextStyle(color: Colors.black87)),
                            value: _isExtra,
                            onChanged: (bool? newVal) {
                              setState(() {
                                _isExtra = newVal ?? false;
                              });
                            },
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: Colors.indigo,
                            tileColor: Colors.white.withOpacity(0.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          const SizedBox(height: 12),
                          Center(child: _buildImagePreview(l10n)),
                          TextButton.icon(
                            style: TextButton.styleFrom(foregroundColor: Colors.indigo),
                            onPressed: _pickVariantImage,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(l10n.buttonSelectPhoto),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.indigo,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: _isSubmitting ? null : _addVariant,
                            child: _isSubmitting
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                                : Text(l10n.buttonAddVariant, style: const TextStyle(fontSize: 16, color: Colors.white)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (displayMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical:8.0),
                    child: Text(
                      displayMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: messageColor,
                          fontWeight: FontWeight.bold
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Text(l10n.currentVariantsTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                Expanded(
                  child: _isLoadingVariants
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : _variants.isEmpty
                          ? Center(child: Text(l10n.noVariantsAdded, style: const TextStyle(color: Colors.white70)))
                          : RefreshIndicator(
                              onRefresh: _fetchVariants,
                              child: GridView.builder(
                                padding: const EdgeInsets.only(top: 16.0),
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 200,
                                  childAspectRatio: 0.8,
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 16
                                ),
                                itemCount: _variants.length,
                                itemBuilder: (context, index) {
                                  final variant = _variants[index];
                                  return _buildVariantCard(variant, l10n);
                                },
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