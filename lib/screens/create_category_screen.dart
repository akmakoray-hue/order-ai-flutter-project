// lib/screens/create_category_screen.dart
import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // Uint8List için
import 'package:flutter/foundation.dart' show kIsWeb; // Web platformu kontrolü
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http; // Django API'sine veri göndermek için
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/api_service.dart'; // Django API URL'si için
import '../services/firebase_storage_service.dart'; // Yeni Firebase servisi
import 'package:path/path.dart' as p; // Dosya adı için
import '../services/user_session.dart';
import '../screens/subscription_screen.dart';

class CreateCategoryScreen extends StatefulWidget {
  final String token;
  final int businessId;
  const CreateCategoryScreen({Key? key, required this.token, required this.businessId}) : super(key: key);

  @override
  _CreateCategoryScreenState createState() => _CreateCategoryScreenState();
}

class _CreateCategoryScreenState extends State<CreateCategoryScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  dynamic selectedParent;
  bool isLoading = false;
  String message = '';
  bool _isSuccessMessage = false;
  List<dynamic> categories = [];

  XFile? _pickedImageXFile;
  Uint8List? _webImageBytes;

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[CreateCategoryScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'create_category_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchCategories();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[CreateCategoryScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'create_category_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchCategories();
        });
      }
    });

    fetchCategories();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> fetchCategories() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final response = await http.get(
        ApiService.getUrl('/categories/'),
        headers: {"Authorization": "Bearer ${widget.token}"},
      );
      if (mounted && response.statusCode == 200) {
        setState(() {
          categories = jsonDecode(utf8.decode(response.bodyBytes));
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = l10n.createCategoryErrorLoadingParents(e.toString());
          _isSuccessMessage = false;
        });
      }
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      if (kIsWeb) {
        _webImageBytes = await image.readAsBytes();
      }
      setState(() {
        _pickedImageXFile = image;
      });
    }
  }

  Widget _buildImagePreview() {
    final l10n = AppLocalizations.of(context)!;
    if (kIsWeb) {
      if (_webImageBytes != null) {
        return Image.memory(_webImageBytes!, height: 100, width: 100, fit: BoxFit.cover);
      }
    } else {
      if (_pickedImageXFile != null) {
        return Image.file(File(_pickedImageXFile!.path), height: 100, width: 100, fit: BoxFit.cover);
      }
    }
    return Text(l10n.createCategoryPhotoNotSelected, style: const TextStyle(color: Colors.white70));
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
  
  Future<void> createCategory() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context)!;

    // *** DEĞİŞİKLİK BURADA: Artık `UserSession.limitsNotifier`'dan gelen anlık veriyi kullanıyoruz. ***
    final currentLimits = UserSession.limitsNotifier.value;
    if (categories.length >= currentLimits.maxCategories) {
      _showLimitReachedDialog(
        l10n.createCategoryErrorLimitExceeded(
          currentLimits.maxCategories.toString(),
        )
      );
      return; 
    }

    setState(() {
      isLoading = true;
      message = '';
    });

    String? imageUrl;

    if (_pickedImageXFile != null || _webImageBytes != null) {
      try {
        String fileName = _pickedImageXFile != null
            ? p.basename(_pickedImageXFile!.path)
            : 'category_image_${DateTime.now().millisecondsSinceEpoch}.jpg';

        imageUrl = await FirebaseStorageService.uploadImage(
          imageFile: _pickedImageXFile != null ? File(_pickedImageXFile!.path) : null,
          imageBytes: _webImageBytes,
          fileName: fileName,
          folderPath: 'category_images',
        );

        if (imageUrl == null) {
          if (mounted) {
            setState(() {
              message = l10n.errorFirebaseUploadFailed;
              _isSuccessMessage = false;
              isLoading = false;
            });
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            message = l10n.errorUploadingPhotoGeneral(e.toString());
            _isSuccessMessage = false;
            isLoading = false;
          });
        }
        return;
      }
    }

    try {
      final Map<String, dynamic> payload = {
        'business': widget.businessId,
        'name': _nameController.text,
        if (selectedParent != null) 'parent': selectedParent['id'],
        if (imageUrl != null) 'image': imageUrl,
      };

      final response = await http.post(
        ApiService.getUrl('/categories/'),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${widget.token}"
        },
        body: jsonEncode(payload),
      );

      if (mounted) {
        if (response.statusCode == 201) {
          setState(() {
            message = l10n.createCategorySuccess;
            _isSuccessMessage = true;
            _nameController.clear();
            selectedParent = null;
            _pickedImageXFile = null;
            _webImageBytes = null;
          });
          await fetchCategories();
        } else {
          String rawError = utf8.decode(response.bodyBytes);
          final jsonStartIndex = rawError.indexOf('{');
          if (jsonStartIndex != -1) {
            try {
              final jsonString = rawError.substring(jsonStartIndex);
              final decodedError = jsonDecode(jsonString);
              if (decodedError is Map && decodedError['code'] == 'limit_reached') {
                _showLimitReachedDialog(decodedError['detail']);
                message = ''; 
              } else {
                message = l10n.createCategoryError(response.statusCode.toString(), rawError);
              }
            } catch (_) {
              message = l10n.createCategoryError(response.statusCode.toString(), rawError);
            }
          } else {
            message = l10n.createCategoryError(response.statusCode.toString(), rawError);
          }
          setState(() {
            _isSuccessMessage = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = l10n.errorMenuItemApi(e.toString());
          _isSuccessMessage = false;
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          l10n.createCategoryScreenTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              color: Colors.white.withOpacity(0.85),
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _nameController,
                        style: const TextStyle(color: Colors.black87),
                        decoration: InputDecoration(
                          labelText: l10n.categoryNameLabelRequired,
                          labelStyle: const TextStyle(color: Colors.black54),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.7),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return l10n.categoryNameValidator;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<dynamic>(
                        value: selectedParent,
                        decoration: InputDecoration(
                          labelText: l10n.parentCategoryLabel,
                          labelStyle: const TextStyle(color: Colors.black54),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.7),
                        ),
                        dropdownColor: Colors.grey[200],
                        items: [
                          DropdownMenuItem(
                            value: null,
                            child: Text(l10n.parentCategoryHint, style: const TextStyle(color: Colors.black54)),
                          ),
                          ...categories.map((cat) {
                            return DropdownMenuItem(
                              value: cat,
                              child: Text(cat['name'] ?? l10n.unknownCategory, style: const TextStyle(color: Colors.black87)),
                            );
                          }).toList(),
                        ],
                        onChanged: (value) {
                          setState(() {
                            selectedParent = value;
                          });
                        },
                      ),
                      const SizedBox(height: 20),
                      Center(child: _buildImagePreview()),
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: Colors.blue.shade800),
                        onPressed: _pickImage,
                        icon: const Icon(Icons.image_outlined),
                        label: Text(l10n.buttonSelectOrChangePhoto),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: isLoading ? null : createCategory,
                        child: isLoading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                            : Text(l10n.createCategoryButton, style: const TextStyle(fontSize: 16, color: Colors.white)),
                      ),
                      const SizedBox(height: 16),
                      if (message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10.0),
                          child: Text(
                            message,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _isSuccessMessage ? Colors.green.shade700 : Colors.red.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}